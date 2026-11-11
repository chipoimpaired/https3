# The lab

The scripts that produced the numbers. They were written for one staging setup and are kept
as they were used; names and addresses will need adapting.

What they expect:

- an internal Docker network `npm-stage-net`, 172.31.250.0/24;
- the proxy under test as container `npm-stage` at 172.31.250.10, answering for
  `h3test.example.org` over HTTP/3 and HTTP/2 and forwarding to the echo backend;
- `echo-backend.mjs` (Node.js) at 172.31.250.20:8080: `/download?bytes=N` sends N bytes,
  `/upload` and every other path take a body and answer with its size and sha256,
  `/headers` shows what the proxy sent;
- the client image: `docker build -t npm-stage-h3client .` (Python with aioquic and h2, curl);
- for the browser test: `docker build -t npm-stage-browsers browsers/` (Firefox ESR, Chromium).

All shaping and cutting of traffic is done with `tc` inside the containers' network
namespaces (`nsenter`, root needed). Nothing on the host is changed.

## A phone that uploads: the queue (`uplink.sh`)

A "phone" container behind a "router" container; the router's link to the proxy is the slow
uplink with a deep queue. The queue has to sit outside the sending machine, as in a phone,
otherwise the sender's TCP sees it and holds back.

    ./uplink.sh up            # 4 Mbit/s up with a 3 MB queue, 30 Mbit/s down, 60 ms round trip
    ./uplink.sh alone 24      # the HTTP/3 player alone: a 340 KB piece every 4 s
    ./uplink.sh run 72        # an upload like the Nextcloud app (HTTP/1.1, 10 MB chunks) + the player
    ./uplink.sh win           # the receive window the proxy advertises
    BURST=200k ./uplink.sh up 100mbit 600k 15 100mbit; ./uplink.sh speed 150    # a fast line
    ./uplink.sh down

## A client that cannot be heard (`silent-test.sh`, `browsers/run-blackhole.sh`)

    docker run -d --name npm-stage-client --network npm-stage-net --ip 172.31.250.30 \
        -v $PWD:/lab:ro npm-stage-h3client sleep infinity
    ./silent-test.sh                   # lab client: idle, cut, cut during a download
    browsers/run-blackhole.sh          # Firefox, a piece every 2 s, its UDP cut for 60 s
    browsers/run-blackhole.sh phone    # UDP passes for one second every 21 s, as on the phones
    browsers/run-blackhole.sh close 5  # proxy without the directive, a reload as stand-in

`h3lab.py` has more modes (`get`, `put`, `stress`, `mix`: media pieces while a page loads on
the same connection); `python h3lab.py --help` lists the options.
