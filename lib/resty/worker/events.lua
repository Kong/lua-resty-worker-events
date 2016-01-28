--[[== START ============= temporary debug code ==============================--
-- with Lua 5.1 patch global xpcall to take function args (standard in 5.2+)
if _VERSION=="Lua 5.1" then
  local xp = xpcall
  xpcall = function(f, err, ...)
    local a = { n = select("#", ...), ...}
    return xp(function(...) return f(unpack(a,1,a.n)) end, err)
  end
end

-- error handler to attach stacktrack to error message
local ehandler = function(err)
  return debug.traceback(tostring(err))
end

-- patch global pcall to attach stacktrace to the error.
pcall = function(fn, ...)
  return xpcall(fn, ehandler, ...)
end
--==== END =============== temporary debug code ============================]]--

local log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local new_timer = ngx.timer.at
local shared = ngx.shared
local debug_mode = true --ngx.config.debug
local tostring = tostring
local ipairs = ipairs
local pcall = pcall
local cjson = require("cjson.safe").new()
local get_pid = ngx.worker.pid
local now = ngx.now
local sleep = ngx.sleep

-- event keys to shm
local KEY_LAST_ID = "events-last"         -- ID of last event posted
local KEY_DATA    = "events-data:"        -- serialized event json data
local KEY_ONE     = "events-one:"         -- key for 'one' events check

-- globals as upvalues (module is intended to run once per worker process)
local _dict          -- the shared dictionary to use
local _timeout       -- expire time for event data posted in shm (seconds)
local _interval      -- polling interval (in seconds)
local _pid = get_pid()
local _callbacks     -- list of event handlers to call with new events
local _last_event    -- event id of the last event handled
local _wait_max      -- how long (in seconds) to wait when we have an event id,
                     -- but no data, for the data to show up.
local _wait_interval -- interval between tries when event data is unavailable

-- defaults
local DEFAULT_TIMEOUT = 2
local DEFAULT_INTERVAL = 1
local DEFAULT_WAIT_MAX = 0.5
local DEFAULT_WAIT_INTERVAL = 0.010

local _M = {
    _VERSION = '0.01',

    events = setmetatable({
        source = "resty-worker-events",   -- event source for own events
        started = "started",              -- event when started
        stopping = "stopping",            -- event for stopping
    }, {
        __index = function(self, key)
          error("event '"..tostring(key).."' is an unknown event", 2)
        end
    })
}

if not ngx.config
   or not ngx.config.ngx_lua_version
   or ngx.config.ngx_lua_version < 9005
then
    error("ngx_lua 0.9.5+ required")
end

local function info(...)
    log(INFO, "worker-events: ", ...)
end

local function warn(...)
    log(WARN, "worker-events: ", ...)
end

local function errlog(...)
    log(ERR, "worker-events: ", ...)
end

local debug = function() end
if debug_mode then
    debug = function(...)
        -- print("debug mode: ", debug_mode)
        if debug_mode then
            log(DEBUG, "worker-events: ", ...)
        end
    end
end

-- gets current event id
-- @return event_id, or nil+error
local function get_event_id()
    return _dict:get(KEY_LAST_ID)
end

-- gets event data
-- @return event_id, or nil+error
local function get_event_data(event_id)
    return _dict:get(KEY_DATA..tostring(event_id))
end

-- posts a new event in shm
local function post_event(source, event, data, one)
    local json, err, event_id, success

    _dict:add(KEY_LAST_ID, 0)
    event_id, err = _dict:incr(KEY_LAST_ID, 1)
    if err then return event_id, err end

    json, err = cjson.encode({
            source = source,
            event = event,
            data = data,
            one = one,
            pid = _pid,
        })
    if not json then return json, err end

    success, err = _dict:add(KEY_DATA..tostring(event_id), json, _timeout)
    if not success then return success, err end

    return event_id
end

local function do_event(source, event, data, pid)
    local err, success

    debug("handling event; source=",source,
           ", event=",event,", pid=",pid,", data=",tostring(data))

    for _, handler in ipairs(_callbacks) do
        success, err = pcall(handler, source, event, data, pid)
        if not success then
            errlog("event callback failed; source=",source,
                   ", event=",event,", pid=",pid, " error='", tostring(err),
                   "', data="..cjson.encode(data))
        end
    end
end


-- for 'one' events, returns `true` when this worker is supposed to handle it
local function mine_to_have(id)
    local key = KEY_ONE .. tostring(id)
    local success, err = _dict:add(key, _pid, _timeout)

    if success then return true end

    if err == "exists"  then
        debug("skipping event ",id," was handled by worker ",
              _dict:get(key))
    else
        errlog("cannot determine who handles event ",id,", dropping it: ",err)
    end
end

-- Handle incoming json based event
local function do_event_json(id, json)
    local d, err
    d, err = cjson.decode(json)
    if not d then
        return errlog("failed decoding json event data: ", err)
    end

    if d.one and not mine_to_have(id) then return end

    return do_event(d.source, d.event, d.data, d.pid)
end

-- Posts a new event. Also immediately handles all events up to and including
-- the newly posted event.
-- @param source string identifying the event source
-- @param event string identifying the event name
-- @param data the data for the event, anything as long as it can be used with cjson
-- @return event id on success, or nil + error message
_M.post = function(source, event, data, one)
    one = one and true
    if type(source) ~= "string" or source == "" then
        return nil, "source is required"
    end
    if type(event) ~= "string" or source == "" then
        return nil, "event is required"
    end

    local success, err = post_event(source, event, data, one)
    if not success then
        err = 'failed posting event "'..event..'" by "'..source..'"'
        errlog(err)
        return success, err
    end

    return _M.poll()
end

