#!/bin/bash
# proxy.test.sh — hermetic tests for mmvpn-proxy (PAC server and HTTPS_PROXY relay).
#
# Runs mmvpn-proxy on a spare port against a temp config folder, a fake SOCKS5 tunnel and a local
# echo server. It never touches 1081, 1082 or the system proxy setting.
#
# WHAT IT PROTECTS
# 1. The PAC served carries exactly the routes in the URL; the bare URL means the sites only.
# 2. Only the PAC and /status are served (http.server, used before, served every file in the folder).
# 3. Relayed connections go through the tunnel only while tools-via-japan exists, with the name
#    resolved in Japan (socks5h), and go direct otherwise.
# 4. FAIL-OPEN: a dead or silent tunnel sends the connection direct, so the tools keep working.
# 5. This Mac's own addresses never go through the tunnel, flag or not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
J="${1:-$HERE/../bin/mmvpn-proxy}"
echo "── mmvpn-proxy (hermetic) ──"
[ -f "$J" ] || { echo "missing: $J"; exit 2; }
/usr/bin/python3 - "$J" "$HERE/../pac/jp.pac" "$HERE/../sites.example" "$HERE/pac-eval.js" <<'PY'
import asyncio, json, os, shutil, socket, subprocess, sys, tempfile, time
J, TEMPLATE, SITES, PACEVAL = sys.argv[1:5]
passed = failed = 0
def check(name, cond, detail=""):
    global passed, failed
    if cond: passed += 1; print("  OK   " + name)
    else: failed += 1; print("  NG   " + name + (" — " + str(detail) if detail else ""))

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

D = tempfile.mkdtemp(prefix="mmvpn-proxy.")
os.makedirs(os.path.join(D, "pac"))
shutil.copy(TEMPLATE, os.path.join(D, "pac", "jp.pac"))
shutil.copy(SITES, os.path.join(D, "sites"))
open(os.path.join(D, "kcp-client.json"), "w").write('{"secret": 1}')
FLAG = os.path.join(D, "tools-via-japan")
PORT, SOCKS, DEAD, ECHO = free_port(), free_port(), free_port(), free_port()
seen = []          # targets the fake tunnel was asked for
mode = {"hang": False}

async def echo_server():
    async def h(r, w):
        while True:
            d = await r.read(65536)
            if not d: break
            w.write(d); await w.drain()
        w.close()
    return await asyncio.start_server(h, "127.0.0.1", ECHO)

async def socks_server():
    async def h(r, w):
        await r.readexactly(3); w.write(b"\x05\x00"); await w.drain()
        head = await r.readexactly(4)
        if head[3] == 3:
            n = (await r.readexactly(1))[0]; host = (await r.readexactly(n)).decode()
        elif head[3] == 1:
            host = socket.inet_ntoa(await r.readexactly(4))
        else:
            host = socket.inet_ntop(socket.AF_INET6, await r.readexactly(16))
        port = int.from_bytes(await r.readexactly(2), "big")
        seen.append((head[3], host, port))
        if mode["hang"]:
            await asyncio.sleep(30); return
        ur, uw = await asyncio.open_connection("127.0.0.1", ECHO)   # every name lands on the echo server
        w.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01" + ECHO.to_bytes(2, "big")); await w.drain()
        async def p(a, b):
            while True:
                d = await a.read(65536)
                if not d: break
                b.write(d); await b.drain()
            b.close()
        await asyncio.gather(p(r, uw), p(ur, w), return_exceptions=True)
    return await asyncio.start_server(h, "127.0.0.1", SOCKS)

def start_proxy(socks_port, route_local):
    open(os.path.join(D, "config"), "w").write('PAC_PORT=%d\nSOCKS_PORT="%d"   # tunnel\n' % (PORT, socks_port))
    env = dict(os.environ, MMVPN_CONFIG_DIR=D, MMVPN_SOCKS_TIMEOUT="1",
               MMVPN_TEST_ROUTE_LOCAL="1" if route_local else "0")
    p = subprocess.Popen(["/usr/bin/python3", J], env=env, stderr=subprocess.PIPE)
    for _ in range(50):
        try: socket.create_connection(("127.0.0.1", PORT), 0.2).close(); return p
        except OSError: time.sleep(0.1)
    raise SystemExit("mmvpn-proxy did not start")

async def get(path):
    r, w = await asyncio.open_connection("127.0.0.1", PORT)
    w.write(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % path).encode()); await w.drain()
    data = await r.read(); w.close()
    head, _, body = data.partition(b"\r\n\r\n")
    return head.decode().split("\r\n")[0], head.decode(), body.decode()

async def tunnel(target, payload=b"ping\n"):
    """CONNECT through the relay, send payload, return (status line, echoed bytes)."""
    r, w = await asyncio.open_connection("127.0.0.1", PORT)
    status, got = "no reply", b""
    try:
        w.write(("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target, target)).encode()); await w.drain()
        status = (await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 10)).decode().split("\r\n")[0]
        if " 200 " in status:
            w.write(payload); await w.drain()
            got = await asyncio.wait_for(r.readexactly(len(payload)), 5)
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError) as e:
        status = status if status != "no reply" else "no reply (%s)" % type(e).__name__
    w.close()
    return status, got

JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
def pac_verdict(body, host):
    f = os.path.join(D, "served.pac"); open(f, "w").write(body)
    out = subprocess.run([JSC, PACEVAL, "--", f, host], capture_output=True, text=True).stdout.strip()
    return out.split(" ", 1)[1] if " " in out else out

