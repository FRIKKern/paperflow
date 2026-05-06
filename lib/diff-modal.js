/* paperflow diff-modal — viewer for the bridge's GET /diff response.
 *
 * Exposes window.openPaperflowDiff(idA, idB). The rail (lib/goal-path-rail.js)
 * calls this when the user shift-clicks two distinct event nodes. The bridge
 * does the actual diffing via lib/text-diff.js — this module only renders.
 *
 * Backdrop click + ESC + close button all dismiss.
 */
(function () {
  if (window.__paperflowDiffModalLoaded) return;
  window.__paperflowDiffModalLoaded = true;

  const BRIDGE = 'http://localhost:8766';
  let modal, body, head, escHandler;

  function ensureModal() {
    if (modal) return modal;
    modal = document.createElement('div');
    modal.className = 'paperflow-diff-modal';
    modal.innerHTML = `
      <div class="paperflow-diff-panel" role="dialog" aria-label="Event diff">
        <div class="paperflow-diff-head">
          <span class="paperflow-diff-title"></span>
          <button class="paperflow-diff-close" type="button" aria-label="Close">✕</button>
        </div>
        <div class="paperflow-diff-body"></div>
      </div>`;
    document.body.appendChild(modal);
    body = modal.querySelector('.paperflow-diff-body');
    head = modal.querySelector('.paperflow-diff-title');
    modal.addEventListener('click', e => {
      if (e.target === modal) close();
    });
    modal.querySelector('.paperflow-diff-close').addEventListener('click', close);
    return modal;
  }

  function close() {
    if (!modal) return;
    modal.classList.remove('is-open');
    if (escHandler) {
      document.removeEventListener('keydown', escHandler, true);
      escHandler = null;
    }
  }

  async function open(idA, idB) {
    if (!idA || !idB || idA === idB) return;
    ensureModal();
    head.textContent = `${idA}  →  ${idB}`;
    body.innerHTML = '<div class="diff-line diff-context">  loading…</div>';
    modal.classList.add('is-open');
    escHandler = e => { if (e.key === 'Escape') close(); };
    document.addEventListener('keydown', escHandler, true);
    try {
      const r = await fetch(`${BRIDGE}/diff?from=${encodeURIComponent(idA)}&to=${encodeURIComponent(idB)}`);
      const j = await r.json();
      if (j && j.diffHtml) {
        body.innerHTML = j.diffHtml;
      } else {
        body.innerHTML = `<div class="diff-line diff-removed">  error: ${(j && j.error) || 'no diff'}</div>`;
      }
    } catch (e) {
      body.innerHTML = `<div class="diff-line diff-removed">  error: ${String(e && e.message || e)}</div>`;
    }
  }

  window.openPaperflowDiff = open;
  window.closePaperflowDiff = close;
})();
