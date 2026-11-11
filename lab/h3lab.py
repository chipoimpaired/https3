#!/usr/bin/env python3
"""HTTP/3 lab client: several transfers on ONE connection, with timing.

Runs inside the client container of the staging network (see README.md in this folder).

  mix     a "player" fetches a piece every few seconds; in the middle a page load of many
          files starts on the same connection. Reports how long each piece took.
          --model mixed    256 files scaled to --page-mb (default 6 MB)
          --model bundles  250 files, 9.6 MB, four script bundles of 1.2 to 2.4 MB
          --concurrency N  files requested at a time
          --proto 2        the same over HTTP/2 (yardstick)
  stress  many downloads of mixed sizes plus uploads at once; everything must arrive whole
  get     one download, reports MB/s          put     one upload, reports MB/s
  player  a player alone: one piece every --every seconds for --duration seconds, while
          something else loads the link (uplink.sh: an upload of the same device)
"""
import argparse
import asyncio
import json
import random
import ssl
import time

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class Client(QuicConnectionProtocol):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.h3 = H3Connection(self._quic)
        self.streams = {}

    def quic_event_received(self, event):
        for ev in self.h3.handle_event(event):
            st = self.streams.get(getattr(ev, "stream_id", None))
            if st is None:
                continue
            now = time.monotonic()
            if isinstance(ev, HeadersReceived):
                st["status"] = dict(ev.headers).get(b":status", b"?").decode()
                st["t_head"] = now
            elif isinstance(ev, DataReceived):
                if st["t_first"] is None and ev.data:
                    st["t_first"] = now
                st["bytes"] += len(ev.data)
            if getattr(ev, "stream_ended", False):
                st["t_end"] = now
                self.streams.pop(ev.stream_id, None)
                if not st["fut"].done():
                    st["fut"].set_result(st)

    def _new(self):
        sid = self._quic.get_next_available_stream_id()
        st = dict(fut=self._loop.create_future(), bytes=0, t_first=None, t_head=None, status=None,
                  t_start=time.monotonic(), t_end=None)
        self.streams[sid] = st
        return sid, st

    async def get(self, host, path):
        sid, st = self._new()
        self.h3.send_headers(sid, [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", host.encode()),
                                   (b":path", path.encode()), (b"user-agent", b"h3lab")], end_stream=True)
        self.transmit()
        return await st["fut"]

    async def put(self, host, path, size):
        sid, st = self._new()
        self.h3.send_headers(sid, [(b":method", b"POST"), (b":scheme", b"https"), (b":authority", host.encode()),
                                   (b":path", path.encode()), (b"user-agent", b"h3lab"),
                                   (b"content-length", str(size).encode()),
                                   (b"content-type", b"application/octet-stream")], end_stream=False)
        block = bytes(256 * 1024)
        left = size
        stream = self._quic._streams[sid]
        while left > 0:
            # keep at most 4 MB waiting in the library, the rest is paced by flow control
            while stream.sender._buffer_stop - stream.sender._buffer_start > 4 * 1024 * 1024:
                await asyncio.sleep(0.002)
            n = min(left, len(block))
            left -= n
            self.h3.send_data(sid, block[:n], end_stream=(left == 0))
            self.transmit()
        return await st["fut"]


class H2Client:
    """The same get() over HTTP/2 (TCP), one connection, browser-sized windows."""

    def __init__(self, addr, host):
        self.addr, self.host, self.streams = addr, host, {}

    async def __aenter__(self):
        import h2.config, h2.connection, h2.settings
        ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        ctx.set_alpn_protocols(["h2"])
        self.r, self.w = await asyncio.open_connection(self.addr, 443, ssl=ctx, server_hostname=self.host)
        self.c = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=True))
        self.c.initiate_connection()
        self.c.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 6 * 1024 * 1024})
        self.c.increment_flow_control_window(15 * 1024 * 1024)
        self.w.write(self.c.data_to_send())
        self.task = asyncio.create_task(self._read())
        return self

    async def __aexit__(self, *a):
        self.task.cancel(); self.w.close()

    async def _read(self):
        import h2.events
        while True:
            data = await self.r.read(262144)
            if not data:
                return
            for ev in self.c.receive_data(data):
                st = self.streams.get(getattr(ev, "stream_id", None))
                now = time.monotonic()
                if isinstance(ev, h2.events.ResponseReceived) and st:
                    st["status"] = dict(ev.headers).get(b":status", b"?").decode()
                elif isinstance(ev, h2.events.DataReceived):
                    self.c.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                    if st:
                        if st["t_first"] is None:
                            st["t_first"] = now
                        st["bytes"] += len(ev.data)
                elif isinstance(ev, h2.events.StreamEnded) and st:
                    st["t_end"] = now
                    self.streams.pop(ev.stream_id, None)
                    st["fut"].set_result(st)
            out = self.c.data_to_send()
            if out:
                self.w.write(out)

    async def get(self, host, path):
        while len(self.streams) >= 100:
            await asyncio.sleep(0.005)
        sid = self.c.get_next_available_stream_id()
        st = dict(fut=asyncio.get_running_loop().create_future(), bytes=0, t_first=None, status=None,
                  t_start=time.monotonic(), t_end=None)
        self.streams[sid] = st
        self.c.send_headers(sid, [(":method", "GET"), (":scheme", "https"), (":authority", host), (":path", path),
                                  ("user-agent", "h3lab")], end_stream=True)
        self.w.write(self.c.data_to_send())
        return await st["fut"]


