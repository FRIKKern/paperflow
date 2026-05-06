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
 *   3. (fallback) skip — no rail, no fetch
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
    try {
      const r = await fetch(`${BRIDGE}/goal-path?goal=${encodeURIComponent(goalId)}`);
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
    if (!goalId) return;            // no Goal in scope, no rail
    ensureRail();
    await refresh();
    subscribeLiveReload();

    window.addEventListener('hashchange', () => {
      // Reset the once-only guard so the new hash applies.
      window.__paperflowRailHashApplied = null;
      applyHashIfPresent();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
