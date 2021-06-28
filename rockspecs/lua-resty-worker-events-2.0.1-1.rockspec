local package_name = "lua-resty-worker-events"
local package_version = "2.0.1"
local rockspec_revision = "1"
local github_account_name = "Kong"
local github_repo_name = package_name
local git_checkout = package_version == "scm" and "master" or package_version


package = package_name
version = package_version.."-"..rockspec_revision
source = {
  url = "git://github.com/"..github_account_name.."/"..github_repo_name..".git",
  tag = git_checkout,
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
   homepage = "https://github.com/"..github_account_name.."/"..github_repo_name,
}

dependencies = {
}

build = {
   type = "builtin",
   modules = {
     ["resty.worker.events"] = "lib/resty/worker/events.lua",
   }
}
