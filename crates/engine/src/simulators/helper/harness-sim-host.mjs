// Harness's simulator streaming host. The engine writes this file next to the
// pinned helper install and runs it with the user's Node; do not edit it there.
//
// It serves exactly two routes of the helper's serve-sim middleware, on
// loopback and behind a bearer token: a simulator's MJPEG stream and its HID
// socket. Every other route the middleware has (shell exec, dashboards,
// devtools, device management) is refused before it reaches the middleware.
// It exits when the engine that started it closes stdin, so an engine that is
// killed never leaves it running.
//
// argv: <path to serve-sim's middleware.js>
// env:  HARNESS_SIM_TOKEN (required), HARNESS_SIM_STREAM (JSON stream settings)
// stdout: one line `HARNESS_SIM_HOST {"port":N}` once listening.

import http from "node:http";
import { Readable } from "node:stream";
import { pathToFileURL } from "node:url";

const token = process.env.HARNESS_SIM_TOKEN ?? "";
delete process.env.HARNESS_SIM_TOKEN;
if (token.length < 32) {
  console.error("harness-sim-host: missing token");
  process.exit(2);
}
let streamSettings = {};
try {
  streamSettings = JSON.parse(process.env.HARNESS_SIM_STREAM ?? "{}");
} catch {
  streamSettings = {};
}

// The engine holds stdin open for as long as it wants this host.
process.stdin.on("data", () => {});
process.stdin.on("end", () => process.exit(0));
process.stdin.on("error", () => process.exit(0));
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.once(signal, () => process.exit(0));
}

const { simMiddleware } = await import(pathToFileURL(process.argv[2]).href);

const BASE = "/sim";
const UDID = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}";
const STREAM = new RegExp(`^${BASE}/helper/${UDID}/stream\\.mjpeg$`);
const HID = new RegExp(`^${BASE}/helper/ws\\?device=${UDID}$`);

const middleware = simMiddleware({
  basePath: BASE,
  proxyHelpers: true,
  requirePreviewToken: true,
  execToken: token,
  streamSettings: { transport: "http", codec: "mjpeg", ...streamSettings },
});

function refuse(res, status) {
  res.writeHead(status, { "Content-Type": "text/plain" });
  res.end(String(status));
}

const server = http.createServer(async (req, res) => {
  const url = req.url ?? "/";
  if (req.method !== "GET" || !STREAM.test(url)) return refuse(res, 404);
  const abort = new AbortController();
  req.once("close", () => abort.abort());
  try {
    const headers = new Headers();
    for (const [name, value] of Object.entries(req.headers)) {
      if (typeof value === "string") headers.set(name, value);
    }
    const response = await middleware(
      new Request(`http://127.0.0.1${url}`, { headers, signal: abort.signal }),
    );
    if (!response) return refuse(res, 404);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    if (!response.body) return res.end();
    const body = Readable.fromWeb(response.body);
    body.on("error", () => res.destroy());
    res.once("close", () => body.destroy());
    body.pipe(res);
  } catch (error) {
    console.error("harness-sim-host:", error);
    if (!res.headersSent) refuse(res, 502);
    else res.destroy();
  }
});

server.on("upgrade", (req, socket, head) => {
  if (!HID.test(req.url ?? "")) {
    socket.destroy();
    return;
  }
  middleware.handleUpgrade(req, socket, head);
});

server.listen(0, "127.0.0.1", () => {
  process.stdout.write(`HARNESS_SIM_HOST ${JSON.stringify({ port: server.address().port })}\n`);
});
