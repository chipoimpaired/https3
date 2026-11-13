# HTTP/3 video stops on a phone while another app of the same phone uploads over TCP

Diagnosis and four server-side changes on an nginx (OpenResty) reverse proxy. Written so
that other operators of HTTP/3 edges can recognise the fault and repair it. Nothing in this
text identifies the deployment.

## Summary

A phone plays HLS video in the browser over HTTP/3. As soon as another app of the same
phone starts a large upload over TCP to the same server, the video stops, and it often does
not come back by itself when the upload is over. Other visitors play without a gap at the
same time, so the server looks healthy from outside. The test was made many times.

Three things were found, by measuring at the edge and, in a second round, on the phone
itself:

1. The upload filled the phone's own uplink queue, because the server granted it a TCP
   receive window of 15 MB. The round trip of the upload connection was 6.1 s.
2. While the TCP upload has data queued, the phone's modem (or its mobile network) holds
   back everything the phone sends over UDP and lets it out when an upload chunk ends, up
   to 21 s later. TCP acknowledgements of the same phone are not held. So HTTP/3 cannot
   work on that phone during its own upload, HTTP/2 can.
3. The browser does not give HTTP/3 up by itself: it waits on the dead connection, and when
   the server closes that one it opens the next (with 0-RTT) at the following chunk end.

What the edge does now: it keeps the upload from queueing seconds of data in the phone, it
closes an HTTP/3 connection whose client cannot be heard after 4 to 6 s, and while a client
on a slow line uploads and another program of the same device talks to the edge, it holds
the upload to about half of what the line carries, so that the phone lets its UDP out and
HTTP/3 keeps working next to the upload (fix 4). For operators who prefer the full upload
speed there is fix 3 instead: the HTTP/3 advertisement is withdrawn for that client's
address during the upload (`Alt-Svc: clear`) and given back afterwards, and the video runs
over HTTP/2 for that time. HTTP/3 stays on for everybody else in either case.

On the real phone, first round: 54 upload chunks of 10 MB in 20 minutes, all answered 201,
and in the same 20 minutes 295 media pieces delivered to the player with no aborted request.
Before: no media piece during an upload, dozens of aborted requests, the player dropped to
its lowest quality and stopped. Two days later the video stopped again on the same phone;
"Second round" below says why (the first version of fix 2 had a flaw that only a real phone
shows) and what was changed. After that, with fix 3: upload at 480 KB/s, 60 media pieces in
4 minutes over HTTP/2, none aborted, no gap. With fix 4: the video stays on HTTP/3 next to
the upload, 16.0 MB in 180 s (89 KB/s, what the player asks for), one connection, no gap,
and the upload runs at 290 KB/s.

## Environment

- Reverse proxy: OpenResty 1.31.8.1 (nginx 1.31.8) with HTTP/3, QUIC Retry, UDP GSO and TLS
  1.3 early data enabled; Linux 7.2 on the host.
- Behind it: a PeerTube instance (HLS, fragmented MP4) and a Nextcloud instance.
- Client: Firefox 158 on Android 16 (kernel 6.1) on mobile data, HSPA+ in the second round;
  Nextcloud Android app 34 (uploads over HTTP/1.1, one TCP connection, 10 MB chunks). The
  test was repeated many times.

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

**3. While the upload transmits, no UDP packet of the phone arrives.** The server's QUIC probes
stay unanswered. (In the first round this looked like loss. It is not: the packets are held and
arrive later, all of them, see "Second round".) UDP passes only in the one second in which an
upload chunk ends; the times of the `PUT ... 201` lines and of the UDP bursts were identical
eleven times in a row. Other small TCP connections of the same phone pass in the middle of a
chunk within a second. The same in every repetition of the test. This stayed true after the
queue of finding 2 was gone (round trip 0.2 s), so it is not a matter of queue length. Why
a phone or a mobile network does this is not known to us.

**4. Firefox does not leave the dead HTTP/3 connection.** A client notices only by its own
idle timeout (30 s) that it is not heard, and every packet the server sends starts that
timeout again; a server repeats what is not acknowledged, and on the phone a burst got
through every 20 s anyway. Requests hung, the player gave most of them up. After four minutes
Firefox moved the video to HTTP/2 by itself, and there the video played during the upload,
which showed where the cure is. (Chromium's QUIC code has a blackhole detector, its tests use
delays of 5 to 10 s; for Firefox there are open reports about requests that hang when UDP is
blocked, Mozilla bugs 1982072 and 1997737.)

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
The module needs a host that allows a 4 MB receive buffer (`net.core.rmem_max` of 4194304
or more; the Linux default is 212992). On a host without it the module does nothing, and
says nothing: it could take a window away there but not give it back.

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

