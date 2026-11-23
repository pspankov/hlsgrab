#!/usr/bin/env bash
# batch_m3u8 — for each page URL in a text file (one per line): open it in Chrome (headful), capture the
# m3u8 request + its Referer/User-Agent, and download it with yt-dlp as <slug>.<ext>, one URL at a time.
# <slug> is the last path segment of the page URL: https://site.com/foo/bar/baz/ -> baz.mp4
#
# usage: batch_m3u8 <urls.txt> [--from=<N|url>] [--out=<dir>] [capture flags...]
#        batch_m3u8 <page-url>  [--out=<dir>] [capture flags...]          # a single page instead of a list
#        batch_m3u8 --probe <page-url> [capture flags...]     # only print the captured m3u8 JSON, no download
#        batch_m3u8 --direct <m3u8-url> [referer] [name] [--out=<dir>]   # skip the browser, just download
#                            (name defaults to video-<timestamp>; pass "" as referer to send none)
#   --from=N | --from=<url>  resume at the Nth URL (the [N] printed per URL) or at that URL (trailing / ignored).
#                            On Ctrl+C the exact resume command is printed.
#   --out=<dir>              where downloads go (default: current directory)
#   --downloader=auto|yt-dlp|ffmpeg   auto (default): yt-dlp for *.m3u8, ffmpeg for playlists with any other
#                            name (master.txt, index.txt, …; segments may be disguised as .js/.css/.woff).
#                            ffmpeg output is always <name>.mp4; also works with --direct.
#   --no-host-check          skip probing segment hosts. By default every segment host is probed first (one real
#                            segment each, with Referer/UA); dead hosts are rerouted to a live host that is verified
#                            to serve the same segment, and ffmpeg downloads the fixed playlist.
#   capture flags (passed to the built-in capture): --timeout=30  --block=<glob>  --verbose  --requests  --all
#                            (batch mode always uses --headful; --probe is headless unless you add --headful)
#
# Blank lines and # comments are skipped. A URL with no m3u8 or a failed download is logged and the batch
# continues; failed URLs go to <urls.txt>.failed (appended to when resuming). Needs: node>=22, google-chrome-stable
# (or $CHROME), jq, yt-dlp.
set -u

FALLBACK_UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36'

# ---------------- embedded capture script (Node, Chrome DevTools Protocol) ----------------
read -r -d '' CAPTURE_JS <<'JS_EOF'
// Open a page in headless Chrome, watch its network traffic (including cross-origin player iframes),
// and print the first .m3u8 request URL plus the Referer it was sent with.
//
// usage (via batch_m3u8 --probe): <page-url> [--all] [--timeout=30] [--headful] [--block=<pattern>]...
//   --block     extra URL glob to block (* = any chars, ? = one char); repeatable.
//               Always blocked: *://*/*disable-devtool*  (anti-DevTools script that kills/redirects the page)
//   --verbose   log targets, navigations, media-looking and failed requests to stderr (for debugging misses)
//   --requests  log EVERY request (method, type, status, mime, url) to stderr; implies --verbose
//   --all       keep collecting until timeout and print every distinct m3u8 request
//   --timeout   seconds to wait for an m3u8 request (default 30)
//   --headful   show the browser window (useful when a page needs a manual click / captcha)
//
// Output (stdout, JSON): { "url": ..., "referer": ..., "origin": ..., "userAgent": ... }
//   with --all: an array of those objects. Exit code 1 if nothing was found.
//
// Zero dependencies: needs Node >= 22 (built-in fetch/WebSocket) and google-chrome-stable (or $CHROME).
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";

const args = process.argv.slice(1);
const pageUrl = args.find((a) => !a.startsWith("--"));
const all = args.includes("--all");
const headful = args.includes("--headful");
const logAll = args.includes("--requests");
const verbose = logAll || args.includes("--verbose");
const log = (...m) => verbose && console.error(...m);
const blockPatterns = ["*://*/*disable-devtool*",
  ...args.filter((a) => a.startsWith("--block=")).map((a) => a.slice("--block=".length))];
