Name
====

lua-resty-worker-events - Inter process events for Nginx worker processes

Table of Contents
=================

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
* [Installation](#installation)
* [TODO](#todo)
* [Community](#community)
    * [English Mailing List](#english-mailing-list)
    * [Chinese Mailing List](#chinese-mailing-list)
* [Bugs and Patches](#bugs-and-patches)
* [Author](#author)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Status
======

This library is still under early development.

Synopsis
========

```nginx
http {
    lua_package_path "/path/to/lua-resty-worker-events/lib/?.lua;;";

    # sample upstream block:
    upstream foo.com {
        server 127.0.0.1:12354;
        server 127.0.0.1:12355;
        server 127.0.0.1:12356 backup;
    }

    # the size depends on the number of event to handle:
    lua_shared_dict process_events 1m;

    init_worker_by_lua_block {
        local ev = require "resty.worker.events"

        local handler = function(source, event, data, pid)
            print("received event; source=",source,
                  ", event=",event,
                  ", data=", tostring(data),
                  ", from process ",pid)
        end

        ev.register(handler)

        local ok, err = ev.configure {
            shm = "process_events", -- defined by "lua_shared_dict"
            timeout = 2,            -- life time of event data in shm
            interval = 1,           -- poll interval (seconds)

            wait_interval = 0.010,  -- wait before retry fetching event data
            wait_max = 0.5,         -- max wait time before discarding event
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to start event system: ", err)
            return
        end
    }

    server {
        ...

        # example for polling:
        location = /some/path {

            default_type text/plain;
            content_by_lua_block {
                -- manually call `poll` to stay up to date, can be used instead,
                -- or together with the timer interval. Polling is efficient,
                -- so if staying up-to-date is important, this is preferred.
                require("resty.worker.events").poll()

                -- do regular stuff here

            }
        }
    }
}
```

Description
===========

[Back to TOC](#table-of-contents)

This module provides a way to send events to the other worker processes in an Nginx
server. Communication is through a shared memory zone where event data will be stored.

The order of events in all workers is __guaranteed__ to be the same.

The workerprocess will setup a timer to check for events in the background. If staying
up-to-date is important though, the interval can be set to a lesser frequency and a
call to [poll](#poll) upon each request received makes sure everything is handled
as soon as possible.

This module itself will fire two events with `source="resty-worker-events"`;
 * `event="started"` when the module is first configured (note: the event handler must be
   [registered](#register) before calling [configure](#configure))
 * `event="stopping"` when the worker process exits (based on a timer `premature` setting)


Methods
=======

[Back to TOC](#table-of-contents)

configure
---------
`syntax: success, err = events.configure(opts)`

Will initialize the event listener. The `opts` parameter is a Lua table with named options

* `shm`: (required) name of the shared memory to use
* `timeout`: (optional) timeout of event data stored in shm (in seconds), default 2
* `interval`: (optional) interval to poll for events (in seconds), default 1
* `wait_interval`: (optional) interval between two tries when a new eventid is found, but the
  data is not available yet (due to asynchronous behaviour of the worker processes)
* `wait_max`: (optional) max time to wait for data when event id is found, before discarding
  the event. This is a fail-safe setting in case something went wrong.

The return value will be `true`, or `nil` and an error message.

This method can be called repeatedly to update the settings, except for the `shm` value which
cannot be changed after the initial configuration.

[Back to TOC](#table-of-contents)

poll
----
`syntax: success, err = events.poll()`

Will poll for new events and handle them all (call the registered callbacks). The implementation is
efficient, it will only check a single shared memory value and return immediately if no new events
are available.

The return value will be `true`, or `nil` and an error message.

[Back to TOC](#table-of-contents)

post
----
`syntax: success, err = events.post(source, event, data, one)`

Will post a new event. `source` and `event` are both strings. `data` can be anything (including `nil`)
as long as it is (de)serializable by the cjson module.
The `one` parameter is a boolean, if `true` the event mechanism will make sure that only 1 worker
process will execute the event (not necessarily the process posting the event).

Before returning, it will call [poll](#poll) to handle all events up to and including the newly posted
event.

The return value will be `true`, or `nil` and an error message.

*Note*: the worker process sending the event, will also receive the event! So to make sure
the order of processing events is the same in all processes, do not handle the event
when posting it, but only when receiving it.

[Back to TOC](#table-of-contents)

post_local
----------
`syntax: success, err = events.post_local(source, event, data)`

The same as [post](#post) except that the event will be local to the worker process, it will not
be broadcasted to other workers. With this method, the `data` element will not be jsonified.

Before returning, it will call [poll](#poll) to first handle the posted event and then handle all
other newly posted events.

The return value will be `true`, or `nil` and an error message.

[Back to TOC](#table-of-contents)

register
--------
`syntax: events.register(callback)`

Will register a callback function to receive events. The callback should have the following signature;

`syntax: callback = function(source, event, data, pid)`

The parameters will be the same as the ones provided to [post](#post), except for the extra value
`pid` which will be the pid of the originating worker process, or `nil` if it was a local event
only. Any return value from `callback` will be discarded.
*Note:* `data` may be a reference type of data (eg. a Lua `table`  type). The same value is passed
to all callbacks, so do not change the value in your handler, unless you know what you are doing!

The return value of `register` will be `true`, or it will throw an error if `callback` is not a
function value.

*Note*: to receive the process own `started` event, the handler must be registered before
calling [configure](#configure)

[Back to TOC](#table-of-contents)

unregister
----------
`syntax: events.unregister(callback)`

Will unregister the callback function and prevent it from receiving further events.

The return value will be `true` if it was removed, `false` if it was not in the handlers list, or
it will throw an error if `callback` is not a function value.

[Back to TOC](#table-of-contents)


Installation
============

Nothing special is required, install like any other pure Lua module. Just make
sure its location is in the module search path.

[Back to TOC](#table-of-contents)

TODO
====

[Back to TOC](#table-of-contents)

* activate and implement the first test, after fixing the "stopping" event

Community
=========

[Back to TOC](#table-of-contents)

English Mailing List
--------------------

The [openresty-en](https://groups.google.com/group/openresty-en) mailing list is for English speakers.

[Back to TOC](#table-of-contents)

Chinese Mailing List
--------------------

The [openresty](https://groups.google.com/group/openresty) mailing list is for Chinese speakers.

[Back to TOC](#table-of-contents)

Bugs and Patches
================

Please report bugs or submit patches by

1. creating a ticket on the [GitHub Issue Tracker](http://github.com/Mashape/lua-resty-worker-events/issues),
1. or posting to the [OpenResty community](#community).

[Back to TOC](#table-of-contents)

Author
======

Thijs Schreijer <thijs@mashape.com>, Mashape Inc.

[Back to TOC](#table-of-contents)

Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2016, by Thijs Schreijer, Mashape Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[Back to TOC](#table-of-contents)

See Also
========
* OpenResty: http://openresty.org

[Back to TOC](#table-of-contents)

