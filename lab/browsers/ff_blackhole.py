"""Firefox while the UDP of its machine does not get out (run-blackhole.sh cuts it for a while).

Seen on production on 2026-11-11: while the Nextcloud app of a phone uploads over TCP, nothing
the browser of the same phone sends over UDP arrives; TCP of the same phone passes. A page
fetches a 340 KB piece every 2 s, like a player; printed per piece: start (s), duration (ms),
protocol, or the error."""
import json, os, socket, subprocess, sys, time
total = float(sys.argv[1]) if len(sys.argv) > 1 else 100
prof = "/tmp/fb"
subprocess.run(["rm", "-rf", prof]); os.mkdir(prof)
prefs = [l for l in open("/lab/browsers/user.js") if "alt-svc-mapping-for-testing" not in l]   # Alt-Svc as a visitor learns it
open(prof + "/user.js", "w").write("".join(prefs) + 'user_pref("devtools.jsonview.enabled", false);\n')
ff = subprocess.Popen(["firefox-esr", "--headless", "--no-remote", "--profile", prof, "--marionette"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
s = None
for _ in range(120):
    try:
        s = socket.create_connection(("127.0.0.1", 2828), timeout=120); break
    except OSError:
        time.sleep(0.5)
buf = b""
def read():
    global buf
    while b":" not in buf:
        buf += s.recv(65536)
    n, rest = buf.split(b":", 1); n = int(n)
    while len(rest) < n:
        rest += s.recv(65536)
    buf = rest[n:]
    return json.loads(rest[:n])
mid = 0
def cmd(name, **params):
    global mid
    mid += 1
    m = json.dumps([0, mid, name, params]).encode()
    s.sendall(str(len(m)).encode() + b":" + m)
    r = read()
    if r[2]:
        return {"error": str(r[2])[:200]}
    return r[3]
read()
cmd("WebDriver:NewSession", capabilities={"alwaysMatch": {"acceptInsecureCerts": False}})
for i in range(4):                       # the first answers bring Alt-Svc, then the browser moves to HTTP/3
    cmd("WebDriver:Navigate", url="https://h3test.example.org/headers?warm%d" % i); time.sleep(1.5)
cmd("WebDriver:ExecuteScript", args=[], script="""
window.__log = []; window.__n = 0; window.__t0 = performance.now();
window.__iv = setInterval(() => {
  const n = window.__n++, t0 = performance.now(), url = '/download?bytes=340000&i=' + n;
  fetch(url, {cache: 'no-store'}).then(r => r.arrayBuffer().then(b => {
    const e = performance.getEntriesByName(location.origin + url).pop();
    window.__log.push([n, t0 - window.__t0, performance.now() - t0, e ? e.nextHopProtocol : '?', b.byteLength]);
  })).catch(err => { window.__log.push([n, t0 - window.__t0, performance.now() - t0, 'failed: ' + err, 0]); });
}, 2000);""")
open("/tmp/fb_started", "w").write(str(time.time()))
time.sleep(total)
log = cmd("WebDriver:ExecuteScript", args=[], script="clearInterval(window.__iv); return window.__log;").get("value") or []
started = set()
for n, at, took, proto, size in sorted(log):
    started.add(n)
    print("piece %3d  start %5.1f s  %6d ms  %s" % (n, at / 1000, took, proto if size == 340000 or str(proto).startswith("failed") else "%s (%d bytes)" % (proto, size)))
n_all = cmd("WebDriver:ExecuteScript", args=[], script="return window.__n;").get("value") or 0
print("pieces started %d, finished %d, never answered %d" % (n_all, len(log), n_all - len(log)))
cmd("Marionette:Quit", flags=["eForceQuit"])
