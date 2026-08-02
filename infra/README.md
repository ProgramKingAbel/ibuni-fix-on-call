# Infrastructure — Fix On Call Platform Overview

Private hosting for a confidential document: S3 + CloudFront, with per-user login
by emailed one-time code, and the session verified **at the edge** so S3 never
serves a byte to an unauthenticated request.

Nothing here hardcodes an account id — everything derives from
`aws sts get-caller-identity`, so these scripts run against whichever account
`AWS_PROFILE` points at.

```
Browser ──► CloudFront
   ├─ /login*   → S3            public — the login page
   ├─ /api/*    → API Gateway   → Lambda; the Lambda enforces the session cookie
   └─ /*        → S3 via OAC    CloudFront Function verifies the session, else 302 /login
```

## Live stack

| | |
|---|---|
| URL | **https://d1ji6dhetvtg99.cloudfront.net** |
| Account / region | `094429135337` / `us-east-1` |
| Distribution | `E273KT135CYZ5Q` |
| S3 bucket | `foc-doc-094429135337` (private, OAC-only) |
| CloudFront Function | `foc-session-gate` |
| API Gateway HTTP API | `foc-doc-api-gw` |
| Lambda | `foc-doc-api` (nodejs20.x) |
| DynamoDB | `foc-doc` |
| CI role | `foc-doc-ci-deploy` (GitHub OIDC) |

## Three things that cost real time — read before changing them

**1. The API origin is API Gateway, not a Lambda Function URL.** Public Function
URLs are blocked at the account level here: they return
`403 Forbidden … urls-auth.html` regardless of `AuthType=NONE` plus a correct
`Principal:"*"` resource policy, and recreating the URL config from scratch does
not help. HTTP API payload format 2.0 gives the handler an identical event shape,
so the Lambda code is the same either way. (Lambda OAC with SigV4 was also tried
and fails signature validation on requests with a body.)

**2. `String.bytesFrom()` throws in the live CloudFront Functions runtime**, even
though it is what the documentation shows:
`SyntaxError: String.bytesFrom() is deprecated, please use another method Buffer.from()`.
Because the throw lands inside the payload-parse `catch`, the symptom is a
*correctly signed* token being bounced — signature verified, payload never
parsed, no error surfaced. Use `Buffer.from`. `infra/test/edge-gate.test.mjs`
now fails outright if the source reintroduces it.

**3. Cookies go in a top-level `cookies` array, not a `set-cookie` header.**
Payload format 2.0 requires header *values* to be strings. Returning an array
under `headers['set-cookie']` produces a bare `500 Internal Server Error` from
API Gateway while CloudWatch shows a completely healthy invocation — the login
even gets written to the access log. Miserable to debug; easy to avoid.

## Quick start

```bash
aws login                        # sessions expire; every script guards for this
# export AWS_PROFILE=<name>      # only if targeting a non-default profile

./infra/provision.sh             # one-time, idempotent
./infra/members.sh add abel@example.com "Abel Morara" "CTO"
./infra/deploy.sh                # build → upload → publish → invalidate → smoke test
```

`provision.sh` prints the CloudFront domain. The distribution takes ~10 minutes to
finish deploying before it serves anything.

**SES is deliberately not automated** — see below. Start it first; it is the only
part with wall-clock delay.

## Files

| File | Purpose |
|---|---|
| `env.sh` | Shared config, identity guard, resource lookups. Sourced by everything. |
| `provision.sh` | One-time resource creation, dependency-ordered, idempotent. |
| `deploy.sh` | Build, upload, update Lambda + edge function, invalidate, **smoke test**. |
| `members.sh` | The allowlist: `list` / `add` / `remove` / `code` / `invite` / `log`. |
| `rotate-secret.sh` | Session-secret rotation, graceful or `--force`. |
| `build.mjs` | Templates `dist/`. Node, not `python3` — that's the Store stub here. |
| `cf-session-gate.js` | The CloudFront Function. Secrets injected at build time. |
| `lambda/index.mjs` | Auth + comments API. |
| `ci-setup.sh` | One-time GitHub OIDC provider + scoped deploy role. |
| `test/run.sh` | Every check that runs without AWS or a browser. |

## Continuous deployment

`.github/workflows/deploy.yml` deploys on every push to `main` that touches
`index.html`, `login/`, `versions/`, or the Lambda / edge function / build script.

