# Fix On Call — Platform Overview · Project Context & Handoff

This file is the handoff for continuing work on the **Fix On Call Platform Overview** site.
It is written as `CLAUDE.md` so Claude Code loads it automatically at session start.

---

## What this project is

The deliverable is a single, self-contained HTML page: the **Fix On Call Platform Overview**.
It is a *confidential, shareable "living document"* for the executive team, partners and
(in time) investors — explaining what the platform is, who it serves, how it fits together,
and the path to delivery — and a vehicle for collecting their feedback.

- **File:** `index.html`
- It is intentionally **one self-contained file**: inline CSS + JS, Google Fonts via CDN, no
  build step, no dependencies. It can be emailed, opened locally, or hosted anywhere. Keep it
  self-contained unless there is a strong reason to split it.

The page was committed to at the first executive meeting (31 July 2026): Abel, as CTO, owns
producing and circulating a "living document / web portal" capturing problem, solution, core
features, distribution and department-specific input, that others can comment on directly.

---

## Naming taxonomy (use exactly — this has been deliberately set)

- **Fix On Call** — the platform and the company. Kenyan roadside assistance marketplace.
- **Driver** — the motorist requesting help. The demand side. (Not "customer", not "user".)
- **Mechanic** — the vetted independent mechanic / tow operator / fuel supplier taking jobs.
  The supply side. "Service provider" is acceptable as a broader synonym.
- **Driver App** — the driver-facing mobile app (Android & iOS).
- **Mechanic App** — the provider-facing mobile app (Android & iOS).
- **Operations Console** — the internal web admin surface. (Not "admin panel" on the page.)
- **Partner Portal** — the planned workspace for insurers, fleets, fuel retailers, garages.
- **Dispatch Core** — the backend system of record and matching engine.
- **Service Request** — one rescue job, request through settlement. The central record.

---

## Brand & design

Brand tokens were lifted from the live site (`getfixoncall.com`) via a saved `.mhtml`:

- **Colours** (CSS `:root`): rescue red `#FF4D3A` (hover `#F13F2C`, theme primary `#DC2626`);
  dark navy `#080B14` → `#0B1220`; gold `#B08B4F` (used for the open-question callouts).
  On light backgrounds the accent is deepened to `--red-ink: #CE3320` so small text passes
  contrast (4.7:1 on `--paper`). Full token set is at the top of the `<style>` block.