nginx reads it, like its other QUIC settings, from the default server of the listener: set
it at http level or in the default server. In another server block it is accepted and does
nothing. (Second version of the patch; what was wrong with the first is in "Second round".)

- When nothing has arrived from a client for half the time, the server sends a PING, and
  once more at three quarters of the time, so that there is something the client has to
  answer. A client with nothing in progress is asked at most 15 times in a row without a
  request in between; a client that is merely idle is then left alone.
- When nothing has arrived for the whole time although the server asked twice, the
  connection is closed the way a reload closes it: GOAWAY, then CONNECTION_CLOSE with
  H3_NO_ERROR. The phone still receives that. The time a client has to answer is half the
  time set, or four times the lowest round trip seen if that is longer, and never more than
  the time set: a connection is closed after 1 to 1.5 times the time.

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

## Second round: what the phone really does, and two more changes

Two days after the first round the video stopped again on the same phone, same test. At the
edge: one HTTP/3 connection lived through the whole upload. Between two chunk ends the
server sent one probe in 10 to 20 s and never closed it. In each burst came 100 and more
requests of the player, most already given up: per minute up to 86 answers with status 499
and 0 bytes. No media was delivered, and afterwards the player was stuck (it asked for the
same 1348-byte piece six times a second until the page was reloaded).

**The first version of fix 2 waited for nginx's probe timeout, and a phone makes that
timeout grow.** It closed when nothing had arrived for 4 s and two probe timeouts of the
loss timer had passed. The probe timeout follows the smoothed round trip time. The phone
does not drop what the browser sends during the upload, it holds it and lets it out later;
every acknowledgement that arrives seconds late is a round trip sample (RFC 9002 has no
rule against that), the probe timeout grew to many seconds, and two of them no longer
fitted between two chunk ends. The lab test of the first round dropped the packets instead
of holding them, and its client measured the close from its own side, where it waits three
of its own (equally inflated) probe timeouts: both hid the flaw. The second version sends
its questions itself and does not use the smoothed round trip time. Lab, every packet of
the client let out 2.5 s late and then none, measured on the server's side: first version
closed after 9.0 s (it grows with the delay), second after 4.5 s.

**Where the UDP is held: measured on the phone.** Numbered UDP packets were sent from the
phone to the server's udp/443 during an upload (five a second, through `adb`, under the
browser's app identity), with a capture on the phone's mobile interface and one at the edge:

- the phone's kernel hands every packet to the modem on time: one every 0.2 s, longest gap
  0.6 s, the kernel's queue empty;
- they reach the edge in bursts, in the second in which an upload chunk ends: up to 21.5 s
  late, 240 of 240 arrived;
- the modem driver has a second transmit queue that had carried only small packets (TCP
  acknowledgements), and TCP answers of the phone are indeed not held: HTTP/2 video runs
  next to the upload.