const timeoutSec = Number((args.find((a) => a.startsWith("--timeout=")) || "--timeout=30").split("=")[1]);
if (!pageUrl) {
  console.error("usage: batch_m3u8 --probe <page-url> [--all] [--timeout=30] [--headful] [--block=<pattern>]...");
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const port = 9400 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(tmpdir() + "/m3u8-");
const chromeArgs = [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run",
  "--no-default-browser-check", "--autoplay-policy=no-user-gesture-required", "--mute-audio",
  "--window-size=1280,800", "about:blank"];
if (!headful) chromeArgs.unshift("--headless=new");
const chrome = spawn(process.env.CHROME || "google-chrome-stable", chromeArgs, { stdio: "ignore" });

let ws;
const cleanup = () => {
  try { ws?.close(); } catch {}
  try { chrome.kill("SIGKILL"); } catch {}
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
};
process.on("exit", cleanup);
process.on("SIGINT", () => process.exit(130));

// --- connect to the browser-level CDP endpoint ---
let wsUrl;
for (let i = 0; i < 50 && !wsUrl; i++) {
  try { wsUrl = (await (await fetch(`http://127.0.0.1:${port}/json/version`)).json()).webSocketDebuggerUrl; }
  catch { await sleep(200); }
}
if (!wsUrl) { console.error("could not start Chrome / connect to DevTools"); process.exit(1); }

ws = new WebSocket(wsUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });

let nextId = 0;
const pending = new Map();
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++nextId;
  pending.set(id, { resolve, reject });
  ws.send(JSON.stringify({ id, method, params, ...(sessionId && { sessionId }) }));
});

const isM3u8 = (u) => /\.m3u8(\?|#|$)/i.test(u) || /[?&](format|type)=m3u8/i.test(u);
const getHeader = (h = {}, name) => {
  const k = Object.keys(h).find((x) => x.toLowerCase() === name);
  return k ? h[k] : undefined;
};

const found = new Map();      // m3u8 url -> result
const byRequestId = new Map(); // requestId -> result (to patch with real headers from ExtraInfo)
let resolveFirst;
const firstFound = new Promise((r) => (resolveFirst = r));

const record = (requestId, url, headers, frameUrl, method) => {
  // The same playlist URL requested again (players reload it): map the new request to the existing result,
  // so its ExtraInfo headers and body still have somewhere to go.
  if (found.has(url)) { byRequestId.set(requestId, found.get(url)); return; }
  const r = {
    url,
    method: method ?? null,
    referer: getHeader(headers, "referer") ?? null,
    origin: getHeader(headers, "origin") ?? null,
    userAgent: getHeader(headers, "user-agent") ?? null,
    frameUrl: frameUrl ?? null,
    master: null, // true = master playlist (#EXT-X-STREAM-INF), false = media/variant playlist, null = body not read
  };
  found.set(url, r);
  byRequestId.set(requestId, r);
  if (!all) setTimeout(() => resolveFirst(), 8000); // fallback if ExtraInfo (real sent headers) never lands; it can lag seconds behind on a cold connection
};

// Per-session setup, sent in order before the target is allowed to run, so blocking is active from its first request.
const setupSession = (s) => {
  send("Fetch.enable", { patterns: blockPatterns.map((urlPattern) => ({ urlPattern, requestStage: "Request" })) }, s)
    .catch(() => {}); // some worker targets don't support Fetch
  send("Network.enable", {}, s).catch(() => {});
  send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, s).catch(() => {});
};

