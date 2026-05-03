/* Live-render — chat-like DOM morph instead of full page reload.
 *
 * Loaded idempotently by doc.js / grill.js (same pattern as mermaid-zoom).
 * Replaces live-server's full-page reload with a fade-in DOM morph that
 * preserves scroll, focus, and already-rendered Mermaid SVGs.
 *
 * WS-intercept strategy
 * ─────────────────────
 * live-server injects /livereload.js into every served HTML; on a `reload`
 * WebSocket message it calls `window.location.reload()`. We don't try to
 * race that injected script — instead we *monkey-patch* `window.location
 * .reload` the instant our module runs. The injected client's call then
 * funnels through our shim, which runs the morph instead. Defense-in-depth:
 * we also wrap the WebSocket constructor so any future live-reload variant
 * that emits a JSON {command:"reload"} frame is caught directly.
 *
 * If `window.LIVE_RENDER_DISABLED` is truthy, or if anything in the morph
 * throws, we fall through to the original reload — the system never gets
 * stuck on a bad morph.
 *
 * Scope: vanilla JS, no deps, ~150 lines. The morph diff operates on
 * direct children of <body> only; nested edits replace the whole top-level
 * child rather than recursing.
 */
(function () {
  if (window.__liveRenderLoaded) return;
  window.__liveRenderLoaded = true;

  // ── 1. Bypass switch ───────────────────────────────────────────────
  if (window.LIVE_RENDER_DISABLED) return;

  // ── 2. Capture the original reload BEFORE we patch it ──────────────
  const originalReload = window.location.reload.bind(window.location);

  // ── 3. Monkey-patch reload so live-server's call funnels here ──────
  try {
    // location.reload is non-configurable in some browsers; wrap via Object
    // .defineProperty on the prototype where possible, fall back to direct
    // assignment which works on Chromium/Safari for non-strict pages.
    window.location.reload = function patchedReload() {
      scheduleMorph();
    };
  } catch (e) {
    // If the assignment fails, we still have the WS-constructor fallback.
    console.warn("live-render: could not patch location.reload", e);
  }

  // ── 4. Defense-in-depth: hook WebSocket to catch reload messages ───
  // live-server's WS messages look like {"command":"reload","path":"…"}.
  const NativeWS = window.WebSocket;
  if (NativeWS) {
    function PatchedWS(url, protocols) {
      const ws = protocols ? new NativeWS(url, protocols) : new NativeWS(url);
      // Only intercept the live-reload socket; leave others untouched.
      if (typeof url === "string" && /\/livereload\b/.test(url)) {
        ws.addEventListener("message", (ev) => {
          try {
            const msg = JSON.parse(ev.data);
            if (msg && msg.command === "reload") {
              scheduleMorph();
            }
          } catch (_) { /* ignore non-JSON frames */ }
        });
      }
      return ws;
    }
    PatchedWS.prototype = NativeWS.prototype;
    PatchedWS.CONNECTING = NativeWS.CONNECTING;
    PatchedWS.OPEN = NativeWS.OPEN;
    PatchedWS.CLOSING = NativeWS.CLOSING;
    PatchedWS.CLOSED = NativeWS.CLOSED;
    try { window.WebSocket = PatchedWS; } catch (_) { /* leave as-is */ }
  }

  // ── 5. Scheduling: coalesce, defer during input ────────────────────
  let pending = false;
  let inFlight = false;

  function isUserTyping() {
    const a = document.activeElement;
    if (!a) return false;
    const tag = a.tagName;
    if (tag === "TEXTAREA" || tag === "INPUT") return true;
    if (a.isContentEditable) return true;
    return false;
  }

  function scheduleMorph() {
    if (pending) return;
    pending = true;
    if (isUserTyping()) {
      // Defer: when focus leaves, run the latest version.
      const onBlur = () => {
        document.removeEventListener("focusout", onBlur, true);
        pending = false;
        scheduleMorph();
      };
      document.addEventListener("focusout", onBlur, true);
      return;
    }
    // Coalesce bursts: many fs writes in quick succession → one fetch.
    requestAnimationFrame(() => {
      pending = false;
      runMorph();
    });
  }

  // ── 6. Stable-key extraction ───────────────────────────────────────
  function keyOf(node, idx) {
    if (node.nodeType !== 1) return `__txt:${idx}`;
    if (node.id) return `id:${node.id}`;
    if (node.dataset && node.dataset.lrKey) return `k:${node.dataset.lrKey}`;
    if (node.dataset && node.dataset.mzKey) return `mz:${node.dataset.mzKey}`;
    const tag = node.tagName.toLowerCase();
    if (tag === "script") return `script:${idx}`;
    const text = (node.textContent || "").trim().slice(0, 100);
    return `${tag}:${text || idx}`;
  }

  function buildKeyMap(parent) {
    const m = new Map();
    let i = 0;
    for (const child of parent.children) {
      const k = keyOf(child, i++);
      // First-wins; if the page has duplicate keys we accept some misses.
      if (!m.has(k)) m.set(k, child);
    }
    return m;
  }

  // ── 7. Fetch + morph ───────────────────────────────────────────────
  async function runMorph() {
    if (inFlight) return;
    inFlight = true;
    try {
      const res = await fetch(location.href, { cache: "no-store" });
      if (!res.ok) throw new Error(`fetch ${res.status}`);
      const html = await res.text();
      const newDoc = new DOMParser().parseFromString(html, "text/html");

      const scrollY = window.scrollY;

      morphBody(document.body, newDoc.body);

      // Title sync
      if (newDoc.title && newDoc.title !== document.title) {
        document.title = newDoc.title;
      }

      // Restore scroll (the morph may have inserted/removed children).
      window.scrollTo(0, scrollY);

      // Re-run Mermaid only on freshly-added pre.mermaid that have no SVG yet.
      rerunMermaidOnFresh();

      // Strip .lr-fresh after the animation completes.
      setTimeout(() => {
        document.querySelectorAll(".lr-fresh").forEach(n => n.classList.remove("lr-fresh"));
      }, 320);
    } catch (e) {
      console.warn("live-render: morph failed, falling back to reload", e);
      originalReload();
    } finally {
      inFlight = false;
    }
  }

  // ── 8. The morph itself ────────────────────────────────────────────
  // Predicates for nodes the morph must NEVER touch in the live DOM:
  //   - .doc-action (action bar injected by doc.js at runtime)
  //   - .mz-modal (mermaid-zoom modal, also runtime-injected)
  //   - [data-lr-skip] (explicit author opt-out)
  function isPreserved(node) {
    if (node.nodeType !== 1) return false;
    if (node.classList && (node.classList.contains("doc-action") ||
                           node.classList.contains("mz-modal"))) return true;
    if (node.hasAttribute && node.hasAttribute("data-lr-skip")) return true;
    return false;
  }

  function morphBody(liveBody, newBody) {
    const liveKeys = buildKeyMap(liveBody);
    const newChildren = Array.from(newBody.children);

    // Walk the new doc in order, anchoring each child against the live DOM.
    let anchor = liveBody.firstElementChild;
    const seen = new Set();

    for (let i = 0; i < newChildren.length; i++) {
      const newChild = newChildren[i];
      // Never re-execute scripts on morph — they ran once at initial load.
      if (newChild.tagName === "SCRIPT") {
        // Skip past any matching live <script> too, so the anchor stays sane.
        if (anchor && anchor.tagName === "SCRIPT") {
          seen.add(keyOf(anchor, -1));
          anchor = anchor.nextElementSibling;
        }
        continue;
      }

      // Skip past any preserved live nodes we hit while walking.
      while (anchor && isPreserved(anchor)) {
        seen.add(keyOf(anchor, -1));
        anchor = anchor.nextElementSibling;
      }

      const k = keyOf(newChild, i);
      const match = liveKeys.get(k);

      if (match && !isPreserved(match)) {
        seen.add(k);
        // Replace inner content if the outerHTML differs — but only when
        // the live node is NOT a freshly-rendered Mermaid container.
        const isRenderedMermaid =
          match.tagName === "PRE" && match.classList.contains("mermaid") &&
          (match.querySelector("svg") || match.getAttribute("data-processed") === "true");
        const isFigureWithRenderedMermaid =
          match.tagName === "FIGURE" &&
          match.querySelector("pre.mermaid svg");

        if (!isRenderedMermaid && !isFigureWithRenderedMermaid &&
            match.outerHTML !== newChild.outerHTML) {
          const fresh = newChild.cloneNode(true);
          fresh.classList && fresh.classList.add("lr-fresh");
          match.replaceWith(fresh);
          // Advance anchor past the replaced node.
          anchor = fresh.nextElementSibling;
        } else {
          // Leave untouched; advance anchor past it.
          if (anchor === match) anchor = anchor.nextElementSibling;
        }
      } else {
        // No matching live node — insert before the current anchor with fade.
        const fresh = newChild.cloneNode(true);
        if (fresh.nodeType === 1) fresh.classList.add("lr-fresh");
        liveBody.insertBefore(fresh, anchor);
        // anchor unchanged — the inserted node sits before it.
      }
    }

    // Remove live children whose keys vanished from the new doc.
    Array.from(liveBody.children).forEach((child, i) => {
      if (isPreserved(child)) return;
      if (child.tagName === "SCRIPT") return;
      const k = keyOf(child, i);
      if (!seen.has(k) && !newChildren.find((nc, j) => keyOf(nc, j) === k)) {
        child.remove();
      }
    });
  }

  // ── 9. Re-run Mermaid on freshly-added diagrams only ───────────────
  function rerunMermaidOnFresh() {
    if (!window.mermaid || typeof window.mermaid.run !== "function") return;
    const fresh = Array.from(document.querySelectorAll(".lr-fresh pre.mermaid, .lr-fresh.mermaid"));
    // Also catch pre.mermaid inside .lr-fresh figures.
    const candidates = fresh.filter(n => !n.querySelector("svg") &&
                                         n.getAttribute("data-processed") !== "true");
    if (!candidates.length) return;
    try {
      window.mermaid.run({ nodes: candidates });
    } catch (e) {
      console.warn("live-render: mermaid.run failed", e);
    }
  }
})();