Authentication is **GitHub OIDC** — the workflow assumes `foc-doc-ci-deploy`, so
there are no long-lived AWS keys anywhere. The role is deploy-only: it can update
the Lambda code, publish the edge function, write to the bucket and invalidate the
distribution. It has no `iam:*` and cannot create or delete infrastructure, so
**provisioning stays a human action** and a compromised workflow can ship a bad
page but cannot take the account. The trust policy is pinned to
`repo:<owner>/<repo>:ref:refs/heads/main` — without the branch condition, anyone
able to open a pull request from a fork could assume it.

The workflow runs the same test suite as `test/run.sh` before deploying, and the
same live smoke tests afterwards — including the edge/Lambda agreement check. A
failed smoke test fails the workflow.

Repository configuration (`infra/ci-setup.sh` prints these):

| | |
|---|---|
| Variable `AWS_ROLE_ARN` | the CI role ARN — not a credential |
| Secret `SESSION_SECRET` | the `current=` line from `.session-secret` |
| Secret `SESSION_PREV` | the `prev=` line (may be empty) |

The session secret is the only secret CI needs, because it rebuilds the edge
function, which carries the signing keys.

## Auth model

**One layer does the real work.** A `__Host-focs` cookie carries an HS256 JWT,
minted by the Lambda and verified by the CloudFront Function on every request to
the default behaviour. No valid cookie → 302 to `/login`.

Login: email → 6-digit code by email → cookie. **The Cognito route was considered
and rejected**: CloudFront Functions cannot verify RS256, so we mint our own token
either way, and Cognito's free email sender can't achieve DKIM alignment with the
domain. That left ~60 lines of OTP mechanics as the entire difference. If a
security reviewer ever wants Cognito named, the swap surface is
`/api/auth/start` + `/api/auth/verify` only — token, cookie, edge gate and page
are unchanged.

**The allowlist is the `__members` partition of the DynamoDB table.** There is no
second list to drift.

**Why a code and not a magic link.** Corporate mail gateways *click* links to scan
them, which consumes a one-time token before the recipient sees it; and a link
opened from Outlook or iOS Mail lands in an in-app webview with its own cookie
jar, so the session ends up somewhere other than where they then read. The OTP
email contains **no links at all**, which also avoids URL-defence rewriting.

**Comment authorship is server-side.** The Lambda ignores the client's
`author_name` and writes the name from the member record plus `author_email` from
the token. The "Commenting as …" label in the page is cosmetic.

### Session lifetime

7 days, sliding — `/api/me` re-mints the cookie when it is more than a day old, so
an active reader never re-authenticates. Stateless, which has one honest
consequence:

**Revoking one person's read access is not instant.** The playbook:

1. `./infra/members.sh remove <email>` — they immediately lose comment access and
   the ability to sign in again. An already-issued cookie still reads the document
   until it expires.
2. If that must stop now: `./infra/rotate-secret.sh --force` — everyone is signed
   out and re-authenticates once. Two minutes.

## DynamoDB — one table, four partitions

Table `foc-doc`, PK `anchor_id`, SK `sort_key`, on-demand, TTL on `expires_at`.

| `anchor_id` | `sort_key` | Holds |
|---|---|---|
| *(real anchor id)* | `<created_at>#<id>` | Comments |
| `__members` | `<email>` | `name, role, active, added_at, expires_at?` |
| `__otp` | `<email>` | `code_hash, expires_at, attempts, sent_at, sends` |
| `__rl` | `ip#<ip>#<hour>` | Rate-limit counters |
| `__invite` | `<jti>` | Consumed break-glass invites |

TTL deletion is best-effort within 48h, so every read checks `expires_at`
explicitly. **Never treat TTL as a security control.**

## SES — current state: sandbox, address sender

`getfixoncall.com` is served by **Vercel DNS** (`ns1/ns2.vercel-dns.com`), and we
do not have access to it, so the domain identity cannot be verified. Note also
that this account **cannot register a domain** — Route 53 Domains returns
*"Free Tier accounts are not supported for this service"* — and a Route 53 hosted
zone on its own is useless without a domain delegating to it.

So SES runs in **sandbox with a single verified address** as the sender, held in
`infra/.sender` (gitignored; `env.sh` falls back to the domain address when the
file is absent). The Lambda's IAM policy permits **both** the sandbox sender and
the eventual `no-reply@notify.getfixoncall.com`, so switching later needs no
policy change — just delete `infra/.sender` and re-run `deploy.sh`.

**What sandbox costs you:**

- Every **recipient** must be individually verified in SES — each person receives
  an AWS verification email and must click it. Seven people, seven clicks.
- 200 messages/day.
- Sending *from* a `gmail.com` address means DKIM and SPF cannot align. Gmail
  publishes `p=none`, so mail should not be rejected outright, but **expect the
  spam folder**. Tell people to look there and mark it "not spam".

