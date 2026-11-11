#!/usr/bin/env python3
"""What the server does with a client it cannot hear (quic_silent_timeout, see
patches/nginx-quic-client-silent.patch). Runs in the client container; the
"cut" modes need silent-test.sh on the host, which cuts the UDP of this container.

  idle    one request, then nothing: how often the server asks (PING) and whether the
          connection is still open afterwards
  cut     one request, UDP out is cut, a second request is sent into the void: when and
          how the server closes
  cutdl   the same in the middle of a 60 MB download
"""
import asyncio, json, os, ssl, sys, time
from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated
from aioquic.quic.logger import QuicLogger

ADDR = os.environ.get("LAB_ADDR", "172.31.250.10")          # staging; LAB_ADDR/LAB_HOST: another edge
HOST = os.environ.get("LAB_HOST", "h3test.example.org")


class Client(QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.h3 = H3Connection(self._quic)
        self.done = {}
        self.bytes = 0
        self.closed = None

    def quic_event_received(self, event):
        if isinstance(event, ConnectionTerminated):
            self.closed = (time.monotonic(), event.error_code, event.reason_phrase)
        for ev in self.h3.handle_event(event):
            if isinstance(ev, DataReceived):
                self.bytes += len(ev.data)
            if getattr(ev, "stream_ended", False) and ev.stream_id in self.done:
                self.done[ev.stream_id].set_result(True)

    def get(self, path):
        sid = self._quic.get_next_available_stream_id()
        self.done[sid] = self._loop.create_future()
        self.h3.send_headers(sid, [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", HOST.encode()),
                                   (b":path", path.encode()), (b"user-agent", b"h3lab-silent")], end_stream=True)
        self.transmit()
        return self.done[sid]


def pings(log, since):
    """times (s after `since`) at which a packet with a PING frame arrived"""
    out = []
    for tr in log.to_dict()["traces"]:
        for ev in tr["events"]:
            if ev["name"] == "transport:packet_received" and any(f["frame_type"] == "ping" for f in ev["data"].get("frames", [])):
                out.append(ev["time"] / 1000)
    return out


async def main(mode):
    log = QuicLogger()
    c = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, quic_logger=log)
    c.verify_mode = ssl.CERT_NONE; c.server_name = HOST; c.idle_timeout = 120
    c.max_stream_data = 6 * 1024 * 1024; c.max_data = 15 * 1024 * 1024
    async with connect(ADDR, 443, configuration=c, create_protocol=Client) as cl:
        await cl.get("/headers?silent-" + mode)
        t_req = time.monotonic()
        if mode == "idle":
            wait = float(sys.argv[2]) if len(sys.argv) > 2 else 45
            await asyncio.sleep(wait)
            got = pings(log, t_req)
            still = cl.closed is None
            if still:
                await asyncio.wait_for(cl.get("/headers?silent-idle-after"), 5)
            print(json.dumps(dict(mode=mode, idle_seconds=wait, server_asked=len(got),
                                  asked_at=[round(x - got[0], 1) for x in got] if got else [],
                                  connection_open_after=still, request_after_ok=still)), flush=True)
            return
        if mode == "cutdl":
            cl.get("/download?bytes=60000000")
            await asyncio.sleep(1.0)
        open("/tmp/silent_ready", "w").write("x")          # silent-test.sh cuts UDP out now
        for _ in range(100):
            if os.path.exists("/tmp/silent_cut"):
                break
            await asyncio.sleep(0.05)
        t_cut = time.monotonic()
        if mode == "cut":
            await asyncio.sleep(0.5)
            cl.get("/headers?silent-lost")                 # never arrives
        for _ in range(600):
            if cl.closed:
                break
            await asyncio.sleep(0.05)
        if cl.closed:
            print(json.dumps(dict(mode=mode, closed_by_server_after_s=round(cl.closed[0] - t_cut, 1),
                                  error_code=hex(cl.closed[1]), reason=cl.closed[2],
                                  received_mb=round(cl.bytes / 1048576, 1))), flush=True)
        else:
            print(json.dumps(dict(mode=mode, closed_by_server_after_s=None, note="not closed within 30 s")), flush=True)
        os._exit(0)

asyncio.run(main(sys.argv[1]))
