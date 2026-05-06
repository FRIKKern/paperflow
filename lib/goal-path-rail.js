/* paperflow goal-path rail — sticky 240px right-rail rendering a Mermaid
 * gitGraph of every event in the active Goal's lifecycle. Click-to-jump
 * morphs the article column to the event's sidecar payload. Live-server's
 * existing WebSocket drives refresh — no new infrastructure.
 *
 * Wiring (see lib/doc.js): doc.js loads this script unconditionally on every
 * paperflow doc. Set window.PAPERFLOW_NO_RAIL = true on a page to opt out.
 *
 * Goal id resolution order:
 *   1. window.PAPERFLOW_GOAL_ID
 *   2. <meta name="paperflow-goal" content="<id>">
 *   3. (server-side fallback) GET /goal-path?source=<window.DOC_PATH>
 *      — the bridge looks up the latest kind:event with this source label
 *      and derives the goal from that event's parent. Lets the rail render
 *      on docs that didn't (yet) emit PAPERFLOW_GOAL_ID inline.
 *   4. (no events anywhere) skip — no rail, no fetch
 *
 * Sources of truth: Beads (event tasks) + ~/.paperflow/events/ (sidecars).
 * The bridge's GET /goal-path?goal=<id> wraps the bd query; GET /event/<id>
 * serves a sidecar; POST /event/active writes the walk-back pointer.
 */
