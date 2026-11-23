// hlsgrab — small web front-end for batch_m3u8.sh (zero dependencies, Node >= 22).
// Every job runs the script itself, so the CLI and the UI behave identically.
//
// env: PORT (8090)  HOST (0.0.0.0)  DATA_DIR (./data)  DOWNLOADS_DIR ($DATA_DIR/downloads)
//      SCRIPT (./batch_m3u8.sh)  CONCURRENCY (1)  AUTH ("user:pass" enables HTTP basic auth)
//      LIBRARY_SIDECARS (off) "1" = jobs can carry a library target (movie/series id, season/episode, language);
//                       a finished job then writes <file>.hlsgrab.json next to the video for an external importer.
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8090);
const HOST = process.env.HOST || "0.0.0.0";
const DATA_DIR = path.resolve(process.env.DATA_DIR || path.join(HERE, "data"));
const DOWNLOADS_DIR = path.resolve(process.env.DOWNLOADS_DIR || path.join(DATA_DIR, "downloads"));
const SCRIPT = process.env.SCRIPT || path.join(HERE, "batch_m3u8.sh");
const CONCURRENCY = Math.max(1, Number(process.env.CONCURRENCY || 1));
const AUTH = process.env.AUTH || "";
const LIBRARY = /^(1|true|yes|on)$/i.test(process.env.LIBRARY_SIDECARS || "");
const LOG_LINES = 600;
const INDEX_HTML = path.join(HERE, "public", "index.html");

fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(DOWNLOADS_DIR, { recursive: true });

// ---------------- persistent job state ----------------
const STATE_FILE = path.join(DATA_DIR, "jobs.json");
let state = { paused: false, jobs: [] };
try { state = { ...state, ...JSON.parse(fs.readFileSync(STATE_FILE, "utf8")) }; } catch {}
for (const j of state.jobs) {
  if (j.status === "running") Object.assign(j, { status: "failed", error: "interrupted (server stopped unexpectedly)", finishedAt: Date.now() });
}
let lastSaveError = "";
const writeState = () => {
  try {
    const tmp = STATE_FILE + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(state));
    fs.renameSync(tmp, STATE_FILE);
    lastSaveError = "";
  } catch (e) {
    // Don't crash the server over it (jobs keep running); log each distinct problem once.
    if (e.message !== lastSaveError) console.error(`cannot save job list to ${STATE_FILE}: ${e.message}`);
    lastSaveError = e.message;
  }
};
let saveTimer;
const save = () => { clearTimeout(saveTimer); saveTimer = setTimeout(writeState, 300); };

// ---------------- jobs ----------------
const running = new Map(); // job id -> child process
let stopping = false;      // set on SIGTERM/SIGINT
const DOWNLOADERS = ["auto", "yt-dlp", "ffmpeg"];

const cleanOptions = (o = {}) => ({
  downloader: DOWNLOADERS.includes(o.downloader) ? o.downloader : "auto",
  timeout: Math.min(600, Math.max(5, Number(o.timeout) || 30)),
  hostCheck: o.hostCheck !== false,
});
const isHttpUrl = (u) => { try { return ["http:", "https:"].includes(new URL(u).protocol); } catch { return false; } };
const cleanName = (n = "") => String(n).trim().replace(/[\/\\\0]/g, "_").replace(/^\.+/, "").slice(0, 200);

// ---------------- library target (LIBRARY_SIDECARS) ----------------
// A job may say what it is: a movie or a series episode, identified by TMDB/TVDB/IMDb id. hlsgrab doesn't talk to
// Radarr/Sonarr itself; it only writes this as a sidecar file, so the container needs no API keys.
const LANGS = ["bul", "eng", "und"];
const MAX_EPISODES = 20;

// "36" | "36-40" | "36-e40" -> [36, ..., 40]
function parseEpisodes(s) {
  const m = /^\s*(\d{1,4})\s*(?:-\s*e?(\d{1,4}))?\s*$/i.exec(String(s ?? ""));
  if (!m) return null;
  const a = Number(m[1]), b = m[2] ? Number(m[2]) : a;
  if (a < 0 || b < a || b - a >= MAX_EPISODES) return null;
  return Array.from({ length: b - a + 1 }, (_, i) => a + i);
}