def opened(args):
    if args.proto == 2:
        return H2Client(args.addr, args.host)
    return connect(args.addr, 443, configuration=conf(args), create_protocol=Client)


def conf(args):
    c = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    c.verify_mode = ssl.CERT_NONE
    c.server_name = args.host
    # receive windows of the order browsers use (Chrome: 6 MB per stream, 15 MB per connection)
    c.max_stream_data = 6 * 1024 * 1024
    c.max_data = 15 * 1024 * 1024
    c.idle_timeout = 120
    return c


def page_load(seed, total_mb, model="mixed"):
    """File sizes of a first, uncached load of a large web application."""
    rnd = random.Random(seed)
    if model == "bundles":
        # a few multi-megabyte script bundles among many small files (Nextcloud-like)
        sizes = [rnd.randint(500, 8000) for _ in range(220)]
        sizes += [rnd.randint(30000, 150000) for _ in range(26)]
        rnd.shuffle(sizes)
        for pos, big in ((10, 1200000), (14, 2400000), (30, 1600000), (60, 2000000)):
            sizes.insert(pos, big)
        return sizes
    sizes = [rnd.randint(1500, 40000) for _ in range(230)]
    sizes += [rnd.randint(90000, 300000) for _ in range(18)]
    big = [rnd.randint(500000, 2500000) for _ in range(8)]
    sizes += big
    scale = total_mb * 1024 * 1024 / sum(sizes)
    sizes = [max(800, int(s * scale)) for s in sizes]
    rnd.shuffle(sizes)
    return sizes


async def run_mix(args):
    out = dict(mode="mix", pieces=[], page=None)
    async with opened(args) as cl:
        t0 = time.monotonic()
        stop = asyncio.Event()

        async def player():
            i = 0
            while not stop.is_set():
                started = time.monotonic()
                st = await cl.get(args.host, f"/download?bytes={args.piece}&piece={i}")
                took = st["t_end"] - st["t_start"]
                out["pieces"].append(dict(at=round(started - t0, 2), took=round(took, 2),
                                          first=round((st["t_first"] or st["t_end"]) - st["t_start"], 2),
                                          ok=(st["status"] == "200" and st["bytes"] == args.piece)))
                i += 1
                wait = args.every - (time.monotonic() - started)
                if wait > 0:
                    try:
                        await asyncio.wait_for(stop.wait(), wait)
                    except asyncio.TimeoutError:
                        pass

        async def page():
            await asyncio.sleep(args.page_at)
            sizes = page_load(args.seed, args.page_mb, args.model)
            started = time.monotonic()
            sem = asyncio.Semaphore(args.concurrency)

            async def one(n, s):
                async with sem:
                    st = await cl.get(args.host, f"/download?bytes={s}&f={n}")
                    return st["status"] == "200" and st["bytes"] == s

            res = await asyncio.gather(*[one(n, s) for n, s in enumerate(sizes)])
            out["page"] = dict(files=len(sizes), mb=round(sum(sizes) / 1048576, 2),
                               at=round(started - t0, 2), took=round(time.monotonic() - started, 2),
                               ok=all(res))

        p = asyncio.create_task(player())
        await page()
        await asyncio.sleep(args.tail)
        stop.set()
        await p
    during = [x for x in out["pieces"] if out["page"]["at"] - 0.01 <= x["at"] <= out["page"]["at"] + out["page"]["took"]]
    before = [x for x in out["pieces"] if x["at"] < out["page"]["at"] - 0.01]
    ends = [x["at"] + x["took"] for x in out["pieces"]]
    gaps = [round(b - a, 2) for a, b in zip(ends, ends[1:])]
    out["summary"] = dict(
        piece_alone_max=max([x["took"] for x in before], default=None),
        piece_during_page_max=max([x["took"] for x in during], default=None),
        piece_during_page_all=[x["took"] for x in during],
        longest_gap_between_pieces=max(gaps, default=None),
        page_took=out["page"]["took"], page_mb=out["page"]["mb"],
        all_ok=out["page"]["ok"] and all(x["ok"] for x in out["pieces"]))
    print(json.dumps(out["summary"] if not args.verbose else out))


