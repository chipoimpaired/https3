#!/bin/bash
# A phone that uploads and plays at the same time (lab/README.md).
#
# Seen on production on 2026-11-11: while the Nextcloud Android app uploaded (HTTP/1.1 over
# TCP, one connection, 10 MB chunks), PeerTube in the browser of the same phone stopped. The
# phone's own uplink queue was full of upload data (TCP round trip 6 s instead of 0.1 s), and
# the player's packets waited behind it or were dropped. How much a sender may queue is
# bounded by the receive window the server grants.
#
# The queue has to sit OUTSIDE the sending machine (as in a phone: in the modem), otherwise
# the sender's TCP sees it and holds back. So: a "phone" container behind a "router"
# container; the router's link to the server is the slow uplink with a deep queue.
#
#   uplink.sh up [rate] [queue] [ms one way] [down rate]   default 4mbit 3000k 30 30mbit
#   uplink.sh up none - <ms one way>   latency only, no rate limit
#   STARVE=1 uplink.sh up ...          the uplink serves UDP only while TCP has nothing queued (a real phone)
#   BURST=200k uplink.sh up 100mbit 600k 15 100mbit   a fast line (tbf needs a larger burst there)
#   uplink.sh run [seconds] [proto]   upload + player (HTTP/3, or 2), prints both results
#   uplink.sh alone [seconds] [proto] the player without the upload (yardstick)
#   uplink.sh speed [MB]              one HTTP/1.1 upload, bytes per second (e.g. after "up none - 15")
#   uplink.sh win                     receive window the server advertises during an upload
#   uplink.sh down
# Needs root, the staging edge of lab/README.md and the image npm-stage-h3client. Host untouched.
set -e
cd "$(dirname "$0")"
pid() { docker inspect -f '{{.State.Pid}}' "$1"; }
ns() { nsenter -t "$1" -n "${@:2}"; }
ADDR=172.31.250.10; HOST=h3test.example.org
CURL="curl -sk --http1.1 --resolve $HOST:443:$ADDR"
case "$1" in
 up)
   RATE=${2:-4mbit}; QUEUE=${3:-3000k}; MS=${4:-30}; DOWN=${5:-30mbit}
   "$0" down 2>/dev/null || true
   docker network create --internal --subnet 172.31.251.0/24 npm-stage-phone-net >/dev/null
   docker run -d --name npm-stage-router --network npm-stage-net --ip 172.31.250.40 npm-stage-h3client sleep infinity >/dev/null
   docker network connect --ip 172.31.251.2 npm-stage-phone-net npm-stage-router
   docker run -d --name npm-stage-phone --network npm-stage-phone-net --ip 172.31.251.30 -v "$PWD":/lab:ro npm-stage-h3client sleep infinity >/dev/null
   R=$(pid npm-stage-router); C=$(pid npm-stage-phone); S=$(pid npm-stage)
   ns $R sysctl -qw net.ipv4.ip_forward=1
   ns $C ip route add 172.31.250.0/24 via 172.31.251.2
   ns $S ip route replace 172.31.251.0/24 via 172.31.250.40
   UP=$(ns $R ip -o -4 addr show | awk '/172\.31\.250\.40/{print $2}'); DN=$(ns $R ip -o -4 addr show | awk '/172\.31\.251\.2/{print $2}')
   ns $R tc qdisc add dev $UP root handle 1: netem delay ${MS}ms limit 200000
   ns $R tc qdisc add dev $DN root handle 1: netem delay ${MS}ms limit 200000
   if [ "$RATE" != none ]; then
     ns $R tc qdisc add dev $UP parent 1:1 handle 10: tbf rate $RATE burst ${BURST:-20k} limit $QUEUE
     ns $R tc qdisc add dev $DN parent 1:1 handle 10: tbf rate $DOWN burst 40k limit 1000k
     if [ -n "$STARVE" ]; then
       # As measured on a test phone on 2026-11-13: what the phone sends over UDP gets out
       # only while its TCP upload has nothing queued, and small TCP packets (the
       # acknowledgements) have a lane of their own. Three bands under the rate limit:
       # small TCP first, the rest of TCP, UDP last.
       ns $R tc qdisc add dev $UP parent 10:1 handle 20: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
       ns $R tc filter add dev $UP parent 20: protocol ip prio 1 u32 match ip protocol 17 0xff flowid 20:3
       ns $R tc filter add dev $UP parent 20: protocol ip prio 2 u32 match ip protocol 6 0xff match u16 0x0000 0xff80 at 2 flowid 20:1
     fi
   fi
   docker exec npm-stage-phone sh -c 'head -c 10485760 /dev/urandom > /tmp/chunk'
   echo "phone link: up $RATE (queue $QUEUE), down $DOWN, $((MS*2)) ms round trip";;
 run|alone)
   SEC=${2:-60}; PROTO=${3:-3}
   docker exec npm-stage-phone python /lab/h3lab.py get --bytes 200000 >/dev/null    # first request after a start is slow
   if [ "$1" = run ]; then
     # like the app: chunk after chunk on one connection, until the player is done
     docker exec -d npm-stage-phone sh -c "stdbuf -oL $CURL -o /dev/null -w '%{speed_upload}\n' -T /tmp/chunk 'https://$HOST/upload/[1-200]' > /tmp/upload.txt 2>&1"
     sleep 3
   fi
   docker exec npm-stage-phone python /lab/h3lab.py player --proto $PROTO --piece 340000 --every 4 --duration $SEC
   if [ "$1" = run ]; then
     docker exec npm-stage-phone sh -c "for p in /proc/[0-9]*; do grep -qs '^curl' \$p/comm && kill \${p#/proc/}; done; sleep 0.3; awk '{n++; s+=\$1} END{if(n) printf \"upload: %d chunks of 10 MB complete, %.0f KB/s on average\n\", n, s/n/1000; else print \"upload: no chunk complete\"}' /tmp/upload.txt"
   fi;;
 speed)
   MB=${2:-100}
   docker exec npm-stage-phone sh -c "head -c $((MB*1048576)) /dev/zero > /tmp/big; $CURL -m ${MAXTIME:-300} -o /dev/null -w 'HTTP/1.1 upload %{speed_upload} B/s (status %{http_code})\n' -T /tmp/big https://$HOST/upload/speed; rm -f /tmp/big";;
 win)
   # window scale from the SYN-ACK of a fresh connection, then the largest window advertised
   S=$(pid npm-stage)
   ( timeout 14 nsenter -t $S -n tcpdump -ni eth0 -tt 'src host 172.31.250.10 and tcp src port 443 and dst host 172.31.251.30' 2>/dev/null > /tmp/npm-stage-win.txt; true ) &
   sleep 1
   docker exec npm-stage-phone sh -c "$CURL -m 10 -o /dev/null -T /tmp/chunk https://$HOST/upload/win" || true
   wait
   awk '/Flags \[S\.\]/ && match($0, /wscale [0-9]+/){w=substr($0, RSTART+7, RLENGTH-7)}
        !/Flags \[S/{for(i=1;i<=NF;i++) if($i=="win"){v=$(i+1); gsub(",","",v); if(v+0>m) m=v+0}}
        END{printf "window scale %s, largest advertised window %d bytes\n", w, m*2^w}' /tmp/npm-stage-win.txt
   rm -f /tmp/npm-stage-win.txt;;
 down)
   docker rm -f npm-stage-phone npm-stage-router >/dev/null 2>&1 || true
   docker network rm npm-stage-phone-net >/dev/null 2>&1 || true
   S=$(pid npm-stage 2>/dev/null) && ns $S ip route del 172.31.251.0/24 2>/dev/null || true;;
 *) sed -n '2,22p' "$0";;
esac