// Season/episode from a URL slug or file name: "show-1x18", "show-s01e18", "show-s02e36-e40", "show-2x36-40".
function slugSE(text) {
  const t = String(text || "").toLowerCase();
  let m = /(?:^|[^a-z0-9])s(\d{1,3})[ ._-]?e(\d{1,4})(?:[-_]?e?(\d{1,4}))?(?![0-9])/.exec(t);
  if (!m) m = /(?:^|[^0-9])(\d{1,3})x(\d{1,4})(?:-(\d{1,4}))?(?![0-9])/.exec(t);
  if (!m) return null;
  // A trailing number that isn't a sane range ("1x18-720p") is ignored rather than failing the whole match.
  const eps = (m[3] && parseEpisodes(`${m[2]}-${m[3]}`)) || parseEpisodes(m[2]);
  return eps ? { season: Number(m[1]), episodes: eps } : null;
}

// "tmdb:22586" | "tvdb:174681" | "imdb:tt0110943" | "22586" | a Seerr/TMDB/TVDB link -> { source, id }
function parseLibraryId(type, raw) {
  const s = String(raw || "").trim();
  if (!s) return null;
  let m;
  if ((m = /^(tmdb|tvdb):\s*(\d+)$/i.exec(s))) return { source: m[1].toLowerCase(), id: Number(m[2]) };
  if ((m = /^imdb:\s*(tt\d+)$/i.exec(s)) || (m = /^(tt\d{5,})$/i.exec(s))) return { source: "imdb", id: m[1].toLowerCase() };
  if (/^\d+$/.test(s)) return { source: type === "movie" ? "tmdb" : "tvdb", id: Number(s) };
  try {
    const u = new URL(s);
    if ((m = /\/(movie|tv)\/(\d+)/.exec(u.pathname))) {           // Seerr and themoviedb.org links use TMDB ids
      if ((m[1] === "movie") !== (type === "movie")) return { error: `that link is a ${m[1] === "tv" ? "series" : "movie"}` };
      return { source: "tmdb", id: Number(m[2]) };
    }
    if (/thetvdb\.com$/.test(u.hostname) && (m = /[?&]id=(\d+)/.exec(u.search))) return { source: "tvdb", id: Number(m[1]) };
    if ((m = /\/title\/(tt\d+)/.exec(u.pathname))) return { source: "imdb", id: m[1] };
  } catch {}
  return { error: "unrecognised id (use tmdb:123, tvdb:123, imdb:tt123 or a Seerr/TMDB link)" };
}

// Validates the library part of a request for one job. slugText = URL slug or file name, used for season/episode.
function cleanLibrary(l, slugText) {
  if (!LIBRARY || !l || !["movie", "series"].includes(l.type)) return { value: null };
  const ref = parseLibraryId(l.type, l.id);
  if (!ref) return { error: "library target needs an id" };
  if (ref.error) return { error: ref.error };
  const value = { type: l.type, idSource: ref.source, id: ref.id, language: LANGS.includes(l.language) ? l.language : "bul" };
  if (l.type === "series") {
    const fromSlug = slugSE(slugText);
    const season = String(l.season ?? "").trim() !== "" ? Number(l.season) : fromSlug?.season;
    const episodes = String(l.episode ?? "").trim() !== "" ? parseEpisodes(l.episode) : fromSlug?.episodes;
    if (!Number.isInteger(season) || season < 0) return { error: "no season (not in the URL; set it in Library)" };
    if (!episodes) return { error: "no episode (not in the URL; set it in Library)" };
    Object.assign(value, { season, episodes });
  }
  return { value };
}

const libraryLabel = (l) => !l ? "" : l.type === "movie" ? `movie ${l.idSource}:${l.id}`
  : `series ${l.idSource}:${l.id} S${String(l.season).padStart(2, "0")}E${l.episodes.map((e) => String(e).padStart(2, "0")).join("-E")}`;

