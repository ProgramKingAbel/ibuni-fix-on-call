#!/usr/bin/env node
/**
 * Templates the deployable artifacts into dist/ (gitignored).
 *
 *   node infra/build.mjs <repo-root> <secret-current> [secret-prev]
 *
 * Node rather than the GCA original's `python3` heredoc: `python3` on this
 * machine is the Windows Store stub, so that heredoc dies immediately. Node 22
 * is already a project prerequisite (serve.mjs), and a committed file can be
 * read and `node --check`ed, unlike a heredoc.
 *
 * Produces:
 *   dist/index.html          — CONFIG flipped to the lambda backend. No secret.
 *   dist/cf-session-gate.js  — CloudFront Function with the signing keys baked in.
 *
 * dist/index.html is NOT sensitive (unlike GCA's, which carried a shared secret).
 * dist/cf-session-gate.js IS — it contains the session signing keys.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

const [, , root, cur, prev = ''] = process.argv;
if (!root || !cur) {
  console.error('usage: node infra/build.mjs <repo-root> <secret-current> [secret-prev]');
  process.exit(1);
}

const dist = join(root, 'dist');
mkdirSync(dist, { recursive: true });

/* ---- index.html ---------------------------------------------------------- */
let html = readFileSync(join(root, 'index.html'), 'utf8');
const before = html;

html = html.replace("backend: 'local',", "backend: 'lambda',");
html = html.replace(/endpoint: '[^']*',/, "endpoint: '/api/comments',");
html = html.replace(/authEndpoint: '[^']*',/, "authEndpoint: '/api',");

// Fail loudly rather than shipping a page still pointed at localStorage.
if (html === before) {
  console.error('build: CONFIG substitution matched nothing — did the CONFIG block change?');
  process.exit(1);
}
if (!/backend: 'lambda',/.test(html)) {
  console.error("build: backend was not flipped to 'lambda'");
  process.exit(1);
}
writeFileSync(join(dist, 'index.html'), html);

/* ---- cf-session-gate.js -------------------------------------------------- */
let fn = readFileSync(join(root, 'infra/cf-session-gate.js'), 'utf8');
if (!fn.includes('__SECRET_CURRENT__')) {
  console.error('build: cf-session-gate.js has no __SECRET_CURRENT__ placeholder');
  process.exit(1);
}
fn = fn.replace('__SECRET_CURRENT__', cur).replace('__SECRET_PREV__', prev);
writeFileSync(join(dist, 'cf-session-gate.js'), fn);

// CloudFront Functions cap at 10 KB of source.
const size = Buffer.byteLength(fn, 'utf8');
if (size > 10000) {
  console.error(`build: cf-session-gate.js is ${size} bytes — over the 10 KB CloudFront Function limit`);
  process.exit(1);
}

console.log(`build: dist/index.html (${(Buffer.byteLength(html) / 1024).toFixed(0)} KB), dist/cf-session-gate.js (${size} B)`);