const reqInfo = new Map(); // requestId -> {url, headers, sessionId}, to match playlists detected by response type
const isPlaylistMime = (m = "") => /mpegurl/i.test(m); // application/vnd.apple.mpegurl, application/x-mpegURL, audio/mpegurl
// Responses that may be an HLS playlist under a disguise (master.txt, index.txt, text/plain, octet-stream):
// their body is read once loaded and accepted only if it starts with #EXTM3U.
const maybeDisguisedPlaylist = (info) => info && info.method !== "HEAD" && ["XHR", "Fetch", "Other"].includes(info.type) &&
  (/\.txt(\?|#|$)/i.test(info.url) || /^text\/plain|octet-stream/i.test(info.mime || ""));
const looksMedia = (u) => /m3u8|mpd|\.ts(\?|$)|\.m4s|manifest|playlist|master|index|hls|stream/i.test(u);

const frameUrls = new Map(); // sessionId -> url of that target (page / iframe)
const extraInfo = new Map(); // requestId -> wire headers that arrived before requestWillBeSent
let pendingBodies = 0;      // playlist bodies still being read (to decide master vs variant)

ws.onmessage = async (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id) {
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result); }
    return;
  }
  const { method, params, sessionId } = msg;

  if (method === "Target.attachedToTarget") {
    // Every page, cross-origin iframe and worker becomes its own session: enable network on each.
    const s = params.sessionId;
    frameUrls.set(s, params.targetInfo.url);
    log(`target: ${params.targetInfo.type} ${params.targetInfo.url}`);
    setupSession(s);
    send("Runtime.runIfWaitingForDebugger", {}, s).catch(() => {});
  } else if (method === "Fetch.requestPaused") {
    // Only URLs matching blockPatterns are paused, so every paused request gets failed.
    console.error(`blocked: ${params.request.url}`);
    send("Fetch.failRequest", { requestId: params.requestId, errorReason: "BlockedByClient" }, sessionId).catch(() => {});
  } else if (method === "Network.requestWillBeSent") {
    const { request, requestId } = params;
    if (logAll) log(`req ${request.method} [${params.type}]: ${request.url.slice(0, 300)}`);
    else if (verbose && !request.url.startsWith("data:") && params.type !== "Manifest" && !/\.webmanifest(\?|$)/i.test(request.url) && (params.type === "Document" || looksMedia(request.url))) log(`req[${params.type}]: ${request.url}`);
    reqInfo.set(requestId, { url: request.url, headers: request.headers, sessionId, method: request.method, type: params.type });
    if (reqInfo.size > 5000) reqInfo.delete(reqInfo.keys().next().value);
    if (isM3u8(request.url)) record(requestId, request.url, request.headers, frameUrls.get(sessionId), request.method);
    const early = extraInfo.get(requestId);
    if (early && byRequestId.has(requestId)) applyExtra(requestId, early);
  } else if (method === "Network.responseReceived") {
    // Playlists served without an .m3u8 extension (e.g. /playlist?id=…, /master.txt) are caught by MIME type.
    const info = reqInfo.get(params.requestId);
    if (logAll) log(`res ${params.response.status} ${params.response.mimeType}: ${params.response.url.slice(0, 300)}`);
    if (info) info.mime = params.response.mimeType;
    if (info && isPlaylistMime(params.response.mimeType) && !byRequestId.has(params.requestId)) {
      record(params.requestId, info.url, info.headers, frameUrls.get(info.sessionId), info.method);
      const early = extraInfo.get(params.requestId);
      if (early) applyExtra(params.requestId, early);
    }
  } else if (method === "Network.loadingFinished") {
    const info = reqInfo.get(params.requestId);
    const known = byRequestId.get(params.requestId);
    if (!info || info.method === "HEAD" || params.encodedDataLength > 2_000_000) return;
    if (!known && !maybeDisguisedPlaylist(info)) return;
    pendingBodies++;
    try {
      const { body, base64Encoded } = await send("Network.getResponseBody", { requestId: params.requestId }, info.sessionId);
      const text = base64Encoded ? Buffer.from(body, "base64").toString("utf8") : body;
      if (!/^\uFEFF?\s*#EXTM3U/.test(text)) return;
      if (!known) {
        record(params.requestId, info.url, info.headers, frameUrls.get(info.sessionId), info.method);
        const early = extraInfo.get(params.requestId);
        if (early) applyExtra(params.requestId, early);
        log(`playlist by content: ${info.url}`);
      }
      byRequestId.get(params.requestId).master = /#EXT-X-STREAM-INF/.test(text);
    } catch {} finally { pendingBodies--; }
  } else if (method === "Network.loadingFailed") {
    const info = reqInfo.get(params.requestId);
    if (info) log(`failed: ${info.url} (${params.blockedReason || params.errorText})`);
  } else if (method === "Page.frameNavigated" && !params.frame.parentId) {
    log(`navigated: ${params.frame.url}`);
  } else if (method === "Network.requestWillBeSentExtraInfo") {
    // Headers as actually sent on the wire (Chrome adds Origin/UA here, after referrer policy is applied).
    // CDP may deliver this before or after requestWillBeSent, so buffer it either way.
    if (byRequestId.has(params.requestId)) applyExtra(params.requestId, params.headers);
    else { extraInfo.set(params.requestId, params.headers); if (extraInfo.size > 2000) extraInfo.clear(); }
  }
};

function applyExtra(requestId, headers) {
  const r = byRequestId.get(requestId);
  if (!r) return;
  r.referer = getHeader(headers, "referer") ?? r.referer;
  r.origin = getHeader(headers, "origin") ?? r.origin;
  r.userAgent = getHeader(headers, "user-agent") ?? r.userAgent;
  if (!all && r === found.values().next().value) resolveFirst();
}

// --- open the page ---
await send("Target.setDiscoverTargets", { discover: true });
const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId: page } = await send("Target.attachToTarget", { targetId, flatten: true });
frameUrls.set(page, pageUrl);
setupSession(page);
await send("Page.enable", {}, page);
await send("Page.navigate", { url: pageUrl }, page);