// Written only after a successful download, atomically, so an importer never sees a half-finished file.
async function writeSidecar(j) {
  if (!LIBRARY || !j.library) return;
  if (!j.file) { j.log.push("!!! library target set, but the downloaded file wasn't found: no sidecar written"); return; }
  const p = path.join(DOWNLOADS_DIR, j.file.replace(/\.[^.]+$/, "") + ".hlsgrab.json");
  const data = { version: 1, file: j.file, ...j.library, sourceUrl: j.url, jobId: j.id, finishedAt: j.finishedAt };
  await fsp.writeFile(p + ".tmp", JSON.stringify(data, null, 2) + "\n");
  await fsp.rename(p + ".tmp", p);
  j.log.push(`--> library sidecar: ${path.basename(p)} (${libraryLabel(j.library)})`);
}

function newJob(fields) {
  return { id: randomUUID(), status: "queued", createdAt: Date.now(), log: [], progress: null, ...fields };
}

function scriptArgs(j) {
  const o = j.options;
  const common = [`--out=${DOWNLOADS_DIR}`, `--downloader=${o.downloader}`];
  if (!o.hostCheck) common.push("--no-host-check");
  if (j.kind === "direct") return ["--direct", j.url, j.referer || "", ...(j.name ? [j.name] : []), ...common];
  return [j.url, ...common, `--timeout=${o.timeout}`];
}

const stripAnsi = (s) => s.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");

