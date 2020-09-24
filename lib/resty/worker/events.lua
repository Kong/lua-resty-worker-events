local ngx = ngx
local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local new_timer = ngx.timer.at
local tostring = tostring
local ipairs = ipairs
local pcall = pcall
local xpcall = xpcall
local cjson = require("cjson.safe").new()
local get_pid = ngx.worker.pid
local now = ngx.now
local sleep = ngx.sleep
local exiting = ngx.worker.exiting
local traceback = debug.traceback
local assert = assert
local select = select
local type = type
local error = error
local pairs = pairs
local setmetatable = setmetatable
local getmetatable = getmetatable
local next = next
local min = math.min

-- event keys to shm
local KEY_LAST_ID = "events-last"         -- ID of last event posted
local KEY_DATA    = "events-data:"        -- serialized event json data
local KEY_ONE     = "events-one:"         -- key for 'one' events check

-- constants
local SLEEP_INTERVAL = 0.5 -- sleep step in the timer loop (in seconds)

-- globals as upvalues (module is intended to run once per worker process)
local _dict           -- the shared dictionary to use
local _unique_timeout -- expire time for unique data posted in shm (seconds)
local _interval       -- polling interval (in seconds)
local _pid = get_pid()
local _last_event     -- event id of the last event handled
local _wait_max       -- how long (in seconds) to wait when we have an event id,
                      -- but no data, for the data to show up.
local _wait_interval  -- interval between tries when event data is unavailable
local _shm_retries    -- retries for "no memory" shm fragmentation

--local dump = function(...)
--  ngx.log(ngx.DEBUG,"\027[31m", require("pl.pretty").write({...}),"\027[0m")
--end

do
  -- test whether xpcall is 5.2 compatible, and supports extra arguments
  local xpcall_52 = xpcall(function(x)
      assert(x == 1)
    end, function() end, 1)

  if not xpcall_52 then
    -- No support for extra args, so need to wrap xpcall
    local _xpcall = xpcall
    local unpack = unpack or table.unpack   -- luacheck: ignore
    xpcall = function(f, eh, ...)
      local args = { n = select("#", ...), ...}
      return _xpcall(function()
                       return f(unpack(args, 1, args.n))
                     end, eh)
    end
  end
end

-- defaults
local DEFAULT_UNIQUE_TIMEOUT = 2
local DEFAULT_INTERVAL = 1
local DEFAULT_WAIT_MAX = 0.5
local DEFAULT_WAIT_INTERVAL = 0.010
local DEFAULT_SHM_RETRIES = 999

-- creates a new level structure for the callback tree
local new_struct = function()
  return {
    weak_count = 0,
    weak_list = setmetatable({},{ __mode = "v"}),
    strong_count = 0,
    strong_list = {},
    subs = {} -- nested sub tables; source based, and event based
              -- (initial one is global)
  }
end
-- metatable that auto creates sub tables if a key is not found
-- __index function to do the auto table magic
local autotable__index = function(self, key)
  local mt = getmetatable(self)
  local t = new_struct()
  if mt.depth ~= 1 then
    setmetatable(t.subs, {
        __index = mt.__index,
        depth = mt.depth - 1,
    })
  end
  self[key] = t
  return t
end

--- Creates a new auto-table.
-- @param depth (optional, default 1) how deep to auto-generate tables.
-- The last table in the chain generated will itself not be an auto-table.
-- If `depth == 0` then there is no limit.
-- @param mode (optional) set the weak table behavior
-- @return new auto-table
local function autotable(depth)

  local at = new_struct()
  setmetatable(at.subs, {
            __index = autotable__index,
            depth = depth,
          })
  return at
end

-- callbacks
local _callbacks = autotable(2)
-- strong/weak; array = global handlers called on every event
-- strong/weak; hash  = subtables for a specific eventsource
-- eventsource-sub-table has the same structure, except the hash part contains
-- not 'eventsource', but 'event' specific handlers, no more sub tables

local local_event_queue = {}

local _M = {
  _VERSION = '2.0.0',
}


-- gets current event id
-- @return event_id
local function get_event_id()
  return _dict:get(KEY_LAST_ID) or 0