So the hold is in the modem or in the mobile network, it lets UDP out only when the TCP
upload has nothing queued, and no server setting can make HTTP/3 work on that phone while
the upload runs at full speed. It can be bought with upload speed: the edge held the upload
of that one address to a fixed receive window (below what the line carries, so that the
phone's queue runs empty between packets) and measured:

| receive window for the upload | upload | UDP of the phone: delay median / longest | video over HTTP/3 |
|---|---|---|---|
| not limited (128 KB or more) | 480 KB/s | up to 21.5 s | none |
| 56 KB | 445 KB/s | 0.30 s / 2.9 s | not measured |
| 48 KB | 386 KB/s | 0.11 s / 2.2 s | not measured |
| 44 KB | 358 KB/s | 0.09 s / 0.9 s | 64 KB/s: the player stops and goes on (it needs 85) |
| 40 KB | 350 KB/s | 0.03 s / 0.5 s | not measured |
| 28 KB | 217 KB/s | not measured | 86 KB/s: enough |

(The line's speed moved during these tries; the last row was taken later than the others.)
HTTP/3 next to the upload needed the upload at about half speed, and was then no better
than HTTP/2 at full speed. The operator first chose full upload speed and HTTP/2 for that
time (fix 3), and an hour later HTTP/3 itself next to the upload (fix 4).

**Firefox goes back to HTTP/3 at every chunk end.** With the second version of fix 2 the
starved connection was closed 4 s after the phone went quiet and the video continued over
HTTP/2 one second later. But at the next chunk end the phone's held packets got out, among
them the first flight of a new HTTP/3 connection with 0-RTT that Firefox 158 had started
right after the close. Firefox moved the video to it, the handshake could not finish (the
phone held UDP again), and Firefox waited 26 s before it returned to HTTP/2: two stops of
26 s in two minutes. (The rule of fix 2 does not watch a connection before its handshake is
done; nginx's own limit there is 60 s.)

## Fix 3: withdraw the HTTP/3 advertisement while the client uploads on a slow line

- The upload module of fix 1 notes the address of a client whose HTTP/1.x upload runs below
  2 MB/s in a table shared by all workers, for 15 s beyond its last look at the upload.
- A header filter answers a noted address on its HTTP/1.x and HTTP/2 connections with
  `Alt-Svc: clear` instead of the HTTP/3 advertisement. The browser stops trying HTTP/3.
  15 s after the upload the advertisement is sent again and the browser comes back.
- HTTP/3 answers and all other addresses are untouched. An address can be a NAT: other
  devices behind it use HTTP/2 for that time. Uploads of 2 MB/s and more mark nothing.
- The advertisement has to be set with `more_set_headers`, not `add_header`: nginx's own
  `add_header` runs after the Lua filter and the answer would carry both lines.

| test | result |
|---|---|
| lab: answer to a client during its own slow upload, over HTTP/2 and HTTP/1.1 | `Alt-Svc: clear`, one line |
| lab: HTTP/3 answer to the same client; HTTP/2 answer to another address | `h3=":443"` as before |
| lab: 17 s after the upload | `h3=":443"` again |
| lab: Firefox ESR 153, its UDP held like on the phone, a slow upload from the same machine | 82 of 82 pieces, one 2 s late; HTTP/2 during the upload without going back and forth; HTTP/3 again 3 s after the note ran out (without fix 3 it stayed on HTTP/2 to the end of the test) |
| real phone | upload 480 KB/s; 60 media pieces in 4 minutes over HTTP/2, none aborted, no HTTP/3 attempt during the upload, no gap (before: two stops of 26 s in two minutes) |
| real phone, after the upload | video back on HTTP/3 by itself within 36 s |

## Fix 4: the upload makes room for the same device's HTTP/3

The other choice: HTTP/3 keeps working next to the upload, and the upload pays for it. In
the same Lua module (`room()` and `h3()`), switched by one constant (`ROOM`); with it on,
fix 3 sends nothing.

- An address "wants room" for 30 s after an HTTP/3 request from it, or after any request
  from it by another program than the one that is uploading (another User-Agent): a browser
  that is on HTTP/2 at the moment, or one that is about to start HTTP/3. The second trigger
  is needed because a new HTTP/3 connection cannot even be set up behind a full-speed
  upload (the token of a QUIC Retry lives 3 s). The uploading program's own requests do not
  count; with no other program active the upload runs at full speed.
- While its address wants room, an HTTP/1.x upload below 2 MB/s is held by the receive
  window to 0.55 of what the line carries. A sender held below what its line carries sends
  each packet as an acknowledgement releases it and queues nothing, and then the phone lets
  UDP out.
- What the line carries is what the upload delivered before it was held, measured again
  every 30 s by opening the window to three times its size for one second. The window is
  that share times the round trip (the larger of the two lowest values the kernel reports
  for the connection, sender side and receiver side). It is lowered by a quarter only when
  the sender's round trip, as the receiver sees it from the timestamp echoes
  (`tcpi_rcv_rtt`), stays far above its lowest value for two seconds.

**Two versions of this steering passed the lab and failed on the phone.** The first moved
the window step by step until the upload delivered its share and took a 30 ms rise of the
round trip as "the sender is queueing": on the real 3G line the round trip moves by tens of
milliseconds all the time, and the upload was cut to 30 KB/s. The second cut whenever the
upload delivered less than its share and reckoned the window after a measurement from the
last window and the last delivery: it squeezed the upload to 50 KB/s and then let it run
full, HTTP/3 starved for 5 s and the browser left. On such a line neither delivery nor round
trip is steady enough to steer by from one look to the next; the version that holds reckons
the window from two measured quantities and leaves it alone.

| test | result |
|---|---|
| lab, uplink that serves UDP only while TCP has nothing queued (`STARVE=1 uplink.sh up`), upload + HTTP/3 player | 24 of 24 pieces, median 0.15 s (as without upload), upload 217 of 470 KB/s; with the upload at full speed: 0 pieces |
| lab, the line halves and recovers during the upload | 28 of 28 pieces, longest 0.62 s; the upload follows |
| lab, HTTP/2 player next to the upload; upload alone | 12 of 12; 471 and 474 KB/s (full speed) |
| lab, upload first, then another program asks over HTTP/2, then a new HTTP/3 connection | window 131 KB -> 16 KB within 3 s, the connection is set up in 0.34 s |
| real phone, upload + video, 3 minutes | video over HTTP/3: 16.0 MB (89 KB/s, every 15 s step 1229 to 1426 KB), one connection, the phone's UDP never silent for more than 3 s; upload 290 KB/s (full speed 480) |
| real phone, 12 minutes | 106 media pieces, none aborted; 21 upload chunks, all answered 201 |

The video is the same over both protocols (HTTP/2 at full upload speed: 60 pieces in 4
minutes, none aborted); HTTP/3 next to the upload costs about 40 % of the upload speed, and
only while another program of the phone is active.

## What remains

- HTTP/3 next to a phone's own upload costs upload speed (fix 4), or the video runs over
  HTTP/2 for that time (fix 3). Why modems or mobile networks hold UDP behind a TCP upload
  is not known to us; a phone that did not, or that had a lane for small UDP packets as it
  has for TCP acknowledgements, would need neither. Related but not the same: an iroh
  report of a QUIC path over Android mobile data that dies under an upload (iroh issue 4647).
- An address can be a NAT: with fix 4 an upload behind it is held while any other program
  behind it talks to the edge; with fix 3 the other devices use HTTP/2 for that time.
- A reload of nginx can break a running upload of the app once (it shows "server
  unavailable" and goes on after a retry). Seen once while the app was between two chunks.
- The return to HTTP/3 after the upload, on the phone: the upload ended, and 36 s later the
  video ran over HTTP/3 again (8.7 MB over one QUIC connection in the next 100 s, nothing
  over TCP), without anything being touched on the phone.
- A connection that has been idle for more than 30 s is not watched. If the upload starts
  then, the browser waits for its own timeout once.
- A connection whose handshake cannot finish is not closed early. Fix 3 keeps the browser
  from starting one during the upload; a browser that ignores `Alt-Svc: clear` would wait.
- The token of a QUIC Retry is valid for 3 s in nginx: a new visitor whose second packet is
  held longer cannot connect over HTTP/3 at all and has to fall back by himself.
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
  60 s, or lets it pass for one second every 21 s as measured on the phone;
- UDP held, not dropped (what the phone really does): the same filter sends UDP into a
  `sch_plug` queue, which holds packets and lets them out on command. `silent-test.sh late`
  lets every packet of a lab client out 2.5 s late and measures on the server's side when
  the server gives the client up; `browsers/run-blackhole.sh hold` does it to Firefox.

## How this was worked out

In one working session with Claude, the AI model of Anthropic, with the operator repeating
the test on a phone many times while the agent measured at the edge:

1. per-second capture of the phone's TCP and UDP during the stall, matched against the
   access log: this showed the 6 s round trip and, later, the UDP gap at chunk boundaries;
2. reproduction in a container lab, internet search for prior work (RFC 9840, the IMC 2016
   paper, the kernel's receive buffer change, browser fallback behaviour);
3. fix 1, tested in staging, deployed, and found not sufficient on the real phone: the lab
   had modelled only a queue, the phone does something a lab did not predict. Measuring the
   real device again gave finding 3;
4. fix 2, tested with a real Firefox in the lab, deployed, confirmed on the phone;
5. two days later the same test failed on the same phone. Capture at the edge again: one
   connection that was never closed. The patch was read against what the capture showed
   (one probe in 10 to 20 s), the lab was changed to hold packets instead of dropping them,
   and the second version of fix 2 was tested, deployed and seen closing after 4 s;
6. the operator wanted HTTP/3 itself during the upload, so the cause was measured on the
   phone itself (numbered UDP packets), and the price of HTTP/3 next to the upload was
   measured on the live edge with a test switch for that one address. The operator decided
   against paying it;
7. the next capture showed Firefox going back to HTTP/3 at every chunk end, which gave fix 3;
8. the operator then wanted HTTP/3 itself next to the upload after all. Fix 4 took three
   versions: each passed the lab, the first two failed on the phone within minutes, and
   each time the capture at the edge (upload speed and the phone's UDP per second) showed
   how. The lab's uplink was changed to behave like the phone (UDP last, TCP
   acknowledgements first) so that it can at least show the starvation.

The lessons we would pass on: measure the real device before and after, per protocol; a lab
proves the mechanism you modelled, not the device. A phone holds packets, a lab that drops
them tests something else. And measure a server on the server's side: a client that is not
heard is a poor witness of when it was given up. A real mobile line is far less steady than
any lab link: a control loop that is stable in the lab can run away on it in a minute, so
watch the device after every change, and prefer a rule that reckons from measured
quantities to one that feels its way.

## Files that go with this report

- `nginx-quic-client-silent.patch` (nginx 1.31.8 as bundled in OpenResty 1.31.8.1)
- `npm_upload_window.lua` and the places that use it (`lua_package_path`, two
  `lua_shared_dict`, a `rewrite_by_lua_block` line, a `header_filter_by_lua_block`, a
  `log_by_lua_block`)
- lab scripts: `uplink.sh`, `silent.py`, `silent-test.sh`, `slowpost.py`,
  `browsers/ff_blackhole.py`, `browsers/run-blackhole.sh`