function handleLine(j, raw, transient) {
  const line = stripAnsi(raw).trimEnd();
  if (!line.trim()) return;
  // Progress lines (yt-dlp "[download]  42.0% of …", ffmpeg "frame=… time=…") replace each other instead of piling up.
  const ytPct = /^\[download\]\s+(\d+(?:\.\d+)?)%/.exec(line);
  const ffStat = /(?:^|\s)(?:frame|size)=.*\btime=(\S+)/.exec(line);
  if (transient || ytPct || ffStat) {
    j.progress = { text: line.trim(), percent: ytPct ? Number(ytPct[1]) : null, time: ffStat ? ffStat[1] : null };
    return; // progress goes to the progress bar, not the log
  }
  let m;
  if ((m = /^--> m3u8:\s+(.*)$/.exec(line))) j.m3u8 = m[1];
  else if ((m = /^--> referer:\s*(.*)$/.exec(line))) j.foundReferer = m[1];
  else if ((m = /^--> file:\s+(.*)\.<ext>$/.exec(line))) j.target = path.basename(m[1]);
  else if ((m = /^--> tool:\s+(.*)$/.exec(line))) j.tool = m[1];
  else if ((m = /^--> hosts:\s+(.*)$/.exec(line))) j.hosts = m[1];
  else if ((m = /^\[(?:download|Merger)\] (?:Destination: |Merging formats into ")(.*?)"?$/.exec(line))) j.file = path.basename(m[1]);
  else if ((m = /^\[download\] (.*) has already been downloaded/.exec(line))) j.file = path.basename(m[1]);
  else if (/^(!!!|ERROR)/.test(line) || /^no m3u8 request seen/.test(line)) j.lastError = line.replace(/^!!!\s*/, "");
  j.log.push(line);
  if (j.log.length > LOG_LINES) j.log.splice(0, j.log.length - LOG_LINES);
}

function lineSplitter(j) {
  let buf = "";
  return (chunk) => {
    buf += chunk.toString("utf8");
    const re = /\r\n|\r|\n/g;
    let m, last = 0;
    while ((m = re.exec(buf))) {
      handleLine(j, buf.slice(last, m.index), m[0] === "\r");
      last = re.lastIndex;
    }
    buf = buf.slice(last);
    if (buf.length > 8192) { handleLine(j, buf, true); buf = ""; }
  };
}

async function findOutputFile(j) {
  if (j.file && fs.existsSync(path.join(DOWNLOADS_DIR, j.file))) return j.file;
  if (!j.target) return null;
  const files = (await fsp.readdir(DOWNLOADS_DIR)).filter((f) => f.startsWith(j.target + ".") && !isTempFile(f));
  if (!files.length) return null;
  const stats = await Promise.all(files.map(async (f) => [f, (await fsp.stat(path.join(DOWNLOADS_DIR, f))).mtimeMs]));
  return stats.sort((a, b) => b[1] - a[1])[0][0];
}

function startJob(j) {
  Object.assign(j, {
    status: "running", startedAt: Date.now(), finishedAt: null, log: [], progress: null, error: null,
    lastError: null, file: null, target: j.kind === "direct" ? j.name || null : null, tool: null, hosts: null,
    m3u8: j.kind === "direct" ? j.url : null, exitCode: null, cancelRequested: false,
  });
  const child = spawn("bash", [SCRIPT, ...scriptArgs(j)], { detached: true, stdio: ["ignore", "pipe", "pipe"] });
  running.set(j.id, child);
  child.stdout.on("data", lineSplitter(j));
  child.stderr.on("data", lineSplitter(j));
  child.on("error", (e) => { j.lastError = `cannot start script: ${e.message}`; });
  child.on("close", async (code, signal) => {
    running.delete(j.id);
    if (stopping) return; // shutdown already saved this job as queued; don't overwrite that
    j.exitCode = code;
    j.finishedAt = Date.now();
    if (j.requeue) { Object.assign(j, { status: "queued", requeue: false }); }
    else if (j.cancelRequested) j.status = "cancelled";
    else if (code === 0) { j.status = "done"; j.progress = j.progress && { ...j.progress, percent: 100 }; }
    else { j.status = "failed"; j.error = j.lastError || (signal ? `killed by ${signal}` : `exit code ${code}`); }
    if (j.status === "done") {
      j.file = await findOutputFile(j).catch(() => null);
      await writeSidecar(j).catch((e) => j.log.push(`!!! cannot write library sidecar: ${e.message}`));
    }
    save();
    pump();
  });
  save();
}

function stopChild(id, { requeue = false } = {}) {
  const child = running.get(id);
  const j = state.jobs.find((x) => x.id === id);
  if (!child || !j) return false;
  if (requeue) j.requeue = true; else j.cancelRequested = true;
  // SIGINT the whole process group: the script cleans up (Chrome, local playlist server, temp files) and exits.
  try { process.kill(-child.pid, "SIGINT"); } catch {}
  setTimeout(() => { if (running.has(id)) try { process.kill(-child.pid, "SIGKILL"); } catch {} }, 8000);
  return true;
}

function pump() {
  if (state.paused) return;
  while (running.size < CONCURRENCY) {
    const j = state.jobs.find((x) => x.status === "queued");
    if (!j) break;
    startJob(j);
  }
}

const summary = (j) => {
  const { log, ...rest } = j;
  return { ...rest, logTail: log.slice(-1)[0] || null };
};

// ---------------- probe (find the stream only, no download) ----------------
function probe(url, timeout) {
  return new Promise((resolve) => {
    const child = spawn("bash", [SCRIPT, "--probe", url, "--headful", `--timeout=${timeout}`], { detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    child.stdout.on("data", (c) => (out += c));
    child.stderr.on("data", (c) => (err += c));
    child.on("close", (code) => {
      try { resolve({ ok: code === 0, result: JSON.parse(out), log: err.trim() }); }
      catch { resolve({ ok: false, error: err.trim().split("\n").pop() || `exit code ${code}`, log: err.trim() }); }
    });
  });
}

// ---------------- files ----------------
const isTempFile = (f) => /\.part(\.mp4)?$|\.ytdl$|\.temp(\.|$)|\.part-Frag\d+|^\.|\.hlsgrab\.json(\.tmp)?$/i.test(f);
const MIME = { mp4: "video/mp4", mkv: "video/x-matroska", webm: "video/webm", ts: "video/mp2t", m4a: "audio/mp4", mp3: "audio/mpeg", vtt: "text/vtt", srt: "text/plain" };

async function listFiles() {
  const ents = await fsp.readdir(DOWNLOADS_DIR, { withFileTypes: true });
  const files = await Promise.all(ents.filter((e) => e.isFile() && !isTempFile(e.name)).map(async (e) => {
    const st = await fsp.stat(path.join(DOWNLOADS_DIR, e.name));
    return { name: e.name, size: st.size, mtime: st.mtimeMs };
  }));
  return files.sort((a, b) => b.mtime - a.mtime);
}

function safeFile(name) {
  const p = path.resolve(DOWNLOADS_DIR, name);
  return path.dirname(p) === DOWNLOADS_DIR && !name.includes("/") && !name.startsWith(".") ? p : null;
}

async function sendFile(req, res, file, download) {
  let st;
  try { st = await fsp.stat(file); } catch { return send(res, 404, { error: "not found" }); }
  const ext = path.extname(file).slice(1).toLowerCase();
  const headers = { "Content-Type": MIME[ext] || "application/octet-stream", "Accept-Ranges": "bytes" };
  if (download) headers["Content-Disposition"] = `attachment; filename*=UTF-8''${encodeURIComponent(path.basename(file))}`;
  let start = 0, end = st.size - 1, status = 200;
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || "");
  if (m && (m[1] || m[2])) {
    if (m[1] === "") start = Math.max(0, st.size - Number(m[2]));
    else { start = Number(m[1]); if (m[2]) end = Math.min(end, Number(m[2])); }
    if (start > end || start >= st.size) { res.writeHead(416, { "Content-Range": `bytes */${st.size}` }); return res.end(); }
    status = 206;
    headers["Content-Range"] = `bytes ${start}-${end}/${st.size}`;
  }
  headers["Content-Length"] = st.size ? end - start + 1 : 0;
  res.writeHead(status, headers);
  if (req.method === "HEAD" || !st.size) return res.end();
  fs.createReadStream(file, { start, end }).pipe(res);
}

// ---------------- http ----------------
function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(data);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on("data", (c) => { size += c.length; if (size > 2_000_000) { reject(new Error("body too large")); req.destroy(); } else chunks.push(c); });
    req.on("end", () => { try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}); } catch { reject(new Error("invalid JSON")); } });
    req.on("error", reject);
  });
}

