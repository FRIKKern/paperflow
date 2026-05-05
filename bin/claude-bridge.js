#!/usr/bin/env node
// claude-bridge: tiny HTTP server that receives POST /build {target, message}
// from a plan/spec HTML "Build" button and dispatches the message into the
// originating terminal tab using whatever targeting mechanism that terminal
// supports (tmux, iTerm AppleScript, Apple Terminal AppleScript, ...).
//
// Foreground for testing:    node claude-bridge.js
// Logs:                      stdout / stderr

const http = require('http');
const { execFile } = require('child_process');

const PORT = 8766;
const HOST = '127.0.0.1';

// ── AppleScript string escape (\" and \\) ──────────────────────────
const esc = s => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');

// ── per-target dispatch ─────────────────────────────────────────────
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
  // Find the tab whose tty matches, `do script` into it, then bring window + app to front.
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
  // cmux.app: use the bundled CLI to send text + Enter to a specific surface.
  // The surface ref is captured at write-time by get-terminal-target.sh.
  const cli = target.cmux_cli || '/Applications/cmux.app/Contents/Resources/bin/cmux';
  const sendArgs = ['send'];
  if (target.cmux_workspace) sendArgs.push('--workspace', target.cmux_workspace);
  if (target.cmux_surface) sendArgs.push('--surface', target.cmux_surface);
  sendArgs.push(message);
  execFile(cli, sendArgs, err1 => {
    if (err1) return cb(err1);
    const keyArgs = ['send-key'];
    if (target.cmux_workspace) keyArgs.push('--workspace', target.cmux_workspace);
    if (target.cmux_surface) keyArgs.push('--surface', target.cmux_surface);
    keyArgs.push('Return');
    execFile(cli, keyArgs, err2 =>
      cb(err2, err2 ? null : 'cmux:' + (target.cmux_surface || target.cmux_workspace)));
  });
}

function viaActivateAndType(pid, message, cb) {
  // Generic fallback: bring PID's app to front, then send keystrokes.
  // ~200ms focus flicker — works for Ghostty/Warp/Alacritty/etc.
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

// ── HTTP server ─────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  // CORS for browser access from http://localhost:8765/...
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  if (req.method === 'GET' && req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('claude-bridge ok\n');
  }

  if (req.method === 'POST' && req.url === '/build') {
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', () => {
      let payload;
      try { payload = JSON.parse(body); }
      catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { target, message } = payload || {};
      if (!message) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'need {target, message}' }));
      }
      dispatch(target, message, (err, result) => {
        const ts = new Date().toISOString();
        if (err) {
          console.error(`[${ts}] dispatch error:`, err.message, '| target:', JSON.stringify(target));
          res.writeHead(500, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: err.message }));
        }
        console.log(`[${ts}] dispatched → ${result} | msg: ${JSON.stringify(message).slice(0, 80)}`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, result }));
      });
    });
    return;
  }

  // POST /marker — write a small sidecar file so paperflow-resume can detect
  // submitted questionnaires. Body: { kind, plan, submitted_at? }.
  // The marker file is written next to the doc HTML, named
  // "<plan-stem>-answered.json". `plan` must be a relative path (no '..',
  // no leading '/') under ~/docs/paperflow/ — anything else is rejected so
  // the browser can't write outside the docs tree.
  if (req.method === 'POST' && req.url === '/marker') {
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', () => {
      const path = require('path');
      const fs   = require('fs');
      let payload;
      try { payload = JSON.parse(body); }
      catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { kind, plan, submitted_at } = payload || {};
      if (!plan || typeof plan !== 'string') {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'need {plan}' }));
      }
      // Reject path traversal + absolute paths.
      if (plan.includes('..') || plan.startsWith('/')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'plan must be a relative path under ~/docs/paperflow/' }));
      }
      const docsRoot = path.join(process.env.HOME, 'docs', 'paperflow');
      // Resolve plan relative to questionnaires/ first; fall back to
      // grills/ for the symmetrical use case.
      const stem = plan.replace(/\.html$/, '');
      const candidates = [
        path.join(docsRoot, 'questionnaires', `${stem}-answered.json`),
        path.join(docsRoot, 'grills',         `${stem}-answered.json`)
      ];
      // Pick the first whose parent directory exists.
      const target = candidates.find(p => {
        try { return fs.statSync(path.dirname(p)).isDirectory(); }
        catch { return false; }
      });
      if (!target) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'no suitable docs/paperflow/{questionnaires,grills}/ dir' }));
      }
      const ts = new Date().toISOString();
      const marker = JSON.stringify({
        kind: kind || 'unknown',
        submitted_at: submitted_at || ts
      });
      fs.writeFile(target, marker, err => {
        if (err) {
          console.error(`[${ts}] marker write error:`, err.message);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: err.message }));
        }
        console.log(`[${ts}] marker → ${target}`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: target }));
      });
    });
    return;
  }

  res.writeHead(404); res.end();
});

server.listen(PORT, HOST, () => {
  console.log(`claude-bridge listening on http://${HOST}:${PORT}`);
});
