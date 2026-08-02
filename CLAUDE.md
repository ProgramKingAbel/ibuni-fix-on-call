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
- **Access / spam:** gate the page itself (shared passcode) and rate-limit the endpoint; the
  name field is self-entered, not authentication.

---

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

## Deployment (not yet done)

Not deployed. When it is: static site → private object storage + CDN, password-gated at the
edge; comments via a small function + a table behind a shared secret. Set `CONFIG.backend` to
`'lambda'` and inject `endpoint` + `sharedSecret` at deploy time (never commit them).
`serve.mjs` has a commented-out `/api` proxy stub for local development against that backend.
