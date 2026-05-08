#!/usr/bin/env node
// claude-bridge: tiny HTTP server that receives POST /build {target, message}
// from a plan/spec HTML "Build" button and dispatches the message into the
// originating terminal tab using whatever targeting mechanism that terminal
// supports (tmux, iTerm AppleScript, Apple Terminal AppleScript, ...).
//
// Foreground for testing:    node claude-bridge.js
// Logs:                      stdout / stderr
//
// Endpoints:
//   GET  /                       liveness ping
//   POST /build                  dispatch a message to the originating terminal
//   POST /marker                 questionnaire-answered sidecar (also fires an
//                                event:questionnaire-answered when active goal
//                                is known)
//   GET  /goal-path?goal=<id>    Goal-path event subtree (paperflow-e5v rail)
//   GET  /goal-path?source=<rel> Resolve goal_id by latest event with
//                                source:<rel> label, then return its path
//   GET  /event/<task-id>        sidecar payload for one event-task
//   POST /event                  create a kind:event Beads task + sidecar
//   POST /event/active           write <repo>/.paperflow/active-event-base
//   GET  /diff?from=<id>&to=<id> bridge-side line-level diff between two events
//   POST /navigate               swap the live-render-controlled browser tab to
//                                a different paperflow doc (rail-interactive)
//   POST /simplify               kick off a leaning-pass + verification job;
//                                returns {ok, job_id} immediately
//   GET  /simplify/status?job=   poll a Simplify job; returns {state, …}
//   POST /simplify/accept        promote a simplified-<n> event to branch:main
//                                (also overwrites the source HTML on disk)
//   POST /simplify/reject        close a simplified-<n> event with a reason

const http = require('http');
const path = require('path');
const fs   = require('fs');
const { execFile, spawn } = require('child_process');
const crypto = require('crypto');

const PORT = 8766;
const HOST = '127.0.0.1';

// Vendored line-level diff. The bridge is the diff engine; the modal is a
// dumb viewer. See lib/text-diff.js (paperflow-e5v.2.2).
const textDiff = require(path.join(__dirname, '..', 'lib', 'text-diff.js'));

// Beads invocations cd into the bridge's own checkout root so they find the
// .beads/ db deterministically. Cmux spawns the bridge with whatever cwd the
// terminal happened to have — relying on inheritance is fragile.
const BD_CWD = path.resolve(__dirname, '..');

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

// ── Goal-path helpers ────────────────────────────────────────────────
//
// Sidecar files live at ~/.paperflow/events/<event-task-id>.{html,md,json}.
// The directory is paperflow-wide (single-user) — same scope as the
// statusline cache.
const EVENTS_DIR = path.join(process.env.HOME, '.paperflow', 'events');

function ensureEventsDir() {
  try { fs.mkdirSync(EVENTS_DIR, { recursive: true }); } catch (_) { /* */ }
}

// Resolve `goal-<slug>` from a goal-task ID by asking Beads for its labels.
// `bd show <id> --json` returns an array of issues. The first label that
// starts with "goal-" wins.
function resolveGoalSlug(goalId, cb) {
  execFile('bd', ['show', goalId, '--json'], { maxBuffer: 8 * 1024 * 1024, cwd: BD_CWD },
    (err, stdout) => {
      if (err) return cb(err);
      let arr;
      try { arr = JSON.parse(stdout); }
      catch (e) { return cb(new Error('bd show: invalid JSON: ' + e.message)); }
      if (!Array.isArray(arr) || !arr.length) {
        return cb(new Error('bd show: no issue: ' + goalId));
      }
      const labels = arr[0].labels || [];
      const slugLabel = labels.find(l => typeof l === 'string' && l.startsWith('goal-'));
      if (!slugLabel) return cb(new Error('no goal-<slug> label on ' + goalId));
      cb(null, slugLabel);
    });
}

