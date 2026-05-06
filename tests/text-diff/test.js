#!/usr/bin/env node
/* Unit tests for lib/text-diff.js — pure Node, no test runner. */
'use strict';

const path = require('path');
const td = require(path.resolve(__dirname, '..', '..', 'lib', 'text-diff.js'));

let passed = 0, failed = 0;

function assert(name, ok, detail) {
  if (ok) { passed++; console.log(`  ✓ ${name}`); }
  else    { failed++; console.error(`  ✗ ${name}${detail ? '\n      ' + detail : ''}`); }
}

function deep(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

console.log('text-diff tests:');

// 1) Identical input → all context.
{
  const out = td.diff('one\ntwo\nthree\n', 'one\ntwo\nthree\n');
  assert('identical input → all context',
    out.length === 3 && out.every(c => c.type === 'context'),
    JSON.stringify(out));
}

// 2) Pure addition.
{
  const out = td.diff('a\nb\n', 'a\nb\nc\n');
  assert('pure addition tail',
    deep(out, [
      { type: 'context', text: 'a' },
      { type: 'context', text: 'b' },
      { type: 'added',   text: 'c' }
    ]), JSON.stringify(out));
}

// 3) Pure deletion.
{
  const out = td.diff('a\nb\nc\n', 'a\nc\n');
  assert('pure deletion middle',
    deep(out, [
      { type: 'context', text: 'a' },
      { type: 'removed', text: 'b' },
      { type: 'context', text: 'c' }
    ]), JSON.stringify(out));
}

// 4) Replacement (one line removed, one added).
{
  const out = td.diff('a\nold\nz\n', 'a\nnew\nz\n');
  // The LCS picks ['a','z'] as common; "old" → removed, "new" → added.
  // Order of the +/- pair is implementation-detail; assert the membership.
  const types = out.map(c => c.type);
  const texts = out.map(c => c.text).sort();
  assert('replaced line present',
    types.filter(t => t === 'context').length === 2 &&
    types.filter(t => t === 'added'  ).length === 1 &&
    types.filter(t => t === 'removed').length === 1 &&
    deep(texts, ['a', 'new', 'old', 'z']),
    JSON.stringify(out));
}

// 5) Empty inputs.
{
  assert('both empty → []', deep(td.diff('', ''), []),
    JSON.stringify(td.diff('', '')));
  assert('empty old → all added',
    deep(td.diff('', 'a\nb\n'), [
      { type: 'added', text: 'a' },
      { type: 'added', text: 'b' }
    ]));
  assert('empty new → all removed',
    deep(td.diff('a\nb\n', ''), [
      { type: 'removed', text: 'a' },
      { type: 'removed', text: 'b' }
    ]));
}

// 6) diffLines op-shape mirror.
{
  const out = td.diffLines('a\nb\n', 'a\nc\n');
  const ops = out.map(c => c.op).sort();
  // {context:a, removed:b, added:c} → ops = ['=','-','+'] (any order)
  assert('diffLines op shape', deep(ops, ['+', '-', '=']),
    JSON.stringify(out));
}

// 7) formatDiffHtml emits the expected envelope and classes.
{
  const html = td.formatDiffHtml(td.diff('a\n', 'b\n'));
  assert('formatDiffHtml envelope',
    html.startsWith('<pre class="diff">') && html.endsWith('</pre>'),
    html);
  assert('formatDiffHtml escapes',
    td.formatDiffHtml([{ type: 'added', text: '<script>alert(1)</script>' }])
      .includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
  assert('formatDiffHtml classes',
    html.includes('diff-removed') && html.includes('diff-added'));
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