// Many players only request the playlist after play/click: nudge them a few times.
const nudge = async () => {
  for (let i = 0; i < 4 && (all || !found.size); i++) {
    await sleep(2500);
    await send("Runtime.evaluate", {
      expression: `document.querySelectorAll('video').forEach(v => { v.muted = true; v.play?.().catch(()=>{}); })`,
    }, page).catch(() => {});
    if (found.size && !all) break;
    for (const type of ["mousePressed", "mouseReleased"])
      await send("Input.dispatchMouseEvent", { type, x: 640, y: 400, button: "left", clickCount: 1 }, page).catch(() => {});
  }
};
nudge();

await Promise.race([all ? new Promise(() => {}) : firstFound, sleep(timeoutSec * 1000)]);

// Prefer the master playlist (it lists all qualities). It is usually requested first, but its body is read
// only after it finishes loading, so give that a moment if no master is known yet.
if (!all) for (let i = 0; i < 20 && (pendingBodies || ![...found.values()].some((r) => r.master)); i++) await sleep(100);
const results = [...found.values()];
const best = results.find((r) => r.master) ?? results[0];
if (!results.length) {
  console.error(`no m3u8 request seen within ${timeoutSec}s`);
  process.exit(1);
}
console.log(JSON.stringify(all ? results : best, null, 2));
process.exit(0);
JS_EOF

capture() { node --input-type=module -e "$CAPTURE_JS" -- "$@"; }

# Which tool downloads: auto = yt-dlp for *.m3u8 URLs, ffmpeg for playlists under any other name
# (master.txt, index.txt, /playlist?id=…). Override with --downloader=yt-dlp|ffmpeg.
downloader=auto
pick_tool() {
  local path=${1%%[?#]*}
  case $downloader in
    auto) [[ ${path,,} == *.m3u8 ]] && echo yt-dlp || echo ffmpeg ;;
    *) echo "$downloader" ;;
  esac
}

# ---------------- segment host check (for streams spread over many throwaway hosts) ----------------
# Before downloading, fetch the playlist (master -> highest-bandwidth variant), make every URI absolute, and
# probe one real segment per host (1-byte range request, with Referer + UA; only 2xx counts as alive).
# Each dead host is mapped to a live host that is verified to serve that same segment path. If any host was
# rerouted, the fixed playlist is served from a throwaway local HTTP server: ffmpeg drops -headers/-user_agent
# for segments when the playlist is a local file, but keeps them when the playlist itself comes over HTTP.
#
# Wrapped segments: some hosts serve each MPEG-TS segment behind a small image header (e.g. a valid 70-byte 1x1
# PNG, so the segment can live on an image CDN). Downloaders save those bytes as they are, and the result is a
# "video" of PNG frames. The first segment is checked; if the TS data starts after a prefix, a local proxy
# serves the playlist and strips the prefix from every segment, and ffmpeg downloads through it (stream copy).
host_check=1
HC_DIR=""; HC_SRV=""; HC_INPUT=""; HC_DEAD=0; HC_EXTS=""; HC_UA=""; HC_REF=""; HC_WRAP=0
hc_cleanup() {
  [[ -n $HC_SRV ]] && kill "$HC_SRV" 2>/dev/null
  [[ -n $HC_DIR ]] && rm -rf "$HC_DIR"
  HC_SRV=""; HC_DIR=""
}

# Offset of the first run of 5 MPEG-TS packets (0x47 every 188 bytes) in a file; -1 if none in the first 64 KB.
TS_START_PY='
import sys
d = open(sys.argv[1], "rb").read(65536 + 5 * 188)
print(next((i for i in range(min(len(d), 65536)) if all(i + k * 188 < len(d) and d[i + k * 188] == 0x47 for k in range(5))), -1))'

# Local proxy for wrapped segments: serves /playlist.m3u8 (segment URIs rewritten to /seg/<n>.ts); each segment
# is fetched with the stream's Referer + User-Agent and returned from its first TS packet on.
UNWRAP_PY='
import http.server, re, sys, urllib.request
src, ua, ref, portfile = sys.argv[1:5]
segs, out = [], []
for line in open(src).read().splitlines():
    if line and not line.startswith("#"):
        out.append(f"/seg/{len(segs)}.ts"); segs.append(line)
    else:
        out.append(line)
