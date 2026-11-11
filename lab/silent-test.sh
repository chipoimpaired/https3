#!/bin/bash
# silent-test.sh   (staging edge and client container of lab/README.md)
# The server and a client it cannot hear (directive quic_silent_timeout, patch
# patches/nginx-quic-client-silent.patch). The UDP of the client container is
# cut with tc inside that container; nothing on the host changes.
C=$(docker inspect -f '{{.State.Pid}}' npm-stage-client)
cut_() { nsenter -t $C -n tc qdisc add dev eth0 root handle 1: prio; nsenter -t $C -n tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff action drop; }
open_() { nsenter -t $C -n tc qdisc del dev eth0 root 2>/dev/null; }
open_
echo "== a client that is idle: asked at most 15 times, connection stays open"
docker exec npm-stage-client python /lab/silent.py idle 45
for m in cut cutdl; do
  echo "== a client that cannot be heard ($m)"
  docker exec npm-stage-client rm -f /tmp/silent_ready /tmp/silent_cut
  docker exec npm-stage-client python /lab/silent.py $m &
  for i in $(seq 1 100); do docker exec npm-stage-client test -f /tmp/silent_ready 2>/dev/null && break; sleep 0.2; done
  cut_; docker exec npm-stage-client touch /tmp/silent_cut
  wait; open_
done
