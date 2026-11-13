-- Uploads over HTTP/1.x: grant the sender only as much TCP receive window as its link uses.
--
-- Why (seen on production on 2026-11-11, reproduced in lab/uplink.sh):
-- while the Nextcloud Android app uploaded (HTTP/1.1, one TCP connection), PeerTube in the
-- browser of the same phone stopped, in test after test. A sender may have as much
-- data on its way as the receiver's window allows. Linux sizes that window by itself and,
-- since a kernel change of 2025 (largest buffer 6 MB -> 32 MB), up to 15 MB; a phone with a 4 Mbit/s uplink then keeps seconds of
-- upload data queued in its own modem (measured: TCP round trip 6.1 s instead of 0.1 s),
-- and everything else the phone sends, the player's requests and acknowledgements, waits
-- behind it or is dropped. The player got one short gap every 20 s.
-- HTTP/2 and HTTP/3 uploads have their own flow control windows (512k, 2m) and are not
-- touched here.
--
-- What it does: while a request with a body of 1 MB or more is being received on an
-- HTTP/1.x connection, a timer looks at the connection twice a second (TCP_INFO: bytes
-- received, lowest round trip time) and sets the receive window to
--     GAIN x (bytes per second received) x (round trip time),
-- never below FLOOR. A sender that the window holds back delivers more as the window
-- grows, so the window multiplies up to what the link carries within a second or two; from
-- FREE on the window is not limited any more (fast links are left alone).
-- The window must never be what holds a sender back: every change is judged by what the
-- sender delivers afterwards, and every few seconds a larger window is tried.
-- What stays queued at the sender is then about (GAIN - 1) round trips of data, or FLOOR
-- on a slow link (128 KB at 4 Mbit/s: a quarter of a second).
-- The idea is the one of RFC 9840 (rLEDBAT): the receiver steers the sender through the
-- window it advertises; no change on the client.
--
-- Used from the server blocks (conf/server.conf): request() in the rewrite phase, done() in the log
-- phase. Any failure leaves the connection as the kernel made it. To switch it off, remove
-- the two calls there (or set ENABLED to false here) and reload.

local ffi = require "ffi"
local base = require "resty.core.base"

local ENABLED  = true
local FLOOR    = 128 * 1024        -- smallest window granted, bytes
local FREE     = 4 * 1024 * 1024   -- from this window on: no limit
local BIG      = 16 * 1024 * 1024  -- buffer of a connection that is not limited
local GAIN     = 4                 -- window = GAIN x rate x round trip time
local MIN_BODY = 1024 * 1024       -- smaller request bodies are not looked at
local TICK     = 0.5               -- seconds between two looks at a connection
local PROBE    = 5                 -- seconds between two tries of a larger window
local RTT_MAX  = 0.3               -- round trip time used at most, seconds (a first sample
                                   -- taken while the link was already congested is too high)
local SLOW     = 2 * 1024 * 1024   -- bytes per second: an upload below this is "on a slow line"
local MARK_TTL = 15                -- seconds a mark outlives the last look at the upload
-- Room for the sender's HTTP/3 (see room() below). false: the sender's browser is told to
-- leave HTTP/3 while it uploads (mark() and conf/server.conf) and the upload keeps
-- its full speed.
local ROOM      = true
local ROOM_HEAD = 0.55             -- share of what the line carries that the upload gets then
local ROOM_HOLD = 30               -- seconds between two tries of what the line carries now
local ROOM_MIN  = 8 * 1024         -- smallest window in that mode, bytes
local ROOM_TTL  = 30               -- seconds an address counts as using HTTP/3 after a request

local _M = { version = 1 }

local ok_os = ffi.os == "Linux" and (ffi.arch == "x64" or ffi.arch == "arm64")
local SOL_SOCKET, SO_RCVBUF, SO_BUF_LOCK = 1, 8, 72
local IPPROTO_TCP, TCP_WINDOW_CLAMP, TCP_INFO = 6, 10, 11