-- the same as post. But the event will only be handled in the worker
-- it was posted from, it will not be broadcasted to other worker processes.
_M.post_local = function(source, event, data)
    if type(source) ~= "string" or source == "" then
        return nil, "source is required"
    end
    if type(event) ~= "string" or source == "" then
        return nil, "event is required"
    end

    do_event(source, event, data, nil)

    return _M.poll()
end

-- poll for events and execute handlers
-- @return true or nil+error
_M.poll = function()
    local event_id, err = get_event_id()
    if event_id == _last_event then return true end

    if not event_id then
        local err = "failed to get currrent event id: "..tostring(err)
        errlog(err)
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
      cache_data[count], cache_err[count] = get_event_data(_last_event)
    end

    local expire = now() + _wait_max
    for idx = 1, count do
        local data = cache_data[idx]
        while not data do
            err = cache_err[idx]
            if err then
                errlog("Error fetching event data: ", err)
                break
            else
                -- just nil, so must wait for data to appear
                if now() >= expire then
                    break
                end
                -- wait and retry
                sleep(_wait_interval)
                data, err = get_event_data(_last_event - count + idx)
            end
        end

       if data then
            do_event_json(_last_event - count + idx, data)
        else
            warn("dropping event; waiting for event data timed out, id: ",
                 _last_event - count + idx)
        end
    end

    -- in case we waited, recurse to handle any new pending events
    return _M.poll()
end

-- executes a polling loop, and reschedules the polling timer
local do_timer
do_timer = function(premature)
    local ok, err
    if premature then
        _M.post(_M.events.source, _M.events.stopping)
    end

    _M.poll()

    if _interval ~= 0 and not premature then
        ok, err = new_timer(_interval, do_timer)
        if not ok then
            if err == "process exiting" then
                _M.post(_M.events.source, _M.events.stopping)
            end
            err = "failed to create timer: " .. tostring(err)
            errlog(err)
            return nil, err
        end
    end
    return true
end

-- registers an event handler callback.
-- signature; callback(source, event, data, originating_pid)
-- @param callback the eventhandler callback to add
-- @return true
_M.register = function(callback)
    assert(type(callback) == "function", "expected function, got: "..
           type(callback))
    _callbacks = _callbacks or {}
    local idx = #_callbacks + 1
    _callbacks[idx] = callback
    _callbacks[callback] = idx
    return true
end


-- unregisters an event handler callback.
-- @param callback the eventhandler callback to remove
-- @return true if it was removed, false if it was not in the list
_M.unregister = function(callback)
    assert(type(callback) == "function", "expected function, got: "..
           type(callback))
    local idx = _callbacks[callback]
    if idx then
        _callbacks[callback] = nil
        _callbacks[idx] = nil
    end
    return idx ~= nil
end

-- (re) configures the event system
-- shm     : name of the shared memory to use
-- timeout : timeout of event data stored in shm (in seconds)
-- interval: interval to poll for events (in seconds)
-- wait_interval : interval between two tries when an eventid is found, but no data
-- wait_max: max time to wait for data when event id is found, before discarding
_M.configure = function(opts)
    assert(type(opts) == "table", "Expected a table, got "..type(opts))

    local started = _dict ~= nil

    if get_pid() ~= _pid then
        -- pid changed, so new process was forked, must reset
        _pid = get_pid()
        --_dict = nil     -- this value can actually stay, because its shared
        _interval = nil
        _timeout = nil
        _callbacks = nil
        _wait_max = nil
        _wait_interval = nil
        started = nil
    end

    local shm = opts.shm
    if shm and (_dict ~= nil) then
        return nil, "Already started, cannot change shm"
    end
    if not (shm or _dict) then
        return nil, '"shm" option required to start'
    end

    local dict = shared[shm]
    if not dict then
        return nil, 'shm "' .. tostring(shm) .. '" not found'
    end

    local timeout = opts.timeout or (_timeout or DEFAULT_TIMEOUT)
    if type(timeout) ~= "number" and timeout ~= nil then
        return nil, 'optional "timeout" option must be a number'
    end
    if timeout <= 0 then
        return nil, '"timeout" must be greater than 0'
    end

    local interval = opts.interval or (_interval or DEFAULT_INTERVAL)
    if type(interval) ~= "number" and interval ~= nil then
        return nil, 'optional "interval" option must be a number'
    end
    if interval <= 0 then
        return nil, '"interval" must be greater than 0'
    end

    local wait_interval = opts.wait_interval or (_wait_interval or
                          DEFAULT_WAIT_INTERVAL)
    if type(wait_interval) ~= "number" and wait_interval ~= nil then
        return nil, 'optional "wait_interval" option must be a number'
    end
    if wait_interval < 0 then
        return nil, '"interval" must be greater than or equal to 0'
    end

    local wait_max = opts.wait_max or (_wait_max or DEFAULT_WAIT_MAX)
    if type(wait_max) ~= "number" and wait_max ~= nil then
        return nil, 'optional "wait_max" option must be a number'
    end
    if wait_max < 0 then
        return nil, '"wait_max" must be greater than or equal to 0'
    end

    local old_interval = _interval
    _interval = interval
    _dict = dict
    _timeout = timeout
    _wait_interval = wait_interval
    _wait_max = wait_max
    _dict:add(KEY_LAST_ID, 0)  -- make sure the key exists

    _last_event = _last_event or get_event_id() or 0

    if not started then
        -- we're live, let's celebrate it with an event
        local id, err = _M.post(_M.events.source, _M.events.started)
        if not id then return id, err end
    end

    if not old_interval then
        -- haven't got a timer setup yet, must create one
        local success, err = do_timer()
        if not success then return success, err end
    else
        _M.poll()
    end

    return true
end

return _M
