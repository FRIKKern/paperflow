#!/usr/bin/env node
// claude-bridge: per-instance HTTP bridge daemon.
//
// One bridge per Claude Code session. Spawns on a dynamic port, owns 4
// endpoints, registers itself in ~/.paperflow/instances/<session_id>.jsonl,
// heartbeats every 3s, dies when its owner Claude Code process dies.
//
// CLI args (BOTH required, daemon refuses to start without them):
//   --owner-pid=<pid>      PID of the Claude Code process this bridge serves
//   --session-id=<id>      Stable session identifier (used for state file name)
//
// Optional:
//   --port-fallback=<n>    Suggested port; ignored (we always bind :0). Kept
//                          for backwards compatibility with older shims.
//
// Endpoints (4 — auxiliaries moved to live-server :8765):
//   GET  /                       liveness ping
//   POST /build                  dispatch a message to the originating terminal
//                                (requires doc_nonce; validates against registry)
//   POST /marker                 questionnaire-answered sidecar
//                                (requires doc_nonce; validates against registry)
//   POST /docs/register          {doc_path, doc_nonce} → appends to JSONL
//   GET  /docs/:nonce/status     {state, age_ms, banner:{buttons:[...]}}
//
// Removed endpoints (return 410 Gone with new_url pointing at :8765):
//   /event, /event/active, /event/<id>, /goal-path, /diff,
//   /navigate, /simplify, /simplify/status, /simplify/accept, /simplify/reject

const http = require('http');
const path = require('path');
const fs   = require('fs');
const os   = require('os');
const { execFile } = require('child_process');

// ── CLI arg parsing ─────────────────────────────────────────────────
function parseArgs(argv) {
  const out = {};
  for (const a of argv.slice(2)) {
    const m = /^--([a-zA-Z0-9_-]+)(?:=(.*))?$/.exec(a);
    if (!m) continue;
    out[m[1]] = m[2] === undefined ? true : m[2];
  }
  return out;
}

const ARGS       = parseArgs(process.argv);
const OWNER_PID  = parseInt(ARGS['owner-pid'], 10);
const SESSION_ID = ARGS['session-id'];

if (!Number.isFinite(OWNER_PID) || OWNER_PID <= 0) {
  console.error('claude-bridge: --owner-pid=<pid> is required (positive integer)');
  process.exit(2);
}
if (!SESSION_ID || typeof SESSION_ID !== 'string' || /[\/\\.]/.test(SESSION_ID)) {
  console.error('claude-bridge: --session-id=<id> is required (no slashes or dots)');
  process.exit(2);
}

const HOST           = '127.0.0.1';
const INSTANCES_DIR  = path.join(os.homedir(), '.paperflow', 'instances');
const LOGS_DIR       = path.join(os.homedir(), '.paperflow', 'logs');
const STATE_FILE     = path.join(INSTANCES_DIR, `${SESSION_ID}.jsonl`);
const LOG_FILE       = path.join(LOGS_DIR, `bridge-${SESSION_ID}.log`);
const LIVE_BASE_URL  = 'http://localhost:8765/paperflow';
const HEARTBEAT_MS   = 3000;
const OWNER_WATCH_MS = 5000;
const LIVENESS_MAX_MS = 10000;

// Optional cmux surface info inherited from the spawning environment.
const CMUX_WORKSPACE = process.env.CMUX_WORKSPACE || null;
const CMUX_SURFACE   = process.env.CMUX_SURFACE   || null;

// In-memory registry of doc_nonces this daemon has registered. JSONL on disk
// is the source of truth on cold-start (currently the daemon is born empty
// each spawn, so the memory set is sufficient — the JSONL is for the doctor).
const REGISTRY = new Map(); // doc_nonce → { doc_path, registered_at }

// ── small helpers ───────────────────────────────────────────────────
function ensureDir(d) {
  try { fs.mkdirSync(d, { recursive: true }); } catch (_) { /* */ }
}

function logLine(msg) {
  ensureDir(LOGS_DIR);
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  try { fs.appendFileSync(LOG_FILE, line); } catch (_) { /* */ }
}

function appendStateLine(obj) {
  // Best-effort append. The file was atomically created at startup so a
  // partial-line race is unlikely; the doctor tolerates malformed lines.
  try { fs.appendFileSync(STATE_FILE, JSON.stringify(obj) + '\n'); }
  catch (e) { logLine(`state append failed: ${e.message}`); }
}

function ownerAlive() {
  try { process.kill(OWNER_PID, 0); return true; }
  catch (_) { return false; }
}

