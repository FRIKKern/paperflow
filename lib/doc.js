/* Shared action bar for spec / plan HTML docs.
 *
 * Each spec/plan HTML must set, before this script loads:
 *   window.CLAUDE_TARGET = { term_program, tty, ... }   // from ~/.local/bin/paperflow-target
 *   window.DOC_PATH      = "/absolute/path/to/this/file.html"
 *
 * Doc type is inferred from URL path (/specs/ → spec, /plans/ → plan).
 * The right button set is injected at the bottom of <body> automatically.
 *
 * Buttons POST to localhost:8766/build with a natural-language instruction
 * for Claude in your originating terminal. Claude picks up the right skill.
 */
(function () {
  const BRIDGE = "http://localhost:8766/build";
  const STYLE_HREF = "/paperflow/_lib/doc.css";
  const AUX_DAEMON = "http://localhost:8765";

  // ---------------------------------------------------------------------------
  // Per-instance bridge: connection pill + orphan recovery banner.
  //
  // Three trigger checkpoints (no persistent polling):
  //   1. On DOMContentLoaded — initial status fetch
  //   2. On visibilitychange to visible — re-fetch
  //   3. Pre-flight before each POST to /build (or /marker) — abort if not live
  //
  // The pill is the visible-state hook for G4 of the bridge-binding contract.
  // State drives both the colored dot (via [data-state]) and an inline
  // recovery banner with Rebind / Spawn-fresh-agent buttons.
  // ---------------------------------------------------------------------------

  // Module-scoped binding state — last status response + the action-bar nodes
  // the pill + banner live in. Populated when the bar is constructed.
  const bindingState = {
    state: "unknown",        // live | stale-binding | session-gone | unknown
    last: null,              // last raw status response
    pill: null,              // <span class="paperflow-pill">
    banner: null,            // <div class="paperflow-banner">
    bar: null,               // outer .doc-action bar
    discoverSession: null    // {bridge_url, session_name, ...} if found in workspace
  };

  async function fetchBindingStatus() {
    const target = window.CLAUDE_TARGET || {};
    if (!target.bridge_url || !target.doc_nonce) {
      // Backwards-compat: legacy docs (pre per-instance-bridge migration)
      // don't carry a bridge_url. Surface as session-gone with a legacy
      // explanation so the recovery banner kicks in.
      return { state: "session-gone", reason: "legacy-binding" };
    }
    try {
      const r = await fetch(`${target.bridge_url}/docs/${target.doc_nonce}/status`, {
        method: "GET",
        signal: AbortSignal.timeout(500)
      });
      if (!r.ok && r.status === 410) {
        const body = await r.json().catch(() => ({}));
        return { state: body.code || "stale-binding", ...body };
      }
      return await r.json();
    } catch (e) {
      return { state: "session-gone", reason: (e && e.message) || "fetch-failed" };
    }
  }

  async function discoverLiveSession() {
    const target = window.CLAUDE_TARGET || {};
    const ws = target.cmux_workspace;
    if (!ws) return null;
    try {
      const r = await fetch(`${AUX_DAEMON}/paperflow/discover?workspace=${encodeURIComponent(ws)}`, {
        method: "GET",
        signal: AbortSignal.timeout(500)
      });
      if (!r.ok) return null;
      const body = await r.json().catch(() => ({}));
      const list = Array.isArray(body) ? body : (body.sessions || []);
      // Prefer a session that isn't ourselves (different session_id).
      const live = list.find(s => s && s.bridge_url && s.session_id !== target.session_id);
      return live || (list.length ? list[0] : null);
    } catch (e) {
      return null;
    }
  }

  function setActionButtonsDisabled(bar, disabled) {
    if (!bar) return;
    bar.querySelectorAll("button.doc-btn").forEach(b => {
      // Don't fight banner-owned buttons.
      if (b.closest(".paperflow-banner")) return;
      b.disabled = disabled;
    });
  }

  function clearBanner() {
    if (bindingState.banner && bindingState.banner.parentNode) {
      bindingState.banner.parentNode.removeChild(bindingState.banner);
    }
    bindingState.banner = null;
  }

  function ageLabel(ms) {
    if (typeof ms !== "number" || !isFinite(ms) || ms < 0) return null;
    const s = Math.floor(ms / 1000);
    if (s < 60) return `${s}s ago`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
  }

  function buildBanner(status) {
    const banner = document.createElement("div");
    banner.className = "paperflow-banner";
    banner.dataset.state = status.state;

    const text = document.createElement("div");
    text.className = "paperflow-banner-text";

    if (status.state === "stale-binding") {
      text.textContent = "Doc binding lost — daemon doesn't know this doc.";
    } else if (status.state === "session-gone") {
      const age = ageLabel(status.age_ms);
      if (status.reason === "legacy-binding") {
        text.textContent = "This doc was written before the per-instance bridge migration. Click 'Spawn fresh agent' to rebind.";
      } else {
        text.textContent = age
          ? `Session ended (last active ${age}).`
          : "Session ended.";
      }
    } else {
      text.textContent = "Connection state unknown.";
    }
    banner.appendChild(text);

    const btnRow = document.createElement("div");
    btnRow.className = "paperflow-banner-buttons";

    // Rebind to a discovered live session in the same workspace.
    if (bindingState.discoverSession && bindingState.discoverSession.bridge_url) {
      const live = bindingState.discoverSession;
      const rebind = document.createElement("button");
      rebind.className = "doc-btn doc-btn-secondary paperflow-banner-btn";
      rebind.dataset.action = "rebind";
      const name = live.session_name || live.session_id || "live session";
      rebind.textContent = `Rebind to ${name}`;
      rebind.addEventListener("click", () => rebindToSession(live, rebind));
      btnRow.appendChild(rebind);
    }

    // Spawn-fresh-agent button (always offered when not live).
    const spawn = document.createElement("button");
    spawn.className = "doc-btn doc-btn-primary paperflow-banner-btn";
    spawn.dataset.action = "spawn";
    spawn.textContent = "Spawn fresh agent";
    spawn.addEventListener("click", () => spawnFreshAgent(spawn));
    btnRow.appendChild(spawn);

    banner.appendChild(btnRow);
    return banner;
  }

  function toast(message, ms) {
    const t = document.createElement("div");
    t.className = "paperflow-toast";
    t.textContent = message;
    document.body.appendChild(t);
    setTimeout(() => {
      if (t.parentNode) t.parentNode.removeChild(t);
    }, ms || 2500);
  }

  function randomNonce() {
    // 96 bits of entropy as hex — good enough for a doc nonce.
    const arr = new Uint8Array(12);
    (window.crypto || {}).getRandomValues
      ? window.crypto.getRandomValues(arr)
      : arr.forEach((_, i) => (arr[i] = Math.floor(Math.random() * 256)));
    return Array.from(arr).map(b => b.toString(16).padStart(2, "0")).join("");
  }

  async function rebindToSession(live, btn) {
    const original = btn.textContent;
    btn.disabled = true;
    btn.textContent = "Rebinding…";
    try {
      const newNonce = randomNonce();
      const docPath = window.DOC_PATH || location.pathname;
      const r = await fetch(`${live.bridge_url}/docs/register`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ doc_path: docPath, doc_nonce: newNonce }),
        signal: AbortSignal.timeout(1500)
      });
      if (!r.ok) throw new Error(`register returned ${r.status}`);
      toast("Rebound — reloading…", 1500);
      setTimeout(() => location.reload(), 600);
    } catch (e) {
      btn.textContent = "✗ Rebind failed";
      setTimeout(() => {
        btn.textContent = original;
        btn.disabled = false;
      }, 2500);
    }
  }

  async function spawnFreshAgent(btn) {
    const original = btn.textContent;
    btn.disabled = true;
    btn.textContent = "Spawning fresh agent…";
    toast("Spawning fresh agent…", 2500);
    try {
      await fetch(`${AUX_DAEMON}/paperflow/spawn-continuation`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          doc_path: window.DOC_PATH,
          doc_nonce: (window.CLAUDE_TARGET || {}).doc_nonce,
          goal_id: window.PAPERFLOW_GOAL_ID
        }),
        signal: AbortSignal.timeout(2000)
      });
    } catch (e) {
      // Daemon may or may not respond before the new tab opens — ignore.
    }
    setTimeout(() => {
      btn.textContent = original;
      btn.disabled = false;
    }, 5000);
  }

  async function applyStatus(status) {
    bindingState.state = status.state;
    bindingState.last = status;

    if (bindingState.pill) {
      bindingState.pill.dataset.state = status.state;
      const ts = {
        live: "Bridge live",
        "stale-binding": "Doc binding lost",
        "session-gone": "Session ended",
        unknown: "Status unknown"
      }[status.state] || status.state;
      bindingState.pill.title = ts;
    }

    if (status.state === "live") {
      clearBanner();
      bindingState.discoverSession = null;
      setActionButtonsDisabled(bindingState.bar, false);
      return;
    }

    // Orphan branch — discover other live sessions in this workspace in
    // parallel, then render the recovery banner.
    bindingState.discoverSession = await discoverLiveSession();
    clearBanner();
    const banner = buildBanner(status);
    bindingState.banner = banner;
    if (bindingState.bar) bindingState.bar.appendChild(banner);
    setActionButtonsDisabled(bindingState.bar, true);
  }

  async function refreshBindingStatus() {
    const status = await fetchBindingStatus();
    await applyStatus(status);
    return status;
  }

  function loadStyles() {
    if (document.querySelector(`link[href="${STYLE_HREF}"]`)) return;
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = STYLE_HREF;
    document.head.appendChild(link);
  }

  function ensureMermaidZoom() {
    if (document.querySelector('link[href$="/_lib/mermaid-zoom.css"]')) return;
    const css = document.createElement("link");
    css.rel = "stylesheet";
    css.href = "/paperflow/_lib/mermaid-zoom.css";
    document.head.appendChild(css);
    const js = document.createElement("script");
    js.src = "/paperflow/_lib/mermaid-zoom.js";
    document.body.appendChild(js);
  }

  function ensureLiveRender() {
    // Per-page opt-out. The script itself also short-circuits off-localhost
    // (see live-render.js), so this flag is the only knob authors need for
    // explicit "no live morph" pages (e.g. fixed-snapshot demos).
    if (window.PAPERFLOW_NO_LIVE_RENDER) return;
    if (document.querySelector('link[href$="/_lib/live-render.css"]')) return;
    const css = document.createElement("link");
    css.rel = "stylesheet";
    css.href = "/paperflow/_lib/live-render.css";
    document.head.appendChild(css);
    const js = document.createElement("script");
    js.src = "/paperflow/_lib/live-render.js";
    document.body.appendChild(js);
  }

  function ensureGoalPathRail() {
    // Per-page opt-out for fixed-snapshot demos. The rail itself also
    // short-circuits when no Goal id is in scope (window.PAPERFLOW_GOAL_ID
    // or <meta name="paperflow-goal">).
    if (window.PAPERFLOW_NO_RAIL) return;
    if (document.querySelector('link[href$="/_lib/goal-path-rail.css"]')) return;
    const css = document.createElement("link");
    css.rel = "stylesheet";
    css.href = "/paperflow/_lib/goal-path-rail.css";
    document.head.appendChild(css);
    const js = document.createElement("script");
    js.src = "/paperflow/_lib/goal-path-rail.js";
    document.body.appendChild(js);
    // diff-modal piggybacks on the rail's stylesheet so we only need the
    // script tag here.
    const dj = document.createElement("script");
    dj.src = "/paperflow/_lib/diff-modal.js";
    document.body.appendChild(dj);
  }

  function detectKind() {
    const p = location.pathname;
    if (p.includes("/specs/")) return "spec";
    if (p.includes("/plans/")) return "plan";
    if (p.includes("/grills/")) return "grill";
    if (p.includes("/notes/")) return "note";
    if (p.includes("/changelog/")) return "changelog";
    if (p.includes("/questionnaires/")) return "questionnaire";
    if (p.includes("/goals/")) return "goal";
    if (p.includes("/missions/")) return "mission";
    if (p.includes("/audits/")) return "audit";
    return null;
  }

  function ensureSimplifyButton() {
    if (document.querySelector('script[src$="/_lib/simplify-button.js"]')) return;
    const js = document.createElement("script");
    js.src = "/paperflow/_lib/simplify-button.js";
    document.body.appendChild(js);
  }

  // Action templates — natural language instructions sent to Claude in the
  // originating terminal. Claude infers / invokes the right skill.
  function actionsFor(kind, docPath) {
    const file = (docPath || location.pathname).split("/").pop();
    if (kind === "spec") {
      return [
        {
          id: "plan",
          label: "Plan",
          variant: "primary",
          message: `Create an implementation plan from this spec: ${file}. Use the /paperflow:plan skill. Write the plan HTML to ~/docs/paperflow/plans/ using the article-style template + the shared /paperflow/_lib/doc.{css,js} for buttons. Use ~/.local/bin/paperflow-target to embed the right CLAUDE_TARGET.`
        },
        {
          id: "grill",
          label: "Grill",
          variant: "secondary",
          message: `Grill this spec: ${file}. Use the /paperflow:plan skill (grill phase) — read it in full, generate 8–15 pointed questions with rationale + recommendation + diagram per question, write the grill HTML to ~/docs/paperflow/grills/ using the shared renderer.`
        },
        {
          id: "simplify",
          label: "Simplify",
          variant: "secondary",
          local: true
        },
        {
          id: "pdf",
          type: "print",
          label: "Save as PDF",
          variant: "secondary"
        }
      ];
    }
    if (kind === "plan") {
      return [
        {
          id: "build",
          label: "Build",
          variant: "primary",
          message: `Implement this plan: ${file}. Use the /paperflow:build skill. Work phase-by-phase, claim each task in Beads, verify before closing.`
        },
        {
          id: "grill",
          label: "Grill",
          variant: "secondary",
          message: `Grill this plan: ${file}. Use the /paperflow:plan skill (grill phase) — pointed questions with rationale + recommendation + diagram per question.`
        },
        {
          id: "simplify",
          label: "Simplify",
          variant: "secondary",
          local: true
        },
        {
          id: "pdf",
          type: "print",
          label: "Save as PDF",
          variant: "secondary"
        }
      ];
    }
    if (kind === "grill") {
      // Grill HTMLs render their own sticky submit bar via grill.js. We layer
      // a doc-action with just Simplify (and PDF) — these don't conflict with
      // the form-submit row.
      return [
        {
          id: "simplify",
          label: "Simplify",
          variant: "secondary",
          local: true
        },
        {
          id: "pdf",
          type: "print",
          label: "Save as PDF",
          variant: "secondary"
        }
      ];
    }
    if (kind === "note") {
      return [
        {
          id: "reply",
          type: "reply",
          label: "Reply",
          variant: "primary",
          messagePrefix: `Re: ${file}: `
        },
        {
          id: "promote",
          label: "Promote",
          variant: "secondary",
          message: `Promote this discussion note to a formal spec: ${file}. Read the note in full, distill the core decision/architecture into a new HTML at ~/docs/paperflow/specs/<date>-<topic>-design.html using the spec template.`
        }
      ];
    }
    if (kind === "changelog") {
      return [
        {
          id: "share",
          label: "Share",
          variant: "secondary",
          message: `Share this changelog: ${file} — copy the URL to clipboard or post to Slack`
        }
      ];
    }
    if (kind === "audit") {
      return [
        {
          id: "share",
          label: "Share",
          variant: "secondary",
          message: `Share this audit: ${file} — copy the URL to clipboard`
        }
      ];
    }
    if (kind === "questionnaire") {
      // The questionnaire form (rendered by grill.js) owns its own sticky
      // submit bar — doc.js doesn't inject a top-level Submit. Keep the PDF
      // affordance for the same export-to-others path that specs/plans have.
      return [
        {
          id: "pdf",
          type: "print",
          label: "Save as PDF",
          variant: "secondary"
        }
      ];
    }
    if (kind === "goal") {
      // Goal HTMLs render the full Goal → Phase → Task subtree from Beads.
      // The natural verbs from here are: advance the active phase by claiming
      // the next ready task (/paperflow:build), refresh the HTML from live
      // Beads state (/paperflow:goal snapshot), or save a static export.
      return [
        {
          id: "build",
          label: "Build next",
          variant: "primary",
          message: `Advance the active phase of this Goal: ${file}. Use the /paperflow:build skill — read the active-goal and active-phase pointers, run bd ready --label phase-<active>, claim the next task with --claim, dispatch a subagent to do the work, verify, close.`
        },
        {
          id: "snapshot",
          label: "Snapshot",
          variant: "secondary",
          message: `Refresh this Goal HTML from live Beads state. Use the /paperflow:goal skill (snapshot sub-action) — bd show + bd list --json, re-render ~/docs/paperflow/goals/<slug>/index.html.`
        },
        {
          id: "pdf",
          type: "print",
          label: "Save as PDF",
          variant: "secondary"
        }
      ];
    }
    if (kind === "mission") {
      // Legacy mission HTMLs from before the Goal → Phase → Task migration.
      // The mission concept has been replaced by Goals in Beads — route the
      // buttons to the /paperflow:resume + /paperflow:goal skills instead.
      return [
        {
          id: "resume",
          label: "Resume",
          variant: "primary",
          message: `Resume work on the Goal corresponding to this legacy mission: ${file}. Use the /paperflow:resume skill — list Goals via bd, pick the closest match by slug, flip the active-goal + active-phase pointers, open the new Goal HTML.`
        },
        {
          id: "snapshot",
          label: "Snapshot",
          variant: "secondary",
          message: `Refresh the Goal HTML for the active goal. Use the /paperflow:goal skill (snapshot sub-action) — re-render ~/docs/paperflow/goals/<slug>/index.html from the live Beads state.`
        }
      ];
    }
    return [];
  }

  async function dispatch(action, message, btn, status, allBtns) {
    if (!window.CLAUDE_TARGET) {
      status.textContent = "window.CLAUDE_TARGET not set in this doc";
      return;
    }
    // Pre-flight binding check (3rd trigger). If the bridge says we're not
    // live, surface the recovery banner instead of POSTing into a stale
    // session.
    const pre = await refreshBindingStatus();
    if (pre.state !== "live") {
      status.textContent = "Bridge not live — see recovery banner below.";
      return;
    }
    allBtns.forEach(b => (b.disabled = true));
    const original = btn.textContent;
    btn.textContent = "Sending…";
    status.textContent = "";
    try {
      const res = await fetch(BRIDGE, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ target: window.CLAUDE_TARGET, message })
      });
      const j = await res.json();
      if (j.ok) {
        btn.textContent = "✓ Sent";
        status.textContent = `${action.id} dispatched → ${j.result}`;
      } else {
        btn.textContent = "✗ Failed";
        status.textContent = j.error || "unknown error";
      }
    } catch (e) {
      btn.textContent = "✗ Error";
      status.textContent = e.message;
    }
    setTimeout(() => {
      btn.textContent = original;
      allBtns.forEach(b => (b.disabled = false));
    }, 3500);
  }

  function init() {
    ensureLiveRender();
    ensureMermaidZoom();
    ensureGoalPathRail();
    ensureSimplifyButton();

    // #event=<id> hash routing is handled by goal-path-rail.js itself;
    // doc.js only needs to ensure the rail is loaded.

    const kind = detectKind();
    if (!kind) return;

    loadStyles();

    const actions = actionsFor(kind, window.DOC_PATH);
    if (!actions.length) return;

    const bar = document.createElement("div");
    bar.className = "doc-action";
    bindingState.bar = bar;

    const lbl = document.createElement("div");
    lbl.className = "doc-action-label";

    // Connection pill — sits LEFT of the label text. Color comes from CSS
    // keyed off [data-state]. Initial state is "unknown" until the first
    // status fetch resolves.
    const pill = document.createElement("span");
    pill.className = "paperflow-pill";
    pill.dataset.state = "unknown";
    pill.textContent = "●";
    pill.title = "Bridge status — checking…";
    bindingState.pill = pill;
    lbl.appendChild(pill);

    lbl.appendChild(document.createTextNode("Send to your terminal"));
    bar.appendChild(lbl);

    // Reply textarea (only when there's a type:reply action — i.e. notes)
    const replyAction = actions.find(a => a.type === "reply");
    let textarea = null;
    if (replyAction) {
      textarea = document.createElement("textarea");
      textarea.className = "doc-reply";
      textarea.placeholder = "Type your reply…";
      textarea.rows = 3;
      bar.appendChild(textarea);
    }

    const row = document.createElement("div");
    row.className = "doc-action-row";
    bar.appendChild(row);

    const status = document.createElement("div");
    status.className = "doc-action-status";

    const btns = actions.map(a => {
      const b = document.createElement("button");
      b.className = `doc-btn doc-btn-${a.variant}`;
      b.textContent = a.label;
      // Tag every button with its action id so external scripts (e.g.
      // simplify-button.js) can hook clicks via [data-action-id="…"].
      b.setAttribute("data-action-id", a.id);
      row.appendChild(b);
      return { btn: b, action: a };
    });
    bar.appendChild(status);

    btns.forEach(({ btn, action }) => {
      btn.addEventListener("click", () => {
        if (action.type === "print") {
          // Browser print dialog — user picks "Save as PDF" or a printer.
          // The @media print block in doc.css strips chrome and reflows
          // the article for paper.
          window.print();
          return;
        }
        // local: true — handled by an external script (e.g. simplify-button.js)
        // listening on [data-action-id="…"]. doc.js just renders the button.
        if (action.local) return;
        let message;
        if (action.type === "reply") {
          const txt = textarea && textarea.value.trim();
          if (!txt) {
            status.textContent = "Type a reply first.";
            textarea && textarea.focus();
            return;
          }
          message = action.messagePrefix + txt;
        } else {
          message = action.message;
        }
        dispatch(action, message, btn, status, btns.map(x => x.btn));
      });
    });

    document.body.appendChild(bar);

    // Trigger #1 — initial fetch (run async, don't block init).
    refreshBindingStatus();

    // Trigger #2 — re-fetch on tab becoming visible. No setInterval; the
    // browser fires this every time the tab refocuses, which is when the
    // user is most likely to actually click a button.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") {
        refreshBindingStatus();
      }
    });
    // (Trigger #3 — pre-flight before each POST — lives inside dispatch().)
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