- **Fonts:** IBM Plex Serif (display, has true italics — the numeral system depends on them)
  + Inter (body — the site's own typeface), via Google Fonts.
- **Rhythm:** hero and footer are dark navy; body sections alternate light `--paper` / tinted
  `--paper-2` band.

> The site itself is **blocked by the corporate web filter** on the author's machine
> (`403 Web Filter Violation`, and WebFetch fails on the proxy certificate). To refresh
> branding, save the page as `.mhtml` from a browser and parse it — do not expect `curl`
> or WebFetch to reach it.

---

## Page structure

Hero (`Fix On Call` + "About this document" callout + three stats) →
`01 Overview` (four principles + services at launch) → `02 Purpose` (goals + business model) →
`03 Users` (four personas) → `04 Architecture` (Core / Applications / Integrations / Ecosystem) →
`05 Lifecycle` (interactive, 7 stages) → `06 Trust & safety` → `07 Roadmap` (5 phases) →
`08 Governance` (roles, cadence, incorporation) → `09 Documents` → `10 Glossary` →
footer (metadata only).

Sticky nav with scroll-spy; scroll-reveal animations via `IntersectionObserver`.

---

## Data-driven patterns — edit the data, not the markup

Three single-source lists live in the `<script>` at the bottom of the file:

- **`GLOSSARY`** — array of `{term, def}`. Powers **both** the Glossary section (auto-rendered,
  alphabetical) **and** the inline tooltips.
  - Add a term: add one entry.
  - Make any word a tooltip anywhere on the page: wrap it as
    `<span class="gloss" data-term="Driver App">Driver App</span>` — it looks up by name.
- **`LIFECYCLE`** — array of `{title, body, openQ?, pathways?, systems:[…]}`. Drives the
  lifecycle stepper's detail panel. Stages: Request · Locate · Match · Dispatch · Rescue ·
  Settle · Follow up.
- **`DOCUMENTS`** — array of `{title, tag, url, desc}`. Renders the Documents section. Empty
  `url` renders a "Pending" placeholder card; set `url` to make it a live link.
- **Tooltip** is a body-level floating element positioned by JS (flips above/below, clamps to
  the viewport; works on hover, keyboard focus, and tap).

**Open questions** are a first-class pattern: `<div class="open-q">` with a gold left border,
used inline wherever a decision is pending. Lifecycle stages get one by adding `openQ:"…"`.

---

## Comment system (built, running on localStorage)

In-page commenting is **anchored, versioned, and backed by a swappable storage adapter**
(`CONFIG.backend` in `index.html`).

- **Anchoring:** stable `data-comment-id` + a human-readable `data-comment-label`, captured at
  write time. Curated blocks carry authored ids; the rest are assigned by selector in
  `ANCHOR_MAP`. Any other block-level element can be commented on via "smart widen" — it gets
  a deterministic id hashed from its structural path + text, so it resolves back on reload.
  **Never** use pixel coordinates or text-range anchoring — both are fragile on responsive
  reflow and content edits.
- **Storage:** `LocalStore` (localStorage, `foc_comments`, default for dev) or `LambdaStore`
  (a hosted Function URL + `x-shared-secret` header — stub until deployed). Do **not** use
  public comment widgets (Giscus/Utterances): they store comments publicly and only support
  one thread per page. The content here is confidential.
- **Data model:** `id`, `anchor_id`, `anchor_label`, `doc_version`, `author_name`, `body`,
  `created_at`, `status` (open/resolved), `carried_from`, `parent_id`.
- **UX:** sticky "Add comment" chip → placing mode (eligible blocks outline; click one) →
  popover with name + comment; name remembered in `localStorage` (`foc_name`); count badges on
  commented blocks; a "Comments" toggle revealing a right-hand rail grouped by section.
- **Versioning:** `VERSIONS` array; this file's content *is* the current version. To cut a new
  one, copy `#doc-content`'s markup into `versions/<old-id>.html`, flip the old entry to
  `current:false` with its `file`, and add the new entry with `current:true`. Open comments
  auto-carry-forward into the newest version.
- **Dev helpers:** `FOC.clearComments()`, `FOC.clearComments('v0.1')`, `FOC.dumpComments()`.
- **Access / spam:** the page is gated per-user at the CloudFront edge and the endpoint is
  rate-limited (see "Deployment & access control"). On the deployed backend the comment author
  comes from the verified session; the self-entered name field applies only to `local` dev.

---

## Mobile layer (≤768px)

The page has a mobile-native layer on top of the responsive desktop layout. Desktop is
unchanged by it. Two clearly-delimited blocks hold nearly all of it:

- **CSS** — one `@media(max-width:768px)` block appended *last* in `<style>`, plus
  `@media(hover:none)`, `@media(prefers-reduced-motion:reduce)` and a landscape-phone block.
  Appended last on purpose: it wins on source order, so nothing above needs re-specifying.
- **JS** — the `MOBILE LAYER` block near the end of the `<script>`.

### The anchor rule — read before touching the markup

Comment anchors come in two kinds. Curated ids (`ANCHOR_MAP`) derive from CSS selectors and
are ancestor-insensitive. Smart-widened `el-*` ids (`computeElId`) hash the element's ancestor
tag-chain + same-tag sibling indices + its first 40 characters of text, terminating at the
nearest id'd ancestor.

**Inside `#doc-content`:**

| Change | Safe? |
|---|---|
| Add/remove a **class** | ✅ |
| Add/remove any **attribute except `id`** | ✅ |
| Add an **`id`** | ❌ `structuralPath` stops at the first id'd ancestor |
| **Insert / remove / reorder** an element | ❌ changes sibling indices and depth |
| Change **text** | ❌ the hash includes the text |

A wrapper element added inside `#doc-content` silently orphans every stored comment on its
descendants — `resolveAnchors()` fails quietly and the rail shows "location isn't present in
this version." **The mobile layer therefore mutates no DOM inside `#doc-content` at all.** The
regression gate for this is in "Verification" below.

`<nav>` and the body-level overlays (`.gloss-tip`, `.cmt-pop`, `.cmt-rail`, `.cmt-fab`,
`.cmt-place-banner`, `.mob-bar`) sit outside `#doc-content` and are free to restructure.

### Key mechanisms

- **`--chrome-h`** — the measured height of the *pinned* page chrome, kept in sync by
  `syncChrome()` via two `ResizeObserver`s. Drives `scroll-padding-top` (so anchor jumps clear
  the nav) and the placing banner's position. Replaced a hard-coded `108px` that was wrong on
  desktop and badly wrong on mobile. It deliberately **skips updating while `nav.nav-up`** is
  set, so it always reports the expanded height — an anchor jump un-collapses the brand row
  first, and a changing value would race that.
- **`isMobile()`** reads `mq.matches` at call time. Never cache it in a boolean — a rotation
  across the breakpoint would desync every branch.
- **`.mob-bar`** — the bottom action bar. The existing `.cmt-fab` is *moved* into it (same
  element, same listeners). On desktop the host is `display:contents`, so the fab's fixed
  positioning still resolves against the viewport and desktop is byte-identical. It's in both
  `SKIP_CLOSEST` and the placing-mode allowlist.
- **The comment sheet is `.cmt-pop` itself**, restyled — not a wrapper around it. The
  outside-click guard at `closePopover`'s listener tests `!pop.contains(e.target)`; a wrapper
  would make every tap on the sheet's own chrome close it under the user's finger.
- **`sheetOpened()` / `sheetClosed()`** — scroll lock, `docHost.inert`, the popover backdrop and
  the back-button `pushState` all hang off these. `pushState` is called with **no URL argument**
  so it can't fight the version switcher's `location.search=''`.
- **No new `document`-level click listeners.** There are exactly three and the count is gated in
  CI-style checks; their ordering is load-bearing (a capture-phase handler swallows clicks during
  placing mode). New dismissal logic binds to its own element instead.
- **`centreIn(container, el)`** scrolls a horizontal rail without scrolling the page.
  `scrollIntoView()` would scroll every scrollable ancestor including the document.
- **Carousels** are `.svc-grid` and `.partner-grid` only — pure CSS (`grid` → `flex` +
  `scroll-snap`). Trust & safety and the exec roles stay stacked: they're read, not browsed, and
  each card is individually commentable.
- **Placing mode is two-tap on mobile** — first tap selects and *names* the block in the bottom
  banner, second tap (or the Comment button) commits. Touch has no hover preview; naming the
  target is better than one anyway.

### Things that will silently break the native feel

- Form controls under `16px` make iOS Safari zoom the page on focus and never zoom back.
- Any `:hover` transform without a `@media(hover:none)` neutraliser latches after a tap.
- `env(safe-area-inset-*)` resolves to `0` without `viewport-fit=cover` in the viewport meta.
- `100vh` jumps when the mobile browser toolbar shows/hides — use `dvh`.

## Open content decisions (confirm with the exec team)

Every one of these is already surfaced on the page as an `open-q` callout — keep the two in sync.

- **Public claims** — "12 min average response", "47 counties covered" are on the live site.
  Split into commitments vs aspirations before launch.
- **Service catalogue** — nine services advertised, four in MVP scope. Confirm what is live at
  launch vs advertised-but-manual.
- **Commission rate** — 15–20% is indicative, not agreed. May need to vary by service type.
- **Build approach** — build in-house vs extend a configurable marketplace product. Undecided,
  and it gates the roadmap's dates. **Vendor names and pricing are deliberately kept off the
  page** (a decision taken 2 August 2026) — this is a shareholder-facing document.
- **Matching rules** — broadcast vs sequential offer, accept window, no-accept escalation.
- **Garage accounts** — can a garage register and manage several technicians?
- **Fallback intake** — USSD / call centre / WhatsApp for drivers with no data or no app.
- **Number masking** — expose driver/provider numbers directly, or mask through the platform?
- **Payout timing & payment failure** — per job or settlement cycle; what if payment fails
  after work is done.
- **Insurance & liability** — who carries risk for damage in tow, failed repair, injured tech.
- **Penetration testing** — needs a date and scope, not an open commitment.
- **Ownership & equity structure** — the highest-priority item. Must be resolved before
  incorporation and before any investor conversation. Formal executive titles to be confirmed
  in the same session (the meeting transcript is ambiguous on them).
- **Partnerships lead** — role not yet briefed to the exec team; Partner Portal scope stays
  provisional until it is.

---

## Source material

Content is derived from two documents (not committed — they contain material not for the page):

1. **Apporio Infolabs software proposal** — MVP scope, app feature lists, technology choices,
   5-phase roadmap, commission-based business model, scalability claims. *Its commercials
   (project cost, payment terms, vendor identity) are deliberately excluded from the page.*
2. **Fix On Call First Executive Meeting** (31 July 2026, Tactiq transcript + summary) —
   executive roles and remits, operating cadence, incorporation path, governance workstream,
   the open risks list, and the mandate for this document itself.

Plus the live marketing site (`getfixoncall.com`) for branding, the service catalogue, the
3-step process and the public performance claims.

---

## Working conventions

- **Edits:** prefer surgical edits to the existing file over regeneration; `index.html` is the
  source of truth.
- **Tone:** factual and plain, not marketing. Section headings are plain names; avoid slogans.
  Where the marketing site makes a claim the business can't yet meet, say so in an `open-q`
  rather than repeating it.
- **Pronouns:** the page describes real named people. Use they/them or write around pronouns
  entirely — do not infer them from names.
- **Confidentiality:** keep internal material off the page — vendor and commercial detail,
  build-vs-extend assessments beyond the stated open question, and anything about individual
  compensation or equity positions.

---

## Local development

Node 22+ (built-ins only — no `npm install`):

```bash
node serve.mjs                 # → http://localhost:8080
PORT=3000 node serve.mjs       # custom port
```

Live reload is on: saving `.html` / `.css` / `.js` refreshes the browser.

`serve.mjs` binds `0.0.0.0`, so **a real phone on the same Wi-Fi can load
`http://<machine-LAN-IP>:8080`** with live reload. That is the only way to test the mobile
layer properly — DevTools device mode reproduces none of: iOS input auto-zoom, safe-area
insets, `visualViewport` keyboard behaviour, momentum scrolling, or latching `:hover`.

## Verification

No headless browser is available on the author's machine (and the corporate web filter blocks
external sites), so checks are static. The scripts live in the session scratchpad; the gates
worth re-creating are:

