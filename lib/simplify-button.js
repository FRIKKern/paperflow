/* paperflow Simplify button — client glue.
 *
 * Listens for clicks on [data-action-id="simplify"] (injected by lib/doc.js
 * for plan / spec / grill kinds). On click:
 *   1. POST /paperflow/simplify {doc_path, goal_id} → {job_id}
 *   2. Poll /paperflow/simplify/status?job=<id> every 2s, cap 5min
 *   3. On done: toast + click-jump to the new event in the goal-path rail
 *   4. On failed: toast with reason
 *
 * The simplify endpoints are NOT per-instance: a simplify job runs out-of-
 * band against ~/.paperflow/events/ and is consumed by any session, so it
 * lives on the fixed aux daemon (localhost:8765) — not the per-session
 * bridge.
 *
 * Goal id resolution mirrors goal-path-rail.js:
 *   1. window.PAPERFLOW_GOAL_ID
 *   2. <meta name="paperflow-goal" content="…">
 */
(function () {
  if (window.__paperflowSimplifyLoaded) return;
  window.__paperflowSimplifyLoaded = true;

  const AUX_DAEMON = 'http://localhost:8765';
  const POLL_MS = 2000;
  const POLL_CAP_MS = 5 * 60 * 1000;

  function resolveGoalId() {
    if (window.PAPERFLOW_GOAL_ID) return String(window.PAPERFLOW_GOAL_ID);
    const meta = document.querySelector('meta[name="paperflow-goal"]');
    return (meta && meta.content && meta.content.trim()) || null;
  }

  function ensureToastHost() {
    let host = document.querySelector('.paperflow-toast-host');
    if (host) return host;
    host = document.createElement('div');
    host.className = 'paperflow-toast-host';
    Object.assign(host.style, {
      position: 'fixed', right: '1rem', bottom: '1rem', zIndex: 10002,
      display: 'flex', flexDirection: 'column', gap: '.4rem',
      maxWidth: '320px', font: '0.85rem var(--sans, system-ui, sans-serif)'
    });
    document.body.appendChild(host);
    return host;
  }

  function toast(text, kind) {
    const host = ensureToastHost();
    const el = document.createElement('div');
    el.textContent = text;
    Object.assign(el.style, {
      background: kind === 'fail' ? '#f5e6e6' : kind === 'ok' ? '#eef7ee' : '#fbfaf6',
      border: '1px solid ' + (kind === 'fail' ? '#a23925' : kind === 'ok' ? '#3b7a3b' : '#1a1a1a'),
      color: '#1a1a1a',
      padding: '.5rem .7rem', borderRadius: '6px',
      boxShadow: '0 1px 4px rgba(0,0,0,.12)',
      cursor: kind === 'ok' ? 'pointer' : 'default'
    });
    host.appendChild(el);
    setTimeout(() => { try { el.remove(); } catch (_) {} }, kind === 'fail' ? 9000 : 6000);
    return el;
  }

  async function startSimplify(docPath, goalId, btn) {
    const orig = btn ? btn.textContent : null;
    if (btn) { btn.disabled = true; btn.textContent = 'Simplifying…'; }
    const liveToast = toast('Simplifying… (subagent running)', 'info');
    let job;
    try {
      const r = await fetch(AUX_DAEMON + '/paperflow/simplify', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ doc_path: docPath, goal_id: goalId })
      });
      const j = await r.json();
      if (!j.ok || !j.job_id) {
        try { liveToast.remove(); } catch (_) {}
        toast('Simplify failed to start: ' + (j.error || 'unknown'), 'fail');
        if (btn) { btn.disabled = false; btn.textContent = orig; }
        return;
      }
      job = j.job_id;
    } catch (e) {
      try { liveToast.remove(); } catch (_) {}
      toast('Simplify failed to start: ' + e.message, 'fail');
      if (btn) { btn.disabled = false; btn.textContent = orig; }
      return;
    }

    const start = Date.now();
    const poll = async () => {
      if (Date.now() - start > POLL_CAP_MS) {
        try { liveToast.remove(); } catch (_) {}
        toast('Simplify timed out (5 min). Job ' + job + ' may still finish — check the rail.', 'fail');
        if (btn) { btn.disabled = false; btn.textContent = orig; }
        return;
      }
      let s;
      try {
        const r = await fetch(AUX_DAEMON + '/paperflow/simplify/status?job=' + encodeURIComponent(job));
        s = await r.json();
      } catch (e) {
        setTimeout(poll, POLL_MS);
        return;
      }
      if (s.state === 'running') { setTimeout(poll, POLL_MS); return; }
      try { liveToast.remove(); } catch (_) {}
      if (btn) { btn.disabled = false; btn.textContent = orig; }
      if (s.state === 'done') {
        const t = toast('Candidate ready · click to compare', 'ok');
        t.addEventListener('click', () => {
          location.hash = '#event=' + encodeURIComponent(s.event_id);
          // Force the rail to re-fetch immediately rather than wait for WS.
          window.dispatchEvent(new CustomEvent('paperflow-simplify-done', { detail: s }));
        });
        // Best-effort proactive rail refresh.
        window.dispatchEvent(new CustomEvent('paperflow-simplify-done', { detail: s }));
      } else {
        toast('Simplify rejected: ' + (s.reason || 'unknown'), 'fail');
        console.warn('[simplify]', s);
      }
    };
    setTimeout(poll, POLL_MS);
  }

  function init() {
    document.addEventListener('click', ev => {
      const btn = ev.target.closest && ev.target.closest('[data-action-id="simplify"]');
      if (!btn) return;
      ev.preventDefault();
      ev.stopPropagation();
      const docPath = window.DOC_PATH;
      const goalId = resolveGoalId();
      if (!docPath) { toast('Simplify: window.DOC_PATH not set', 'fail'); return; }
      if (!goalId)  { toast('Simplify: no active Goal in scope', 'fail'); return; }
      startSimplify(docPath, goalId, btn);
    }, true);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else { init(); }
})();
