# Fix On Call — Platform Overview

A confidential, access-controlled document for the executive team.

**Live:** https://d1ji6dhetvtg99.cloudfront.net — readable only by people on the
allowlist, each signing in with their own email.

This file is the **operator's runbook** — the commands you actually need.
For how it's built and why, see [`infra/README.md`](infra/README.md).
For the document's content and conventions, see [`CLAUDE.md`](CLAUDE.md).

---

## Before any command

Every script needs an AWS session and the profile name. Sessions expire — if a
script says *"no valid AWS session"*, this is why.

```bash
cd ~/Documents/FixOnCall/ibuni-fix-on-call
aws login                       # opens a browser
export AWS_PROFILE=default      # do this once per terminal
```

Everything below assumes those two lines have been run.

> **`gh` not found?** It's installed but not on Git Bash's PATH:
> `export PATH="$PATH:/c/Program Files/GitHub CLI"`

---

## Getting someone into the document

**Right now email is unreliable** (SES is in sandbox and we don't have DNS for
the domain — see [Email status](#email-status)). Use an invite link.

```bash
./infra/members.sh invite sariabarnabas@gmail.com
```

Prints one link. Send it over WhatsApp. It is **single-use** and valid **24
hours**; opening it signs that person in for **7 days**, and that session renews
itself every time they open the document. So:

- They only need a new link if they wait more than 24h to open it, go a full week
  without reading, clear cookies, **or switch to another device or browser**.
- One link = one device. Phone and laptop need one each.

**If someone is on the phone with you and can't find the link:**

```bash
./infra/members.sh code sariabarnabas@gmail.com
```

Prints a 6-digit code valid 10 minutes. They go to
`https://d1ji6dhetvtg99.cloudfront.net/login`, enter their email, then the code
you read out. (The email they receive, if any, would carry the same thing.)

---

## Managing who has access

```bash
./infra/members.sh list                                   # who's on it
./infra/members.sh add    ken@example.com "Ken M" "Legal"  # add someone
./infra/members.sh edit   ken@example.com "Ken M" "Legal & compliance"
./infra/members.sh expire ken@example.com 14              # time-boxed (0 clears)
./infra/members.sh disable ken@example.com                # revoke, keep the record
./infra/members.sh enable  ken@example.com                # restore
./infra/members.sh remove  ken@example.com                # delete outright
```

**Prefer `disable` over `remove`** — it revokes access identically but keeps the
record, so you can still see who used to have access.

**Important:** disabling stops sign-in and commenting *immediately*, but someone
already signed in keeps **reading** until their session expires (up to 7 days).
To cut that off now:

```bash
./infra/rotate-secret.sh --force     # signs EVERYONE out; each re-authenticates once
```

That is the emergency lever. It takes about two minutes and asks for confirmation.

---

## Publishing changes to the document

Edit `index.html`, then either:

```bash
git add -A && git commit -m "..." && git push      # CI deploys automatically
```

or deploy straight from here:

```bash
./infra/deploy.sh
```

Both run the same tests first and the same **smoke tests** afterwards, and both
**fail loudly** rather than leave a broken document live. `deploy.sh` takes about
a minute.

Before pushing, you can run the tests alone:

```bash
./infra/test/run.sh
```

### Cutting a new version

When you want the current draft archived so readers can still see it after you
revise — the page has a version dropdown for exactly this.

1. Copy everything between `<div id="doc-content">` and `</div><!-- /#doc-content -->`
   in `index.html` into `versions/v0.1.html` (or whatever the outgoing version is).
2. In `index.html`'s `VERSIONS` list, flip that entry to
   `current:false, file:'versions/v0.1.html'` and add the new one as
   `current:true, file:null`.
3. Update `CONFIG.currentVersion` and the footer's document/date metadata.
4. Deploy.

Open comments carry forward to the new version automatically; resolved ones stay
behind on the version they were made against.

> **Careful when editing the document body.** Comment anchors are derived from
> each element's position in the page, so inserting or reordering elements inside
> `#doc-content` can orphan existing comments. `./infra/test/run.sh` warns you if
> the body changed structurally. Editing *text* is fine; restructuring is what to
> watch.

---

## Seeing who has read it

```bash
./infra/members.sh log 24        # sign-ins in the last 24 hours
./infra/members.sh log 168       # last week
```

Comments carry a **verified** author — the server records the identity from the
session and ignores whatever the browser claims, so a name in a comment is real.

---

## Local preview

```bash
node serve.mjs                   # http://localhost:8080, live reload
```

The local copy is **not access-controlled** — it's a plain file server, and the
login gate lives at CloudFront in front of S3. That's intentional, and the local
build shows a striped banner saying so. **Don't hand the local file around
thinking it's protected.** Only the CloudFront URL is.

Local preview also uses browser storage for comments, so anything you write there
is yours alone and never reaches the real document.

---

## Email status

Codes are sent from a single verified Gmail address because we don't have DNS
access for `getfixoncall.com` (it's on Vercel) and this AWS account can't
register a domain.

Consequences, honestly:

- **Every recipient must be verified in SES individually** before a code can
  reach them — each person gets an AWS email to click. Only
  `abelmorara254@gmail.com` is verified so far.
- Mail sent as `gmail.com` can't be cryptographically aligned, so **expect the
  spam folder**. Tell people to look there and mark it *not spam*.
- 200 messages/day.

This is why invite links are the recommended route for now.

**To fix it properly:** get DNS access for `getfixoncall.com` (or any domain),
add the records `aws sesv2 get-email-identity` generates, then request SES
production access — which also removes the per-recipient verification step. Full
detail in [`infra/README.md`](infra/README.md#ses--current-state-sandbox-address-sender).

---

## When something looks wrong

| Symptom | What to do |
|---|---|
| Signs in, then bounces back to `/login` | The edge and the API disagree on the signing secret. Run `./infra/deploy.sh` — its smoke test names this exact failure. |
| An invite link goes to `/login?used=1` | Already opened. Mint a new one. |
| An invite link goes to `/login` with no `used` | Expired (>24h). Mint a new one. |
| Someone can't get a code | Spam folder first; otherwise `./infra/members.sh code <email>` and read it out. |
| You deployed and nothing changed | CloudFront cache. `deploy.sh` invalidates automatically; give it a minute. |
| **Locked out entirely** | `aws s3 presign s3://foc-doc-094429135337/index.html --expires-in 900` — a 15-minute link that bypasses CloudFront using your AWS credentials. |

---

## What's where

| | |
|---|---|
| `index.html` | The document. One self-contained file. |
| `login/index.html` | The sign-in page. |
| `infra/` | Deployment scripts, the API, the edge gate, tests. |
| `infra/.session-secret` | **Secret.** Signing keys. Never commit — it's gitignored. |
| `infra/.sender` | The SES sender address. Not secret, but environment-specific. |
| `versions/` | Archived snapshots for the in-page version switcher. |

**If you lose `infra/.session-secret`**, everyone is signed out and you'll need to
re-run `./infra/provision.sh` to generate a new one. It is not stored anywhere
else — back it up somewhere safe (a password manager entry is fine).
