import { readFileSync } from 'node:fs';

// Comment anchor ids (computeElId) hash an element's ancestor tag-chain + same-tag
// sibling indices + its text, terminating at the nearest id'd ancestor. So inside
// #doc-content, ONLY class values and non-id attributes may change. Anything that
// alters structure, ids or text silently orphans stored comments.
const cut = s => {
  const a = s.indexOf('<div id="doc-content">');
  const b = s.indexOf('</div><!-- /#doc-content -->');
  if (a < 0 || b < 0) throw new Error('doc-content markers not found');
  return s.slice(a, b);
};

const before = cut(readFileSync(process.argv[2], 'utf8'));
const after  = cut(readFileSync(process.argv[3], 'utf8'));

if (before === after) {
  console.log('ANCHOR-SAFE: #doc-content is byte-identical. No el-* id can have changed.');
  process.exit(0);
}

// Not identical — is every difference confined to class attribute values?
const stripClasses = s => s.replace(/\sclass="[^"]*"/g, ' class="~"');
if (stripClasses(before) === stripClasses(after)) {
  console.log('ANCHOR-SAFE: only class attribute values differ.');
  // show what changed, for the record
  const cb = [...before.matchAll(/\sclass="([^"]*)"/g)].map(m => m[1]);
  const ca = [...after.matchAll(/\sclass="([^"]*)"/g)].map(m => m[1]);
  cb.forEach((v, i) => { if (v !== ca[i]) console.log(`  class[${i}]: "${v}" -> "${ca[i]}"`); });
  process.exit(0);
}

console.log('ANCHOR RISK: #doc-content differs beyond class values.');
const lb = before.split('\n'), la = after.split('\n');
let shown = 0;
for (let i = 0; i < Math.max(lb.length, la.length) && shown < 25; i++) {
  if (lb[i] !== la[i]) {
    console.log(`  line ${i}:\n    - ${(lb[i] || '').trim().slice(0, 150)}\n    + ${(la[i] || '').trim().slice(0, 150)}`);
    shown++;
  }
}
process.exit(1);
