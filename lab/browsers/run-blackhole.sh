#!/bin/bash
# run-blackhole.sh [close [seconds] | phone | hold [cycles]]
# Firefox plays (a 340 KB piece every 2 s). From second 12 to second 72 nothing its machine
# sends over UDP gets out; TCP is not touched. With "close" the staging server is reloaded
# some seconds after the cut (default 5): the server has not seen the requests the browser
# sent since, so for it the HTTP/3 connection is idle and the retiring worker closes it at
# once with CONNECTION_CLOSE, which reaches the browser. Stand-in for a server that closes a
# connection whose client went silent (what quic_silent_timeout does by itself).
# With "phone" UDP passes for one second every 21 s during the cut, as on the phone.
# With "hold" (2026-11-13) the UDP packets are not dropped but HELD and let out for one
# second every 21 s, which is what the phone really does: the server then gets, up to 20 s
# late, the acknowledgements of what it sent before, takes them as round trip samples, and
# its probe timeout grows to many seconds. The first version of quic_silent_timeout never
# closed such a connection; "phone" (packets dropped) did not show that. Default 4 cycles.
# Needs the staging edge of lab/README.md and the image npm-stage-browsers. Host untouched.
LAB=$(dirname "$(dirname "$(readlink -f "$0")")")
docker rm -f npm-stage-browser >/dev/null 2>&1
docker run -d --name npm-stage-browser --network npm-stage-net --ip 172.31.250.45 \
    --add-host h3test.example.org:172.31.250.10 --shm-size 512m -v "$LAB":/lab:ro npm-stage-browsers sleep infinity >/dev/null
B=$(docker inspect -f '{{.State.Pid}}' npm-stage-browser)
T=96; [ "$1" = hold ] && T=$((12 + 21 * ${2:-4} + 24))
docker exec npm-stage-browser python3 /lab/browsers/ff_blackhole.py $T &
for i in $(seq 1 180); do docker exec npm-stage-browser test -f /tmp/fb_started 2>/dev/null && break; sleep 1; done
sleep 12
if [ "$1" = hold ]; then
  # all traffic in band 2, UDP alone in band 4 behind a plug queue (sch_plug: holds, does not drop)
  N="nsenter -t $B -n tc"
  $N qdisc add dev eth0 root handle 1: prio bands 4 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
  $N qdisc add dev eth0 parent 1:4 handle 40: plug limit 30000000
  $N filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff flowid 1:4
  echo "second 12: UDP from the browser's machine held"
  for n in $(seq 1 ${2:-4}); do sleep 20; $N qdisc change dev eth0 parent 1:4 handle 40: plug release_indefinite
    echo "second $((12 + 21 * n - 1)): held UDP let out, passes for one second"; sleep 1
    [ $n = ${2:-4} ] || $N qdisc change dev eth0 parent 1:4 handle 40: plug block; done
  sleep 0.3; $N qdisc del dev eth0 root
  echo "second $((12 + 21 * ${2:-4})): UDP passes again"
  wait
  docker rm -f npm-stage-browser >/dev/null 2>&1
  exit 0
fi
nsenter -t $B -n tc qdisc add dev eth0 root handle 1: prio
nsenter -t $B -n tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff action drop
echo "second 12: UDP from the browser's machine cut"
if [ "$1" = phone ]; then
  # as measured on the phone: UDP passes for about a second each time an upload chunk ends
  for n in 1 2; do sleep 20; nsenter -t $B -n tc qdisc del dev eth0 root; echo "second $((12+21*n-1)): UDP passes for one second"; sleep 1
    nsenter -t $B -n tc qdisc add dev eth0 root handle 1: prio; nsenter -t $B -n tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff action drop; done
  sleep 18
elif [ "$1" = close ]; then W=${2:-5}; sleep $W; docker exec npm-stage nginx -s reload; echo "second $((12+W)): staging server reloaded (closes the HTTP/3 connection)"; sleep $((60-W)); else sleep 60; fi
nsenter -t $B -n tc qdisc del dev eth0 root
echo "second 72: UDP passes again"
wait
docker rm -f npm-stage-browser >/dev/null 2>&1