local C = ffi.C
local ibuf, ilen, ti, peer
if ok_os then
    -- own names, so that nothing another Lua library declared can clash
    ok_os = pcall(ffi.cdef, [[
        int npm_uw_getsockopt(int fd, int level, int name, void *val, unsigned int *len) __asm__("getsockopt");
        int npm_uw_setsockopt(int fd, int level, int name, const void *val, unsigned int len) __asm__("setsockopt");
        int npm_uw_getpeername(int fd, void *addr, unsigned int *len) __asm__("getpeername");
        int npm_uw_socket(int domain, int type, int protocol) __asm__("socket");
        int npm_uw_close(int fd) __asm__("close");
        struct npm_uw_tcp_info {
            uint8_t  head[8];
            uint32_t rto, ato, snd_mss, rcv_mss;
            uint32_t unacked, sacked, lost, retrans, fackets;
            uint32_t last_data_sent, last_ack_sent, last_data_recv, last_ack_recv;
            uint32_t pmtu, rcv_ssthresh, rtt, rttvar, snd_ssthresh, snd_cwnd, advmss, reordering;
            uint32_t rcv_rtt, rcv_space;
            uint32_t total_retrans;
            uint64_t pacing_rate, max_pacing_rate, bytes_acked, bytes_received;
            uint32_t segs_out, segs_in;
            uint32_t notsent_bytes, min_rtt, data_segs_in, data_segs_out;
            uint8_t  rest[352];
        };
    ]])
end
if ok_os then
    ibuf = ffi.new("int[1]")
    ilen = ffi.new("unsigned int[1]")
    ti = ffi.new("struct npm_uw_tcp_info")
    peer = ffi.new("uint8_t[128]")
end

-- What this host allows: the largest SO_RCVBUF value (net.core.rmem_max; 16 MB after
-- raising it with sysctl, 208 KB on an untouched Linux). On a host that cannot hold a
-- buffer of FREE bytes a window could be taken away but not given back, which would only
-- slow uploads down: nothing is touched there.
local cap
local function probe()
    local s = C.npm_uw_socket(2, 1, 0)
    if s < 0 then
        return false
    end
    ibuf[0] = BIG
    C.npm_uw_setsockopt(s, SOL_SOCKET, SO_RCVBUF, ibuf, 4)
    ilen[0] = 4
    C.npm_uw_getsockopt(s, SOL_SOCKET, SO_RCVBUF, ibuf, ilen)
    cap = math.floor(ibuf[0] / 2)
    C.npm_uw_close(s)
    return cap >= FREE
end

local conns, count = {}, 0      -- per worker: connection number -> state

-- "This address is uploading on a slow line" (shared by all workers, conf/http.conf).
-- Measured on 2026-11-13 with a test phone on 3G (numbered UDP packets sent from the phone
-- during an upload): the phone's kernel hands them to the modem on time, they reach this
-- server only in the second in which an upload chunk ends, up to 21 s late, none lost. TCP
-- acknowledgements of the same phone are not held. So HTTP/3 of that phone cannot work
-- while it uploads, HTTP/2 can. With the upload held to half its speed UDP did get through,
-- at that price; the operator chose full upload speed and HTTP/2 for that time.
-- conf/server.conf therefore answers a marked address with "Alt-Svc: clear" on its
-- TCP connections: its browser stops trying HTTP/3 (each try cost up to 26 s there) until
-- the mark has run out, MARK_TTL seconds after the upload; then HTTP/3 is advertised again.
-- An address is that of a NAT too: other devices behind it use HTTP/2 for that time.
local function mark(st)
    local d = ngx.shared.uploading
    if not ROOM and d and st.ip and st.win and st.peak > 0 and st.peak < SLOW then
        d:set(st.ip, true, MARK_TTL)
    end
end

local function peer_port(fd)
    ilen[0] = 128
    if C.npm_uw_getpeername(fd, peer, ilen) ~= 0 then
        return nil
    end
    return peer[2] * 256 + peer[3]
end

-- the socket of the client connection of the current request
local function client_fd()
    local r = base.get_request()
    if r == nil then
        return nil
    end
    -- ngx_http_request_t: signature, connection; ngx_connection_t: data, read, write, fd
    local c = ffi.cast("void **", r)[1]
    if c == nil then
        return nil
    end
    local fd = ffi.cast("int *", ffi.cast("char *", c) + 24)[0]
    local port = tonumber(ngx.var.realip_remote_port) or tonumber(ngx.var.remote_port)
    -- proof that this really is the client's socket: its peer has the client's port
    if fd < 3 or not port or peer_port(fd) ~= port then
        return nil
    end
    return fd, port
end

