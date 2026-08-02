#!/usr/bin/env bash
# Rotate the session signing secret.
#
#   AWS_PROFILE=<profile> ./infra/rotate-secret.sh          # graceful — nobody signed out
#   AWS_PROFILE=<profile> ./infra/rotate-secret.sh --force   # immediate — everyone signed out
#
# THE ORDER IS LOAD-BEARING. The edge function must accept the new key BEFORE the
# Lambda starts signing with it. Reverse it and every user logs in successfully
# and is then bounced straight back to /login — which looks exactly like a cookie
# bug and is the most confusing failure this design can produce.
#
# Graceful: the old key is kept as `prev`, so existing sessions keep working until
# they expire naturally. New sessions use the new key.
#
# --force: `prev` is cleared, so every existing session is invalidated at once.
# This is the "revoke someone's read access right now" lever — it signs out
# everybody, and they each re-authenticate once.

source "$(dirname "$0")/env.sh"
load_secrets

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

NEW="$(openssl rand -base64 48 | tr -d '\n')"
if [ "$FORCE" = "1" ]; then
  KEEP=""
  echo "FORCE rotation — every existing session will be invalidated."
  read -r -p "Type 'yes' to continue: " ans
  [ "$ans" = "yes" ] || { echo "aborted"; exit 1; }
else
  KEEP="$SESSION_CURRENT"
  echo "graceful rotation — existing sessions remain valid until they expire."
fi

# 1. write the new secret file
{ echo "current=$NEW"; echo "prev=$KEEP"; echo "pepper=$OTP_PEPPER"; } > "$SECRET_FILE"
echo "==> wrote $SECRET_FILE"

# 2. edge FIRST — it must accept the new key before anything signs with it
echo "==> rebuilding + publishing the edge function"
node "$ROOT/infra/build.mjs" "$ROOT" "$NEW" "$KEEP"
ETAG="$(aws cloudfront describe-function --name "$CFFUNC" --query ETag --output text)"
aws cloudfront update-function --name "$CFFUNC" \
  --function-config 'Comment="Fix On Call session gate",Runtime=cloudfront-js-2.0' \
  --function-code "$(filebarg "$ROOT/dist/cf-session-gate.js")" --if-match "$ETAG" >/dev/null
ETAG2="$(aws cloudfront describe-function --name "$CFFUNC" --query ETag --output text)"
aws cloudfront publish-function --name "$CFFUNC" --if-match "$ETAG2" >/dev/null

echo "==> waiting 60s for edge propagation"
sleep 60

# 3. Lambda SECOND
echo "==> updating the lambda"
CUR_ENV="$(aws lambda get-function-configuration --function-name "$FUNC" \
  --query 'Environment.Variables' --output json)"
NEW_ENV="$(echo "$CUR_ENV" | jq -c \
  --arg s "$NEW" --arg p "$KEEP" '.SESSION_SECRET=$s | .SESSION_SECRET_PREV=$p')"
nopath aws lambda update-function-configuration --function-name "$FUNC" \
  --environment "{\"Variables\":$NEW_ENV}" >/dev/null
aws lambda wait function-updated --function-name "$FUNC"

# 4. prove the two agree
echo "==> verifying edge and lambda agree"
D="https://$(dist_domain)"
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
H="$(printf '{"alg":"HS256","typ":"JWT"}' | b64u)"
P="$(printf '{"sub":"rotate@test","iss":"foc-doc","exp":%d}' $(( $(date +%s) + 600 )) | b64u)"
G="$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -hmac "$NEW" -binary | b64u)"
TOK="$H.$P.$G"

EDGE="$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: __Host-focs=$TOK" "$D/")"
API="$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: __Host-focs=$TOK" "$D/api/comments?doc_version=v0.1")"

echo "    edge: $EDGE   api: $API"
if [ "$EDGE" != "200" ] || [ "$API" != "200" ]; then
  echo
  echo "ROTATION VERIFICATION FAILED — the edge and the Lambda do not agree."
  echo "Users will log in and be bounced. Re-run this script, or restore the"
  echo "previous secret into $SECRET_FILE and re-run."
  exit 1
fi
echo
echo "rotated. ${FORCE:+everyone must sign in again.}"