// Resolve a goal-task id from a doc-relative source path. Lists every
// kind:event whose labels include `source:<rel>`, picks the most recent
// one (lexicographic created_at sort, last entry wins), then derives
// the goal-task by stripping the trailing segment from the event-task's
// hierarchical Beads ID. Events are created with `--parent <goal_id>`
// (see createEvent), so an event id like `bd-a1b2.7` belongs to goal
// `bd-a1b2`. Returns null when no matching event exists.
function resolveGoalIdFromSource(sourceRel, cb) {
  execFile('bd',
    ['list', '--label', 'kind:event', '--label', `source:${sourceRel}`, '--json', '--no-default-args'],
    { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
    (err, stdout) => {
      const finish = (s) => {
        let arr = [];
        try { arr = JSON.parse(s || '[]'); } catch (_) { /* */ }
        if (!Array.isArray(arr) || !arr.length) return cb(null, null);
        arr.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
        const latest = arr[arr.length - 1];
        const id = String(latest.id || '');
        const parts = id.split('.');
        if (parts.length < 2) {
          // Not hierarchical — fall back to the id itself.
          return cb(null, id || null);
        }
        cb(null, parts.slice(0, parts.length - 1).join('.'));
      };
      if (err) {
        return execFile('bd',
          ['list', '--label', 'kind:event', '--label', `source:${sourceRel}`, '--json'],
          { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
          (e2, s2) => { if (e2) return cb(e2); finish(s2); });
      }
      finish(stdout);
    });
}

// Load a sidecar by event-task ID. Tries .html, then .md, then .json.
function loadSidecar(eventId, cb) {
  const exts = ['.html', '.md', '.json'];
  let i = 0;
  function tryNext() {
    if (i >= exts.length) return cb(new Error('no sidecar for ' + eventId));
    const p = path.join(EVENTS_DIR, eventId + exts[i++]);
    fs.readFile(p, 'utf8', (err, data) => {
      if (err) return tryNext();
      cb(null, { ext: exts[i - 1], path: p, content: data });
    });
  }
  tryNext();
}

// Repo-relative path-traversal guard — same shape as /marker uses for `plan`.
function safeRelPath(p) {
  return typeof p === 'string'
      && !p.includes('..')
      && !p.startsWith('/');
}

// Body collect helper.
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

// ── Simplify state (in-memory) ──────────────────────────────────────
// job_id → {state, event_id?, branch?, reason?, started_at, doc_path, goal_id}
// Bridge restart abandons in-flight jobs (acceptable for v1 — see plan).
const SIMPLIFY_JOBS = new Map();
const SIMPLIFY_FAIL_LOG = path.join(process.env.HOME, '.paperflow', 'simplify-failures.log');
const SIMPLIFY_BRIEF_LEAN   = path.join(__dirname, '..', 'lib', 'simplify-leaning-pass-brief.md');
const SIMPLIFY_BRIEF_VERIFY = path.join(__dirname, '..', 'lib', 'simplify-verification-brief.md');
const SIMPLIFY_VERIFIER     = path.join(__dirname, 'paperflow-simplify-verify');
const DOCS_ROOT             = path.join(process.env.HOME, 'docs', 'paperflow');

function logSimplifyFailure(entry) {
  try {
    fs.mkdirSync(path.dirname(SIMPLIFY_FAIL_LOG), { recursive: true });
    fs.appendFileSync(SIMPLIFY_FAIL_LOG,
      JSON.stringify(Object.assign({ ts: new Date().toISOString() }, entry)) + '\n');
  } catch (_) { /* */ }
}

// Internal: create a kind:event Beads task + (optional) sidecar. Used by
// POST /event AND by /marker so questionnaire submits leave an event trail.
function createEvent(opts, cb) {
  const { goal_id, event_type, source_doc, parent_event, branch, payload_html } = opts;
  if (!goal_id || !event_type) {
    return cb(new Error('createEvent: need {goal_id, event_type}'));
  }
  resolveGoalSlug(goal_id, (slugErr, slugLabel) => {
    if (slugErr) return cb(slugErr);
    const labels = [
      'kind:event',
      slugLabel,
      `event:${event_type}`,
      `branch:${branch || 'main'}`
    ];
    if (source_doc)   labels.push(`source:${source_doc}`);
    if (parent_event) labels.push(`parent-event:${parent_event}`);
    const title = `${event_type}${source_doc ? ' · ' + source_doc : ''}`;
    const description = `${event_type} for goal ${goal_id} at ${new Date().toISOString()}`
      + (source_doc ? `\nsource: ${source_doc}` : '')
      + (parent_event ? `\nparent-event: ${parent_event}` : '');
    const args = [
      'create',
      title,
      '-d', description,
      '--parent', goal_id,
      '-l', labels.join(','),
      '--no-inherit-labels',
      '--silent'
    ];
    execFile('bd', args, { maxBuffer: 4 * 1024 * 1024, cwd: BD_CWD }, (err, stdout) => {
      if (err) return cb(err);
      const eventId = String(stdout || '').trim();
      if (!eventId) return cb(new Error('bd create: empty id from --silent'));
      // Optional sidecar.
      if (payload_html) {
        ensureEventsDir();
        const dst = path.join(EVENTS_DIR, eventId + '.html');
        fs.writeFile(dst, payload_html, w => {
          if (w) return cb(w);
          cb(null, { event_id: eventId, sidecar: dst });
        });
      } else {
        cb(null, { event_id: eventId });
      }
    });
  });
}

// ── HTTP server ─────────────────────────────────────────────────────
const server = http.createServer((req, res) => {
  // CORS for browser access from http://localhost:8765/...
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const url = new URL(req.url, `http://${HOST}:${PORT}`);

  if (req.method === 'GET' && url.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('claude-bridge ok\n');
  }

  if (req.method === 'POST' && url.pathname === '/build') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
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

  // POST /marker — write a small sidecar file so /paperflow:resume can detect
  // submitted questionnaires. Body: { kind, plan, submitted_at?, goal_id? }.
  // The marker file is written next to the doc HTML, named
  // "<plan-stem>-answered.json". `plan` must be a relative path (no '..',
  // no leading '/') under ~/docs/paperflow/ — anything else is rejected so
  // the browser can't write outside the docs tree. When goal_id is set, an
  // event:questionnaire-answered event is also recorded.
  if (req.method === 'POST' && url.pathname === '/marker') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { kind, plan, submitted_at, goal_id } = payload || {};
      if (!plan || typeof plan !== 'string') {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'need {plan}' }));
      }
      if (plan.includes('..') || plan.startsWith('/')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'plan must be a relative path under ~/docs/paperflow/' }));
      }
      const docsRoot = path.join(process.env.HOME, 'docs', 'paperflow');
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
        // Best-effort event-trail entry. If no goal_id was supplied or Beads
        // is unhappy, the marker still succeeds — events are auxiliary.
        const sourceRel = plan.replace(/^\/+/, '');
        if (goal_id && typeof goal_id === 'string') {
          createEvent({
            goal_id,
            event_type: 'questionnaire-answered',
            source_doc: 'questionnaires/' + sourceRel
          }, eErr => {
            if (eErr) console.warn(`[${ts}] marker event skipped:`, eErr.message);
          });
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: target }));
      });
    });
    return;
  }

  // GET /goal-path?goal=<task-id>  OR  /goal-path?source=<rel-path>
  // Returns the event subtree for a Goal as JSON, sorted by created-at.
  // The ?source= form is a fallback used by lib/goal-path-rail.js when the
  // doc didn't set window.PAPERFLOW_GOAL_ID — it walks Beads for any
  // kind:event whose `source:<rel>` matches, takes the latest one's parent
  // (the goal-task) and resolves from there. Path-traversal guarded.
  if (req.method === 'GET' && url.pathname === '/goal-path') {
    const goalId = url.searchParams.get('goal');
    const source = url.searchParams.get('source');
    if (!goalId && !source) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'need ?goal=<task-id> or ?source=<rel-path>' }));
    }
    if (!goalId) {
      // Resolve the goal_id from the most recent matching source-event.
      if (!safeRelPath(source)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'source must be a relative path under ~/docs/paperflow/' }));
      }
      return resolveGoalIdFromSource(source, (rErr, resolvedGoalId) => {
        if (rErr) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: rErr.message }));
        }
        if (!resolvedGoalId) {
          // Same shape as a hit with zero events — keeps the rail hidden.
          res.writeHead(200, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ ok: true, slug_label: null, events: [] }));
        }
        resolveGoalSlug(resolvedGoalId, (slugErr, slugLabel) => {
          if (slugErr) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: slugErr.message }));
          }
          execFile('bd',
            ['list', '--label', 'kind:event', '--label', slugLabel, '--json', '--no-default-args'],
            { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
            (lErr, lOut) => {
              if (lErr) {
                return execFile('bd',
                  ['list', '--label', 'kind:event', '--label', slugLabel, '--json'],
                  { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
                  (l2Err, l2Out) => {
                    if (l2Err) {
                      res.writeHead(500, { 'Content-Type': 'application/json' });
                      return res.end(JSON.stringify({ error: l2Err.message }));
                    }
                    respondGoalPath(res, slugLabel, l2Out);
                  });
              }
              respondGoalPath(res, slugLabel, lOut);
            });
        });
      });
    }
    resolveGoalSlug(goalId, (slugErr, slugLabel) => {
      if (slugErr) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: slugErr.message }));
      }
      execFile('bd',
        ['list', '--label', 'kind:event', '--label', slugLabel, '--json', '--no-default-args'],
        { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
        (err, stdout) => {
          // --no-default-args is best-effort: bd may not know the flag on
          // older versions. Retry once without it on EUSAGE-style failure.
          if (err) {
            execFile('bd',
              ['list', '--label', 'kind:event', '--label', slugLabel, '--json'],
              { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
              (err2, stdout2) => {
                if (err2) {
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  return res.end(JSON.stringify({ error: err2.message }));
                }
                respondGoalPath(res, slugLabel, stdout2);
              });
            return;
          }
          respondGoalPath(res, slugLabel, stdout);
        });
    });
    return;
  }

  // POST /navigate — swap the live-render-controlled browser tab to a
  // different paperflow doc. Body: {path: "<rel-under-/paperflow/>"}.
  // Mirrors hooks/auto-open-doc.sh: shells out to macOS `/usr/bin/open <url>`,
  // which (a) refocuses an existing tab without duplicating it, and (b) on
  // cmux invokes the URL handler whose tab-reuse contract returns
  // "OK surface=N placement=reuse|new". Live-render handles the in-page
  // content swap separately. Path validation is a strict whitelist —
  // only relative HTML docs under /paperflow/ are permitted, so the
  // browser can't be steered at off-doc URLs.
  if (req.method === 'POST' && url.pathname === '/navigate') {
    collectBody(req, (parseErr, payload) => {
      const json = (code, body) => {
        res.writeHead(code, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(body));
      };
      if (parseErr) return json(400, { ok: false, error: 'invalid JSON' });
      const { path: relPath } = payload || {};
      if (typeof relPath !== 'string') {
        return json(400, { ok: false, error: 'path must be a string' });
      }
      if (relPath.includes('..')) {
        return json(400, { ok: false, error: 'path must not contain ".."' });
      }
      if (relPath.startsWith('/')) {
        return json(400, { ok: false, error: 'path must be relative (no leading "/")' });
      }
      if (/^https?:\/\//i.test(relPath)) {
        return json(400, { ok: false, error: 'path must not be absolute URL' });
      }
      if (!/^[a-zA-Z0-9_./-]+\.html$/.test(relPath)) {
        return json(400, { ok: false, error: 'path must match [a-zA-Z0-9_./-]+\\.html' });
      }
      const fullUrl = `http://localhost:8765/paperflow/${relPath}`;
      // /usr/bin/open hits cmux's URL handler when run inside cmux.app
      // (tab-reuse contract); on plain macOS it focuses the existing tab
      // in the default browser. Either way the live-render hot-reload
      // swaps content if the URL is already open.
      execFile('/usr/bin/open', [fullUrl], { timeout: 2000 }, (err, stdout, stderr) => {
        const ts = new Date().toISOString();
        if (err) {
          console.error(`[${ts}] navigate error:`, err.message, '| url:', fullUrl);
          return json(500, {
            ok: false,
            error: err.message,
            stderr: String(stderr || '').slice(0, 400)
          });
        }
        console.log(`[${ts}] navigate → ${fullUrl} | ${String(stdout || '').trim().slice(0, 120)}`);
        json(200, { ok: true, target: 'open', url: fullUrl });
      });
    });
    return;
  }

  // GET /event/<task-id>
  if (req.method === 'GET' && url.pathname.startsWith('/event/')) {
    const eventId = decodeURIComponent(url.pathname.slice('/event/'.length));
    if (!eventId || eventId.includes('/') || eventId.includes('..')) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'bad event id' }));
    }
    loadSidecar(eventId, (err, side) => {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: err.message }));
      }
      const ct = side.ext === '.html' ? 'text/html'
               : side.ext === '.json' ? 'application/json'
               :                        'text/markdown';
      res.writeHead(200, { 'Content-Type': ct + '; charset=utf-8' });
      res.end(side.content);
    });
    return;
  }

  // POST /event — create a new event-task + optional sidecar.
  // Body: {goal_id, event_type, source_doc?, parent_event?, branch?, payload_html?}
  if (req.method === 'POST' && url.pathname === '/event') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { goal_id, event_type } = payload || {};
      if (!goal_id || !event_type) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'need {goal_id, event_type}' }));
      }
      createEvent(payload, (err, result) => {
        const ts = new Date().toISOString();
        if (err) {
          console.error(`[${ts}] event error:`, err.message);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: err.message }));
        }
        console.log(`[${ts}] event → ${result.event_id} (${event_type})`);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, ...result }));
      });
    });
    return;
  }

  // POST /event/active — write <repo>/.paperflow/active-event-base.
  // Body: {repo_path, event_id}. Path-traversal guarded: repo_path must
  // be absolute and contain a .paperflow dir; event_id is a flat token.
  if (req.method === 'POST' && url.pathname === '/event/active') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { repo_path, event_id } = payload || {};
      if (!repo_path || typeof repo_path !== 'string'
          || !repo_path.startsWith('/')
          || repo_path.includes('..')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad repo_path' }));
      }
      if (typeof event_id !== 'string'
          || event_id.includes('/')
          || event_id.includes('..')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad event_id' }));
      }
      const dir = path.join(repo_path, '.paperflow');
      try {
        if (!fs.statSync(dir).isDirectory()) throw new Error('not a directory');
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'no .paperflow dir at ' + dir }));
      }
      const dst = path.join(dir, 'active-event-base');
      fs.writeFile(dst, event_id + '\n', err => {
        if (err) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: err.message }));
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: dst }));
      });
    });
    return;
  }

  // GET /diff?from=<id>&to=<id> — line-level diff between two sidecars.
  if (req.method === 'GET' && url.pathname === '/diff') {
    const fromId = url.searchParams.get('from');
    const toId   = url.searchParams.get('to');
    if (!fromId || !toId) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'need ?from=&to=' }));
    }
    if ([fromId, toId].some(id => id.includes('/') || id.includes('..'))) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'bad id' }));
    }
    loadSidecar(fromId, (e1, s1) => {
      if (e1) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'from: ' + e1.message }));
      }
      loadSidecar(toId, (e2, s2) => {
        if (e2) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: 'to: ' + e2.message }));
        }
        const chunks = textDiff.diff(s1.content, s2.content);
        const html = textDiff.formatDiffHtml(chunks);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, from: fromId, to: toId, diffHtml: html }));
      });
    });
    return;
  }

  // POST /simplify — body: {doc_path, goal_id}. Spawns a leaning-pass + verify
  // pipeline asynchronously, returns {ok, job_id} immediately.
  if (req.method === 'POST' && url.pathname === '/simplify') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { doc_path, goal_id } = payload || {};
      if (!doc_path || !goal_id) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'need {doc_path, goal_id}' }));
      }
      if (!safeRelPath(doc_path)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'doc_path must be relative under ~/docs/paperflow/' }));
      }
      const job_id = crypto.randomBytes(6).toString('hex');
      SIMPLIFY_JOBS.set(job_id, {
        state: 'running', started_at: new Date().toISOString(),
        doc_path, goal_id
      });
      // Fire-and-forget. The pipeline writes back to SIMPLIFY_JOBS.
      runSimplifyPipeline(job_id, doc_path, goal_id);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, job_id }));
    });
    return;
  }

  // GET /simplify/status?job=<id>
  if (req.method === 'GET' && url.pathname === '/simplify/status') {
    const job = url.searchParams.get('job');
    if (!job || !SIMPLIFY_JOBS.has(job)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'unknown job' }));
    }
    const j = SIMPLIFY_JOBS.get(job);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(j));
  }

  // POST /simplify/accept — body: {simplified_event_id}.
  // Reads the simplified payload, overwrites the source HTML on disk,
  // relabels the event branch from simplified-<n> to main.
  if (req.method === 'POST' && url.pathname === '/simplify/accept') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { simplified_event_id } = payload || {};
      if (!simplified_event_id || typeof simplified_event_id !== 'string'
          || simplified_event_id.includes('/') || simplified_event_id.includes('..')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad simplified_event_id' }));
      }
      acceptSimplified(simplified_event_id, (err, info) => {
        if (err) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: err.message }));
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, ...info }));
      });
    });
    return;
  }

  // POST /simplify/reject — body: {simplified_event_id, reason?}. Closes the
  // event-task via bd close.
  if (req.method === 'POST' && url.pathname === '/simplify/reject') {
    collectBody(req, (parseErr, payload) => {
      if (parseErr) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'invalid JSON' }));
      }
      const { simplified_event_id, reason } = payload || {};
      if (!simplified_event_id || typeof simplified_event_id !== 'string'
          || simplified_event_id.includes('/') || simplified_event_id.includes('..')) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad simplified_event_id' }));
      }
      const args = ['close', simplified_event_id];
      if (reason) args.push('--reason', String(reason).slice(0, 280));
      execFile('bd', args, { cwd: BD_CWD }, (err) => {
        if (err) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: err.message }));
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, closed: simplified_event_id }));
      });
    });
    return;
  }

  res.writeHead(404); res.end();
});

