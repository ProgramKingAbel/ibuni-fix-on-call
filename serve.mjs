#!/usr/bin/env node
/**
 * Fix On Call — zero-dependency local dev server.
 *
 *   node serve.mjs            → http://localhost:8080
 *   PORT=3000 node serve.mjs  → custom port
 *
 * Uses only Node built-ins (no npm install). Features:
 *   • Static file serving from this directory
 *   • Live reload — saves to .html/.css/.js refresh the browser automatically
 *     (a tiny script is injected into served HTML; it listens on /__livereload)
 *   • /api proxy stub — COMMENTED OUT below. Uncomment + set LAMBDA_URL once the
 *     comment backend exists, so local fetch('/api/...') avoids CORS in dev.
 *
 * Why serve over http instead of opening the file directly:
 * on file:// the page origin is "null", which CORS rejects — so once a hosted
 * comment backend is wired up, fetch() only works cleanly over http://localhost.
 */
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { watch } from 'node:fs';
import { extname, join, normalize, resolve } from 'node:path';
// import { request as httpsRequest } from 'node:https'; // for /api proxy

const ROOT = resolve(import.meta.dirname);
const PORT = Number(process.env.PORT) || 8080;

// const LAMBDA_URL = process.env.LAMBDA_URL || ''; // e.g. https://xxxx.lambda-url.<region>.on.aws

const MIME = {
  '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
  '.mjs':'text/javascript; charset=utf-8', '.css':'text/css; charset=utf-8',
  '.json':'application/json; charset=utf-8', '.svg':'image/svg+xml',
  '.png':'image/png', '.jpg':'image/jpeg', '.jpeg':'image/jpeg',
  '.gif':'image/gif', '.ico':'image/x-icon', '.woff2':'font/woff2',
  '.map':'application/json; charset=utf-8',
};

// ---- live reload: hold open SSE clients, ping them when files change --------
const clients = new Set();
function notifyReload() { for (const res of clients) res.write('data: reload\n\n'); }

let debounce;
watch(ROOT, { recursive: true }, (_e, file) => {
  if (!file || file === 'serve.mjs') return;            // ignore self
  if (!/\.(html|css|js|mjs|svg)$/.test(file)) return;
  clearTimeout(debounce);
  debounce = setTimeout(() => { console.log('↻ change:', file); notifyReload(); }, 80);
});

const LIVE_RELOAD_SNIPPET = `
<script>
(()=>{ // injected by serve.mjs — dev only
  const es = new EventSource('/__livereload');
  es.onmessage = () => location.reload();
  es.onerror = () => { es.close(); setTimeout(()=>location.reload(), 1500); };
})();
</script>`;

// ---- safe path resolution (no directory traversal) -------------------------
function safePath(urlPath) {
  const clean = normalize(decodeURIComponent(urlPath.split('?')[0])).replace(/^(\.\.[/\\])+/, '');
  const full = join(ROOT, clean === '/' ? 'index.html' : clean);
  return full.startsWith(ROOT) ? full : null;
}

const server = createServer(async (req, res) => {
  // live-reload event stream
  if (req.url === '/__livereload') {
    res.writeHead(200, { 'Content-Type':'text/event-stream', 'Cache-Control':'no-cache', 'Connection':'keep-alive' });
    res.write('\n'); clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  /* ---- /api proxy stub — uncomment when the comment backend exists --------
  if (req.url.startsWith('/api/')) {
    if (!LAMBDA_URL) { res.writeHead(503).end('Set LAMBDA_URL to enable the /api proxy'); return; }
    const target = new URL(LAMBDA_URL + req.url.replace(/^\/api/, ''));
    const chunks = []; req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const upstream = httpsRequest(target, {
        method: req.method,
        headers: { 'content-type':'application/json', 'x-shared-secret': process.env.SHARED_SECRET || '' },
      }, up => { res.writeHead(up.statusCode, up.headers); up.pipe(res); });
      upstream.on('error', e => { res.writeHead(502).end('proxy error: ' + e.message); });
      if (chunks.length) upstream.write(Buffer.concat(chunks));
      upstream.end();
    });
    return;
  }
  -------------------------------------------------------------------------- */

  const path = safePath(req.url);
  if (!path) { res.writeHead(403).end('Forbidden'); return; }

  try {
    let target = path;
    if ((await stat(target)).isDirectory()) target = join(target, 'index.html');
    let data = await readFile(target);
    const ext = extname(target).toLowerCase();
    const type = MIME[ext] || 'application/octet-stream';
    if (ext === '.html') data = Buffer.from(data.toString('utf8') + LIVE_RELOAD_SNIPPET);
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control':'no-store' });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type':'text/html; charset=utf-8' });
    res.end('<h1>404</h1><p>Not found: ' + req.url + '</p>' + LIVE_RELOAD_SNIPPET);
  }
});

server.listen(PORT, () => {
  console.log(`\n  Fix On Call — Platform Overview dev server`);
  console.log(`  → http://localhost:${PORT}\n  (live reload on; Ctrl+C to stop)\n`);
});
