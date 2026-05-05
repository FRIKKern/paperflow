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

  function detectKind() {
    const p = location.pathname;
    if (p.includes("/specs/")) return "spec";
    if (p.includes("/plans/")) return "plan";
    if (p.includes("/notes/")) return "note";
    if (p.includes("/changelog/")) return "changelog";
    if (p.includes("/missions/")) return "mission";
    if (p.includes("/audits/")) return "audit";
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
          label: "Plan",
          variant: "primary",
          message: `Create an implementation plan from this spec: ${file}. Use the paperflow-plan skill. Write the plan HTML to ~/docs/paperflow/plans/ using the article-style template + the shared /paperflow/_lib/doc.{css,js} for buttons. Use ~/.local/bin/paperflow-target to embed the right CLAUDE_TARGET.`
        },
        {
          id: "grill",
          label: "Grill",
          variant: "secondary",
          message: `Grill this spec: ${file}. Use the paperflow-plan skill (grill phase) — read it in full, generate 8–15 pointed questions with rationale + recommendation + diagram per question, write the grill HTML to ~/docs/paperflow/grills/ using the shared renderer.`
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
          message: `Implement this plan: ${file}. Use the paperflow-build skill. Work phase-by-phase, claim each task in Beads, verify before closing.`
        },
        {
          id: "grill",
          label: "Grill",
          variant: "secondary",
          message: `Grill this plan: ${file}. Use the paperflow-plan skill (grill phase) — pointed questions with rationale + recommendation + diagram per question.`
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
    if (kind === "mission") {
      // Legacy mission HTMLs from before the Goal → Phase → Task migration.
      // The mission concept has been replaced by Goals in Beads — route the
      // buttons to the paperflow-resume + paperflow-goal skills instead.
      return [
        {
          id: "resume",
          label: "Resume",
          variant: "primary",
          message: `Resume work on the Goal corresponding to this legacy mission: ${file}. Use the paperflow-resume skill — list Goals via bd, pick the closest match by slug, flip the active-goal + active-phase pointers, open the new Goal HTML.`
        },
        {
          id: "snapshot",
          label: "Snapshot",
          variant: "secondary",
          message: `Refresh the Goal HTML for the active goal. Use the paperflow-goal skill (snapshot sub-action) — re-render ~/docs/paperflow/goals/<slug>/index.html from the live Beads state.`
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
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
