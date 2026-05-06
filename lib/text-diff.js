/* paperflow text-diff — line-level LCS, vendored, no deps.
 *
 * Exports:
 *   diff(oldText, newText)        → [{type,text}, …]   structured chunks
 *   diffLines(oldText, newText)   → [{op,text}, …]     op∈{=,+,-} alias view
 *   formatDiffHtml(chunks)        → "<pre class=\"diff\">…</pre>"  for the
 *                                   bridge GET /diff endpoint
 *
 * The two array shapes are aliases of each other; `op:"="` ↔ `type:"context"`,
 * `op:"+"` ↔ `type:"added"`, `op:"-"` ↔ `type:"removed"`. Both are exported
 * because the plan + brief use both names — and consumers vary.
 *
 * Algorithm: classic dynamic-programming LCS over the two line arrays. For
 * typical paperflow doc diffs (a few hundred lines either side) the O(n·m)
 * grid is trivial. No external runtime needed.
 */

'use strict';

function splitLines(s) {
  if (s == null) return [];
  const arr = String(s).split('\n');
  if (arr.length && arr[arr.length - 1] === '') arr.pop();
  return arr;
}

function diffChunks(a, b) {
  const m = a.length, n = b.length;
  const dp = new Array(m + 1);
  for (let i = 0; i <= m; i++) dp[i] = new Int32Array(n + 1);
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      if (a[i - 1] === b[j - 1]) dp[i][j] = dp[i - 1][j - 1] + 1;
      else dp[i][j] = dp[i - 1][j] >= dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
    }
  }
  const rev = [];
  let i = m, j = n;
  while (i > 0 && j > 0) {
    if (a[i - 1] === b[j - 1]) {
      rev.push({ type: 'context', text: a[i - 1] });
      i--; j--;
    } else if (dp[i - 1][j] >= dp[i][j - 1]) {
      rev.push({ type: 'removed', text: a[i - 1] });
      i--;
    } else {
      rev.push({ type: 'added', text: b[j - 1] });
      j--;
    }
  }
  while (i > 0) { rev.push({ type: 'removed', text: a[i - 1] }); i--; }
  while (j > 0) { rev.push({ type: 'added',   text: b[j - 1] }); j--; }
  return rev.reverse();
}

function diff(oldText, newText) {
  return diffChunks(splitLines(oldText), splitLines(newText));
}

function diffLines(oldText, newText) {
  return diff(oldText, newText).map(c => ({
    op: c.type === 'context' ? '=' : (c.type === 'added' ? '+' : '-'),
    text: c.text
  }));
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function formatDiffHtml(chunks) {
  const lines = chunks.map(c => {
    const cls = c.type === 'context' ? 'diff-context'
              : c.type === 'added'   ? 'diff-added'
              :                        'diff-removed';
    const prefix = c.type === 'context' ? '  '
                 : c.type === 'added'   ? '+ '
                 :                        '- ';
    return `<div class="diff-line ${cls}">${esc(prefix + c.text)}</div>`;
  });
  return `<pre class="diff">${lines.join('')}</pre>`;
}

module.exports = { diff, diffLines, formatDiffHtml };