async def main():
    e = await echo_server(); s = await socks_server()
    p = start_proxy(SOCKS, route_local=True)
    try:
        st, head, body = await get("/jp.pac?routes=sites")
        check("PAC is served with the PAC content type",
              st.endswith("200 OK") and "application/x-ns-proxy-autoconfig" in head, st)
        check("routes=sites fills ROUTES with sites", 'var ROUTES = "sites";' in body)
        check("the site list is filled in from the sites file", '"abema.tv"' in body and "/*__SITES__*/" not in body)
        T = "SOCKS5 127.0.0.1:%d; SOCKS 127.0.0.1:%d" % (SOCKS, SOCKS)
        check("served PAC: a listed site through the configured SOCKS port", pac_verdict(body, "abema.tv") == T,
              pac_verdict(body, "abema.tv"))
        check("served PAC: Google direct", pac_verdict(body, "www.google.com") == "DIRECT")
        _, _, body = await get("/jp.pac")
        check("the bare URL (the one-switch version) means the sites only", 'var ROUTES = "sites";' in body)
        _, _, body = await get("/jp.pac?routes=rest,tools,other")
        check("only sites and rest can reach a PAC; others are dropped", 'var ROUTES = "rest";' in body)
        check("served PAC with rest: Google through Japan, then DIRECT",
              pac_verdict(body, "www.google.com") == T + "; DIRECT")
        _, _, body = await get("/jp.pac?routes=")
        check("an empty routes= turns every route off", 'var ROUTES = "";' in body)
        for path in ("/kcp-client.json", "/config", "/sites", "/pac/jp.pac", "/../config"):
            st, _, _ = await get(path)
            check("%s is not served" % path, st.endswith("404 Not Found"), st)

        # The relay for programs that use HTTPS_PROXY
        if os.path.exists(FLAG): os.remove(FLAG)
        seen.clear()
        st, got = await tunnel("127.0.0.1:%d" % ECHO)
        check("tools off: direct, data flows", " 200 " in st and got == b"ping\n" and not seen, (st, got, seen))
        open(FLAG, "w").close()
        seen.clear()
        st, got = await tunnel("127.0.0.1:%d" % ECHO)
        check("tools on: through the tunnel, data flows", " 200 " in st and got == b"ping\n" and len(seen) == 1,
              (st, got, seen))
        seen.clear()
        st, got = await tunnel("api.anthropic.com:443")
        check("a name goes to the tunnel unresolved (socks5h), so it resolves in Japan",
              seen == [(3, "api.anthropic.com", 443)] and got == b"ping\n", seen)
        big = os.urandom(3 * 1024 * 1024)
        st, got = await tunnel("api.anthropic.com:443", big)
        check("3 MB passes through intact", got == big)
        mode["hang"] = True
        t0 = time.time(); st, got = await tunnel("127.0.0.1:%d" % ECHO)
        check("a silent tunnel falls back to direct within the timeout (fail-open)",
              " 200 " in st and got == b"ping\n" and time.time() - t0 < 5, (st, time.time() - t0))
        mode["hang"] = False
        _, _, body = await get("/status")
        stt = json.loads(body)
        check("/status counts it as fell_back", stt.get("fell_back") == 1 and stt.get("tools_via_japan") is True, stt)
        seen.clear(); t0 = time.time(); st, got = await tunnel("127.0.0.1:%d" % ECHO)
        check("after a failure the tunnel is skipped for a while: direct at once, no wait",
              got == b"ping\n" and not seen and time.time() - t0 < 0.5, (seen, time.time() - t0))
        _, _, body = await get("/status")
        check("/status shows the pause", json.loads(body).get("tunnel_paused") is True, body)
    finally:
        p.terminate(); p.wait()

    # The tunnel is dead (nothing listens) and the local-address rule is live, as in production.
    p = start_proxy(DEAD, route_local=False)
    try:
        st, got = await tunnel("127.0.0.1:%d" % ECHO)
        check("dead tunnel with tools on: still direct, data flows (fail-open)", " 200 " in st and got == b"ping\n", st)
    finally:
        p.terminate(); p.wait()
    p = start_proxy(SOCKS, route_local=False)
    try:
        seen.clear()
        st, got = await tunnel("127.0.0.1:%d" % ECHO)
        check("this Mac's own addresses never use the tunnel, flag or not", got == b"ping\n" and not seen, seen)
        st, _ = await tunnel("no-such-host.invalid:443")
        check("planted control: an unknown name with tools on does use the tunnel",
              seen and seen[-1][1] == "no-such-host.invalid", seen)
        seen.clear()
        st, _ = await tunnel("app.localhost:443")
        check("local suffixes (.localhost, .internal, .lan, .home.arpa) never use the tunnel", not seen, seen)
        st, _ = await tunnel(("a" * 300) + ".example:443")
        check("a name too long for SOCKS still gets an answer (falls back, then 502)", " 502 " in st, st)
        st, _ = await tunnel("example.com:70000")
        check("a port out of range answers 400", " 400 " in st, st)
        os.remove(FLAG)
        st, _ = await tunnel("no-such-host.invalid:443")
        check("a direct connection that fails answers 502, the relay stays up", " 502 " in st, st)
        st, _, _ = await get("/status")
        check("the relay still answers after a failed connection", st.endswith("200 OK"), st)
    finally:
        p.terminate(); p.wait()
    e.close(); s.close()

asyncio.run(main())
shutil.rmtree(D, ignore_errors=True)
print("\nPASS=%d FAIL=%d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
