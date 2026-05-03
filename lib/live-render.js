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

  // Classes the morph must NEVER remove or replace once present in the
  // live DOM. See isPreserved() below.
  //   - doc-action : action bar injected by doc.js at runtime
  //   - mz-modal   : mermaid-zoom modal, runtime-injected, must not be
  //                  yanked mid-zoom
  //   - lr-fresh   : live-render's own fade-in marker; the existing
  //                  animation-end handler removes it once the fade
  //                  completes — re-replacing it would re-trigger the
  //                  animation mid-flight
  const PRESERVED_CLASSES = ["doc-action", "mz-modal", "lr-fresh"];

  // Maximum time we'll defer a morph while an input is focused before
  // applying anyway. 30s is long enough that a normal pause-while-typing
  // never trips it, but short enough that an idle-but-focused field
  // doesn't strand stale content.
  const FOCUS_DEFER_MAX_MS = 30000;

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
      // Hard cap: if focus persists past FOCUS_DEFER_MAX_MS, apply anyway
      // so an idle-but-focused field can't strand stale content forever.
      let timer = null;
      const cleanup = () => {
        document.removeEventListener("focusout", onBlur, true);
        if (timer !== null) { clearTimeout(timer); timer = null; }
      };
      const onBlur = () => {
        cleanup();
        pending = false;
        scheduleMorph();
      };
      document.addEventListener("focusout", onBlur, true);
      timer = setTimeout(() => {
        cleanup();
        console.warn("[live-render] morph deferred 30s while focused; applying anyway");
        // Run directly — don't bounce through scheduleMorph(), since
        // isUserTyping() would still defer us again.
        requestAnimationFrame(() => {
          pending = false;
          runMorph();
        });
      }, FOCUS_DEFER_MAX_MS);
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
  // Predicates for nodes the morph must NEVER touch in the live DOM.
  // See PRESERVED_CLASSES above for the canonical list.
  // [data-lr-skip] is the explicit author opt-out.
  function isPreserved(node) {
    if (node.nodeType !== 1) return false;
    if (node.classList) {
      for (const cls of PRESERVED_CLASSES) {
        if (node.classList.contains(cls)) return true;
      }
    }
    if (node.hasAttribute && node.hasAttribute("data-lr-skip")) return true;
    return false;
  }

  // Hash a string with a fast 32-bit rolling hash. Stable across page loads
  // (no Math.random / no crypto), suitable for "did the Mermaid source
  // change?" equality checks. Collisions are theoretically possible but
  // ignorable for diagram-source-sized inputs.
  function hashStr(s) {
    return [...(s || "")].reduce(
      (h, c) => Math.imul(31, h) + c.charCodeAt(0) | 0, 0);
  }

  // Extract the canonical Mermaid source from a pre.mermaid element.
  // Mermaid 10 stores the source as the element's textContent before render.
  // After render, textContent is the rendered SVG text — useless for hashing.
  // So we only call this on:
  //   - incoming (newDoc) nodes, which are always pre-render (just parsed
  //     HTML, no Mermaid run yet), or
  //   - live nodes whose data-processed is NOT "true" and which have no svg
  //     descendant (i.e. not yet rendered).
  function mermaidSourceOf(preEl) {
    if (!preEl) return "";
    // Some authors wrap the source in <code>; strip whitespace either way.
    const code = preEl.querySelector("code");
    const raw = (code ? code.textContent : preEl.textContent) || "";
    return raw.trim();
  }

  // Detect the "this pre.mermaid is rendered" condition once, since we
  // check it from multiple call sites.
  function isRenderedMermaidEl(el) {
    return el && el.tagName === "PRE" && el.classList.contains("mermaid") &&
           (el.querySelector("svg") || el.getAttribute("data-processed") === "true");
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
        // Special-case Mermaid containers: a rendered <pre class="mermaid">
        // has had its source replaced with the SVG, so a naive outerHTML
        // diff will always say "different" and re-replace the node — which
        // wipes the rendered diagram on every morph. Instead, hash the
        // source from the incoming node and compare against the stored
        // hash on the live node. Edits to the source ⇒ replace; otherwise
        // keep the rendered SVG.
        const liveMermaid =
          (match.tagName === "PRE" && match.classList.contains("mermaid"))
            ? match
            : (match.tagName === "FIGURE"
                ? match.querySelector("pre.mermaid")
                : null);
        const newMermaid =
          (newChild.tagName === "PRE" && newChild.classList.contains("mermaid"))
            ? newChild
            : (newChild.tagName === "FIGURE"
                ? newChild.querySelector("pre.mermaid")
                : null);

        if (liveMermaid && newMermaid && isRenderedMermaidEl(liveMermaid)) {
          const newHash = String(hashStr(mermaidSourceOf(newMermaid)));
          const liveHash = liveMermaid.dataset.mzSrcHash;

          if (liveHash && liveHash === newHash) {
            // Source unchanged → keep the rendered SVG, advance anchor.
            if (anchor === match) anchor = anchor.nextElementSibling;
          } else if (!liveHash) {
            // First time we've seen this rendered diagram — adopt the
            // incoming source hash as the baseline so future morphs can
            // detect edits. Don't replace this round.
            liveMermaid.dataset.mzSrcHash = newHash;
            if (anchor === match) anchor = anchor.nextElementSibling;
          } else {
            // Source changed → replace, stamping the new hash so Mermaid's
            // re-render starts from a known baseline.
            const fresh = newChild.cloneNode(true);
            const freshMermaid =
              (fresh.tagName === "PRE" && fresh.classList.contains("mermaid"))
                ? fresh
                : fresh.querySelector && fresh.querySelector("pre.mermaid");
            if (freshMermaid) freshMermaid.dataset.mzSrcHash = newHash;
            fresh.classList && fresh.classList.add("lr-fresh");
            match.replaceWith(fresh);
            anchor = fresh.nextElementSibling;
          }
        } else if (match.outerHTML !== newChild.outerHTML) {
          const fresh = newChild.cloneNode(true);
          // Pre-stamp any pre.mermaid in the fresh subtree so its first
          // post-render morph has a baseline.
          const freshMermaid = fresh.nodeType === 1 && fresh.querySelector
            ? (fresh.matches && fresh.matches("pre.mermaid")
                ? fresh
                : fresh.querySelector("pre.mermaid"))
            : null;
          if (freshMermaid) {
            freshMermaid.dataset.mzSrcHash =
              String(hashStr(mermaidSourceOf(freshMermaid)));
          }
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
        // Pre-stamp Mermaid source hash so the next morph can diff cleanly.
        const freshMermaid = fresh.nodeType === 1 && fresh.querySelector
          ? (fresh.matches && fresh.matches("pre.mermaid")
              ? fresh
              : fresh.querySelector("pre.mermaid"))
          : null;
        if (freshMermaid) {
          freshMermaid.dataset.mzSrcHash =
            String(hashStr(mermaidSourceOf(freshMermaid)));
        }
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