(function () {
  if (window.__paperflowRailLoaded) return;
  window.__paperflowRailLoaded = true;
  if (window.PAPERFLOW_NO_RAIL) return;

  const BRIDGE = 'http://localhost:8766';

  function resolveGoalId() {
    if (window.PAPERFLOW_GOAL_ID) return String(window.PAPERFLOW_GOAL_ID);
    const meta = document.querySelector('meta[name="paperflow-goal"]');
    if (meta && meta.content) return meta.content.trim();
    return null;
  }

  // ── module state ────────────────────────────────────────────────────
  let goalId = null;
  let railEl = null;
  let graphHostEl = null;
  let lastEvents = [];
  // Used by lib/diff-modal.js to track shift-click selection.
  window.__paperflowRailSelected = window.__paperflowRailSelected || null;

  // ── network ─────────────────────────────────────────────────────────
  async function fetchPath() {
    // Two query shapes: by goal id (preferred when known) or by source
    // doc path (fallback for docs that didn't emit PAPERFLOW_GOAL_ID).
    const qs = goalId
      ? `goal=${encodeURIComponent(goalId)}`
      : `source=${encodeURIComponent(window.DOC_PATH || '')}`;
    try {
      const r = await fetch(`${BRIDGE}/goal-path?${qs}`);
      if (!r.ok) return [];
      const j = await r.json();
      return Array.isArray(j.events) ? j.events : [];
    } catch (_) { return []; }
  }

  async function postActiveBase(eventId) {
    // We don't know the repo path from the browser; the bridge needs an
    // absolute path. We pass the docs root by convention — the rail's
    // walk-back pointer for the active Goal lives next to the bridge's
    // best-guess repo. The hook also reads <repo>/.paperflow/active-event-
    // base, so /event/active just needs *some* matching .paperflow dir.
    // For the in-doc rail use case the docs tree's own .paperflow works.
    const repo = window.PAPERFLOW_REPO_PATH || `${location.origin.replace(/^https?:/, 'file:')}`;
    try {
      await fetch(`${BRIDGE}/event/active`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ repo_path: repo, event_id: eventId })
      });
    } catch (_) { /* non-fatal */ }
  }

  async function fetchEventBody(eventId) {
    try {
      const r = await fetch(`${BRIDGE}/event/${encodeURIComponent(eventId)}`);
      if (!r.ok) return null;
      return await r.text();
    } catch (_) { return null; }
  }

  // ── DOM ─────────────────────────────────────────────────────────────
  function ensureRail() {
    if (railEl) return railEl;
    railEl = document.createElement('aside');
    railEl.className = 'paperflow-goal-path-rail';
    railEl.setAttribute('aria-label', 'Goal path');

    const head = document.createElement('div');
    head.className = 'paperflow-rail-head';

    const title = document.createElement('div');
    title.className = 'paperflow-rail-title';
    title.textContent = 'Goal path';
    head.appendChild(title);

    const collapse = document.createElement('button');
    collapse.type = 'button';
    collapse.className = 'paperflow-rail-collapse-btn';
    collapse.setAttribute('aria-label', 'Toggle rail');
    collapse.textContent = '›';
    collapse.addEventListener('click', () => {
      const collapsed = railEl.classList.toggle('is-collapsed');
      try { localStorage.setItem('paperflow-rail-collapsed', collapsed ? '1' : '0'); }
      catch (_) { /* storage may be blocked */ }
    });
    head.appendChild(collapse);

    railEl.appendChild(head);

    graphHostEl = document.createElement('div');
    graphHostEl.className = 'paperflow-rail-graph';
    railEl.appendChild(graphHostEl);

    const hint = document.createElement('div');
    hint.className = 'paperflow-rail-hint';
    hint.innerHTML = 'click: jump · <kbd>shift</kbd>+click two: diff';
    railEl.appendChild(hint);

    document.body.appendChild(railEl);

    // Restore collapse state.
    try {
      if (localStorage.getItem('paperflow-rail-collapsed') === '1') {
        railEl.classList.add('is-collapsed');
      }
    } catch (_) { /* ignore */ }

    return railEl;
  }

  function escAttr(s) {
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }

  function buildGitGraph(events) {
    // Group by branch, in order of first appearance. Mermaid gitGraph wants
    // a `branch <name>` declaration before commits land on it (after the
    // initial `main` is implicit). We emit explicit `branch` + `checkout`
    // around any commit on a non-main branch.
    const lines = ['gitGraph'];
    let currentBranch = 'main';
    const branchesSeen = new Set(['main']);
    for (const ev of events) {
      const br = ev.branch || 'main';
      if (!branchesSeen.has(br)) {
        lines.push(`   branch ${br}`);
        branchesSeen.add(br);
      }
      if (br !== currentBranch) {
        lines.push(`   checkout ${br}`);
        currentBranch = br;
      }
      // commit id: must be unique per graph; use the event-task ID (which
      // may contain '.' — Mermaid accepts that fine in quoted ids).
      const tag = ev.event_type || 'event';
      lines.push(`   commit id: "${escAttr(ev.id)}" tag: "${escAttr(tag)}"`);
    }
    return lines.join('\n');
  }

  async function renderGraph(events) {
    if (!graphHostEl) return;
    if (!events.length) {
      // Hide the rail entirely on zero events.
      if (railEl) railEl.style.display = 'none';
      return;
    }
    if (railEl) railEl.style.display = '';

    const src = buildGitGraph(events);
    graphHostEl.innerHTML = '';
    const pre = document.createElement('pre');
    pre.className = 'mermaid';
    pre.textContent = src;
    graphHostEl.appendChild(pre);

    if (!window.mermaid) {
      // Mermaid not loaded — render a plain list fallback.
      graphHostEl.innerHTML = '<ol class="paperflow-rail-fallback">' +
        events.map(e => `<li data-event-id="${escAttr(e.id)}">${escAttr(e.event_type || 'event')} <small>${escAttr(e.id)}</small></li>`).join('') +
        '</ol>';
      wireFallbackClicks();
      return;
    }

    try {
      // Mermaid 10+ provides .run({nodes}); fall back to init for older.
      if (typeof window.mermaid.run === 'function') {
        await window.mermaid.run({ nodes: [pre] });
      } else if (typeof window.mermaid.init === 'function') {
        window.mermaid.init(undefined, pre);
      }
    } catch (_) { /* swallow — graphHostEl will just show the source */ }

    wireSvgClicks(pre);
  }

  function wireFallbackClicks() {
    graphHostEl.querySelectorAll('[data-event-id]').forEach(li => {
      li.addEventListener('click', ev => handleNodeClick(ev, li.getAttribute('data-event-id')));
    });
  }

  function wireSvgClicks(pre) {
    // Mermaid's gitGraph SVG renders each commit as a <g class="commit-…">
    // with a child <circle> + <text>. The `id` attribute on the group is
    // derived from the commit id we passed. Walk all such groups and bind.
    const svg = pre.querySelector('svg');
    if (!svg) return;
    const nodes = svg.querySelectorAll('g[class*="commit"]');
    nodes.forEach(node => {
      // Find the matching event by reading the text label inside the group.
      // Mermaid renders the commit id as a <text> child for gitGraph — find
      // the first text node and match against our event ids.
      const texts = Array.from(node.querySelectorAll('text')).map(t => t.textContent || '');
      const evId = lastEvents.find(e => texts.some(t => t.includes(e.id)));
      const id = evId && evId.id;
      if (!id) return;
      node.setAttribute('data-event-id', id);
      node.style.cursor = 'pointer';
      node.addEventListener('click', ev => handleNodeClick(ev, id));
    });
  }

  async function handleNodeClick(ev, eventId) {
    if (!eventId) return;
    if (ev.shiftKey) {
      // Two-step diff selection — handed off to lib/diff-modal.js.
      const sel = window.__paperflowRailSelected;
      if (!sel) {
        window.__paperflowRailSelected = eventId;
        // Visual hint: outline the selected node.
        try {
          const node = ev.currentTarget;
          if (node && node.classList) node.classList.add('paperflow-rail-selected');
        } catch (_) { /* */ }
        return;
      }
      window.__paperflowRailSelected = null;
      if (typeof window.openPaperflowDiff === 'function') {
        window.openPaperflowDiff(sel, eventId);
      }
      return;
    }

    // Plain click: walk-back jump.
    await postActiveBase(eventId);
    const html = await fetchEventBody(eventId);
    if (html) swapArticle(html);
    // Update URL hash. pushState so back/forward navigates.
    try {
      const newHash = `#event=${encodeURIComponent(eventId)}`;
      if (location.hash !== newHash) {
        history.pushState({ paperflowEvent: eventId }, '', newHash);
      }
    } catch (_) { /* ignore */ }

    // Simplified branch? Surface Accept / Reject controls in the rail.
    const meta = lastEvents.find(e => e.id === eventId);
    if (meta && meta.branch && /^simplified-/.test(meta.branch)) {
      showSimplifyToolbar(eventId);
    } else {
      hideSimplifyToolbar();
    }
  }

  function swapArticle(html) {
    // The sidecar payload is the *full* doc HTML. Parse it and replace the
    // current <article> if both have one; otherwise replace <body>'s first
    // long-form block. Live-render's morph would also work but we don't
    // assume it's loaded.
    let newDoc;
    try { newDoc = new DOMParser().parseFromString(html, 'text/html'); }
    catch (_) { return; }

    const newArticle = newDoc.querySelector('article');
    const curArticle = document.querySelector('article');
    if (newArticle && curArticle) {
      curArticle.replaceWith(newArticle.cloneNode(true));
      return;
    }
    // Fallback: replace everything between the <h1> and the first sticky
    // rail/footer element. Cheap heuristic — keep the rail.
    const newBody = newDoc.body;
    if (!newBody) return;
    // Move every direct child of <body> into the existing body, except
    // the rail itself and any modal overlays.
    const keep = Array.from(document.body.children).filter(el =>
      el.classList.contains('paperflow-goal-path-rail') ||
      el.classList.contains('paperflow-diff-modal') ||
      el.classList.contains('mz-modal') ||
      el.classList.contains('doc-action'));
    document.body.innerHTML = '';
    Array.from(newBody.children).forEach(c => document.body.appendChild(c));
    keep.forEach(el => document.body.appendChild(el));
  }

  // ── Simplify Accept / Reject UI ─────────────────────────────────────
  // When a simplified-<n> event is selected (via plain click → walk-back
  // jump), render a small toolbar with Accept / Reject. Lives next to the
  // rail collapse button so it doesn't clobber the article.
  function ensureSimplifyToolbar() {
    let bar = document.querySelector('.paperflow-rail-simplify-actions');
    if (bar) return bar;
    bar = document.createElement('div');
    bar.className = 'paperflow-rail-simplify-actions';
    Object.assign(bar.style, {
      display: 'none',
      marginTop: '0.5rem', paddingTop: '0.4rem',
      borderTop: '1px solid var(--rule, #e6e2d8)',
      fontSize: '0.75rem'
    });
    const title = document.createElement('div');
    title.textContent = 'Simplified candidate';
    Object.assign(title.style, { fontWeight: '600', marginBottom: '0.3rem',
      color: 'var(--accent, #a23925)' });
    bar.appendChild(title);
    const row = document.createElement('div');
    Object.assign(row.style, { display: 'flex', gap: '0.4rem' });
    const accept = document.createElement('button');
    accept.type = 'button';
    accept.textContent = 'Accept';
    accept.dataset.simplifyAction = 'accept';
    const reject = document.createElement('button');
    reject.type = 'button';
    reject.textContent = 'Reject';
    reject.dataset.simplifyAction = 'reject';
    [accept, reject].forEach(b => {
      Object.assign(b.style, {
        flex: '1', padding: '0.25rem 0.4rem', cursor: 'pointer',
        border: '1px solid var(--rule, #e6e2d8)',
        background: 'var(--paper, #fff)', borderRadius: '4px',
        fontSize: '0.75rem'
      });
    });
    row.appendChild(accept);
    row.appendChild(reject);
    bar.appendChild(row);
    railEl.appendChild(bar);

    accept.addEventListener('click', () => simplifyAction('accept'));
    reject.addEventListener('click', () => simplifyAction('reject'));
    return bar;
  }

  let activeSimplifiedId = null;
  function showSimplifyToolbar(eventId) {
    activeSimplifiedId = eventId;
    const bar = ensureSimplifyToolbar();
    bar.style.display = '';
  }
  function hideSimplifyToolbar() {
    activeSimplifiedId = null;
    const bar = document.querySelector('.paperflow-rail-simplify-actions');
    if (bar) bar.style.display = 'none';
  }

  async function simplifyAction(kind) {
    if (!activeSimplifiedId) return;
    const eventId = activeSimplifiedId;
    let body = { simplified_event_id: eventId };
    if (kind === 'reject') {
      const reason = window.prompt('Reject reason (optional):', '') || '';
      body.reason = reason;
    }
    try {
      const r = await fetch(`${BRIDGE}/simplify/${kind}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      });
      const j = await r.json();
      if (!j.ok) {
        alert('Simplify ' + kind + ' failed: ' + (j.error || 'unknown'));
        return;
      }
      hideSimplifyToolbar();
      await refresh();
    } catch (e) {
      alert('Simplify ' + kind + ' failed: ' + e.message);
    }
  }

  // ── live-server WebSocket: refresh on saves ─────────────────────────
  function subscribeLiveReload() {
    // live-server injects /livereload.js which opens a WS to ws://host:port/.
    // We don't need to coordinate with that script — open our own WS to the
    // documented endpoint. live-server broadcasts JSON like
    //   {command:"reload", path:"/specs/foo.html"}
    // on every save. We simply re-fetch the goal path on any such message.
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${location.host}/`;
    let ws;
    try { ws = new WebSocket(url); }
    catch (_) { return; }
    ws.addEventListener('message', () => { refresh(); });
    ws.addEventListener('close', () => {
      // Reconnect after a short delay — the live-server may still be up.
      setTimeout(subscribeLiveReload, 2000);
    });
  }

  async function refresh() {
    const events = await fetchPath();
    lastEvents = events;
    await renderGraph(events);
    // After a re-render, re-apply hash-based jump if any.
    applyHashIfPresent();
  }

  function applyHashIfPresent() {
    const m = /#event=([^&]+)/.exec(location.hash || '');
    if (!m) return;
    const id = decodeURIComponent(m[1]);
    if (!lastEvents.some(e => e.id === id)) return;
    // Only auto-jump on initial load; subsequent hashchanges are user nav.
    if (window.__paperflowRailHashApplied === id) return;
    window.__paperflowRailHashApplied = id;
    fetchEventBody(id).then(html => { if (html) swapArticle(html); });
  }

  // ── init ────────────────────────────────────────────────────────────
  async function init() {
    goalId = resolveGoalId();
    // No GOAL_ID inline — only proceed if we have a DOC_PATH for the
    // server-side ?source= fallback. Otherwise nothing the rail can do.
    if (!goalId && !window.DOC_PATH) return;
    ensureRail();
    await refresh();
    subscribeLiveReload();

    window.addEventListener('hashchange', () => {
      // Reset the once-only guard so the new hash applies.
      window.__paperflowRailHashApplied = null;
      applyHashIfPresent();
    });

    // Simplify-button.js fires this when a candidate just landed; refresh
    // proactively rather than wait for the next live-server WS tick.
    window.addEventListener('paperflow-simplify-done', () => { refresh(); });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
