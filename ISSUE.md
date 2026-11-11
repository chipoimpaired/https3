# HTTP/3 video stops on a phone while another app of the same phone uploads over TCP

Diagnosis and two server-side fixes on an nginx (OpenResty) reverse proxy. Written so that
other operators of HTTP/3 edges can recognise the fault and repair it. Nothing in this text
identifies the deployment.

## Summary

A phone plays HLS video in the browser over HTTP/3. As soon as another app of the same
phone starts a large upload over TCP to the same server, the video stops, and it often does
not come back by itself when the upload is over. A second phone that does not upload plays
without a gap at the same time, so the server looks healthy from outside.

Two separate causes were found by measuring at the edge, and both had to be fixed:

1. The upload filled the phone's own uplink queue, because the server granted it a TCP
   receive window of 15 MB. The round trip of the upload connection was 6.1 s.
2. While the TCP upload transmits, the phone lets no UDP out at all. The browser keeps
   waiting on its HTTP/3 connection instead of moving to HTTP/2.

After both fixes, on the real phone: 56 upload chunks of 10 MB in 20 minutes, all answered
201, and during the same 20 minutes 316 media pieces delivered to the player with no aborted
request. Before: no media piece during an upload, dozens of aborted requests, the player
dropped to its lowest quality and stopped.

## Environment

- Reverse proxy: OpenResty 1.31.8.1 (nginx 1.31.8) with HTTP/3, QUIC Retry, UDP GSO and TLS
  1.3 early data enabled; Linux 7.2 on the host.
- Behind it: a PeerTube instance (HLS, fragmented MP4) and a Nextcloud instance.
- Clients: Firefox 155 on Android 14 and Firefox 158 on Android 16, on two different 4G
  networks; Nextcloud Android app 34 (uploads over HTTP/1.1, one TCP connection, 10 MB
  chunks).

## How it was measured

Everything was read at the edge, with sizes and times only, no payload:

- `tcpdump -q` for the phone's address, summed per second and split into TCP and UDP;
- the access log, to match the end of each upload chunk (`PUT ... 201`) with what the player
  received;
- TCP timestamps of the upload connection (the age of the server timestamp the phone
  echoes) for the round trip including the phone's queue;
- `ss -ti` on the server for the receive window actually granted.

## Findings

**1. The upload runs at a flat 500 KB/s: the phone's uplink is full.** That alone is normal.

**2. The kernel granted the upload 15 MB of receive window.** Linux sizes the receive buffer
by itself, and the maximum (`net.ipv4.tcp_rmem`) is 32 MB on recent kernels where it used
to be 6 MB. A sender may keep as much in flight as the window allows, so the phone kept about
3 MB queued in its own modem. Measured round trip of the upload connection: 6.1 s, lowest
0.09 s. Everything else the phone sends waits behind that queue. This is the on-device upload
bufferbloat described in "Understanding On-device Bufferbloat for Cellular Upload" (IMC 2016).

**3. While the upload transmits, no UDP packet of the phone arrives.** Not delayed: absent.
The server's QUIC probes stay unanswered. UDP passes only in the one second in which an
upload chunk ends; the times of the `PUT ... 201` lines and of the UDP bursts were identical
eleven times in a row. Other small TCP connections of the same phone pass in the middle of a
chunk within a second. The same on the second phone and network. This stayed true after the
queue of finding 2 was gone (round trip 0.2 s), so it is not a matter of queue length. Why
phones or mobile networks do this is not known to us.

**4. Firefox does not leave the dead HTTP/3 connection.** A client notices only by its own
idle timeout (30 s) that it is not heard, and every packet the server sends starts that
timeout again; a server repeats what is not acknowledged, and on the phone a burst got
through every 20 s anyway. Requests hung, the player gave most of them up. After four minutes
Firefox moved the video to HTTP/2 by itself, and there the video played during the upload,
which showed where the cure is. (Chromium's QUIC code has a blackhole detector, its tests use
delays of 5 to 10 s; for Firefox there is a report about missing fallback, Mozilla bug
1734110.)

## Fix 1: the receive window of an upload follows the sender's link

A small Lua module in OpenResty (`npm_upload_window.lua`, about 370 lines, LuaJIT FFI),
called in the rewrite and log phases. While a request body of 1 MB or more is received on an
HTTP/1.x connection, a timer looks at the connection twice a second (`TCP_INFO`: bytes
received, lowest round trip time) and sets the receive window (`SO_RCVBUF` and
`TCP_WINDOW_CLAMP`) to

    4 x (bytes per second received) x (round trip time)

never below 128 KB, and with no limit from 4 MB on. This is the idea of RFC 9840 (rLEDBAT):
the receiver steers the sender through the window it advertises, the client is not changed.

Two rules keep it from ever slowing an upload:

- every change is judged by what the sender delivers in the next second: a smaller window
  that costs speed is taken back and not tried again for a while;
- every few seconds a larger window is tried, and kept if the sender then delivers more.

HTTP/2 and HTTP/3 uploads have their own flow control windows and are not touched.