// ── Simplify pipeline ─────────────────────────────────────────────────
function setJob(jobId, patch) {
  const cur = SIMPLIFY_JOBS.get(jobId) || {};
  SIMPLIFY_JOBS.set(jobId, Object.assign(cur, patch));
}

// Read the prior leaning-pass briefs from disk once at boot. We re-read on
// every job so authors can iterate the brief without restarting the bridge.
function readBrief(p) {
  try { return fs.readFileSync(p, 'utf8'); } catch (_) { return ''; }
}

// Spawn `claude --print` with stdin = brief + payload. cb(err, stdout).
function runClaudePrint(stdinPayload, cb) {
  let claudeBin;
  try {
    claudeBin = require('child_process').execSync('command -v claude', { encoding: 'utf8' }).trim();
  } catch (_) { claudeBin = 'claude'; }
  const proc = spawn(claudeBin, ['--print', '--dangerously-skip-permissions'], {
    stdio: ['pipe', 'pipe', 'pipe']
  });
  let out = '', err = '';
  proc.stdout.on('data', d => { out += d; });
  proc.stderr.on('data', d => { err += d; });
  proc.on('error', e => cb(e));
  proc.on('close', code => {
    if (code !== 0) return cb(new Error(`claude --print exited ${code}: ${err.slice(0, 400)}`));
    cb(null, out);
  });
  proc.stdin.write(stdinPayload);
  proc.stdin.end();
}