function nonceSafe(n) {
  return typeof n === 'string' && /^[a-zA-Z0-9_-]+$/.test(n) && n.length <= 128;
}

function collectBody(req, cb) {
  let body = '';
  req.on('data', c => (body += c));
  req.on('end', () => {
    let payload;
    try { payload = body ? JSON.parse(body) : {}; }
    catch (e) { return cb(e); }
    cb(null, payload);
  });
}

function jsonRes(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

// ── AppleScript escape + per-target dispatch (carried over) ─────────
const esc = s => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

function viaTmux(pane, message, cb) {
  execFile('tmux', ['send-keys', '-t', pane, message, 'Enter'],
    err => cb(err, err ? null : 'tmux:' + pane));
}

function viaITerm(sessionId, message, cb) {
  const script = `
    tell application "iTerm"
      tell session id "${esc(sessionId)}"
        write text "${esc(message)}"
        select
      end tell
      activate
    end tell`;
  execFile('osascript', ['-e', script],
    (err, stdout) => cb(err, err ? null : 'iterm:' + (stdout || '').trim()));
}

function viaAppleTerminal(tty, message, cb) {
  const script = `
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          try
            if tty of t is "${esc(tty)}" then
              do script "${esc(message)}" in t
              set selected of t to true
              set frontmost of w to true
              activate
              return "ok:" & (id of w as text) & "/" & (tty of t)
            end if
          end try
        end repeat
      end repeat
      return "not_found:" & "${esc(tty)}"
    end tell`;
  execFile('osascript', ['-e', script],
    (err, stdout) => cb(err, err ? null : 'apple:' + (stdout || '').trim()));
}

function viaCmux(target, message, cb) {
  const cli = target.cmux_cli || '/Applications/cmux.app/Contents/Resources/bin/cmux';
  const sendArgs = ['send'];
  if (target.cmux_workspace) sendArgs.push('--workspace', target.cmux_workspace);
  if (target.cmux_surface)   sendArgs.push('--surface',   target.cmux_surface);
  sendArgs.push(message);
  execFile(cli, sendArgs, err1 => {
    if (err1) return cb(err1);
    const keyArgs = ['send-key'];
    if (target.cmux_workspace) keyArgs.push('--workspace', target.cmux_workspace);
    if (target.cmux_surface)   keyArgs.push('--surface',   target.cmux_surface);
    keyArgs.push('Return');
    execFile(cli, keyArgs, err2 =>
      cb(err2, err2 ? null : 'cmux:' + (target.cmux_surface || target.cmux_workspace)));
  });
}

function viaActivateAndType(pid, message, cb) {
  const script = `
    tell application "System Events"
      set frontmost of (first process whose unix id is ${parseInt(pid, 10)}) to true
      delay 0.15
      keystroke "${esc(message)}"
      key code 36
    end tell`;
  execFile('osascript', ['-e', script],
    (err, stdout) => cb(err, err ? null : 'activate:' + pid));
}

function dispatch(target, message, cb) {
  if (!target || typeof target !== 'object') {
    return cb(new Error('target must be an object'));
  }
  if (target.term_program === 'cmux' || target.cmux_workspace || target.cmux_surface) {
    return viaCmux(target, message, cb);
  }
  if (target.tmux_pane) {
    return viaTmux(target.tmux_pane, message, cb);
  }
  if (target.term_program === 'iTerm.app' && target.term_session_id) {
    return viaITerm(target.term_session_id, message, cb);
  }
  if (target.term_program === 'Apple_Terminal' && target.tty) {
    return viaAppleTerminal(target.tty, message, cb);
  }
  if (target.pid) {
    return viaActivateAndType(target.pid, message, cb);
  }
  cb(new Error('unsupported target: ' + JSON.stringify(target)));
}

// ── liveness signal (heartbeat) ─────────────────────────────────────
let lastHeartbeat = Date.now();
function heartbeat() {
  const ts = new Date().toISOString();
  lastHeartbeat = Date.now();
  // Touch + append: the doctor's age check uses both file mtime and the most
  // recent heartbeat line, whichever is younger.
  appendStateLine({ type: 'heartbeat', ts });
  try { fs.utimesSync(STATE_FILE, new Date(), new Date()); } catch (_) { /* */ }
}

// ── HTTP server ─────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  // CORS — buttons POST from http://localhost:8765
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const port = server.address() ? server.address().port : 0;
  const url = new URL(req.url, `http://${HOST}:${port}`);

  // ── liveness ─────────────────────────────────────────────────────
  if (req.method === 'GET' && url.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('claude-bridge ok\n');
  }

  // ── POST /docs/register ──────────────────────────────────────────
  if (req.method === 'POST' && url.pathname === '/docs/register') {
    collectBody(req, (pErr, payload) => {
      if (pErr) return jsonRes(res, 400, { error: 'invalid JSON' });
      const { doc_path, doc_nonce } = payload || {};
      if (!doc_path || typeof doc_path !== 'string') {
        return jsonRes(res, 400, { error: 'need {doc_path}' });
      }
      if (!nonceSafe(doc_nonce)) {
        return jsonRes(res, 400, { error: 'doc_nonce must be [a-zA-Z0-9_-]{1,128}' });
      }
      const registered_at = new Date().toISOString();
      REGISTRY.set(doc_nonce, { doc_path, registered_at });
      appendStateLine({ type: 'registration', doc_path, doc_nonce, registered_at });
      logLine(`register ${doc_nonce} → ${doc_path}`);
      return jsonRes(res, 200, { ok: true });
    });
    return;
  }

  // ── GET /docs/:nonce/status ──────────────────────────────────────
  const statusMatch = /^\/docs\/([a-zA-Z0-9_-]+)\/status$/.exec(url.pathname);
  if (req.method === 'GET' && statusMatch) {
    const nonce = statusMatch[1];
    const entry = REGISTRY.get(nonce);
    const age_ms = Date.now() - lastHeartbeat;
    if (!entry) {
      // Port listening but nonce unknown — stale binding (registry was wiped
      // or daemon restarted without it). Browser should offer rebind+spawn.
      // If we want strict 404, swap to jsonRes(res, 404, {state: 'unknown'}).
      return jsonRes(res, 200, {
        state: 'unknown',
        age_ms,
        banner: { buttons: [] }
      });
    }
    if (!ownerAlive()) {
      return jsonRes(res, 200, {
        state: 'session-gone',
        age_ms,
        banner: { buttons: ['spawn'] }
      });
    }
    if (age_ms > LIVENESS_MAX_MS) {
      // Heartbeat stalled — same outcome as owner-dead from the browser's POV.
      return jsonRes(res, 200, {
        state: 'session-gone',
        age_ms,
        banner: { buttons: ['spawn'] }
      });
    }
    return jsonRes(res, 200, {
      state: 'live',
      age_ms,
      banner: { buttons: [] }
    });
  }

  // ── POST /build ──────────────────────────────────────────────────
  if (req.method === 'POST' && url.pathname === '/build') {
    collectBody(req, (pErr, payload) => {
      if (pErr) return jsonRes(res, 400, { error: 'invalid JSON' });
      const { target, message, doc_nonce } = payload || {};
      if (!message) return jsonRes(res, 400, { error: 'need {target, message, doc_nonce}' });
      if (!nonceSafe(doc_nonce)) {
        return jsonRes(res, 400, { error: 'doc_nonce required' });
      }
      if (!REGISTRY.has(doc_nonce)) {
        return jsonRes(res, 410, {
          code: 'stale-binding',
          message: 'doc_nonce not registered with this daemon — rebind needed'
        });
      }
      if (!ownerAlive()) {
        return jsonRes(res, 410, {
          code: 'session-gone',
          message: 'owner Claude Code process is dead — spawn fresh agent'
        });
      }
      dispatch(target, message, (err, result) => {
        if (err) {
          logLine(`dispatch error: ${err.message} | target: ${JSON.stringify(target)}`);
          return jsonRes(res, 500, { error: err.message });
        }
        logLine(`dispatched → ${result} | msg: ${JSON.stringify(message).slice(0, 80)}`);
        return jsonRes(res, 200, { ok: true, result });
      });
    });
    return;
  }

  // ── POST /marker ─────────────────────────────────────────────────
  if (req.method === 'POST' && url.pathname === '/marker') {
    collectBody(req, (pErr, payload) => {
      if (pErr) return jsonRes(res, 400, { error: 'invalid JSON' });
      const { kind, plan, submitted_at, doc_nonce } = payload || {};
      if (!plan || typeof plan !== 'string') {
        return jsonRes(res, 400, { error: 'need {plan, doc_nonce}' });
      }
      if (plan.includes('..') || plan.startsWith('/')) {
        return jsonRes(res, 400, { error: 'plan must be a relative path under ~/docs/paperflow/' });
      }
      if (!nonceSafe(doc_nonce)) {
        return jsonRes(res, 400, { error: 'doc_nonce required' });
      }
      if (!REGISTRY.has(doc_nonce)) {
        return jsonRes(res, 410, {
          code: 'stale-binding',
          message: 'doc_nonce not registered with this daemon — rebind needed'
        });
      }
      if (!ownerAlive()) {
        return jsonRes(res, 410, {
          code: 'session-gone',
          message: 'owner Claude Code process is dead — spawn fresh agent'
        });
      }
      const docsRoot = path.join(os.homedir(), 'docs', 'paperflow');
      const stem = plan.replace(/\.html$/, '');
      const candidates = [
        path.join(docsRoot, 'questionnaires', `${stem}-answered.json`),
        path.join(docsRoot, 'grills',         `${stem}-answered.json`)
      ];
      const target = candidates.find(p => {
        try { return fs.statSync(path.dirname(p)).isDirectory(); }
        catch { return false; }
      });
      if (!target) {
        return jsonRes(res, 400, { error: 'no suitable docs/paperflow/{questionnaires,grills}/ dir' });
      }
      const ts = new Date().toISOString();
      const marker = JSON.stringify({
        kind: kind || 'unknown',
        submitted_at: submitted_at || ts
      });
      fs.writeFile(target, marker, err => {
        if (err) {
          logLine(`marker write error: ${err.message}`);
          return jsonRes(res, 500, { error: err.message });
        }
        logLine(`marker → ${target}`);
        return jsonRes(res, 200, { ok: true, path: target });
      });
    });
    return;
  }

  // ── 410 Gone for the 9 auxiliary endpoints that moved to :8765 ───
  // Anything matching these prefixes — short-circuit to a structured 410
  // with a hint at the new live-server URL.
  const movedPaths = new Set([
    '/event', '/event/active',
    '/goal-path', '/diff',
    '/navigate',
    '/simplify', '/simplify/status',
    '/simplify/accept', '/simplify/reject'
  ]);
  if (movedPaths.has(url.pathname) || url.pathname.startsWith('/event/')) {
    return jsonRes(res, 410, {
      error: 'moved',
      new_url: `${LIVE_BASE_URL}${url.pathname}`
    });
  }

  // ── unknown ──────────────────────────────────────────────────────
  res.writeHead(404); res.end();
});