end

-- gets event data
-- @return event_id, or nil+error
local function get_event_data(event_id)
  return _dict:get(KEY_DATA..tostring(event_id))
end

-- posts a new event in shm
local function post_event(source, event, data, unique)
  local json, err, event_id, success, retries

  json, err = cjson.encode({
    source = source,
    event = event,
    data = data,
    unique = unique,
    pid = _pid,
  })
  if not json then return json, err end

  _dict:add(KEY_LAST_ID, 0)
  event_id, err = _dict:incr(KEY_LAST_ID, 1)
  if err then return event_id, err end

  retries = 0
  while not success and retries <= _shm_retries do
    success, err = _dict:add(KEY_DATA..tostring(event_id), json)
    if success then
      return event_id

    elseif err ~= "no memory" then
      return success, err

    elseif retries >= _shm_retries then
      log(WARN, "worker-events: could not write to shm after ", retries + 1,
                " tries (no memory), it is either fragmented or cannot ",
                "allocate more memory, consider increasing ",
                "'opts.shm_retries'. Payload size: ", #json, " bytes, ",
                "source: '", tostring(source), "', event: '", tostring(event))
      return success, err
    end

    retries = retries + 1
  end
  -- unreachable
end


local function do_handlerlist(handler_list, source, event, data, pid)
  local err, success

  local count_key = "weak_count"
  local list_key = "weak_list"
  while true do
    local i = 1
    local list = handler_list[list_key]
    while i <= handler_list[count_key] do
      local handler = list[i]
      if type(handler) ~= "function" then
        -- handler was removed, unregistered, or GC'ed, cleanup.
        -- Entry is nil, but recreated as a table due to the auto-table
        list[i] = list[handler_list[count_key]]
        list[handler_list[count_key]] = nil
        handler_list[count_key] = handler_list[count_key] - 1
      else
        success, err = xpcall(handler, traceback, data, event, source, pid)
        if not success then
          local d, e
          if type(data) == "table" then
            d, e = cjson.encode(data)
            if not d then d = tostring(e) end
          else
            d = tostring(data)
          end
          log(ERR, "worker-events: event callback failed; source=",source,
                 ", event=", event,", pid=",pid, " error='", tostring(err),
                 "', data=", d)
        end
        i = i + 1
      end
    end
    if list_key == "strong_list" then
      return
    end
    count_key = "strong_count"
    list_key = "strong_list"
  end
end


local function do_event(source, event, data, pid)
  log(DEBUG, "worker-events: handling event; source=",source,
      ", event=", event, ", pid=", pid) --,", data=",tostring(data))
      -- do not log potentially private data, hence skip 'data'

  local list = _callbacks
  do_handlerlist(list, source, event, data, pid)
  list = list.subs[source]
  do_handlerlist(list, source, event, data, pid)
  list = list.subs[event]
  do_handlerlist(list, source, event, data, pid)
end


-- for 'one' events, returns `true` when this worker is supposed to handle it
local function mine_to_have(id, unique)
  local key = KEY_ONE .. tostring(unique)
  local success, err = _dict:add(key, _pid, _unique_timeout)

  if success then return true end

  if err == "exists"  then
    log(DEBUG, "worker-events: skipping event ",id," was handled by worker ",
          _dict:get(key))
  else
    log(ERR, "worker-events: cannot determine who handles event ", id,
             ", dropping it: ", err)
  end
end

-- Handle incoming json based event
local function do_event_json(id, json)
  local d, err
  d, err = cjson.decode(json)
  if not d then
    return log(ERR, "worker-events: failed decoding json event data: ", err)
  end

  if d.unique and not mine_to_have(id, d.unique) then return end

  return do_event(d.source, d.event, d.data, d.pid)
end

-- Posts a new event.
-- @param source string identifying the event source
-- @param event string identifying the event name
-- @param data the data for the event, anything as long as it can be used
-- with cjson
-- @param unique a unique identifier for this event, providing it will make
-- only 1
-- worker execute the event
-- @return true if the event was successfully posted, nil+error if there was an
-- error posting the event
_M.post = function(source, event, data, unique)
  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end

  if type(event) ~= "string" or event == "" then
    return nil, "event is required"
  end

  local success, err = post_event(source, event, data, unique)
  if not success then
    err = 'failed posting event "' .. event .. '" by "' ..
          source .. '"; ' .. tostring(err)
    log(ERR, "worker-events: ", err)
    return nil, err
  end

  return true