async def run_player(args):
    """One piece every --every seconds for --duration seconds; a piece that is not complete
    after --piece-timeout counts as failed. Reports what a viewer would notice."""
    pieces = []
    async with opened(args) as cl:
        t0 = time.monotonic()
        i = 0
        while time.monotonic() - t0 < args.duration:
            started = time.monotonic()
            try:
                st = await asyncio.wait_for(cl.get(args.host, f"/download?bytes={args.piece}&piece={i}"),
                                            args.piece_timeout)
                took, ok = st["t_end"] - st["t_start"], st["status"] == "200" and st["bytes"] == args.piece
            except asyncio.TimeoutError:
                took, ok = args.piece_timeout, False
            pieces.append(dict(at=round(started - t0, 1), took=round(took, 2), ok=ok))
            i += 1
            wait = args.every - (time.monotonic() - started)
            if wait > 0:
                await asyncio.sleep(wait)
        wall = time.monotonic() - t0
    good = [x for x in pieces if x["ok"]]
    tooks = sorted(x["took"] for x in good)
    out = dict(mode="player", proto=args.proto, seconds=round(wall, 1),
               media_seconds_fetched=round(len(good) * args.every, 1),
               pieces_ok=len(good), pieces_failed=len(pieces) - len(good),
               pieces_slower_than_playback=sum(1 for x in good if x["took"] > args.every),
               piece_median=tooks[len(tooks) // 2] if tooks else None,
               piece_max=tooks[-1] if tooks else None)
    if args.verbose:
        out["pieces"] = pieces
    print(json.dumps(out))


async def run_stress(args):
    """Many downloads of mixed sizes plus uploads at once on one connection; everything must arrive whole."""
    rnd = random.Random(args.seed)
    sizes = [rnd.choice([3000, 20000, 70000, 200000, 900000, 3000000]) for _ in range(args.count)]
    async with connect(args.addr, 443, configuration=conf(args), create_protocol=Client) as cl:
        t0 = time.monotonic()
        gets = [cl.get(args.host, f"/download?bytes={s}&n={n}") for n, s in enumerate(sizes)]
        puts = [cl.put(args.host, "/upload", args.upload) for _ in range(args.uploads)]
        res = await asyncio.wait_for(asyncio.gather(*gets, *puts), args.timeout)
        took = time.monotonic() - t0
    ok_get = sum(1 for st, s in zip(res, sizes) if st["status"] == "200" and st["bytes"] == s)
    ok_put = sum(1 for st in res[len(sizes):] if st["status"] == "200")
    print(json.dumps(dict(mode="stress", downloads=f"{ok_get}/{len(sizes)}", uploads=f"{ok_put}/{args.uploads}",
                          mb=round((sum(sizes) + args.uploads * args.upload) / 1048576, 1), seconds=round(took, 1))))


async def run_get(args):
    async with opened(args) as cl:
        st = await cl.get(args.host, f"/download?bytes={args.bytes}")
        took = st["t_end"] - st["t_start"]
        print(json.dumps(dict(mode="get", ok=st["status"] == "200" and st["bytes"] == args.bytes,
                              seconds=round(took, 2), mb_per_s=round(args.bytes / took / 1048576, 2))))


async def run_put(args):
    async with connect(args.addr, 443, configuration=conf(args), create_protocol=Client) as cl:
        st = await cl.put(args.host, "/upload", args.bytes)
        took = st["t_end"] - st["t_start"]
        print(json.dumps(dict(mode="put", ok=st["status"] == "200", seconds=round(took, 2),
                              mb_per_s=round(args.bytes / took / 1048576, 2))))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["mix", "get", "put", "stress", "player"])
    ap.add_argument("--addr", default="172.31.250.10")
    ap.add_argument("--host", default="h3test.example.org")
    ap.add_argument("--piece", type=int, default=160000)
    ap.add_argument("--every", type=float, default=4.0)
    ap.add_argument("--page-at", type=float, default=9.0)
    ap.add_argument("--page-mb", type=float, default=6.0)
    ap.add_argument("--concurrency", type=int, default=100)
    ap.add_argument("--tail", type=float, default=8.0)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--model", default="mixed")
    ap.add_argument("--proto", type=int, default=3, choices=[2, 3])
    ap.add_argument("--bytes", type=int, default=20 * 1024 * 1024)
    ap.add_argument("--count", type=int, default=40)
    ap.add_argument("--uploads", type=int, default=4)
    ap.add_argument("--upload", type=int, default=2 * 1024 * 1024)
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--duration", type=float, default=60)
    ap.add_argument("--piece-timeout", type=float, default=20)
    a = ap.parse_args()
    asyncio.run(dict(mix=run_mix, get=run_get, put=run_put, stress=run_stress, player=run_player)[a.mode](a))
