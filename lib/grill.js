/* Grill form renderer.
 *
 * Reads window.GRILL = { plan, target, questions } and renders a form
 * into <main id="grill-form">. Handles submit by POSTing structured
 * answers back through the claude-bridge.
 *
 * Question schema:
 *   { id, type: "open"|"single"|"multi"|"yesno"|"scale", text,
 *     options?: string[], min?: number, max?: number, hint?: string }
 */

(function () {
  const BRIDGE = "http://localhost:8766/build";

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

  function collectAnswers(questions) {
    const answered = [];
    const skipped = [];
    for (const q of questions) {
      // Custom override takes precedence for non-open types.
      if (q.type !== "open") {
        const custom = document.querySelector(`[name="${q.id}__custom"]`);
        const customVal = custom && custom.value.trim();
        if (customVal) {
          answered.push({ q, val: customVal, custom: true });
          continue;
        }
      }

      let val;
      if (q.type === "open") {
        const ta = document.querySelector(`[name="${q.id}"]`);
        val = ta && ta.value.trim() ? ta.value.trim() : null;
      } else if (q.type === "multi") {
        const checked = [...document.querySelectorAll(`[name="${q.id}"]:checked`)].map(i => i.value);
        val = checked.length ? checked : null;
      } else {
        const sel = document.querySelector(`[name="${q.id}"]:checked`);
        val = sel ? sel.value : null;
      }
      if (val === null) skipped.push(q);
      else answered.push({ q, val });
    }
    return { answered, skipped };
  }

  function buildMessage(plan, answered, skipped) {
    let msg = `Grill answers for ${plan}:\n\n`;
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
    msg += `Please integrate these answers into a revised version of the plan.`;
    return msg;
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
    const message = buildMessage(grill.plan, answered, skipped);
    try {
      const res = await fetch(BRIDGE, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ target: grill.target, message }),
      });
      const j = await res.json();
      if (j.ok) {
        btn.textContent = `✓ Sent (${answered.length} answered, ${skipped.length} skipped)`;
        status.textContent = "Dispatched → " + j.result;
      } else {
        btn.textContent = "✗ Failed";
        status.textContent = j.error || "unknown error";
      }
    } catch (e) {
      btn.textContent = "✗ Error";
      status.textContent = e.message;
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

    btn.addEventListener("click", () => submit(grill, btn, status));
    root.addEventListener("input", () => updateProgress(grill));
    root.addEventListener("change", () => updateProgress(grill));

    updateProgress(grill);

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