| measurement | before | after |
|---|---|---|
| round trip of the upload on the real phone | 6.1 s | 0.2 s |
| upload speed on the real phone | 489 KB/s | 489 KB/s |
| lab: 4 Mbit/s uplink with a deep queue, HTTP/3 player next to the upload, 340 KB pieces | 2 pieces in 78 s, 2 failed | 18 of 18, median 0.55 s |
| lab: 100 Mbit/s line, 30 ms and 100 ms round trip | 11.7 and 11.0 MB/s | 11.7 and 11.1 MB/s |
| lab: path that becomes 20 times longer after the connection started | 8.9 MB/s | 9.0 MB/s |

A fixed small window (`listen ... rcvbuf=`) gives the same relief on slow links but caps
fast uploaders at window / round trip time, which is why the window is adaptive.

Two details that cost time: the kernel overwrites `TCP_WINDOW_CLAMP` whenever its own
sizing grows the buffer, so the buffer has to be set with `SO_RCVBUF` as well; and a buffer
that was held small does not grow again by itself when it is handed back (`SO_BUF_LOCK`),
it has to be set large first.

**This fix alone did not bring the video back** (finding 3), but without it the HTTP/2
connection the browser falls back to would crawl behind the same 6 s queue.

## Fix 2: close an HTTP/3 connection whose client cannot be heard

A patch that adds about 110 lines to nginx's QUIC code brings one directive, off unless set:

    quic_silent_timeout 4s;        # context http, server

- When nothing has arrived from a client for half the time and nothing the server sent is
  waiting for an acknowledgement, the server sends a PING, so that there is something the
  client has to answer. At most 15 times in a row without a request of the client in
  between; a client that is merely idle is then left alone.
- When nothing has arrived for the whole time and two probe timeouts have passed without an
  acknowledgement, the connection is closed the way a reload closes it: GOAWAY, then
  CONNECTION_CLOSE with H3_NO_ERROR. The phone still receives that.

The browser then repeats the waiting requests over HTTP/2 by itself, at once, and comes back
to HTTP/3 later. A client that answers notices nothing; HTTP/3 stays on for everybody.

Firefox ESR 153 in a lab, a 340 KB piece requested every 2 s, the UDP of the browser's
machine cut for 60 s (TCP untouched):

| server | what the page sees |
|---|---|
| unpatched | 30 s without an answer, then 15 requests fail, then HTTP/2 |
| `quic_silent_timeout 4s` | one request 2 s late, none fail, HTTP/2 from 4 s after the cut (5 of 6 runs; in one run Firefox itself waited 30 s, still none failed) |

A lab QUIC client confirms the mechanics: an idle client is asked 15 times in 30 s and its
connection stays usable; a silent client is closed after 4.0 s, in the middle of a download
after 5.4 s. Retry, 0-RTT, a 0-RTT replay guard, transfer speeds, a stress test and reloads
behave as before with the patch.

## What remains

- The phone still lets no UDP out while it uploads; its video runs over HTTP/2 during that
  time, after one pause of 4 to 6 s. The cause inside the phone or the mobile network is
  open. Related but not the same: an iroh report of a QUIC path over Android mobile data
  that dies under an upload (iroh issue 4647).
- A connection that has been idle for more than 30 s is not watched. If the upload starts
  then, the browser waits for its own timeout once.
- Suggestions upstream: browsers could detect a path on which nothing is acknowledged within
  a few seconds and retry over TCP (as Chromium does); nginx could offer an option like the
  one above; the Linux receive buffer sizing could take the lowest round trip time into
  account when the sender's queue inflates the measured one.

## How to reproduce in a lab

All with containers on an internal Docker network and `tc` inside the containers' network
namespaces, nothing on the host:

- upload bufferbloat: a "phone" container behind a "router" container; the router's link to
  the server is a 4 Mbit/s token bucket with a 3 MB queue (the queue has to sit outside the
  sending machine, otherwise the sender's TCP sees it and holds back). An HTTP/1.1 upload in
  10 MB chunks on one connection next to an HTTP/3 client that fetches a 340 KB piece every
  4 s;
- UDP starvation: a `tc` filter in the browser's container that drops all outgoing UDP for
  60 s, or lets it pass for one second every 21 s as measured on the phones.

## How this was worked out

In one working session with Claude, the AI model of Anthropic, with the operator testing on
two phones while the agent measured at the edge:

1. per-second capture of the phone's TCP and UDP during the stall, matched against the
   access log: this showed the 6 s round trip and, later, the UDP gap at chunk boundaries;
2. reproduction in a container lab, internet search for prior work (RFC 9840, the IMC 2016
   paper, the kernel's receive buffer change, browser fallback behaviour);
3. fix 1, tested in staging, deployed, and found not sufficient on the real phone: the lab
   had modelled only a queue, the phones do something a lab did not predict. Measuring the
   real device again gave finding 3;
4. fix 2, tested with a real Firefox in the lab, deployed, confirmed on the phone.

The lesson we would pass on: measure the real device before and after, per protocol; a lab
proves the mechanism you modelled, not the device.

## Files that go with this report

- `nginx-quic-client-silent.patch` (nginx 1.31.8 as bundled in OpenResty 1.31.8.1)
- `npm_upload_window.lua` and the three places that call it (`lua_package_path`, a
  `rewrite_by_lua_block` line, a `log_by_lua_block`)
- lab scripts: `uplink.sh`, `silent.py`, `silent-test.sh`, `browsers/ff_blackhole.py`,
  `browsers/run-blackhole.sh`