local function info(fd)
    ilen[0] = ffi.sizeof(ti)
    if C.npm_uw_getsockopt(fd, IPPROTO_TCP, TCP_INFO, ti, ilen) ~= 0 or ilen[0] < 152 then
        return nil
    end
    local rt = ti.min_rtt
    if rt == 0 or rt == 0xffffffff then
        rt = ti.rtt
    end
    -- third value: the round trip as the receiver measures it from the sender's timestamp
    -- echoes; it grows with what the sender has queued in itself (0 without timestamps)
    return tonumber(ti.bytes_received), rt / 1e6, ti.rcv_rtt / 1e6
end

local function hold(st, win)
    ibuf[0] = win
    if C.npm_uw_setsockopt(st.fd, SOL_SOCKET, SO_RCVBUF, ibuf, 4) ~= 0 then
        return
    end
    C.npm_uw_setsockopt(st.fd, IPPROTO_TCP, TCP_WINDOW_CLAMP, ibuf, 4)
    st.win = win
end

-- Back to a window that does not limit. The buffer is first made as large as the host
-- allows and only then handed back to the kernel: the kernel enlarges a buffer only when
-- more arrives per round trip than ever before on this connection, so a buffer that was
-- held small would otherwise stay small (seen on production: 300 instead of 500 KB/s).
local function free(st)
    ibuf[0] = BIG
    C.npm_uw_setsockopt(st.fd, SOL_SOCKET, SO_RCVBUF, ibuf, 4)
    ibuf[0] = 0
    C.npm_uw_setsockopt(st.fd, SOL_SOCKET, SO_BUF_LOCK, ibuf, 4)
    ibuf[0] = 0x3fffffff
    C.npm_uw_setsockopt(st.fd, IPPROTO_TCP, TCP_WINDOW_CLAMP, ibuf, 4)
    st.win = nil
end

local function forget(serial)
    if conns[serial] then
        conns[serial] = nil
        count = count - 1
    end
end

local tick
local function arm(serial, st)
    if not st.timer then
        st.timer = ngx.timer.at(TICK, tick, serial) and true or false
    end
end

-- window in force: a number while it is held, FREE while it is not limited
local function set(st, win)
    if win >= FREE then
        if st.win then
            free(st)
        end
    else
        hold(st, win)
    end
end

-- how long a window that proved necessary is kept: longer each time it proves so again
local function pin(st)
    st.pin = math.min(300, (st.pin or 15) * 2)
    return st.pin
end

-- Room for the sender's HTTP/3 (operator's decision of 2026-11-13, after the measurement
-- above: HTTP/3 has to work on a phone during its own upload too).
-- The phone lets UDP out only while its TCP upload has nothing queued. A sender that is held
-- by the receive window below what its line carries sends each packet as it is released by
-- an acknowledgement and queues nothing; then the UDP of the same phone passes (measured:
-- delay 0.03 to 0.3 s instead of up to 21 s).
-- So while the sender's address is using HTTP/3, or another program of that device is
-- talking to this server at all (both noted by h3() below), its upload is held to
-- ROOM_HEAD of what the line carries:
--  * what the line carries: what the upload delivered before it was held; measured again
--    every ROOM_HOLD seconds by opening the window wider for a second; lowered when the
--    sender queues although it is held (its round trip, as the receiver sees it from the
--    timestamp echoes, stays far above the lowest one);
--  * the window is that share times the round trip.
-- Without HTTP/3 from that address the upload runs as before, at full speed.
local function room(st, rate, rr, now)
    local r = st.room
    if not r then
        -- not before the upload has shown what the line carries (two seconds at its own pace)
        if st.looks < 4 then
            return false
        end
        local carries = math.max(st.peak, rate)
        if carries <= 0 or carries >= SLOW then
            return false
        end
        r = { carries = carries, queued = 0, wait = 0, measure_at = now + ROOM_HOLD }
        st.room, st.exp = r, nil
    end
    if rr > 0 and (not r.base or rr < r.base) then
        r.base = rr
    end
    -- The window is reckoned, not felt for: share of the line x round trip. (Two versions
    -- that moved the window by what the upload delivered both went wrong on a real phone on
    -- 3G: one cut the upload to 30 KB/s, one let it run full again. On such a line neither
    -- the delivery nor the round trip is steady enough to steer by from look to look.)
    local rt = math.min(math.max(st.rt or 0, r.base or 0, 0.02), RTT_MAX)
    if r.measuring then
        -- the window is open wider for a second: what arrives now is what the line carries
        r.best = math.max(r.best, rate)
        r.measuring = r.measuring - 1
        if r.measuring > 0 then
            return true
        end
        r.measuring = nil
        if r.best > 0.5 * r.carries then               -- (not a pause of the sender)
            r.carries = math.min(SLOW, r.best)
        end
        r.measure_at, r.queued, r.wait = now + ROOM_HOLD, 0, 2
    elseif r.wait > 0 then
        r.wait = r.wait - 1
    else
        -- held, and its round trip far above the lowest for two seconds: the line carries
        -- much less than assumed (only a large rise counts, see above)
        local queueing = r.base and rr > 0 and rr - r.base > math.max(0.25, 2 * r.base)
        r.queued = queueing and r.queued + 1 or 0
        if r.queued >= 4 then
            r.carries = math.max(16 * 1024, 0.75 * r.carries)
            r.queued, r.wait = 0, 4
        elseif now >= r.measure_at and rate >= 0.3 * ROOM_HEAD * r.carries then
            r.measuring, r.best = 2, 0
            hold(st, math.max(ROOM_MIN, math.floor(3 * ROOM_HEAD * r.carries * rt)))
            return true
        end
    end
    local win = math.max(ROOM_MIN, math.floor(ROOM_HEAD * r.carries * rt))
    if not st.win or math.abs(win - st.win) > 0.05 * st.win then
        hold(st, win)
    end
    return true
