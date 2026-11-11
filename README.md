# HTTP/3 in front of PeerTube and Nextcloud: what went wrong and how it was fixed

An nginx (OpenResty 1.31.8.1) reverse proxy serves a PeerTube instance and a Nextcloud
instance over HTTP/3, with QUIC Retry, UDP GSO and TLS 1.3 early data switched on. On paper
that is a matter of a few directives. In use, video stopped, uploads crawled, and settings
that were switched on did nothing. This repository holds what was measured, the patches and
the configuration that made it work, and the lab to repeat the measurements.

Everything here was found on one deployment; the numbers are from its staging lab and from
real phones. Use it as a description of faults to look for, not as a drop-in product.

## The fault that needs a patch: video stops while the same phone uploads

A phone plays PeerTube in the browser over HTTP/3. As soon as the Nextcloud app of the same
phone uploads over TCP, the video stops. **[ISSUE.md](ISSUE.md) has the full report.** In short:

| cause | fix | result |
|---|---|---|
| The server grants the upload 15 MB of TCP receive window, the phone queues 3 MB in itself: round trip 6.1 s | `lua/npm_upload_window.lua`: the window follows what the sender's link carries | round trip 0.2 s, upload speed unchanged |
| While the TCP upload transmits, the phone lets no UDP out; Firefox keeps waiting on HTTP/3 | `patches/nginx-quic-client-silent.patch`: directive `quic_silent_timeout`, the server closes a connection whose client cannot be heard, the browser retries over HTTP/2 at once | Firefox: 30 s and 15 failed requests before, one request 2 s late and none failed after |

On the real phone after both: 56 upload chunks of 10 MB in 20 minutes and, in the same 20
minutes, 316 media pieces delivered with no aborted request. Before: none during an upload.

## Other HTTP/3 faults met on the same proxy

| fault | what was measured | fix |
|---|---|---|
| QUIC settings written into a virtual host do nothing. nginx reads the stream window, Retry, GSO and early data from the default server of the listener | HTTP/3 ran with the 64k default window: upload 1.8 MB/s, download 2.1 MB/s at 30 ms round trip; with the settings at http level 23 and 60 MB/s | `conf/http.conf` |
| After every reload the retired workers keep reading the QUIC sockets of the new ones for as long as a websocket keeps them alive | uploads at 30 KB/s, handshakes failing with "quic garbage token" | `conf/main.conf` bounds it, `patches/nginx-quic-exiting-worker.patch` removes it (60 of 60 requests fast after a reload) |
| `http3_stream_buffer_size` is also the amount one response may queue ahead of all others of the connection | on a 2 Mbit/s link a media piece that takes 1 s alone took 15.6 s while a page loaded | `patches/nginx-quic-send-slice.patch`: 8.7 s, transfer speeds unchanged |
| QUIC Retry without `quic_host_key` | a returning browser is refused after every reload ("cannot decrypt token") | `conf/http.conf` |
| `Alt-Svc` sent with `add_header` at server level | it disappears as soon as a location adds a header of its own (HSTS), and the site silently stops offering HTTP/3 | `more_set_headers`, `conf/server.conf` |
| 0-RTT requests can be replayed | a recorded first flight sent again was served a second time; OpenSSL's own protection, switched on, stops all session resumption | safe methods only, and a table of first flights shared by all workers, `conf/server.conf` |
| curl as an HTTP/3 test client (Debian 13, OpenSSL's QUIC stack) | with Retry on, about 1 of 20 new connections hangs and uploads are slow; browsers are not affected | test with a browser or the lab client |

## What is in here

- `ISSUE.md`: the report on the phone fault, written to be posted as it is.
- `patches/`: three patches for nginx 1.31.8 as bundled in OpenResty 1.31.8.1; apply them in
  this order: `nginx-quic-exiting-worker.patch`, `nginx-quic-send-slice.patch`,
  `nginx-quic-client-silent.patch` (`patch -p1` inside `bundle/nginx-1.31.8`). Each header
  says what the patch does and what was measured.
- `lua/npm_upload_window.lua`: the upload window, for OpenResty (LuaJIT FFI, Linux on x86-64
  or arm64). It needs `net.core.rmem_max` of 4 MB or more and does nothing on a host
  without it.
- `conf/`: `main.conf`, `http.conf`, `server.conf`: the directives and the two Lua hooks in
  the places where they take effect. nginx accepts them as they are (tested with the patched
  build).
- `lab/`: the scripts behind the numbers, see `lab/README.md`.

## How it was worked out

By measuring at the proxy while the operator tested with real phones, and by repeating each
fault in a container lab before and after a change. The work was done with Claude, the AI
model of Anthropic, over several sessions. The first fix for the phone fault was proven in
the lab and still did not help on the phone, because the lab had modelled only a queue;
measuring the real device again showed the second cause. A lab proves the mechanism you
modelled, not the device.

## Licence

The patches are changes to nginx source code and are offered under nginx's own 2-clause BSD
licence. No licence has been chosen for the other files yet.