function authorized(req) {
  if (!AUTH) return true;
  const m = /^Basic (.+)$/.exec(req.headers.authorization || "");
  if (!m) return false;
  const given = Buffer.from(Buffer.from(m[1], "base64").toString("utf8"));
  const want = Buffer.from(AUTH);
  return given.length === want.length && timingSafeEqual(given, want);
}

function addJobs(body) {
  const options = cleanOptions(body.options);
  const created = [], rejected = [];
  const slugOf = (u) => { try { return new URL(u).pathname.split("/").filter(Boolean).pop() || ""; } catch { return ""; } };
  if (body.mode === "direct") {
    const url = String(body.url || "").trim();
    if (!isHttpUrl(url)) return { created, rejected: [`${url || "(empty)"}: not an http(s) URL`] };
    const name = cleanName(body.name);
    const lib = cleanLibrary(body.library, name);
    if (lib.error) return { created, rejected: [`${name || url}: ${lib.error}`] };
    created.push(newJob({ kind: "direct", url, referer: String(body.referer || "").trim(), name, options, library: lib.value }));
  } else {
    for (let line of String(body.urls || "").split(/\r?\n/)) {
      line = line.trim();
      if (!line || line.startsWith("#")) continue;
      if (!isHttpUrl(line)) { rejected.push(`${line}: not an http(s) URL`); continue; }
      const lib = cleanLibrary(body.library, slugOf(line));
      if (lib.error) { rejected.push(`${line}: ${lib.error}`); continue; }
      created.push(newJob({ kind: "page", url: line, options, library: lib.value }));
    }
  }
  state.jobs.push(...created);
  save();
  pump();
  return { created: created.map((j) => j.id), rejected };
}