1. **Anchor safety** — extract `#doc-content` from a known-good copy and from the working tree
   and assert they're byte-identical apart from `class=` values. If identical, no `el-*` id can
   have changed. This is a proof, not a spot-check, and it is the acceptance test for any
   change that touches markup.
2. **CSS brace balance** in the `<style>` block — an unterminated `@media` silently kills every
   rule after it.
3. `node --check` on the extracted `<script>`.
4. Grep gates: no static `vh` left; `viewport-fit=cover` present; `document.addEventListener('click'`
   count still 3; form controls at 16px; `:active` rules present; carousels limited to the two
   agreed grids.
5. Structural checks: every `data-term` resolves to a `GLOSSARY` entry, nav anchors resolve,
   stepper button count matches `LIFECYCLE`, section indices sequential, div balance, all CSS
   vars declared.

The end-to-end test that only a browser can do: **place a comment, reload, confirm the badge is
still there** — and place one on desktop, then open on mobile, and confirm it resolves.

## Deployment & access control

Built, not yet provisioned. **Full detail is in `infra/README.md`** — this is the summary.

S3 + CloudFront, with per-user login. A **CloudFront Function verifies an HS256 session cookie
at the edge**, so S3 never serves a byte to an unauthenticated request and the document stays
one self-contained inline file. Three behaviours on one distribution: `/login*` public,
`/api/*` → Lambda, everything else gated.

