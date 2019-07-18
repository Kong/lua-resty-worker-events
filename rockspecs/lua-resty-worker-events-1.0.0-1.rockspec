package = "lua-resty-worker-events"
version = "1.0.0-1"
source = {
   url = "https://github.com/Kong/lua-resty-worker-events/archive/1.0.0.tar.gz",
   dir = "lua-resty-worker-events-1.0.0"
}
description = {
   summary = "Cross worker eventbus for OpenResty",
   detailed = [[
      lua-resty-worker-events is a module that can emit events
      to be handled local (in the worker emitting the event), global
      (in all worker processes), or once (only in one worker).
      The order of the events is guaranteed the same in all workers.
   ]],
   license = "Apache 2.0",
   homepage = "https://github.com/Kong/lua-resty-worker-events"
}
dependencies = {
}
build = {
   type = "builtin",
   modules = {
     ["resty.worker.events"] = "lib/resty/worker/events.lua",
   }
}