end

tick = function(premature, serial)
    local st = conns[serial]
    if not st then
        return
    end
    st.timer = false
    if premature then
        return
    end
    if peer_port(st.fd) ~= st.port then      -- closed, or the number belongs to someone else now
        return forget(serial)
    end
    local bytes, rt, rr = info(st.fd)
    if not bytes then
        return forget(serial)
    end
    local now = ngx.now()
    local dt = now - st.t
    if dt >= TICK / 2 then
        local got = bytes - st.bytes
        local rate = got / dt
        st.bytes, st.t = bytes, now
        st.idle = rate > 0 and 0 or st.idle + 1
        st.rt = rt
        st.looks = (st.looks or 0) + 1
        -- the sender's address is using HTTP/3: the upload makes room for it
        local h3 = ROOM and ngx.shared.h3_recent
        if h3 and st.ip and st.busy then
            h3:set("u|" .. st.ip, st.agent, 20)      -- "an upload of this program is running"
        end
        if h3 and st.ip and h3:get(st.ip) then
            if room(st, rate, rr, now) then
                st.peak = math.max(rate, st.peak * 0.7)
                st.last = rate
                if st.busy and st.idle < 8 then
                    arm(serial, st)
                else
                    st.seen = now
                end
                return
            end
        elseif st.room then
            -- no HTTP/3 from that address any more: back to the window as before
            st.room, st.peak = nil, math.max(st.peak, st.room.carries)
            if st.room == nil and st.win then
                set(st, st.keep or FREE)
            end
        end
        -- the best of the last moments, so that a short pause does not close the window
        st.peak = math.max(rate, st.peak * 0.7)
        local steady = rate < st.last * 1.25 and rate > st.last * 0.8
        local before = (rate + st.last) / 2

        -- The verdict on a change of the window, two looks after it. The rule is that the
        -- window must never be what holds a sender back:
        --  * a smaller window that cost speed is taken back and kept away for a while;
        --  * a larger window that brought speed is kept, and the next larger one is tried.
        -- Both happen when the round trip time is underestimated (the path got longer, or
        -- other traffic queues in front of the sender).
        local ex = st.exp
        if ex then
            ex.n, ex.got, ex.dt = ex.n + 1, ex.got + got, ex.dt + dt
            if ex.n >= 2 then
                st.exp = nil
                local after = ex.got / ex.dt
                if ex.up then
                    if st.busy and after >= 1.15 * ex.rate then
                        st.keep, st.keep_until = st.win or FREE, now + pin(st)
                        st.probe_gap, st.probe_at = PROBE, now
                    else
                        set(st, ex.win)
                        st.probe_gap = math.min(60, st.probe_gap * 2)
                        st.probe_at = now + st.probe_gap
                    end
                elseif st.busy and after < 0.8 * ex.rate then
                    st.keep, st.keep_until = ex.win, now + pin(st)
                end
            end
        end

        local cur = st.win or FREE
        local want = FREE
        if rt > 0 and st.peak > 0 then
            want = math.floor(GAIN * st.peak * math.min(rt, RTT_MAX))
            if want < FLOOR then
                want = FLOOR
            elseif want > FREE then
                want = FREE
            end
        end
        if st.keep_until and now < st.keep_until and want < st.keep then
            want = st.keep
        end

        if st.exp then
            -- a change is being judged: nothing else until the verdict
        elseif want > cur * 1.2 then
            set(st, want)
        elseif want < cur * 0.8 then
            -- (not while the sender is still speeding up: its start must not be cut short)
            if rate < st.last * 1.25 then
                st.exp = { win = cur, rate = st.peak, n = 0, got = 0, dt = 0 }
                set(st, want)
            end
        elseif st.win and st.busy and steady and now >= st.probe_at then
            -- the window is as computed: is it what holds the sender back?
            st.exp = { up = true, win = cur, rate = before, n = 0, got = 0, dt = 0 }
            set(st, math.floor(cur * 1.5))
        end
        st.last = rate
        if st.busy then
            mark(st)
        end
    end
    -- goes on while the request is being received; stops by itself if the end of the
    -- request was missed and nothing has arrived for four seconds
    if st.busy and st.idle < 8 then
        arm(serial, st)
    else
        st.seen = now
    end
