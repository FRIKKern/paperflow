/* GitHub-style click-to-zoom for Mermaid diagrams.
 *
 * Listens (via event delegation) for clicks on rendered Mermaid SVGs that
 * appear anywhere in the document (pre.mermaid, .q-diagram, inside <figure>).
 * Opens a full-screen modal with the cloned SVG. Pan with click-drag, zoom
 * with the mouse wheel (centered on the cursor; trackpad pinch works because
 * the browser dispatches wheel events with ctrlKey). Close with ESC, click on
 * the backdrop, or the small ✕ button in the top-right.
 *
 * Pure vanilla JS, no dependencies. Loads idempotently from doc.js / grill.js.
 */
(function () {
  if (window.__mermaidZoomLoaded) return;
  window.__mermaidZoomLoaded = true;

  const MIN_SCALE = 0.3;
  const MAX_SCALE = 8;

  // A rendered Mermaid SVG either *is* the click target or one of its
  // ancestors matches one of these selectors. We walk up to find an SVG.
  const TRIGGER_SELECTORS = [
    "pre.mermaid",
    ".mermaid",
    ".q-diagram",
    "figure"
  ];

  function findSvgFrom(target) {
    // Walk up at most a few levels to find a container with an SVG inside.
    let el = target;
    for (let i = 0; i < 6 && el && el !== document.body; i++) {
      if (el.tagName === "svg") return el;
      if (el.matches && TRIGGER_SELECTORS.some(s => el.matches(s))) {
        const svg = el.querySelector("svg");
        if (svg) return svg;
      }
      el = el.parentElement;
    }
    // Last shot: did we click directly on/inside an SVG?
    if (target.closest) {
      const svg = target.closest("svg");
      if (svg && svg.closest(TRIGGER_SELECTORS.join(","))) return svg;
    }
    return null;
  }

  let modal = null;
  let stage = null;
  let currentSvg = null;
  let scale = 1;
  let tx = 0, ty = 0;
  let dragging = false;
  let dragStartX = 0, dragStartY = 0;
  let txStart = 0, tyStart = 0;

  function applyTransform() {
    if (currentSvg) {
      currentSvg.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
    }
  }

  function ensureModal() {
    if (modal) return modal;
    modal = document.createElement("div");
    modal.className = "mz-modal";
    modal.innerHTML = `
      <div class="mz-stage"></div>
      <button class="mz-close" type="button" aria-label="Close">✕</button>
    `;
    document.body.appendChild(modal);
    stage = modal.querySelector(".mz-stage");

    modal.addEventListener("click", (e) => {
      if (e.target === modal || e.target === stage) close();
    });
    modal.querySelector(".mz-close").addEventListener("click", close);

    // Wheel zoom centered on cursor.
    modal.addEventListener("wheel", (e) => {
      if (!currentSvg) return;
      e.preventDefault();
      const rect = currentSvg.getBoundingClientRect();
      const cx = e.clientX - rect.left - rect.width / 2;
      const cy = e.clientY - rect.top - rect.height / 2;
      // Trackpad pinch reports ctrlKey + wheel; use a stronger factor for it.
      const factor = e.ctrlKey ? 0.02 : 0.0015;
      const delta = -e.deltaY * factor;
      const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale * (1 + delta)));
      const ratio = next / scale;
      // Keep cursor pinned: shift translate so the cursor-anchored point stays put.
      tx -= cx * (ratio - 1);
      ty -= cy * (ratio - 1);
      scale = next;
      applyTransform();
    }, { passive: false });

    // Click-drag pan.
    stage.addEventListener("mousedown", (e) => {
      if (!currentSvg) return;
      dragging = true;
      dragStartX = e.clientX;
      dragStartY = e.clientY;
      txStart = tx;
      tyStart = ty;
      currentSvg.style.transition = "none";
      currentSvg.style.cursor = "grabbing";
      e.preventDefault();
    });
    window.addEventListener("mousemove", (e) => {
      if (!dragging) return;
      tx = txStart + (e.clientX - dragStartX);
      ty = tyStart + (e.clientY - dragStartY);
      applyTransform();
    });
    window.addEventListener("mouseup", () => {
      if (!dragging) return;
      dragging = false;
      if (currentSvg) currentSvg.style.cursor = "grab";
    });

    document.addEventListener("keydown", (e) => {
      if (modal.classList.contains("is-open") && e.key === "Escape") close();
    });

    return modal;
  }

  function open(svg) {
    ensureModal();
    // Clone — never move the SVG out of the article.
    const clone = svg.cloneNode(true);
    clone.removeAttribute("style");
    clone.style.maxWidth = "none";
    clone.style.maxHeight = "none";
    clone.style.cursor = "grab";
    clone.style.userSelect = "none";
    clone.style.transformOrigin = "center center";
    stage.innerHTML = "";
    stage.appendChild(clone);
    currentSvg = clone;

    // Open the modal first so the stage has its real layout dimensions.
    modal.classList.add("is-open");

    // Fit-to-stage on next frame: compute the scale that makes the SVG fill
    // ~92% of the available stage area without overflowing either axis.
    // Then the user can zoom further from there.
    requestAnimationFrame(() => {
      const stageRect = stage.getBoundingClientRect();
      const svgRect   = clone.getBoundingClientRect();
      if (svgRect.width > 0 && svgRect.height > 0 && stageRect.width > 0) {
        const fit = Math.min(
          (stageRect.width  * 0.92) / svgRect.width,
          (stageRect.height * 0.92) / svgRect.height
        );
        scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, fit));
      } else {
        scale = 1;
      }
      tx = 0; ty = 0;
      applyTransform();
    });
  }

  function close() {
    if (!modal) return;
    modal.classList.remove("is-open");
    setTimeout(() => {
      if (stage) stage.innerHTML = "";
      currentSvg = null;
    }, 220);
  }

  // Event delegation: catches diagrams rendered before AND after this loads.
  document.body.addEventListener("click", (e) => {
    // Ignore clicks while modal is open (modal handles its own clicks).
    if (modal && modal.classList.contains("is-open")) return;
    const svg = findSvgFrom(e.target);
    if (!svg) return;
    e.preventDefault();
    e.stopPropagation();
    open(svg);
  });

  // Set the zoom-in cursor on Mermaid containers as soon as their SVG appears.
  // We use a MutationObserver (cheap; runs once Mermaid finishes rendering).
  function tagAffordance(root) {
    root.querySelectorAll(TRIGGER_SELECTORS.join(",")).forEach((el) => {
      if (el.querySelector("svg")) el.classList.add("mz-zoomable");
    });
  }
  if (document.body) tagAffordance(document.body);
  const mo = new MutationObserver((muts) => {
    for (const m of muts) {
      for (const n of m.addedNodes) {
        if (n.nodeType === 1) tagAffordance(n);
      }
      if (m.type === "attributes" && m.target.nodeType === 1) {
        tagAffordance(m.target.parentNode || document.body);
      }
    }
  });
  mo.observe(document.body, { childList: true, subtree: true });
})();