playlist = ("\n".join(out) + "\n").encode()
def ts_start(d):
    for i in range(min(len(d), 65536)):
        if all(i + k * 188 < len(d) and d[i + k * 188] == 0x47 for k in range(5)):
            return i
    return -1
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/playlist.m3u8":
            body, ctype = playlist, "application/vnd.apple.mpegurl"
        else:
            m = re.fullmatch(r"/seg/(\d+)\.ts", self.path)
            if not m or int(m[1]) >= len(segs):
                return self.send_error(404)
            hdr = {"User-Agent": ua, **({"Referer": ref} if ref else {})}
            try:
                d = urllib.request.urlopen(urllib.request.Request(segs[int(m[1])], headers=hdr), timeout=60).read()
            except Exception as e:
                return self.send_error(502, str(e)[:120])
            off = ts_start(d)
            if off < 0:
                return self.send_error(502, "no MPEG-TS data in segment")
            body, ctype = d[off:], "video/mp2t"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()'
hc_curl() { curl -sfL -m 20 -A "$HC_UA" ${HC_REF:+-e "$HC_REF"} "$@"; }

ABS_AWK='
function abs(r) {
  if (r ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//) return r
  if (r ~ /^\/\//) return scheme ":" r
  if (r ~ /^\//) return origin r
  return dir "/" r
}
{ sub(/\r$/, "") }
/^#/ {
  if (match($0, /URI="[^"]*"/)) { u = substr($0, RSTART + 5, RLENGTH - 6); $0 = substr($0, 1, RSTART - 1) "URI=\"" abs(u) "\"" substr($0, RSTART + RLENGTH) }
  print; next
}
/^[ \t]*$/ { next }
{ print abs($0) }'
absolutize() { # <playlist-url> < playlist  ->  playlist with absolute URIs
  local b=${1%%[?#]*}
  awk -v scheme="${b%%://*}" -v origin="$(grep -oE '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+' <<<"$b")" -v dir="${b%/*}" "$ABS_AWK"
}
hc_probe() { # <url> -> prints HTTP status (000 = unreachable)
  curl -sL -o /dev/null -m 10 -r 0-0 -A "$HC_UA" ${HC_REF:+-e "$HC_REF"} -w '%{http_code}' "$1"
}

# check_hosts <playlist-url> <referer> <ua>
#   returns 0 = checked (HC_DEAD rerouted hosts; HC_INPUT = playlist to use), 1 = no live host at all,
#           2 = check not possible (skipped; download the original URL as before)
check_hosts() {
  HC_INPUT=$1; HC_REF=$2; HC_UA=$3; HC_DEAD=0; HC_EXTS=""; HC_WRAP=0
  local w media total good dead_n
  command -v curl >/dev/null && command -v python3 >/dev/null || { echo "--> hosts:   check skipped (needs curl + python3)" >&2; return 2; }
  HC_DIR=$(mktemp -d); w=$HC_DIR
  if ! hc_curl "$1" -o "$w/master" || ! grep -q '#EXTM3U' "$w/master"; then
    echo "--> hosts:   check skipped (could not fetch the playlist directly)" >&2; return 2
  fi
  absolutize "$1" < "$w/master" > "$w/master.abs"
  media=$1
  if grep -q '^#EXT-X-STREAM-INF' "$w/master.abs"; then
    if grep -qE '^#EXT-X-MEDIA:.*URI=' "$w/master.abs"; then
      echo "--> hosts:   check skipped (master has separate audio/subtitle playlists)" >&2; return 2
    fi
    media=$(awk '/^#EXT-X-STREAM-INF/ { bw = 0; if (match($0, /BANDWIDTH=[0-9]+/)) bw = substr($0, RSTART + 10, RLENGTH - 10) + 0; want = 1; next }
                 want && !/^#/ { if (bw >= best) { best = bw; u = $0 } want = 0 }
                 END { print u }' "$w/master.abs")
    if [[ -z $media ]] || ! hc_curl "$media" -o "$w/media"; then
      echo "--> hosts:   check skipped (could not fetch variant playlist)" >&2; return 2
    fi
    absolutize "$media" < "$w/media" > "$w/media.abs"
  else
    cp "$w/master.abs" "$w/media.abs"
  fi
  awk '!/^#/' "$w/media.abs" > "$w/segs"
  [[ -s $w/segs ]] || { echo "--> hosts:   check skipped (no segments in playlist)" >&2; return 2; }

  # wrapped segments? (TS data that doesn't start at byte 0; encrypted streams are left alone)
  local off
  if ! grep -qE '^#EXT-X-KEY:.*METHOD=(AES|SAMPLE)' "$w/media.abs" && hc_curl -r 0-65535 "$(head -n 1 "$w/segs")" -o "$w/seg0"; then
    off=$(python3 -c "$TS_START_PY" "$w/seg0" 2>/dev/null)
    if [[ $off =~ ^[0-9]+$ ]] && (( off > 0 )); then
      HC_WRAP=1
      echo "--> segments: wrapped ($(head -c 4 "$w/seg0" | tr -dc '[:alnum:]' | head -c 4 || true) header, TS data from byte $off): stripping it via a local proxy" >&2
    fi
  fi

  # one sample segment per host, probed in parallel
  awk -F/ '!seen[$3]++ { print $3 " " $0 }' "$w/segs" > "$w/samples"
  total=$(wc -l < "$w/samples")
  export HC_UA HC_REF
  xargs -d '\n' -n 1 -P 16 bash -c '
    h=${1%% *}; u=${1#* }
    c=$(curl -sL -o /dev/null -m 10 -r 0-0 -A "$HC_UA" ${HC_REF:+-e "$HC_REF"} -w "%{http_code}" "$u")
    case $c in 2??) echo "ok $h" ;; *) echo "dead $h $c" ;; esac' _ < "$w/samples" > "$w/probe"
  awk '$1 == "ok" { print $2 }' "$w/probe" > "$w/good"
  dead_n=$(awk '$1 == "dead"' "$w/probe" | wc -l)
  if [[ ! -s $w/good ]]; then
    echo "!!! hosts:   none of $total segment hosts is reachable" >&2; return 1
  fi
  : > "$w/map"
  if (( dead_n == 0 )); then
    echo "--> hosts:   $total segment host(s), all reachable" >&2
  else
    # map each dead host to a live host that really serves the same path (try up to 8 live hosts)
    local h u code g cand unfixed=0
    while read -r _ h code; do
      u=$(awk -v h="$h" '$1 == h { print $2; exit }' "$w/samples")
      g=""
      while read -r cand; do
        [[ $(hc_probe "${u/:\/\/$h\//:\/\/$cand\/}") == 2?? ]] && { g=$cand; break; }
      done < <(head -n 8 "$w/good")
      if [[ -n $g ]]; then echo "$h $g" >> "$w/map"; echo "--> hosts:   $h ($code) -> $g" >&2
      else unfixed=$((unfixed + 1)); echo "--> hosts:   $h ($code) -> no live host serves its segments, left as is" >&2; fi
    done < <(awk '$1 == "dead"' "$w/probe")
    HC_DEAD=$(wc -l < "$w/map")
    echo "--> hosts:   $total total, $dead_n dead, $HC_DEAD rerouted$( (( unfixed )) && echo ", $unfixed unfixable")" >&2
  fi
  (( HC_DEAD || HC_WRAP )) || return 0

  mkdir -p "$w/srv"
  # FILENAME, not NR == FNR: the map is empty when no host was rerouted (wrapped-only), and NR == FNR would
  # then swallow the whole playlist as map entries.
  awk 'FILENAME == ARGV[1] { m[$1] = $2; next }
       { for (d in m) { k = "://" d "/"; while ((i = index($0, k)) > 0) $0 = substr($0, 1, i - 1) "://" m[d] "/" substr($0, i + length(k)) } print }' \
    "$w/map" "$w/media.abs" > "$w/srv/playlist.m3u8"
  HC_EXTS=$(awk '!/^#/ { sub(/[?#].*/, ""); n = split($0, p, "/"); if (match(p[n], /\.[A-Za-z0-9]+$/)) print substr(p[n], RSTART + 1) }' "$w/srv/playlist.m3u8" | sort -u | paste -sd,)
  if (( HC_WRAP )); then
    python3 -c "$UNWRAP_PY" "$w/srv/playlist.m3u8" "$HC_UA" "$HC_REF" "$w/port" </dev/null >/dev/null 2>&1 &
  else
  python3 -c 'import http.server, sys, functools
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Q, directory=sys.argv[1]))
open(sys.argv[2], "w").write(str(s.server_port)); s.serve_forever()' "$w/srv" "$w/port" </dev/null >/dev/null 2>&1 &
  fi
  HC_SRV=$!
  local i; for i in {1..50}; do [[ -s $w/port ]] && break; sleep 0.1; done
  [[ -s $w/port ]] || { echo "!!! hosts:   could not start local playlist server" >&2; return 1; }
  HC_INPUT="http://127.0.0.1:$(cat "$w/port")/playlist.m3u8"
  return 0
}

# download <playlist-url> <referer> <output path without extension> [user-agent]
download() {
  local url=$1 ref=$2 out=$3 ua=${4:-$FALLBACK_UA} tool input=$1 exts="ts,js,css,woff" rc=0
  tool=$(pick_tool "$url")
  if [[ $tool == ffmpeg && -e $out.mp4 ]]; then echo "--> $out.mp4 already exists, skipping" >&2; return 0; fi
  # Host check runs for ffmpeg downloads and for auto mode (forced --downloader=yt-dlp skips it).
  if (( host_check )) && [[ $tool == ffmpeg || $downloader == auto ]]; then
    check_hosts "$url" "$ref" "$ua"; rc=$?
    if (( rc == 1 )); then hc_cleanup; return 1; fi
    if (( rc == 0 && (HC_DEAD > 0 || HC_WRAP) )); then
      input=$HC_INPUT; [[ -n $HC_EXTS ]] && exts+=",$HC_EXTS"
      if [[ $tool == yt-dlp ]]; then echo "--> switching to ffmpeg to use the $( (( HC_WRAP )) && echo unwrapping proxy || echo rerouted playlist)" >&2; tool=ffmpeg; fi
    fi
  fi
  command -v "$tool" >/dev/null || { echo "missing dependency: $tool" >&2; hc_cleanup; return 2; }
  echo "--> tool:    $tool" >&2
  if [[ $tool == yt-dlp ]]; then
    hc_cleanup
    local yt_args=(--user-agent "$ua" -o "$out.%(ext)s")
    [[ -n $ref ]] && yt_args+=(--referer "$ref")
    yt-dlp "${yt_args[@]}" "$url" </dev/null
    return
  fi
  if [[ -e $out.mp4 ]]; then echo "--> $out.mp4 already exists, skipping" >&2; hc_cleanup; return 0; fi
  # ffmpeg: segments may be disguised as .js/.css/.woff, so don't be picky about extensions.
  # Writes to <name>.part.mp4 and renames on success, so an interrupted run is never mistaken for a finished one.
  local ff_args=(-nostdin -hide_banner -loglevel warning -stats -y -user_agent "$ua")
  [[ -n $ref ]] && ff_args+=(-headers "Referer: $ref"$'\r\n')
  ff_args+=(-f hls -extension_picky 0 -allowed_segment_extensions "$exts" -http_persistent 0 -seg_max_retry 5
            -i "$input" -c copy -f mp4 "$out.part.mp4")
  if ffmpeg "${ff_args[@]}"; then
    mv -f "$out.part.mp4" "$out.mp4"; rc=0
  else
    rc=$?; rm -f "$out.part.mp4"
  fi
  hc_cleanup
  return $rc
}
trap 'hc_cleanup; [[ -n ${tmpdir:-} ]] && rm -rf "$tmpdir"' EXIT

if [[ ${1:-} == --direct ]]; then
  shift
  outdir="."; pos=()
  for a in "$@"; do case $a in --out=*) outdir=${a#--out=} ;; --downloader=*) downloader=${a#--downloader=} ;; --no-host-check) host_check=0 ;; *) pos+=("$a") ;; esac; done
  (( ${#pos[@]} >= 1 && ${#pos[@]} <= 3 )) || { echo "usage: batch_m3u8 --direct <m3u8-url> [referer] [name] [--out=<dir>]" >&2; exit 2; }
  mkdir -p "$outdir" || exit 2
  name=${pos[2]:-video-$(date +%Y%m%d-%H%M%S)}
  echo "--> m3u8:    ${pos[0]}" >&2
  echo "--> referer: ${pos[1]:-}" >&2
  echo "--> file:    $outdir/$name.<ext>" >&2
  download "${pos[0]}" "${pos[1]:-}" "$outdir/$name"
  exit
fi

if [[ ${1:-} == --probe ]]; then
  shift
  capture "$@"
  exit
fi

# ---------------- batch mode ----------------
usage="usage: batch_m3u8 <urls.txt> [--from=<N|url>] [--out=<dir>] [capture flags...]   |   batch_m3u8 --probe <url>"
list=${1:?$usage}
shift
from=""; outdir="."
passthru=()
for a in "$@"; do
  case $a in
    --from=*) from=${a#--from=} ;;
    --out=*)  outdir=${a#--out=} ;;
    --downloader=*) downloader=${a#--downloader=} ;;
    --no-host-check) host_check=0 ;;
    *) passthru+=("$a") ;;
  esac
done
single=0
if [[ ! -e $list && $list =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
  # A page URL instead of a list file: run it as a one-line list; no .failed file, no resume.
  single=1
  [[ -n $from ]] && { echo "--from only applies to a URL list file" >&2; exit 2; }
  tmpdir=$(mktemp -d)
  printf '%s\n' "$list" > "$tmpdir/urls.txt"
  src="$tmpdir/urls.txt"; failed_file="$tmpdir/failed"
else
  [[ -r $list ]] || { echo "cannot read $list (pass a URL list file or a page URL)" >&2; exit 2; }
  src=$list; failed_file="$list.failed"
fi
mkdir -p "$outdir" || exit 2
for dep in node jq; do command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 2; }; done

[[ -z $from ]] && : > "$failed_file"    # fresh run: start a new failed list; resumed run: keep appending
ok=0; fail=0; done_n=0; n=0
started=$([[ -z $from ]] && echo 1 || echo 0)
cur_n=""; cur_url=""

on_interrupt() {
  echo >&2
  if [[ -n $cur_n ]] && (( ! single )); then
    echo "=== interrupted at [$cur_n] $cur_url" >&2
    printf '=== resume with: %q %q --from=%s' "$(basename "$0")" "$list" "$cur_n" >&2
    [[ $outdir != . ]] && printf ' %q' "--out=$outdir" >&2
    [[ $downloader != auto ]] && printf ' %q' "--downloader=$downloader" >&2
    (( host_check )) || printf ' --no-host-check' >&2
    (( ${#passthru[@]} )) && printf ' %q' "${passthru[@]}" >&2
    echo >&2
  fi
  exit 130
}
trap on_interrupt INT TERM

# Read the list on fd 3 so neither Chrome/node nor yt-dlp can swallow lines from stdin.
while IFS= read -r line <&3 || [[ -n $line ]]; do
  url=${line%$'\r'}                       # tolerate Windows line endings
  url=${url#"${url%%[![:space:]]*}"}; url=${url%"${url##*[![:space:]]}"}   # trim
  [[ -z $url || $url == \#* ]] && continue
  n=$((n + 1))

  if (( ! started )); then
    # --from=N matches the Nth URL; otherwise match the URL itself (trailing slash ignored).
    if [[ $from =~ ^[0-9]+$ ]] && (( n == from )) || [[ ${url%/} == "${from%/}" ]]; then
      started=1
    else
      continue
    fi
  fi

  cur_n=$n; cur_url=$url
  echo "=== [$n] $url" >&2
  done_n=$((done_n + 1))

  if ! json=$(capture "$url" --headful ${passthru[@]+"${passthru[@]}"}); then
    echo "!!! no m3u8 found: $url" >&2
    echo "$url" >> "$failed_file"; fail=$((fail + 1)); continue
  fi
  m3u8=$(jq -r '.url' <<<"$json")
  referer=$(jq -r '.referer // ""' <<<"$json")
  ua=$(jq -r '.userAgent // ""' <<<"$json"); ua=${ua:-$FALLBACK_UA}
  ua=${ua/HeadlessChrome/Chrome}          # never advertise headless to the CDN

  # Last path segment of the page URL: https://site.com/foo/bar/baz/?x=1#y -> baz
  slug=${url%%[?#]*}                 # drop query string / fragment
  slug=${slug#*://}                  # drop scheme
  [[ $slug == */* ]] && slug=${slug#*/} || slug=""   # drop host (no path -> empty)
  while [[ $slug == */ ]]; do slug=${slug%/}; done   # drop trailing slashes
  slug=${slug##*/}
  slug=${slug:-episode-$n}           # no path segment -> numbered name instead of a hidden ".mp4"

  echo "--> m3u8:    $m3u8" >&2
  echo "--> referer: $referer" >&2
  echo "--> file:    $outdir/$slug.<ext>" >&2

  if download "$m3u8" "$referer" "$outdir/$slug" "$ua"; then
    ok=$((ok + 1))
  else
    echo "!!! download failed (exit $?): $url" >&2
    echo "$url" >> "$failed_file"; fail=$((fail + 1))
  fi
done 3< "$src"
cur_n=""

if (( ! started )); then
  echo "!!! --from=$from not found in $list ($n URLs)" >&2
  exit 2
fi
echo "=== done: $ok ok, $fail failed (of $done_n run this time)" >&2
if (( single )); then :
elif [[ -s $failed_file ]]; then echo "failed URLs written to $failed_file" >&2; else rm -f "$failed_file"; fi
(( fail == 0 ))