- **Login is a 6-digit code emailed via SES**, not a magic link. Corporate mail gateways click
  links to scan them, consuming one-time tokens; and links opened in Outlook/iOS Mail land in
  an in-app webview with its own cookie jar. The OTP email contains **no links at all**.
- **The allowlist is the `__members` partition** of the DynamoDB table — one list, no drift.
  `./infra/members.sh add <email> "<name>" "<role>"`.
- **Cognito was considered and rejected**: CloudFront Functions cannot verify RS256 so we mint
  our own token regardless, and Cognito's free sender can't achieve DKIM alignment. The swap
  surface if that changes is ~60 lines in two auth routes.
- **`CONFIG.sharedSecret` is gone.** The session cookie authenticates the *user*, so nothing
  sensitive is injected into the built page — `dist/index.html` is no longer a secret artifact.
  `dist/cf-session-gate.js` **is** (it carries the signing keys); both are gitignored.
- Because `/api/*` is same-origin via CloudFront, **there is no CORS anywhere**.

**Comment authorship is now server-side.** The Lambda ignores the client's `author_name` and
writes it from the member record, plus `author_email` from the token. This supersedes the note
above that the name field is self-entered — that is now true only on the `local` dev backend.

`serve.mjs`'s commented-out `/api` proxy stub still works for local development against the
deployed backend.

### Session lifetime and revocation

7 days, sliding. Stateless, so removing someone stops comments and re-login immediately but
read access persists until their cookie expires. To cut that off now:
`./infra/rotate-secret.sh --force` (everyone re-authenticates once).
