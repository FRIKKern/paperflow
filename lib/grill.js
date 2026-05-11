/* Grill form renderer.
 *
 * Reads window.GRILL = { plan, target, questions, kind?, goalId? } and
 * renders a form into <main id="grill-form">. Handles submit by POSTing
 * structured answers back through the claude-bridge. Same renderer for
 * kind: "grill" (default) and kind: "questionnaire" — only the bridge
 * header label and optional `Goal:` line differ.
 *
 * Question schema:
 *   { id, type: "open"|"single"|"multi"|"yesno"|"scale", text,
 *     options?: string[], min?: number, max?: number, hint?: string,
 *     dependsOn?: { question: string, answer: string } }
 *
 * Gated questions (v1): optional `dependsOn` hides a question until
 * another's answer matches. Single object only. Omitting it keeps the
 * existing always-visible behaviour. Match is string-equals; for multi-
 * select answers (arrays) the gate fires when the array .includes(answer).
 * Authoring order is trusted — no auto-reorder. On gate close, the
 * dependent's inputs are cleared so stale state can't leak back. Hidden
 * questions are excluded from the payload via the live DOM [hidden]
 * attribute (single source of truth). Invalid/malformed dependsOn refs
 * surface as an error overlay; valid questions still render below.
 *
 * TODO(v2): multi-gate via dependsOn: {all:[...], any:[...]}.
 */

