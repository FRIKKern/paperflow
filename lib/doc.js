/* Shared action bar for spec / plan HTML docs.
 *
 * Each spec/plan HTML must set, before this script loads:
 *   window.CLAUDE_TARGET = { term_program, tty, ... }   // from get-terminal-target.sh
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
  const STYLE_HREF = "/superpowers/_lib/doc.css";

  function loadStyles() {
    if (document.querySelector(`link[href="${STYLE_HREF}"]`)) return;
    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = STYLE_HREF;
    document.head.appendChild(link);
  }

  function detectKind() {
    const p = location.pathname;
    if (p.includes("/specs/")) return "spec";
    if (p.includes("/plans/")) return "plan";
    return null;
  }

  // Action templates — natural language instructions sent to Claude in the
  // originating terminal. Claude infers / invokes the right skill.
  function actionsFor(kind, docPath) {
    const file = (docPath || location.pathname).split("/").pop();
    if (kind === "spec") {
      return [
        {
          id: "plan",
          label: "Create plan from this spec",
          variant: "primary",
          message: `Create an implementation plan from this spec: ${file}. Use the superpowers:writing-plans skill. Write the plan HTML to ~/docs/superpowers/plans/ using the article-style template + the shared /superpowers/_lib/doc.{css,js} for buttons. Use the get-terminal-target.sh helper to embed the right CLAUDE_TARGET.`
        },
        {
          id: "grill",
          label: "Grill the spec",
          variant: "secondary",
          message: `Grill this spec: ${file}. Use the grill-plan skill — read it in full, generate 8–15 pointed questions with rationale + recommendation + diagram per question, write the grill HTML to ~/docs/superpowers/grills/ using the shared renderer.`
        }
      ];
    }
    if (kind === "plan") {
      return [
        {
          id: "build",
          label: "Build this plan",
          variant: "primary",
          message: `Implement this plan: ${file}. Use the superpowers:executing-plans skill. Work step by step; verify each step before moving on.`
        },
        {
          id: "grill",
          label: "Grill the plan",
          variant: "secondary",
          message: `Grill this plan: ${file}. Use the grill-plan skill — pointed questions with rationale + recommendation + diagram per question.`
        }
      ];
    }
    return [];
  }

  async function dispatch(action, btn, status, allBtns) {
    if (!window.CLAUDE_TARGET) {
      status.textContent = "window.CLAUDE_TARGET not set in this doc";
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
        body: JSON.stringify({ target: window.CLAUDE_TARGET, message: action.message })
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
    const kind = detectKind();
    if (!kind) return;

    loadStyles();

    const actions = actionsFor(kind, window.DOC_PATH);
    if (!actions.length) return;

    const bar = document.createElement("div");
    bar.className = "doc-action";

    const lbl = document.createElement("div");
    lbl.className = "doc-action-label";
    lbl.textContent = "Send to your terminal";
    bar.appendChild(lbl);

    const row = document.createElement("div");
    row.className = "doc-action-row";
    bar.appendChild(row);

    const status = document.createElement("div");
    status.className = "doc-action-status";

    const btns = actions.map(a => {
      const b = document.createElement("button");
      b.className = `doc-btn doc-btn-${a.variant}`;
      b.textContent = a.label;
      row.appendChild(b);
      return { btn: b, action: a };
    });
    bar.appendChild(status);

    btns.forEach(({ btn, action }) => {
      btn.addEventListener("click", () =>
        dispatch(action, btn, status, btns.map(x => x.btn))
      );
    });

    document.body.appendChild(bar);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
