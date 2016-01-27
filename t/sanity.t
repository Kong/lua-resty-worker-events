# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 + 8);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
_EOC_

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: worker.events starting and stopping, with its own events
--- SKIP
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
    we.register(function(source, event, data, pid) 
        ngx.log(ngx.DEBUG, "worker-events: ","source=",source,", event=",event, ", pid=", pid,
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
            ngx.sleep(2)

            local we = require "resty.worker.events"
            ngx.print("hello world\\n")

        ';
    }

--- request
GET /t

--- response_body
Upstream foo.com
    Primary Peers
        127.0.0.1:12354 up
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[error]
[alert]
[warn]
dropping event: waiting for event data timed out
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|publishing peers version \d+|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
publishing peers version 1
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){3,5}$/
--- timeout: 6


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
    we.register(function(source, event, data, pid) 
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
            ngx.sleep(2)
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
    we.register(function(source, event, data, pid) 
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
            ngx.sleep(2)
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
    we.register(function(source, event, data, pid) 
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
            ngx.sleep(2)
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

=== TEST 5: worker.events 'one' being done
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
    we.register(function(source, event, data, pid) 
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
            ngx.sleep(2)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            we.post("content_by_lua","request2","01234567890", true)
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
worker-events: handling event; source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request2, pid=\d+, data=01234567890
worker-events: handling event; source=content_by_lua, event=request3, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request3, pid=\d+, data=01234567890$/
--- timeout: 6


=== TEST 6: worker.events 'one' being done by another worker
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
    we.register(function(source, event, data, pid) 
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
            ngx.sleep(2)
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            assert(ngx.shared.worker_events:add("events-one:3", 666))
            we.post("content_by_lua","request2","01234567890", true)
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