(function () {
  // The bridge URL comes from window.CLAUDE_TARGET.bridge_url (per-instance
  // bridge migration). Docs written before the migration won't have it —
  // they surface as a structured failure rather than POSTing into the void
  // at the old hardcoded localhost:8766.

  // Resolve the per-instance bridge base URL ("http://127.0.0.1:NNNN")
  // from window.CLAUDE_TARGET. Returns null when missing — caller is
  // responsible for surfacing the failure to the user.
  function resolveBridgeBase() {
    const target = window.CLAUDE_TARGET || {};
    if (typeof target.bridge_url === "string" && target.bridge_url) {
      return target.bridge_url.replace(/\/+$/, "");
    }
    return null;
  }

  // Dispatch a structured failure event so doc.js's connection pill can
  // refresh and surface the orphan recovery banner. The detail payload
  // mirrors what we logged so consumers can inspect it via the event.
  function dispatchFailure(eventName, detail) {
    try {
      window.dispatchEvent(new CustomEvent(eventName, { detail }));
    } catch (e) {
      // CustomEvent is supported everywhere we run; this catch is purely
      // defensive against very old shells. Don't escalate — the console
      // error logged separately is the load-bearing signal.
    }
    // If doc.js exposed refreshBindingStatus on window.paperflow, call it
    // directly too — the event handler in doc.js already does this, but
    // calling it here means the refresh fires even when doc.js isn't on
    // the page (e.g. a future standalone grill viewer).
    const pf = window.paperflow;
    if (pf && typeof pf.refreshBindingStatus === "function") {
      // Best-effort, no await — we want the failure path to return fast.
      pf.refreshBindingStatus();
    }
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
    if (document.querySelector('link[href$="/_lib/live-render.css"]')) return;
    const css = document.createElement("link");
    css.rel = "stylesheet";
    css.href = "/paperflow/_lib/live-render.css";
    document.head.appendChild(css);
    const js = document.createElement("script");
    js.src = "/paperflow/_lib/live-render.js";
    document.body.appendChild(js);
  }

  function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (k === "class") e.className = v;
        else if (k === "html") e.innerHTML = v;
        else if (k.startsWith("on") && typeof v === "function") e[k] = v;
        else e.setAttribute(k, v);
      }
    }
    for (const c of children.flat()) {
      if (c == null) continue;
      e.append(c.nodeType ? c : document.createTextNode(String(c)));
    }
    return e;
  }

  function isRecommended(q, opt) {
    if (q.recommendation == null) return false;
    if (Array.isArray(q.recommendation)) return q.recommendation.includes(opt);
    return String(q.recommendation) === String(opt);
  }

  // Pure visibility check — no DOM. True when no gate, or when the
  // gating answer matches (string-equals; .includes for arrays).
  function isVisible(q, answers) {
    if (!q.dependsOn) return true;
    const dep = q.dependsOn;
    if (typeof dep !== "object" || typeof dep.question !== "string") return true;
    const current = answers ? answers[dep.question] : undefined;
    if (current == null) return false;
    if (Array.isArray(current)) return current.includes(dep.answer);
    return String(current) === String(dep.answer);
  }

  // Returns [{questionId, reason}] for malformed/unknown-ref dependsOn.
  function validateGates(questions) {
    const ids = new Set(questions.map(q => q.id));
    const errors = [];
    const fail = (id, reason) => errors.push({ questionId: id, reason });
    for (const q of questions) {
      if (!q.dependsOn) continue;
      const dep = q.dependsOn;
      if (typeof dep !== "object" || Array.isArray(dep)) fail(q.id, "dependsOn must be an object {question, answer}");
      else if (typeof dep.question !== "string" || !dep.question) fail(q.id, "dependsOn.question must be a non-empty string");
      else if (dep.answer == null) fail(q.id, "dependsOn.answer is required");
      else if (!ids.has(dep.question)) fail(q.id, `dependsOn.question references unknown id "${dep.question}"`);
    }
    return errors;
  }

  function renderQuestion(q, idx) {
    const card = el("div", { class: "q", "data-qid": q.id, "data-qtype": q.type });
    card.append(el("div", { class: "q-num" }, `Q${idx + 1} · ${q.category || q.type}`));
    card.append(el("div", { class: "q-text" }, q.text));

    if (q.rationale) {
      card.append(el("div", { class: "q-rationale" }, q.rationale));
    }

    if (q.diagram) {
      const fig = el("div", { class: "q-diagram" });
      const pre = el("pre", { class: "mermaid" });
      pre.textContent = q.diagram.trim();
      fig.append(pre);
      if (q.diagramCaption) {
        fig.append(el("div", { class: "q-diagram-cap" }, q.diagramCaption));
      }
      card.append(fig);
    }

    function optLabel(opt, checked) {
      const recommended = isRecommended(q, opt);
      const label = el("label", { class: recommended ? "is-recommended" : "" },
        el("input", {
          type: q.type === "multi" ? "checkbox" : "radio",
          name: q.id,
          value: opt,
          ...(checked ? { checked: "checked" } : {})
        }),
        el("span", null, opt),
        recommended ? el("span", { class: "rec-star", title: "Claude's pick" }, " ★") : null
      );
      return label;
    }

    switch (q.type) {
      case "open": {
        const ta = el("textarea", {
          name: q.id,
          placeholder: q.recommendation || q.hint || "Answer…",
          rows: 3
        });
        if (q.recommendation) {
          // For open: don't pre-fill; offer a one-click "use suggested" link.
          card.append(ta);
          const useBtn = el("button", { type: "button", class: "use-rec" }, "Use suggested answer");
          useBtn.addEventListener("click", () => {
            ta.value = q.recommendation;
            ta.dispatchEvent(new Event("input", { bubbles: true }));
            ta.focus();
          });
          card.append(useBtn);
        } else {
          card.append(ta);
        }
        break;
      }
      case "single": {
        for (const opt of q.options || []) {
          card.append(optLabel(opt, isRecommended(q, opt)));
        }
        break;
      }
      case "multi": {
        for (const opt of q.options || []) {
          card.append(optLabel(opt, isRecommended(q, opt)));
        }
        break;
      }
      case "yesno": {
        for (const opt of ["Yes", "No"]) {
          card.append(optLabel(opt, isRecommended(q, opt)));
        }
        break;
      }
      case "scale": {
        const min = q.min ?? 1, max = q.max ?? 5;
        const row = el("div", { class: "scale" });
        for (let i = min; i <= max; i++) {
          const recommended = isRecommended(q, i);
          row.append(el("label", { class: recommended ? "is-recommended" : "" },
            el("input", {
              type: "radio",
              name: q.id,
              value: i,
              ...(recommended ? { checked: "checked" } : {})
            }),
            el("span", null, i),
            recommended ? el("span", { class: "rec-star" }, "★") : null
          ));
        }
        card.append(row);
        if (q.minLabel || q.maxLabel) {
          card.append(el("div", { class: "q-meta" }, `${q.minLabel || min} ↔ ${q.maxLabel || max}`));
        }
        break;
      }
      default:
        card.append(el("div", { class: "q-meta" }, `[unknown question type: ${q.type}]`));
    }

    if (q.recommendationReason) {
      const reason = el("div", { class: "q-rec-reason" });
      reason.append(el("span", { class: "rec-star" }, "★"));
      reason.append(el("span", { class: "rec-label" }, " Claude's pick: "));
      reason.append(el("span", null, q.recommendationReason));
      card.append(reason);
    }

    if (q.hint && q.type !== "open") {
      card.append(el("div", { class: "q-meta" }, q.hint));
    }

    // Escape hatch: every non-open question gets an optional custom-answer
    // override. If filled in, it replaces the selection on submit.
    if (q.type !== "open") {
      const custom = el("textarea", {
        name: q.id + "__custom",
        class: "q-custom",
        placeholder: "Or write your own answer (overrides selection above)…",
        rows: 2
      });
      card.append(custom);
    }
    return card;
  }

  // Read current answer from live DOM.
  function readAnswer(q) {
    if (q.type === "open") {
      const ta = document.querySelector(`[name="${q.id}"]`);
      return ta && ta.value.trim() ? ta.value.trim() : null;
    }
    if (q.type === "multi") {
      const checked = [...document.querySelectorAll(`[name="${q.id}"]:checked`)].map(i => i.value);
      return checked.length ? checked : null;
    }
    const sel = document.querySelector(`[name="${q.id}"]:checked`);
    return sel ? sel.value : null;
  }

  function collectAnswers(questions) {
    const answered = [];
    const skipped = [];
    for (const q of questions) {
      // Hidden cards never enter the payload (live DOM is truth).
      const card = document.querySelector(`[data-qid="${q.id}"]`);
      if (card && card.hidden) continue;
      // Custom override takes precedence for non-open types.
      if (q.type !== "open") {
        const custom = document.querySelector(`[name="${q.id}__custom"]`);
        const customVal = custom && custom.value.trim();
        if (customVal) {
          answered.push({ q, val: customVal, custom: true });
          continue;
        }
      }

      const val = readAnswer(q);
      if (val === null) skipped.push(q);
      else answered.push({ q, val });
    }
    return { answered, skipped };
  }

  // Clear all inputs for a question when its gate closes.
  function clearQuestionInputs(q) {
    document.querySelectorAll(`[name="${q.id}"], [name="${q.id}__custom"]`).forEach(i => {
      if (i.type === "checkbox" || i.type === "radio") i.checked = false;
      else i.value = "";
    });
  }

  // Toggle [hidden] on each .q card; clear inputs on visible → hidden.
  function recomputeVisibility(questions) {
    const answers = {};
    for (const q of questions) answers[q.id] = readAnswer(q);
    for (const q of questions) {
      const card = document.querySelector(`[data-qid="${q.id}"]`);
      if (!card) continue;
      const shouldBeHidden = !isVisible(q, answers);
      if (card.hidden === shouldBeHidden) continue;
      card.hidden = shouldBeHidden;
      if (shouldBeHidden) clearQuestionInputs(q);
    }
  }

  function buildMessage(plan, kind, goalId, answered, skipped) {
    const label = kind === "questionnaire" ? "Questionnaire" : "Grill";
    let msg = `${label} answers for ${plan}:\n\n`;
    if (goalId) msg += `Goal: ${goalId}\n\n`;
    for (const a of answered) {
      const v = Array.isArray(a.val) ? a.val.join(", ") : a.val;
      const tag = a.custom ? " _(custom override)_" : "";
      msg += `**${a.q.text}**${tag}\n→ ${v}\n\n`;
    }
    if (skipped.length) {
      msg += `_Skipped (${skipped.length}):_\n`;
      for (const q of skipped) msg += `- ${q.text}\n`;
      msg += `\n`;
    }
    if (kind === "questionnaire") {
      msg += `Please fold these answers into the Goal vision (or plan draft) and proceed.`;
    } else {
      msg += `Please integrate these answers into a revised version of the plan.`;
    }
    return msg;
  }

  // On successful questionnaire submit, write a tiny sidecar marker so
  // /paperflow:resume can detect unfinished forms by their absence.
  // The bridge handles the actual file write — we just signal intent
  // via a follow-up POST that the bridge interprets as "marker request".
  //
  // Per-instance-bridge requirements (post-migration):
  //   - POST to <window.CLAUDE_TARGET.bridge_url>/marker, NOT a hardcoded
  //     localhost:8766 (the bridge runs on a per-session port now).
  //   - Include doc_nonce in the body so the bridge can validate that the
  //     POST is coming from a doc it knows about.
  //   - Surface failures via console.error + a paperflow:marker-failed
  //     CustomEvent so doc.js's connection pill refreshes immediately
  //     (instead of waiting for the next visibilitychange).
  async function writeAnsweredMarker(grill) {
    if (grill.kind !== "questionnaire") return;
    if (!grill.plan) return;

    const target = window.CLAUDE_TARGET || {};
    const base = resolveBridgeBase();
    if (!base) {
      // Legacy doc — bridge_url is missing. Don't throw (non-blocking for
      // the user's submit happy path) but log structured + dispatch so the
      // pill can flip to session-gone.
      console.error("[paperflow grill] /marker POST aborted: missing window.CLAUDE_TARGET.bridge_url (legacy doc, needs rebind)");
      dispatchFailure("paperflow:marker-failed", {
        reason: "missing-bridge-url",
        status: 0,
        body: null
      });
      return;
    }

    const url = `${base}/marker`;
    let res;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          kind: "questionnaire-answered",
          plan: grill.plan,
          doc_nonce: target.doc_nonce,
          submitted_at: new Date().toISOString()
        })
      });
    } catch (e) {
      // Network-level failure (bridge process dead, port closed, etc).
      console.error("[paperflow grill] /marker POST fetch failed:", {
        url,
        reason: (e && e.message) || "fetch-failed"
      });
      dispatchFailure("paperflow:marker-failed", {
        reason: "fetch-failed",
        status: 0,
        body: { error: (e && e.message) || "fetch-failed" }
      });
      return;
    }

    if (!res.ok) {
      // Non-2xx — most importantly 410 (stale-binding / session-gone) from
      // the per-instance bridge's doc_nonce validation. Read the body for
      // diagnostics + structured event payload; the actual UI refresh is
      // handled by doc.js listening for the event we dispatch below.
      let body = null;
      try { body = await res.json(); } catch (_) { /* body may be empty */ }
      console.error("[paperflow grill] /marker POST non-2xx:", {
        url,
        status: res.status,
        body
      });
      dispatchFailure("paperflow:marker-failed", {
        reason: (body && body.code) || "non-2xx",
        status: res.status,
        body
      });
    }
  }

  async function submit(grill, btn, status) {
    const { answered, skipped } = collectAnswers(grill.questions);
    if (!answered.length) {
      status.textContent = "Answer at least one question first.";
      return;
    }
    btn.disabled = true;
    btn.textContent = "Sending…";
    status.textContent = "";
    const kind = grill.kind || "grill";
    const message = buildMessage(grill.plan, kind, grill.goalId, answered, skipped);

    // Per-instance bridge: resolve the bridge URL from CLAUDE_TARGET. If
    // it's missing (legacy doc) abort with a structured failure so the
    // pill can flip to session-gone and prompt rebind.
    const target = window.CLAUDE_TARGET || {};
    const base = resolveBridgeBase();
    if (!base) {
      console.error("[paperflow grill] /build POST aborted: missing window.CLAUDE_TARGET.bridge_url (legacy doc, needs rebind)");
      dispatchFailure("paperflow:build-failed", {
        reason: "missing-bridge-url",
        status: 0,
        body: null
      });
      btn.textContent = "✗ Bridge missing";
      status.textContent = "This doc is not bound to a live bridge. See recovery banner.";
      setTimeout(() => {
        btn.disabled = false;
        btn.textContent = "Send answers to Claude";
      }, 4000);
      return;
    }

    const url = `${base}/build`;
    let res;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          target: grill.target,
          message,
          doc_nonce: target.doc_nonce
        }),
      });
    } catch (e) {
      console.error("[paperflow grill] /build POST fetch failed:", {
        url,
        reason: (e && e.message) || "fetch-failed"
      });
      dispatchFailure("paperflow:build-failed", {
        reason: "fetch-failed",
        status: 0,
        body: { error: (e && e.message) || "fetch-failed" }
      });
      btn.textContent = "✗ Error";
      status.textContent = (e && e.message) || "fetch-failed";
      setTimeout(() => {
        btn.disabled = false;
        btn.textContent = "Send answers to Claude";
      }, 4000);
      return;
    }

    if (!res.ok) {
      // Non-2xx — most importantly 410 stale-binding / session-gone from
      // doc_nonce validation. Abort, log structured, dispatch event so
      // doc.js's pill refreshes and the recovery banner appears.
      let body = null;
      try { body = await res.json(); } catch (_) { /* body may be empty */ }
      console.error("[paperflow grill] /build POST non-2xx:", {
        url,
        status: res.status,
        body
      });
      dispatchFailure("paperflow:build-failed", {
        reason: (body && body.code) || "non-2xx",
        status: res.status,
        body
      });
      btn.textContent = "✗ Failed";
      status.textContent = (body && body.error) || `bridge returned ${res.status}`;
      setTimeout(() => {
        btn.disabled = false;
        btn.textContent = "Send answers to Claude";
      }, 4000);
      return;
    }

    // 2xx — happy path. Parse the JSON envelope the bridge returns.
    let j = {};
    try { j = await res.json(); } catch (_) { /* envelope optional */ }
    if (j.ok) {
      btn.textContent = `✓ Sent (${answered.length} answered, ${skipped.length} skipped)`;
      status.textContent = "Dispatched → " + j.result;
      // Fire-and-forget marker so /paperflow:resume can detect submitted
      // questionnaires (no sibling -answered.json ⇒ unfinished).
      writeAnsweredMarker(grill);
    } else {
      // 2xx with ok:false — application-level rejection. Log structured
      // (the bridge already passed nonce validation, so this is NOT a
      // binding failure — keep the event out of the marker-failed channel).
      console.error("[paperflow grill] /build returned ok:false:", j);
      btn.textContent = "✗ Failed";
      status.textContent = j.error || "unknown error";
    }
    setTimeout(() => {
      btn.disabled = false;
      btn.textContent = "Send answers to Claude";
    }, 4000);
  }

  function updateProgress(grill) {
    const total = grill.questions.length;
    const { answered } = collectAnswers(grill.questions);
    const done = answered.length;
    const bar = document.getElementById("progress");
    if (bar) {
      bar.innerHTML = `<span>Progress</span> <span><strong>${done}</strong> / ${total} answered</span>`;
    }
  }

  function init() {
    ensureLiveRender();
    ensureMermaidZoom();

    const grill = window.GRILL;
    if (!grill) {
      console.error("window.GRILL not set");
      return;
    }
    const root = document.getElementById("grill-form");
    if (!root) {
      console.error("#grill-form not found");
      return;
    }

    root.append(el("div", { id: "progress", class: "progress" },
      "Loading…"
    ));

    // Surface gate errors as a render-time overlay; valid questions still render.
    const gateErrors = validateGates(grill.questions);
    if (gateErrors.length) {
      const overlay = el("div", {
        class: "grill-validation-error",
        style: "border:1px solid #a23925;background:#faeae6;color:#5a1d12;padding:.9rem 1rem;border-radius:4px;margin-bottom:1rem;"
      });
      overlay.append(el("div", { style: "font-weight:600;margin-bottom:.4rem;" },
        `Gate validation: ${gateErrors.length} invalid dependsOn reference${gateErrors.length === 1 ? "" : "s"}`));
      const list = el("ul", { style: "margin:.2rem 0 0 1rem;padding:0;" });
      for (const e of gateErrors) list.append(el("li", null, `${e.questionId}: ${e.reason}`));
      overlay.append(list);
      root.append(overlay);
    }

    // Group by category if present
    const groups = {};
    grill.questions.forEach(q => {
      const cat = q.category || "Questions";
      (groups[cat] = groups[cat] || []).push(q);
    });

    let qIdx = 0;
    for (const [cat, qs] of Object.entries(groups)) {
      if (Object.keys(groups).length > 1) root.append(el("h2", null, cat));
      for (const q of qs) root.append(renderQuestion(q, qIdx++));
    }

    const submitBar = el("div", { class: "submit-bar" });
    submitBar.append(el("div", { class: "label" }, "Send answers back to your terminal"));
    const btn = el("button", { id: "submit-btn", type: "button" }, "Send answers to Claude");
    submitBar.append(btn);
    const status = el("div", { id: "submit-status" });
    submitBar.append(status);
    root.append(submitBar);

    const onChange = () => { recomputeVisibility(grill.questions); updateProgress(grill); };
    btn.addEventListener("click", () => submit(grill, btn, status));
    root.addEventListener("input", onChange);
    root.addEventListener("change", onChange);
    onChange(); // apply visibility on load so initially-gated cards start hidden

    // Render any embedded Mermaid diagrams (Mermaid must be loaded by the page).
    if (window.mermaid && typeof window.mermaid.run === "function") {
      window.mermaid.run({ querySelector: ".q-diagram pre.mermaid" })
        .catch(err => console.warn("mermaid render failed:", err));
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
