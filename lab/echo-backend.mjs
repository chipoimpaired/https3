// Staging test backend: echoes what the proxy sent, verifies uploads, serves verifiable
// downloads and answers a WebSocket handshake. Listens on :8080.
import crypto from "node:crypto";
import http from "node:http";

const BLOCK = crypto.randomBytes(1024 * 1024);
const hashCache = new Map();
const hashOf = (n) => {
	if (!hashCache.has(n)) {
		const h = crypto.createHash("sha256");
		let left = n;
		while (left > 0) { const c = left >= BLOCK.length ? BLOCK : BLOCK.subarray(0, left); h.update(c); left -= c.length; }
		hashCache.set(n, h.digest("hex"));
	}
	return hashCache.get(n);
};
const pick = (req) => ({
	method: req.method, url: req.url, httpVersion: req.httpVersion,
	host: req.headers.host ?? null,
	xff: req.headers["x-forwarded-for"] ?? null,
	xfp: req.headers["x-forwarded-proto"] ?? null,
	xfs: req.headers["x-forwarded-scheme"] ?? null,
	xri: req.headers["x-real-ip"] ?? null,
	earlyData: req.headers["early-data"] ?? null,
	upgrade: req.headers.upgrade ?? null,
	connection: req.headers.connection ?? null,
	peer: req.socket.remoteAddress,
});

const server = http.createServer((req, res) => {
	const u = new URL(req.url, "http://x");
	if (u.pathname === "/download") {
		const n = Math.min(Number.parseInt(u.searchParams.get("bytes") || "0", 10) || 0, 1024 * 1024 * 1024);
		res.writeHead(200, { "Content-Type": "application/octet-stream", "Content-Length": n, "X-Body-Sha256": hashOf(n) });
		let left = n;
		const pump = () => {
			while (left > 0) {
				const c = left >= BLOCK.length ? BLOCK : BLOCK.subarray(0, left);
				left -= c.length;
				if (!res.write(c)) { res.once("drain", pump); return; }
			}
			res.end();
		};
		pump();
		return;
	}
	if (u.pathname === "/static/web-videos/test.mp4") {   // path the per-IP whole-file limit looks at
		res.writeHead(req.headers.range ? 206 : 200, { "Content-Type": "video/mp4" });
		res.end("video");
		return;
	}
	if (u.pathname === "/setcookie-hsts") {               // an upstream that sets its own headers
		res.writeHead(200, { "Content-Type": "text/plain", "Upgrade": "h2", "X-Upstream": "1" });
		res.end("ok");
		return;
	}
	const h = crypto.createHash("sha256");
	let bytes = 0;
	req.on("data", (c) => { bytes += c.length; h.update(c); });
	req.on("end", () => {
		const body = JSON.stringify({ ...pick(req), bytes, sha256: h.digest("hex") });
		res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
		res.end(body);
	});
});
server.on("upgrade", (req, socket) => {
	const key = req.headers["sec-websocket-key"] || "";
	const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
	socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
	// keep the connection open (a long-lived websocket, like Nextcloud notify_push); send a ping frame every 20 s
	const iv = setInterval(() => { try { socket.write(Buffer.from([0x89, 0x00])); } catch (_e) { clearInterval(iv); } }, 20000);
	socket.on("close", () => clearInterval(iv));
	socket.on("error", () => clearInterval(iv));
});
server.listen(8080, "0.0.0.0", () => console.log("echo backend on :8080"));
