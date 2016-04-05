# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 + 5);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
_EOC_

#no_diff();
no_long_string();
master_on();
run_tests();

__DATA__

=== TEST 1: worker.events starting and stopping, with its own events
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
        interval = 0.001,
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.print("hello world\\n")
            local f = assert(io.open("t/servroot/logs/nginx.pid"))
            local pid = assert(tonumber(f:read()), "read pid")
            f:close()
            assert(os.execute("kill -HUP "..pid))
        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*|gracefully .*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
gracefully shutting down
worker-events: handling event; source=resty-worker-events, event=stopping, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=stopping, pid=\d+, data=nil
worker-events: handling event; source=resty-worker-events, event=stopping, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=stopping, pid=\d+, data=nil$/
--- timeout: 6
--- wait: 0.2


=== TEST 2: worker.events posting and handling events, broadcast and local
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post_local("content_by_lua","request2","01234567890")
            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, data=.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6


=== TEST 3: worker.events handling remote events
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", tostring(data))
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }

    local cjson = require("cjson.safe").new()

    local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
    assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
        cjson.encode({ source="hello", event="1", data="there-1", pid=123456}), 2))

    local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
    assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
        cjson.encode({ source="hello", event="2", data="there-2", pid=123456}), 2))

    local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
    assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
        cjson.encode({ source="hello", event="3", data="there-3", pid=123456}), 2))

    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local cjson = require("cjson.safe").new()
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post_local("content_by_lua","request2","01234567890")

            local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))
            assert(ngx.shared.worker_events:add("events-data:"..tostring(event_id),
                  cjson.encode({ source="hello", event="4", data="there-4", pid=123456}), 2))

            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, data=.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=hello, event=1, pid=123456, data=there-1
worker-events: handler event;  source=hello, event=1, pid=123456, data=there-1
worker-events: handling event; source=hello, event=2, pid=123456, data=there-2
worker-events: handler event;  source=hello, event=2, pid=123456, data=there-2
worker-events: handling event; source=hello, event=3, pid=123456, data=there-3
worker-events: handler event;  source=hello, event=3, pid=123456, data=there-3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, pid=nil, data=01234567890
worker-events: handling event; source=hello, event=4, pid=123456, data=there-4
worker-events: handler event;  source=hello, event=4, pid=123456, data=there-4
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6

=== TEST 4: worker.events missing data, timeout
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", tostring(data))
            end)
    local ok, err = we.configure{
        shm = "worker_events",
        interval = 1,
        timeout = 2,
        wait_max = 0.5,
        wait_interval = 0.200,
    }

    local cjson = require("cjson.safe").new()

    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local cjson = require("cjson.safe").new()
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post("content_by_lua","request2","01234567890", true)

            local event_id = assert(ngx.shared.worker_events:incr("events-last", 1))

            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
--- grep_error_log eval: qr/worker-events: .*?, data=.*|worker-events: dropping event; waiting for event data timed out.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: dropping event; waiting for event data timed out, id: 4.*
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6

=== TEST 5: worker.events 'one' being done, and only once
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post("content_by_lua","request2","01234567890", "unique_value")
            we.post("content_by_lua","request3","01234567890", "unique_value")
            we.post("content_by_lua","request4","01234567890")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, data=.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request4, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request4, pid=\d+, data=01234567890$/
--- timeout: 6


=== TEST 6: worker.events 'unique' being done by another worker
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    we.register(function(data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data)
            end)
    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            assert(ngx.shared.worker_events:add("events-one:unique_value", 666))
            we.post("content_by_lua","request2","01234567890", "unique_value")
            we.post("content_by_lua","request3","01234567890")
            ngx.print("hello world\\n")
        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, data=.*|worker-events: skipping event \d+ was handled by worker \d+/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: skipping event 3 was handled by worker 666
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6

=== TEST 7: registering and unregistering event handlers at different levels
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

lua_shared_dict worker_events 1m;
init_worker_by_lua '
    ngx.shared.worker_events:flush_all()
    local we = require "resty.worker.events"
    local cb = function(extra, data, event, source, pid)
        ngx.log(ngx.DEBUG, "worker-events: handler event;  ","source=",source,", event=",event, ", pid=", pid,
                ", data=", data, ", callback=",extra)
    end
    ngx.cb_global  = function(...) return cb("global", ...) end
    ngx.cb_source  = function(...) return cb("source", ...) end
    ngx.cb_event12 = function(...) return cb("event12", ...) end
    ngx.cb_event3  = function(...) return cb("event3", ...) end
    
    we.register(ngx.cb_global)
    we.register(ngx.cb_source,  "content_by_lua")
    we.register(ngx.cb_event12, "content_by_lua", "request1", "request2")
    we.register(ngx.cb_event3,  "content_by_lua", "request3")
    
    local ok, err = we.configure{
        shm = "worker_events",
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to configure worker events: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(1)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","123")
            we.post("content_by_lua","request2","123")
            we.post("content_by_lua","request3","123")
            we.unregister(ngx.cb_global)
            we.post("content_by_lua","request1","124")
            we.post("content_by_lua","request2","124")
            we.post("content_by_lua","request3","124")
            we.unregister(ngx.cb_source,  "content_by_lua")
            we.post("content_by_lua","request1","125")
            we.post("content_by_lua","request2","125")
            we.post("content_by_lua","request3","125")
            we.unregister(ngx.cb_event12, "content_by_lua", "request1", "request2")
            we.post("content_by_lua","request1","126")
            we.post("content_by_lua","request2","126")
            we.post("content_by_lua","request3","126")
            we.unregister(ngx.cb_event3,  "content_by_lua", "request3")
            we.post("content_by_lua","request1","127")
            we.post("content_by_lua","request2","127")
            we.post("content_by_lua","request3","127")
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
hello world
--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/worker-events: .*?, data=.*/
--- grep_error_log_out eval
qr/^worker-events: handling event; source=resty-worker-events, event=started, pid=\d+, data=nil
worker-events: handler event;  source=resty-worker-events, event=started, pid=\d+, data=nil, callback=global
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=123
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=123, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=123
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=123, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=123
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=global
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=source
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=123, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=124
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=124, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=124
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=124, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=124
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=124, callback=source
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=124, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=125
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=125, callback=event12
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=125
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=125, callback=event12
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=125
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=125, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=126
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=126
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=126
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=126, callback=event3
worker-events: handling event; source=content_by_lua, event=request1, pid=\d+, data=127
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=127
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=127$/
--- timeout: 6
