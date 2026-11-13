#!/bin/bash
# silent-test.sh [late]  (staging edge and client container of lab/README.md)
# The server and a client it cannot hear (directive quic_silent_timeout, patch
# patches/nginx-quic-client-silent.patch). The UDP of the client container is
# cut with tc inside that container; nothing on the host changes.
C=$(docker inspect -f '{{.State.Pid}}' npm-stage-client)
cut_() { nsenter -t $C -n tc qdisc add dev eth0 root handle 1: prio; nsenter -t $C -n tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff action drop; }
open_() { nsenter -t $C -n tc qdisc del dev eth0 root 2>/dev/null; }
# the same, but the packets are held, not dropped (sch_plug), and can be let out again
hold_() { nsenter -t $C -n tc qdisc add dev eth0 root handle 1: prio bands 4 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
          nsenter -t $C -n tc qdisc add dev eth0 parent 1:4 handle 40: plug limit 30000000
          nsenter -t $C -n tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff flowid 1:4; }
plug_() { nsenter -t $C -n tc qdisc change dev eth0 parent 1:4 handle 40: plug "$1"; }
open_
if [ "$1" = late ]; then
  echo "== a client whose packets all get out 2.5 s late, then not at all (late)"
  S=$(docker inspect -f '{{.State.Pid}}' npm-stage); CAP=$(mktemp)
  nsenter -t $S -n tcpdump -l -ni eth0 -q -tt udp port 443 and host 172.31.250.30 > $CAP 2>/dev/null & TD=$!
  docker exec npm-stage-client rm -f /tmp/silent_ready /tmp/silent_cut
  hold_                                            # the plug queue starts closed
  docker exec npm-stage-client python /lab/silent.py late &
  # "block" marks a point in the queue, "release" lets out what was queued before it
  for i in $(seq 1 60); do sleep 2.5; plug_ block; plug_ release
    docker exec npm-stage-client test -f /tmp/silent_ready 2>/dev/null && break; done
  docker exec npm-stage-client touch /tmp/silent_cut   # from here on nothing gets out
  sleep ${2:-32}; kill $TD; wait $TD 2>/dev/null; open_
  python3 - $CAP <<'PY2'
import re, sys
rows = []
for l in open(sys.argv[1]):
    m = re.match(r"(\d+\.\d+) IP (\S+) > \S+ UDP, length (\d+)", l.replace(": UDP", " UDP"))
    if m: rows.append((float(m.group(1)), m.group(2).startswith("172.31.250.10."), int(m.group(3))))
last_in = max(t for t, out, n in rows if not out)
after = [(round(t - last_in, 1), n) for t, out, n in rows if out and t > last_in]
print('{"mode": "late", "rounds_with_late_packets": %d, "server_packets_after_the_last_client_packet": %d, '
      '"server_went_quiet_after_s": %s}' % (len(set(round(t) for t, out, n in rows if not out)), len(after), after[-1][0] if after else None))
print("   (s after the client's last packet, bytes) of what the server sent then:", after[-14:])
PY2
  rm -f $CAP
  exit 0
fi
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