// Pick the next simplified-N branch number. Scans existing events for this
// goal+source_doc and looks for branch:simplified-* labels.
function nextSimplifiedBranch(goal_id, source_doc, cb) {
  resolveGoalSlug(goal_id, (slugErr, slugLabel) => {
    if (slugErr) return cb(slugErr);
    execFile('bd',
      ['list', '--label', 'kind:event', '--label', slugLabel, '--label', `source:${source_doc}`, '--json', '--no-default-args'],
      { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
      (err, stdout) => {
        const tryFallback = err
          ? cb2 => execFile('bd',
              ['list', '--label', 'kind:event', '--label', slugLabel, '--label', `source:${source_doc}`, '--json'],
              { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD }, cb2)
          : cb2 => cb2(null, stdout);
        tryFallback((e2, s2) => {
          if (e2) return cb(e2);
          let arr = [];
          try { arr = JSON.parse(s2 || '[]'); } catch (_) { /* */ }
          let max = 0;
          for (const it of (Array.isArray(arr) ? arr : [])) {
            for (const l of (it.labels || [])) {
              const m = /^branch:simplified-(\d+)$/.exec(l);
              if (m) max = Math.max(max, parseInt(m[1], 10));
            }
          }
          cb(null, max + 1, slugLabel);
        });
      });
  });
}

// Find the most recent event-task on the source doc's goal-path lineage.
// Returns the event-task ID (or null when none — fall back to the goal-task).
function findLatestSourceEvent(goal_id, source_doc, cb) {
  resolveGoalSlug(goal_id, (slugErr, slugLabel) => {
    if (slugErr) return cb(slugErr);
    execFile('bd',
      ['list', '--label', 'kind:event', '--label', slugLabel, '--label', `source:${source_doc}`, '--json', '--no-default-args'],
      { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
      (err, stdout) => {
        const finish = (s) => {
          let arr = [];
          try { arr = JSON.parse(s || '[]'); } catch (_) { /* */ }
          if (!Array.isArray(arr) || !arr.length) return cb(null, null);
          arr.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
          cb(null, arr[arr.length - 1].id);
        };
        if (err) {
          execFile('bd',
            ['list', '--label', 'kind:event', '--label', slugLabel, '--label', `source:${source_doc}`, '--json'],
            { maxBuffer: 16 * 1024 * 1024, cwd: BD_CWD },
            (e2, s2) => { if (e2) return cb(e2); finish(s2); });
          return;
        }
        finish(stdout);
      });
  });
}

function runSimplifyPipeline(jobId, doc_path, goal_id) {
  const ts = () => new Date().toISOString();
  const docAbs = path.join(DOCS_ROOT, doc_path);
  let originalHtml;
  try { originalHtml = fs.readFileSync(docAbs, 'utf8'); }
  catch (e) {
    setJob(jobId, { state: 'failed', reason: `cannot read source doc: ${e.message}` });
    logSimplifyFailure({ job: jobId, doc_path, reason: 'read', error: e.message });
    return;
  }

  // 1. Run the leaning-pass subagent.
  const leanBrief = readBrief(SIMPLIFY_BRIEF_LEAN);
  if (!leanBrief) {
    setJob(jobId, { state: 'failed', reason: 'leaning-pass brief missing' });
    return;
  }
  console.log(`[${ts()}] simplify ${jobId} → leaning-pass starting (${doc_path})`);
  runClaudePrint(leanBrief + originalHtml, (err, candidate) => {
    if (err) {
      setJob(jobId, { state: 'failed', reason: `leaning-pass: ${err.message}` });
      logSimplifyFailure({ job: jobId, doc_path, reason: 'leaning-pass', error: err.message });
      return;
    }
    candidate = String(candidate || '').trim();
    if (!candidate || candidate.length < 100) {
      setJob(jobId, { state: 'failed', reason: 'leaning-pass returned empty/tiny output' });
      logSimplifyFailure({ job: jobId, doc_path, reason: 'lean-empty', size: candidate.length });
      return;
    }

    // 2. Structural verifier — write to a tmp file pair, exec the verifier.
    const tmpDir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'pf-simplify-'));
    const origTmp = path.join(tmpDir, 'orig.html');
    const candTmp = path.join(tmpDir, 'cand.html');
    fs.writeFileSync(origTmp, originalHtml);
    fs.writeFileSync(candTmp, candidate);
    execFile(SIMPLIFY_VERIFIER, [origTmp, candTmp], { maxBuffer: 4 * 1024 * 1024 }, (vErr, vOut) => {
      if (vErr) {
        setJob(jobId, { state: 'failed', reason: `verifier: ${vErr.message}` });
        logSimplifyFailure({ job: jobId, doc_path, reason: 'verifier-exec', error: vErr.message });
        return;
      }
      let v;
      try { v = JSON.parse(vOut); }
      catch (e) {
        setJob(jobId, { state: 'failed', reason: 'verifier: invalid JSON' });
        logSimplifyFailure({ job: jobId, doc_path, reason: 'verifier-json', error: e.message });
        return;
      }
      if (!v.ok) {
        const failNames = (v.checks || []).filter(c => !c.passed).map(c => c.name).join(',');
        setJob(jobId, { state: 'failed', reason: `structural-fail: ${failNames}` });
        logSimplifyFailure({ job: jobId, doc_path, reason: 'structural', checks: v.checks });
        return;
      }

      // 3. Verification subagent.
      const verBrief = readBrief(SIMPLIFY_BRIEF_VERIFY);
      const verPayload = verBrief
        + '\nORIGINAL:\n' + originalHtml
        + '\n---\nCANDIDATE:\n' + candidate
        + '\n---\n';
      console.log(`[${ts()}] simplify ${jobId} → verification subagent`);
      runClaudePrint(verPayload, (e2, vsOut) => {
        if (e2) {
          setJob(jobId, { state: 'failed', reason: `verification-subagent: ${e2.message}` });
          logSimplifyFailure({ job: jobId, doc_path, reason: 'verification-subagent', error: e2.message });
          return;
        }
        const verdict = String(vsOut || '').trim().split('\n').find(Boolean) || '';
        if (!/^PASS\b/i.test(verdict)) {
          setJob(jobId, { state: 'failed', reason: `verification-fail: ${verdict.slice(0, 200)}` });
          logSimplifyFailure({ job: jobId, doc_path, reason: 'verification', verdict });
          return;
        }

        // 4. Branch counter + parent-event resolution.
        nextSimplifiedBranch(goal_id, doc_path, (bErr, n /*, slugLabel */) => {
          if (bErr) {
            setJob(jobId, { state: 'failed', reason: `branch-counter: ${bErr.message}` });
            logSimplifyFailure({ job: jobId, doc_path, reason: 'branch-counter', error: bErr.message });
            return;
          }
          findLatestSourceEvent(goal_id, doc_path, (lErr, parentEventId) => {
            // Non-fatal — when no prior event exists, omit parent-event.
            const branch = `simplified-${n}`;
            createEvent({
              goal_id,
              event_type: 'plan-simplified',
              source_doc: doc_path,
              parent_event: parentEventId || undefined,
              branch,
              payload_html: candidate
            }, (cErr, result) => {
              if (cErr) {
                setJob(jobId, { state: 'failed', reason: `event-create: ${cErr.message}` });
                logSimplifyFailure({ job: jobId, doc_path, reason: 'event-create', error: cErr.message });
                return;
              }
              setJob(jobId, {
                state: 'done', event_id: result.event_id, branch,
                verdict: verdict.slice(0, 200)
              });
              console.log(`[${ts()}] simplify ${jobId} → done (${result.event_id} ${branch})`);
            });
          });
        });
      });
    });
  });
}