end

local function sweep(now)
    for serial, st in pairs(conns) do
        if not st.timer and now - st.seen > 120 then
            forget(serial)
        end
    end
end

local ready
function _M.request()
    if not ENABLED or not ok_os or ngx.is_subrequest then
        return
    end
    local proto = ngx.var.server_protocol
    if proto ~= "HTTP/1.1" and proto ~= "HTTP/1.0" then
        return
    end
    local len = tonumber(ngx.var.content_length)
    if len then
        if len < MIN_BODY then
            return
        end
    elseif not ngx.var.http_transfer_encoding then
        return
    end
    if ready == nil then
        ready = probe()
    end
    if not ready then
        return
    end
    local serial = ngx.var.connection
    local st = conns[serial]
    local now = ngx.now()
    if not st then
        local fd, port = client_fd()
        if not fd then
            return
        end
        if count >= 4096 then
            sweep(now)
            if count >= 4096 then
                return
            end
        end
        st = { fd = fd, port = port, peak = 0, last = 0, idle = 0, seen = now,
               probe_gap = PROBE, probe_at = now + PROBE, ip = ngx.var.remote_addr,
               agent = ngx.crc32_short(ngx.var.http_user_agent or "") }
        conns[serial] = st
        count = count + 1
    end
    local bytes = info(st.fd)
    if not bytes then
        return forget(serial)
    end
    if not st.busy then
        st.bytes, st.t, st.idle, st.last = bytes, now, 0, 0
    end
    st.busy = true
    ngx.ctx.npm_upload_window = serial
    arm(serial, st)
end

-- Every request (conf/server.conf, rewrite phase). An address counts as "wants
-- room" for ROOM_TTL seconds after
--  * an HTTP/3 request from it, or
--  * any request from it by another program than the one that is uploading from it right
--    now (another User-Agent): a browser that was pushed to HTTP/2, or one that is about to
--    start HTTP/3. A new HTTP/3 connection could not even be set up behind a full-speed
--    upload: the token of a QUIC Retry is valid for 3 s.
function _M.h3()
    if not ROOM then
        return
    end
    local d = ngx.shared.h3_recent
    if not d then
        return
    end
    local addr = ngx.var.remote_addr
    if ngx.var.server_protocol == "HTTP/3.0" then
        d:set(addr, true, ROOM_TTL)
        return
    end
    local up = d:get("u|" .. addr)
    if up and up ~= ngx.crc32_short(ngx.var.http_user_agent or "") then
        d:set(addr, true, ROOM_TTL)
    end
end

function _M.done()
    local serial = ngx.ctx.npm_upload_window
    local st = serial and conns[serial]
    if st then
        st.busy = false
        st.seen = ngx.now()
    end
end

-- for tests: number of connections this worker knows, and the window held for one
function _M.state(serial)
    local st = serial and conns[serial]
    return count, st and (st.win or 0)
end

return _M