**The two escape hatches exist precisely for this** and need no email at all:

```bash
./infra/members.sh code   <email>    # prints a valid code — read it down the phone
./infra/members.sh invite <email>    # single-use 24h link — send over WhatsApp
```

Given the exec team already coordinates on WhatsApp, `invite` is the pragmatic
first-round distribution.

**To fix it properly**, either get access to `getfixoncall.com` DNS (the records
are generated by `aws sesv2 get-email-identity`) or register a domain elsewhere
and point it at Route 53. Then request production access, which also removes the
per-recipient verification requirement.

## SES — the proper setup, once a domain is available

Deliverability is the difference between this working and failing in front of the
executive team. Verify a **subdomain**, not the apex, so a mistake can't affect
the marketing site's mail.

1. Verify `notify.getfixoncall.com` in SES.
2. **Easy DKIM** — 3 CNAME records. Non-negotiable.
3. **Custom MAIL FROM** (`bounce.notify.getfixoncall.com`, 1 MX + 1 TXT). Without
   it the Return-Path is `amazonses.com` and **SPF cannot align**, leaving DKIM as
   the only route to a DMARC pass. Corporate filters weight alignment heavily —
   this is the single biggest lever on whether the code arrives.
4. **DMARC** on `_dmarc.notify…`: start at `p=none` with a `rua` address.
5. **Configuration set** → CloudWatch for bounces and complaints. SES suspends
   accounts with unhandled bounces, and you want the signal first.
6. **Request production access** *and* verify the recipient addresses in parallel
   — the sandbox allows 200/day to verified addresses, which is enough for the
   exec team, so you are not blocked while the request is pending.

Tell each recipient to allowlist the sender **before** you circulate.

## Rotation

```bash
./infra/rotate-secret.sh            # graceful — nobody is signed out
./infra/rotate-secret.sh --force    # immediate — everyone is signed out
```

**The order inside that script is load-bearing.** The edge function must accept
the new key *before* the Lambda starts signing with it. Reversed, every user logs
in successfully and is bounced straight back — which looks exactly like a cookie
bug and is the most confusing failure this design can produce. The script enforces
the order and then proves both sides agree before exiting.

## When something breaks

| Symptom | Cause | Fix |
|---|---|---|
| Login succeeds, then bounces back to `/login` | Edge and Lambda hold different secrets | Re-run `deploy.sh`; its smoke test names this specifically. The login page also detects it and says so rather than looping. |
| `/api/*` returns 403 | Viewer `Host` header forwarded to the Function URL | The `/api/*` behaviour must use `Managed-AllViewerExceptHostHeader`. |
| Login "works" but no cookie is set | `Set-Cookie` stripped from a cacheable response | The `/api/*` behaviour must use `Managed-CachingDisabled`. |
| Invalidation succeeds, nothing updates | Git Bash rewrote `/index.html` into a Windows path | Use the `nopath` wrapper in `env.sh`. |
| Code never arrives | Quarantined | `./infra/members.sh code <email>` prints a valid code to read down the phone; or `invite` for a single-use link over Signal. |
| Locked out entirely | Bad member record, botched rotation, edge-function bug | `aws s3 presign s3://<bucket>/index.html --expires-in 900` — bypasses CloudFront, uses IAM, time-limited. **Do not build a bypass into the distribution.** |

## Testing

```bash
./infra/test/run.sh        # syntax, CSS balance, security matrix, secret hygiene, anchor stability
```

The two that matter:

- **`edge-gate.test.mjs`** runs the *real* CloudFront Function source against a
  forged-token matrix with the runtime shimmed — expiry, clock skew, tampering,
  wrong issuer, unknown key, and the whole `alg:none` confusion class.
- **`cross-verifier.test.mjs`** extracts the *real* mint/verify functions from the
  Lambda and asserts the edge accepts what the Lambda produces, including across a
  rotation overlap. This is the local version of the check `deploy.sh` runs
  against the live stack.

`anchor-gate.mjs` guards a different invariant: comment anchor ids hash each
element's ancestor chain, so any structural change inside `#doc-content` orphans
stored comments. It asserts the document body is byte-identical apart from class
values.

## Cost

Under **$0.05/month** at this scale — CloudFront and Lambda sit inside the
always-free tiers; DynamoDB and SES are ~$0.01 each. Set a $5 billing alarm. A
leaked URL would need ~130M requests to reach $100.

## Teardown

CloudFront first (disable, wait for `distribution-deployed`, then delete), then
the function and OAC, then Lambda + Function URL, DynamoDB, IAM role and policies,
the S3 bucket (empty it first), and the CloudWatch log group.