// Accept a simplified-<n> event: read its sidecar, write to source doc,
// relabel the Beads task's branch from simplified-<n> to main.
function acceptSimplified(eventId, cb) {
  loadSidecar(eventId, (sErr, side) => {
    if (sErr) return cb(sErr);
    if (side.ext !== '.html') return cb(new Error('sidecar is not HTML: ' + side.ext));
    execFile('bd', ['show', eventId, '--json'], { maxBuffer: 4 * 1024 * 1024, cwd: BD_CWD },
      (eErr, eOut) => {
        if (eErr) return cb(eErr);
        let arr;
        try { arr = JSON.parse(eOut); } catch (e) { return cb(e); }
        if (!Array.isArray(arr) || !arr.length) return cb(new Error('no event-task ' + eventId));
        const labels = arr[0].labels || [];
        const sourceLabel = labels.find(l => typeof l === 'string' && l.startsWith('source:'));
        if (!sourceLabel) return cb(new Error('event has no source: label'));
        const sourceRel = sourceLabel.slice('source:'.length);
        if (!safeRelPath(sourceRel)) return cb(new Error('unsafe source rel-path'));
        const dst = path.join(DOCS_ROOT, sourceRel);
        fs.writeFile(dst, side.content, wErr => {
          if (wErr) return cb(wErr);
          // Relabel branch:simplified-<n> → branch:main.
          const branchLabel = labels.find(l => typeof l === 'string' && /^branch:simplified-/.test(l));
          if (!branchLabel) return cb(null, { source_doc: sourceRel, written: dst, relabeled: false });
          execFile('bd',
            ['update', eventId, '--remove-label', branchLabel, '--add-label', 'branch:main'],
            { cwd: BD_CWD },
            (uErr) => {
              // Older Beads may not support --remove-label / --add-label;
              // fall through quietly — the source HTML write is the load-bearing
              // piece, the relabel is a nicety.
              if (uErr) {
                return cb(null, { source_doc: sourceRel, written: dst, relabeled: false, relabel_error: uErr.message });
              }
              cb(null, { source_doc: sourceRel, written: dst, relabeled: true });
            });
        });
      });
  });
}

// Format the goal-path response: parse `bd list --json`, normalise events
// into a chronological array with branch + parent-event fields hoisted out
// of the labels for client convenience.
function respondGoalPath(res, slugLabel, stdout) {
  let arr;
  try { arr = JSON.parse(stdout || '[]'); }
  catch (e) {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'bd list: invalid JSON: ' + e.message }));
  }
  const events = (Array.isArray(arr) ? arr : [])
    .filter(it => Array.isArray(it.labels) && it.labels.includes('kind:event'))
    .map(it => {
      const ls = it.labels || [];
      const findPrefix = pre => {
        const l = ls.find(x => typeof x === 'string' && x.startsWith(pre));
        return l ? l.slice(pre.length) : null;
      };
      return {
        id: it.id,
        title: it.title,
        created_at: it.created_at,
        event_type: findPrefix('event:'),
        branch: findPrefix('branch:') || 'main',
        parent_event: findPrefix('parent-event:'),
        source_doc: findPrefix('source:'),
        labels: ls
      };
    })
    .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true, slug_label: slugLabel, events }));
}

server.listen(PORT, HOST, () => {
  console.log(`claude-bridge listening on http://${HOST}:${PORT}`);
});
