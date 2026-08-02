# ibuni-fix-on-call

Fix On Call — **Platform Overview**. A single, self-contained HTML page (`index.html`):
a confidential, shareable living document for the Fix On Call roadside assistance platform.
Inline CSS + JS, Google Fonts via CDN, no build step.

See `CLAUDE.md` for the full project context, naming taxonomy and design notes.

## Local development

Node 22+ (uses built-ins only — no `npm install`):

```bash
node serve.mjs                 # → http://localhost:8080
PORT=3000 node serve.mjs       # custom port
```

The dev server serves `index.html` over HTTP with **live reload** (saves to
`.html/.css/.js` refresh the browser automatically).

> **Why not just open the file?** `index.html` works fine via `file://` while the
> comment system uses its `localStorage` backend. But once comments are wired to a
> hosted backend, `fetch()` + CORS only behave correctly over `http://localhost`
> (on `file://` the origin is `null`, which CORS rejects).

### `/api` proxy (for later)

`serve.mjs` contains a commented-out `/api/*` proxy stub. When the comment backend
exists, uncomment it and run with the endpoint URL so local `fetch('/api/...')` calls
avoid CORS during development:

```bash
LAMBDA_URL=https://xxxx.lambda-url.<region>.on.aws SHARED_SECRET=… node serve.mjs
```

## Comment system

In-page commenting is anchored, versioned, and backed by a **swappable storage
adapter** (`CONFIG.backend` in `index.html`): `local` (localStorage, default for dev)
or `lambda` (a hosted Function URL behind a shared secret). Comments are per document
version, can be resolved, and open comments auto-carry-forward to the newest version.

Click **Add comment**, then click any highlighted block on the page. Console helpers:
`FOC.clearComments()`, `FOC.dumpComments()`.

## Cutting a new version

1. Copy the current `#doc-content` markup into `versions/v0.1.html` (or whatever the
   outgoing id is).
2. In `VERSIONS`, flip that entry to `current:false` and set `file:'versions/v0.1.html'`.
3. Add the new entry with `current:true, file:null`, and update `CONFIG.currentVersion`
   and the footer's document/date metadata.

## Deployment

Not yet deployed. Intended: static site → private object storage + CDN, password-gated
at the edge; comments via a function + table behind a shared secret. See `CLAUDE.md`.
