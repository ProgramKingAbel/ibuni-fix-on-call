#!/usr/bin/env bash
# Shared configuration + guards. Sourced by every other script in infra/.
#
# Nothing here hardcodes an account id — it is derived from the caller identity,
# so these scripts work against whichever account AWS_PROFILE points at.

set -euo pipefail

# AWS_PROFILE is optional: set it to target a specific profile, otherwise the
# CLI's own resolution applies (the `default` profile). Requiring it explicitly
# was pure friction — the identity guard below catches the case that actually
# matters, which is not having a valid session at all.
[ -n "${AWS_PROFILE:-}" ] && export AWS_PROFILE
export AWS_REGION="${AWS_REGION:-us-east-1}"      # CloudFront Functions, OAC and ACM
                                                  # all have their control plane here

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# --- names (stable; only the account suffix varies) --------------------------
export TABLE="foc-doc"
export FUNC="foc-doc-api"
export ROLE="foc-doc-api-role"
export CFFUNC="foc-session-gate"
export APIGW="foc-doc-api-gw"
export FROM_DOMAIN="notify.getfixoncall.com"
# Sender address. The domain identity is the goal, but it needs DNS records on
# getfixoncall.com (currently served by Vercel, and not accessible to us). Until
# then SES runs in sandbox with a single verified ADDRESS as the sender, stored
# in infra/.sender. Delete that file once the domain verifies.
if [ -f "$ROOT/infra/.sender" ]; then
  FROM_ADDR="$(tr -d ' \r\n' < "$ROOT/infra/.sender")"
else
  FROM_ADDR="no-reply@${FROM_DOMAIN}"
fi
export FROM_ADDR

# --- identity guard ----------------------------------------------------------
# `aws login` sessions expire mid-task; fail here with a clear message rather
# than three commands later with a confusing one.
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  echo "ERROR: no valid AWS session for profile '$AWS_PROFILE'. Run: aws login" >&2
  exit 1
fi
export ACCOUNT
export BUCKET="foc-doc-${ACCOUNT}"

# --- secrets -----------------------------------------------------------------
export SECRET_FILE="$ROOT/infra/.session-secret"

load_secrets() {
  [ -f "$SECRET_FILE" ] || { echo "ERROR: missing $SECRET_FILE — run infra/provision.sh first" >&2; exit 1; }
  SESSION_CURRENT="$(sed -n 's/^current=//p' "$SECRET_FILE")"
  SESSION_PREV="$(sed -n 's/^prev=//p' "$SECRET_FILE")"
  OTP_PEPPER="$(sed -n 's/^pepper=//p' "$SECRET_FILE")"
  [ -n "$SESSION_CURRENT" ] || { echo "ERROR: no current= line in $SECRET_FILE" >&2; exit 1; }
  [ -n "$OTP_PEPPER" ]      || { echo "ERROR: no pepper= line in $SECRET_FILE" >&2; exit 1; }
  export SESSION_CURRENT SESSION_PREV OTP_PEPPER
}

# --- lookups (cached per-invocation, never hardcoded) ------------------------
# Identify the distribution by its S3 origin domain, which contains the account
# id and is unambiguous. (Matching on the Comment field looked tidier but the
# em-dash in it does not survive the shell → JMESPath round trip, and the lookup
# silently returned None.)
_dist_field() {
  aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(to_string(Origins.Items[].DomainName), '${BUCKET}')].$1 | [0]" \
    --output text 2>/dev/null
}
dist_id()     { _dist_field Id; }
dist_domain() { _dist_field DomainName; }
dist_status() { _dist_field Status; }

func_url() {
  aws lambda get-function-url-config --function-name "$FUNC" \
    --query FunctionUrl --output text 2>/dev/null
}

# --- Git Bash / Windows path handling ----------------------------------------
# Two opposite problems, so two helpers. Using the wrong one is why the first
# provisioning run failed.
#
# 1. Git Bash rewrites any argument that LOOKS like a POSIX path into a Windows
#    one, so `--paths '/index.html'` silently becomes
#    'C:/Program Files/Git/index.html'. The invalidation then "succeeds" and
#    nothing updates. Wrap those calls in `nopath`.
nopath() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$@"; }
#
# 2. The AWS CLI is a native Windows binary, so a genuine MSYS path like
#    /c/Users/... or /tmp/... means nothing to it. Any file:// or fileb://
#    argument must be converted to a Windows path first. `cygpath -m` gives
#    C:/style/with/forward/slashes, which the CLI accepts inside a file:// URL.
#    NOTE: never wrap these in `nopath` — that is exactly the mistake.
winpath()  { cygpath -m "$1"; }
filearg()  { echo "file://$(cygpath -m "$1")"; }
filebarg() { echo "fileb://$(cygpath -m "$1")"; }

# Scratch dir for temp files: inside the repo (gitignored) rather than /tmp, so
# both MSYS and the Windows CLI can reach it.
TMPD="$ROOT/dist/.tmp"
export TMPD
mkdir -p "$TMPD"