end

-- Similar to `post`. The event will only be handled in the worker
-- it was posted from, it will not be broadcasted to other worker processes.
-- @return `true` or nil+error
_M.post_local = function(source, event, data)
  if type(source) ~= "string" or source == "" then
    return nil, "source is required"
  end
  if type(event) ~= "string" or event == "" then
    return nil, "event is required"
  end

  local_event_queue[#local_event_queue + 1] = {
    source = source,
    event = event,
    data = data,
  }

  return true
end

-- flag to indicate we're already in a polling loop
local _busy_polling

-- poll for events and execute handlers
-- @return `"done"` when all is done, `"recursive"` if a loop is already
-- running, or `nil+error`
_M.poll = function()
  if _busy_polling then
    -- we're probably calling the `poll` method from an event
    -- handler (by posting an event from an event handler for example)
    -- so we cannot handle it here right now.
    return "recursive"
  end

  while #local_event_queue > 0 do
    -- exchange queue with a new one, so we can post new ones while
    -- dealing with existing ones
    local queue = local_event_queue
    local_event_queue = {}

    -- deal with local events
    for i, data in ipairs(queue) do
      _busy_polling = true -- need to flag to make sure the eventhandlers do not re-enter
      do_event(data.source, data.event, data.data, nil)
      _busy_polling = nil
    end
  end

  local event_id, err = get_event_id()
  if event_id <= _last_event then
    -- if event_id < _last_event then a reload is executed whilst clearing the SHM
    return "done"
  end

  if not event_id then
    local err = "failed to get current event id: " .. tostring(err)
    log(ERR, "worker-events: ", err)
    return nil, err
  end

  local count = 0
  local cache_data = {}
  local cache_err = {}
  -- in case an event id has been published, but we're fetching it before
  -- its data was posted and we have to wait, we don't want the next
  -- event to timeout before we get to it, so go and cache what's
  -- available, to minimize lost data
  while _last_event < event_id do
    count = count + 1
    _last_event = _last_event + 1
    --debug("fetching event", _last_event)
    cache_data[count], cache_err[count] = get_event_data(_last_event)
  end

  local expire = now() + _wait_max
  for idx = 1, count do
    local data = cache_data[idx]
    local err = cache_err[idx]
    while not data do
      if err then
        log(ERR, "worker-events: error fetching event data: ", err)
        break
      else
        -- just nil, so must wait for data to appear
        if now() >= expire then
          break
        end
        -- wait and retry
        -- if the `sleep` function is unavailable in the current openresty
        -- 'context' (eg. 'init_worker'), then the pcall fails. We're not
        -- checking the result, but will effectively be doing a busy-wait
        -- by looping until it hits the time-out, or the data is retrieved
        _busy_polling = true  -- need to flag because `sleep` will yield control
                              -- and another coroutine might re-enter
        pcall(sleep, _wait_interval)
        _busy_polling = nil
        data, err = get_event_data(_last_event - count + idx)
      end
    end

    if data then
      _busy_polling = true -- need to flag to make sure the eventhandlers
                           -- do not re-enter
      do_event_json(_last_event - count + idx, data)
      _busy_polling = nil
    else
      log(ERR, "worker-events: dropping event; waiting for event data ",
          "timed out, id: ", _last_event - count + idx)
    end
  end

  -- in case we waited, recurse to handle any new pending events
  return _M.poll()
end

-- executes a polling loop
local function do_timer(premature)
  while true do
    if premature then
      _M.post(_M.events._source, _M.events.stopping)
    end

    local ok, err = _M.poll()
    if not ok then
      log(ERR, "worker-events: timer-poll returned: ", err)
    end

    if _interval == 0 or premature then
      break  -- exit overall timer loop
    end

    local sleep_left = _interval
    while sleep_left > 0 do
      sleep(min(sleep_left, SLEEP_INTERVAL))
      sleep_left = sleep_left - SLEEP_INTERVAL

      if exiting() then
        premature = true
        break  -- exit sleep loop only
      end
    end
  end