// ── startup: bind dynamic port, write state file atomically ─────────
ensureDir(INSTANCES_DIR);

server.listen(0, HOST, () => {
  const port = server.address().port;

  // Atomic state-file create: write to tmp + rename. Open with 'wx' so the
  // file MUST be new — a stale file from a crashed previous instance with
  // the same session_id would otherwise let two daemons race.
  const tmp = STATE_FILE + '.tmp-' + process.pid;
  const session = {
    type: 'session',
    session_id: SESSION_ID,
    port,
    owner_pid: OWNER_PID,
    cmux_workspace: CMUX_WORKSPACE,
    cmux_surface: CMUX_SURFACE,
    started_at: new Date().toISOString(),
    pid: process.pid
  };
  try {
    fs.writeFileSync(tmp, JSON.stringify(session) + '\n', { flag: 'wx' });
    fs.renameSync(tmp, STATE_FILE);
  } catch (e) {
    console.error(`claude-bridge: cannot write state file ${STATE_FILE}: ${e.message}`);
    try { fs.unlinkSync(tmp); } catch (_) { /* */ }
    process.exit(3);
  }

  logLine(`listening port=${port} session=${SESSION_ID} owner_pid=${OWNER_PID}`);
  console.log(`claude-bridge listening on http://${HOST}:${port} (session=${SESSION_ID}, owner_pid=${OWNER_PID})`);

  // Schedule heartbeat + owner-watch. setInterval refs keep the loop alive,
  // which is exactly what we want — bridge runs until SIGTERM or owner death.
  setInterval(heartbeat, HEARTBEAT_MS);
  setInterval(() => {
    if (!ownerAlive()) {
      logLine(`owner pid ${OWNER_PID} is gone; self-SIGTERM`);
      // Raise SIGTERM on ourselves so the orderly-shutdown handler runs once.
      try { process.kill(process.pid, 'SIGTERM'); } catch (_) { process.exit(0); }
    }
  }, OWNER_WATCH_MS);
});

// ── orderly shutdown ────────────────────────────────────────────────
let shuttingDown = false;
function shutdown(reason) {
  if (shuttingDown) return;
  shuttingDown = true;
  const ts = new Date().toISOString();
  appendStateLine({ type: 'orphan', ts, reason });
  logLine(`shutdown reason=${reason}`);
  try { server.close(() => process.exit(0)); } catch (_) { process.exit(0); }
  // Hard exit fallback if server.close drags.
  setTimeout(() => process.exit(0), 1500).unref();
}

process.on('SIGTERM', () => shutdown('sigterm'));
process.on('SIGINT',  () => shutdown('sigint'));