const server = http.createServer(async (req, res) => {
  try {
    if (!authorized(req)) {
      res.writeHead(401, { "WWW-Authenticate": 'Basic realm="hlsgrab"' });
      return res.end("authentication required");
    }
    const url = new URL(req.url, "http://x");
    const p = url.pathname;
    const seg = p.split("/").filter(Boolean).map(decodeURIComponent);

    if (req.method === "GET" && (p === "/" || p === "/index.html")) {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      return fs.createReadStream(INDEX_HTML).pipe(res);
    }
    if (req.method === "GET" && p === "/api/state") {
      return send(res, 200, { paused: state.paused, concurrency: CONCURRENCY, downloadsDir: DOWNLOADS_DIR, library: LIBRARY, jobs: state.jobs.map(summary) });
    }
    if (req.method === "POST" && p === "/api/jobs") return send(res, 200, addJobs(await readJson(req)));
    if (req.method === "POST" && p === "/api/queue") {
      const body = await readJson(req);
      state.paused = !!body.paused; save(); pump();
      return send(res, 200, { paused: state.paused });
    }
    if (req.method === "POST" && p === "/api/jobs/clear") {
      state.jobs = state.jobs.filter((j) => ["queued", "running"].includes(j.status)); save();
      return send(res, 200, { ok: true });
    }
    if (req.method === "POST" && p === "/api/jobs/retry-failed") {
      for (const j of state.jobs) if (["failed", "cancelled"].includes(j.status)) Object.assign(j, { status: "queued", error: null });
      save(); pump();
      return send(res, 200, { ok: true });
    }
    if (seg[0] === "api" && seg[1] === "jobs" && seg[2]) {
      const j = state.jobs.find((x) => x.id === seg[2]);
      if (!j) return send(res, 404, { error: "no such job" });
      if (req.method === "GET" && !seg[3]) return send(res, 200, j);
      if (req.method === "POST" && seg[3] === "cancel") {
        if (j.status === "queued") { j.status = "cancelled"; save(); return send(res, 200, { ok: true }); }
        return send(res, 200, { ok: stopChild(j.id) });
      }
      if (req.method === "POST" && seg[3] === "retry") {
        if (j.status === "running") return send(res, 409, { error: "job is running" });
        Object.assign(j, { status: "queued", error: null }); save(); pump();
        return send(res, 200, { ok: true });
      }
      if (req.method === "DELETE" && !seg[3]) {
        if (j.status === "running") return send(res, 409, { error: "cancel it first" });
        state.jobs = state.jobs.filter((x) => x !== j); save();
        return send(res, 200, { ok: true });
      }
    }
    if (req.method === "POST" && p === "/api/probe") {
      const body = await readJson(req);
      const u = String(body.url || "").trim();
      if (!isHttpUrl(u)) return send(res, 400, { error: "not an http(s) URL" });
      return send(res, 200, await probe(u, cleanOptions(body).timeout));
    }
    if (req.method === "GET" && p === "/api/files") return send(res, 200, { files: await listFiles() });
    if (seg[0] === "api" && seg[1] === "files" && seg[2] && req.method === "DELETE") {
      const f = safeFile(seg[2]);
      if (!f) return send(res, 400, { error: "bad file name" });
      await fsp.unlink(f).catch(() => {});
      return send(res, 200, { ok: true });
    }
    if (seg[0] === "files" && seg[1] && (req.method === "GET" || req.method === "HEAD")) {
      const f = safeFile(seg[1]);
      if (!f) return send(res, 400, { error: "bad file name" });
      return sendFile(req, res, f, url.searchParams.has("download"));
    }
    send(res, 404, { error: "not found" });
  } catch (e) {
    send(res, 500, { error: e.message });
  }
});

// On a normal stop (docker stop / Ctrl+C) put running jobs back in the queue so they resume on the next start.
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    if (stopping) return;
    stopping = true;
    for (const id of running.keys()) stopChild(id, { requeue: true });
    for (const j of state.jobs) if (j.status === "running") Object.assign(j, { status: "queued", requeue: false });
    clearTimeout(saveTimer);
    writeState();
    setTimeout(() => process.exit(0), running.size ? 1500 : 0);
  });
}

server.listen(PORT, HOST, () => {
  console.log(`hlsgrab listening on http://${HOST}:${PORT}  downloads: ${DOWNLOADS_DIR}  data: ${DATA_DIR}${AUTH ? "  (basic auth on)" : ""}${LIBRARY ? "  (library sidecars on)" : ""}`);
  pump();
});
