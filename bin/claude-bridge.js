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
//   GET  /event/<task-id>        sidecar payload for one event-task
//   POST /event                  create a kind:event Beads task + sidecar
//   POST /event/active           write <repo>/.paperflow/active-event-base
//   GET  /diff?from=<id>&to=<id> bridge-side line-level diff between two events

const http = require('http');
const path = require('path');
const fs   = require('fs');
const { execFile } = require('child_process');

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

  // POST /marker — write a small sidecar file so paperflow-resume can detect
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

  // GET /goal-path?goal=<task-id>
  // Returns the event subtree for a Goal as JSON, sorted by created-at.
  if (req.method === 'GET' && url.pathname === '/goal-path') {
    const goalId = url.searchParams.get('goal');
    if (!goalId) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'need ?goal=<task-id>' }));
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

  res.writeHead(404); res.end();
});

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