end

-- @param mode either "weak" or "strong"
local register = function(callback, mode, source, ...)
  assert(type(callback) == "function", "expected function, got: "..
         type(callback))

  local count_key, list_key
  if mode == "weak" then
    count_key = "weak_count"
    list_key = "weak_list"
  else
    count_key = "strong_count"
    list_key = "strong_list"
  end

  if not source then
    -- register as global event handler
    local list = _callbacks
    local n = list[count_key] + 1
    list[count_key] = n
    list[list_key][n] = callback
  else
    local events = {...}
    if #events == 0 then
      -- register as an eventsource handler
      local list = _callbacks.subs[source]
      local n = list[count_key] + 1
      list[count_key] = n
      list[list_key][n] = callback
    else
      -- register as an event specific handler, for multiple events
      for _, event in ipairs(events) do
        local list = _callbacks.subs[source].subs[event]
        local n = list[count_key] + 1
        list[count_key] = n
        list[list_key][n] = callback
      end
    end
  end
  return true
end


-- registers an event handler callback.
-- signature; callback(source, event, data, originating_pid)
-- @param callback the eventhandler callback to add
-- @param source (optional) if given only this source is being called for
-- @param ... (optional) event names (0 or more) to register for
-- @return true
_M.register = function(callback, source, ...)
  register(callback, "strong", source, ...)
end

-- registers a weak-event handler callback.
-- Workerevents will maintain a weak reference to the handler.
-- signature; callback(source, event, data, originating_pid)
-- @param callback the eventhandler callback to add
-- @param source (optional) if given only this source is being called for
-- @param ... (optional) event names (0 or more) to register for
-- @return true
_M.register_weak = function(callback, source, ...)
  register(callback, "weak", source, ...)
end

-- unregisters an event handler callback.
-- Will remove both the weak and strong references.
-- @param callback the eventhandler callback to remove
-- @return `true` if it was removed, `false` if it was not in the list.
-- If multiple eventnames have been specified, `true` means at least 1
-- occurrence was removed
_M.unregister = function(callback, source, ...)
  assert(type(callback) == "function", "expected function, got: "..
         type(callback))

  local success
  local count_key = "weak_count"
  local list_key = "weak_list"
  -- NOTE: we only set entries to `nil`, the event runner will
  -- cleanup and remove those entries to 'heal' the lists
  while true do
    local list = _callbacks
    if not source then
      -- remove as global event handler
      for i = 1, list[count_key] do
        local cb = list[list_key][i]
        if cb == callback then
          list[list_key][i] = nil
          success = true
        end
      end
    else
      local events = {...}
      if not next(events) then
        -- remove as an eventsource handler
        local target = list.subs[source]
        for i = 1, target[count_key] do
          local cb = target[list_key][i]
          if cb == callback then
            target[list_key][i] = nil
            success = true
          end
        end
      else
        -- remove as an event specific handler, for multiple events
        for _, event in ipairs(events) do
          local target = list.subs[source].subs[event]
          for i = 1, target[count_key] do
            local cb = target[list_key][i]
            if cb == callback then
              target[list_key][i] = nil
              success = true
            end
          end
        end
      end
    end
    if list_key == "strong_list" then
      break
    end
    count_key = "strong_count"
    list_key = "strong_list"
  end

  return (success == true)
end

