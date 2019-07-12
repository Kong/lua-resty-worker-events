use Test::Nginx::Socket::Lua 'no_plan';

use Cwd qw(cwd);
my $pwd = cwd();

#no_diff();
repeat_each(1);
no_long_string();
master_on();
workers(4);

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/lib/?.lua;;";
_EOC_

run_tests();

__DATA__

=== TEST 1: worker.events posting and handling events, broadcast
--- http_config eval
"$::HttpConfig"
. q{
    lua_shared_dict worker_events 1m;
    init_worker_by_lua_block {
        ngx.shared.worker_events:flush_all()

        local we = require "resty.worker.events"
        we.register(function(data, event, source, pid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ",
                    "source=",source, ", event=",event, ", pid=", pid,
                    ", data=", data)
        end)

        local ok, err = we.configure{
            shm = "worker_events",
            interval = 0.001
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to configure worker events: ", err)
            return
        end
    }
}
--- config
    location = /t {
        access_log off;
        content_by_lua_block {
            local we = require "resty.worker.events"
            we.post("content_by_lua","request1","01234567890")
            ngx.sleep(0.1)
            ngx.say("hello world")
        }
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
--- grep_error_log eval: qr/worker-events: handler event.*, data=01234567890/
--- grep_error_log_out eval
qr/^worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890
worker-events: handler event;  source=content_by_lua, event=request1, pid=\d+, data=01234567890$/



=== TEST 2: worker.events posting and handling events, broadcast local
--- http_config eval
"$::HttpConfig"
. q{
    lua_shared_dict worker_events 1m;
    init_worker_by_lua_block {
        ngx.shared.worker_events:flush_all()

        local we = require "resty.worker.events"
        we.register(function(data, event, source, pid)
            ngx.log(ngx.DEBUG, "worker-events: handler event;  ",
                    "source=",source, ", event=",event, ", pid=", pid,
                    ", data=", data)
        end)

        local ok, err = we.configure{
            shm = "worker_events",
            interval = 0.001
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to configure worker events: ", err)
            return
        end
    }
}
--- config
    location = /t {
        access_log off;
        content_by_lua_block {
            local we = require "resty.worker.events"
            we.post_local("content_by_lua","request1","01234567890")
            ngx.sleep(0.1)
            ngx.say("hello world")
        }
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
--- grep_error_log eval: qr/worker-events: handler event.*, data=01234567890/
--- grep_error_log_out eval
qr/^worker-events: handler event;  source=content_by_lua, event=request1, pid=nil, data=01234567890$/