-- (re) configures the event system
-- shm     : name of the shared memory to use
-- timeout : timeout of event data stored in shm (in seconds)
-- interval: interval to poll for events (in seconds)
-- wait_interval : interval between two tries when an eventid is found,
-- but no data.
-- wait_max: max time to wait for data when event id is found, before discarding
-- shm_retries: how often to retry when the shm gives an "out of memory" when posting
-- debug   : if true a value `_callbacks` is exported on the module table
_M.configure = function(opts)
  assert(type(opts) == "table", "Expected a table, got "..type(opts))

  local started = _dict ~= nil

  if get_pid() ~= _pid then
    -- pid changed, so new process was forked, must reset
    _pid = get_pid()
    --_dict = nil     -- this value can actually stay, because its shared
    _interval = nil
    _unique_timeout = nil
    _callbacks = autotable(2)
    _wait_max = nil
    _wait_interval = nil
    _shm_retries = nil
    started = nil
  end

  local shm = opts.shm
  if shm and (_dict ~= nil) then
    return nil, "Already started, cannot change shm"
  end
  if not (shm or _dict) then
    return nil, '"shm" option required to start'
  end

  local dict = ngx.shared[shm]
  if not dict then
    return nil, 'shm "' .. tostring(shm) .. '" not found'
  end

  local unique_timeout = opts.timeout or
                         (_unique_timeout or DEFAULT_UNIQUE_TIMEOUT)
  if type(unique_timeout) ~= "number" and unique_timeout ~= nil then
    return nil, 'optional "timeout" option must be a number'
  end
  if unique_timeout <= 0 then
    return nil, '"timeout" must be greater than 0'
  end

  local interval = opts.interval or (_interval or DEFAULT_INTERVAL)
  if type(interval) ~= "number" and interval ~= nil then
    return nil, 'optional "interval" option must be a number'
  end
  if interval < 0 then
    return nil, '"interval" must be greater than or equal to 0'
  end

  local wait_interval = opts.wait_interval or (_wait_interval or
                        DEFAULT_WAIT_INTERVAL)
  if type(wait_interval) ~= "number" and wait_interval ~= nil then
    return nil, 'optional "wait_interval" option must be a number'
  end
  if wait_interval < 0 then
    return nil, '"wait_interval" must be greater than or equal to 0'
  end

  local wait_max = opts.wait_max or (_wait_max or DEFAULT_WAIT_MAX)
  if type(wait_max) ~= "number" and wait_max ~= nil then
    return nil, 'optional "wait_max" option must be a number'
  end
  if wait_max < 0 then
    return nil, '"wait_max" must be greater than or equal to 0'
  end

  local shm_retries = opts.shm_retries or (_shm_retries or DEFAULT_SHM_RETRIES)
  if type(shm_retries) ~= "number" and shm_retries ~= nil then
    return nil, 'optional "shm_retries" option must be a number'
  end
  if shm_retries < 0 then
    return nil, '"shm_retries" must be 0 or greater'
  end

  local old_interval = _interval
  _interval = interval
  _dict = dict
  _unique_timeout = unique_timeout
  _wait_interval = wait_interval
  _wait_max = wait_max
  _shm_retries = shm_retries
  _last_event = _last_event or get_event_id()

  if not started then
    -- we're live, let's celebrate it with an event
    local id, err = _M.post(_M.events._source, _M.events.started)
    if not id then return id, err end
  end

  if not old_interval then
    -- haven't got a timer setup yet, must create one
    local success, err = new_timer(0, do_timer)
    if not success then
      if err == "process exiting" then
        _M.post(_M.events._source, _M.events.stopping)
      end
      err = "failed to create timer: " .. tostring(err)
      log(ERR, "worker-events: ", err)
      return nil, err
    end

  else
    _M.poll()
  end

  if opts.debug then
    _M._callbacks = _callbacks
  end

  return true
end

-- Check whether the event module has already been configured
-- @return `true`  if configured and ready to accept events, or `false` if not
_M.configured = function()
  return (_dict ~= nil)
end

-- Utility function to generate event lists and prevent typos in
-- magic strings. Accessing a non-existing event on the table will result in
-- an unknown event error.
-- @param source string with the event source name
-- @param ... vararg, strings, with all events available
-- @return events table where key `_source` contains the event source name and
-- all other eventnames are in the hashtable by their own name.
_M.event_list = function(source, ...)
  local events = { _source = source }
  for _, event in pairs({...}) do
    events[event] = event
  end
  return setmetatable(events, {
    __index = function(self, key)
      error("event '"..tostring(key).."' is an unknown event", 2)
    end
  })
end

_M.events = _M.event_list(
  "resty-worker-events",      -- event source for own events
  "started",                  -- event when started
  "stopping")                 -- event when stopping

return _M
