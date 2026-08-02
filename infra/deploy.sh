#!/usr/bin/env bash
# Build → upload → update the edge function and the Lambda → invalidate → smoke test.
#
#   AWS_PROFILE=<profile> ./infra/deploy.sh
#
# Ends with a cross-verifier smoke test and FAILS the deploy if it doesn't pass.
# That test catches the worst silent failure in this design: the CloudFront
# Function and the Lambda disagreeing about the signing secret, which presents as
# "login works, then bounces you straight back" and looks exactly like a cookie bug.

source "$(dirname "$0")/env.sh"
load_secrets

DIST="$(dist_id)"
[ "$DIST" != "None" ] && [ -n "$DIST" ] || { echo "ERROR: no distribution — run ./infra/provision.sh" >&2; exit 1; }
DOMAIN="$(dist_domain)"

echo "account : $ACCOUNT"
echo "dist    : $DIST  ($DOMAIN)"
echo

# ------------------------------------------------------------------- build ---
node "$ROOT/infra/build.mjs" "$ROOT" "$SESSION_CURRENT" "$SESSION_PREV"

# ------------------------------------------------------------------ upload ---
echo "==> uploading site"
aws s3 cp "$ROOT/dist/index.html" "s3://$BUCKET/index.html" \
  --content-type 'text/html; charset=utf-8' --cache-control 'no-cache' >/dev/null
aws s3 cp "$ROOT/login/index.html" "s3://$BUCKET/login/index.html" \
  --content-type 'text/html; charset=utf-8' --cache-control 'no-cache' >/dev/null
# /login (no trailing slash) is its own object — CloudFront's DefaultRootObject
# only applies at the distribution root, not per-prefix.
aws s3 cp "$ROOT/login/index.html" "s3://$BUCKET/login" \
  --content-type 'text/html; charset=utf-8' --cache-control 'no-cache' >/dev/null

if [ -d "$ROOT/versions" ] && [ -n "$(ls -A "$ROOT/versions" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
  aws s3 sync "$ROOT/versions" "s3://$BUCKET/versions" \
    --content-type 'text/html; charset=utf-8' --cache-control 'no-cache' --delete >/dev/null
fi

# ------------------------------------------------------------------ lambda ---
echo "==> updating lambda"
rm -f "$ROOT/infra/lambda/function.zip"
powershell.exe -NoProfile -Command \
  "Compress-Archive -Path '$(cygpath -w "$ROOT/infra/lambda/index.mjs")' -DestinationPath '$(cygpath -w "$ROOT/infra/lambda/function.zip")' -Force" >/dev/null
aws lambda update-function-code --function-name "$FUNC" \
  --zip-file "$(filebarg "$ROOT/infra/lambda/function.zip")" >/dev/null
aws lambda wait function-updated --function-name "$FUNC"

# ---------------------------------------------------------- edge function ----
echo "==> updating edge function"
ETAG="$(aws cloudfront describe-function --name "$CFFUNC" --query ETag --output text)"
aws cloudfront update-function --name "$CFFUNC" \
  --function-config 'Comment="Fix On Call session gate",Runtime=cloudfront-js-2.0' \
  --function-code "$(filebarg "$ROOT/dist/cf-session-gate.js")" --if-match "$ETAG" >/dev/null

# Measure the compute budget before publishing. Over ~50% and it will start
# throttling under load; the lever is token size.
cat > "$TMPD/foc-event.json" <<'JSON'
{ "version":"1.0","context":{"eventType":"viewer-request"},
  "viewer":{"ip":"1.2.3.4"},
  "request":{"method":"GET","uri":"/","headers":{},"cookies":{},"querystring":{}} }
JSON
ETAG2="$(aws cloudfront describe-function --name "$CFFUNC" --query ETag --output text)"
UTIL="$(aws cloudfront test-function --name "$CFFUNC" --stage DEVELOPMENT --if-match "$ETAG2" \
  --event-object "$(filebarg "$TMPD/foc-event.json")" \
  --query 'TestResult.ComputeUtilization' --output text 2>/dev/null || echo '?')"

echo "    compute utilisation: ${UTIL}%"

aws cloudfront publish-function --name "$CFFUNC" --if-match "$ETAG2" >/dev/null
echo "    published"

# -------------------------------------------------------------- invalidate ---
echo "==> invalidating"
# nopath: Git Bash would rewrite '/index.html' into a Windows path and the
# invalidation would silently target the wrong thing.
nopath aws cloudfront create-invalidation --distribution-id "$DIST" \
  --paths '/index.html' '/' '/login' '/login/*' '/versions/*' >/dev/null

# ------------------------------------------------------------- smoke tests ---
echo
echo "==> smoke tests"
D="https://$DOMAIN"
fail=0
chk() { # name expected actual
  if [ "$2" = "$3" ]; then echo "    ok   $1 ($3)"; else echo "    FAIL $1 — expected $2, got $3"; fail=$((fail+1)); fi
}

b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mk() { # $1 exp-offset, $2 iss, $3 secret
  local h p g
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64u)
  p=$(printf '{"sub":"smoke@test","iss":"%s","exp":%d}' "$2" $(( $(date +%s) + $1 )) | b64u)
  g=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$3" -binary | b64u)
  echo "$h.$p.$g"
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

TOK="$(mk 3600 foc-doc "$SESSION_CURRENT")"

chk "no cookie redirects to login"  302 "$(code "$D/")"
chk "login page is public"          200 "$(code "$D/login")"
chk "malformed cookie rejected"     302 "$(code -H 'Cookie: __Host-focs=aaa.bbb.ccc' "$D/")"
chk "expired token rejected"        302 "$(code -H "Cookie: __Host-focs=$(mk -3600 foc-doc "$SESSION_CURRENT")" "$D/")"
chk "wrong issuer rejected"         302 "$(code -H "Cookie: __Host-focs=$(mk 3600 wrong "$SESSION_CURRENT")" "$D/")"
chk "bad signature rejected"        302 "$(code -H "Cookie: __Host-focs=${TOK%?}X" "$D/")"
chk "valid token serves the doc"    200 "$(code -H "Cookie: __Host-focs=$TOK" "$D/")"
chk "api rejects no cookie"         401 "$(code "$D/api/comments?doc_version=v0.1")"
# THE cross-verifier check. /api/comments cannot serve here: it 401s both for a
# bad signature AND for a valid token whose subject is not a member, so a pass
# would be ambiguous. /api/health reports on the signature alone.
chk "lambda accepts the edge's token" '{"ok":true,"token":"valid"}' \
    "$(curl -s -H "Cookie: __Host-focs=$TOK" "$D/api/health")"
chk "lambda rejects a forged token"  '{"ok":true,"token":"invalid"}' \
    "$(curl -s -H "Cookie: __Host-focs=${TOK%?}X" "$D/api/health")"
# A validly-signed token for a non-member must still be refused by the API.
chk "valid token, non-member → 401" 401 "$(code -H "Cookie: __Host-focs=$TOK" "$D/api/comments?doc_version=v0.1")"
chk "unknown email is not an oracle" 200 "$(code -X POST -H 'content-type: application/json' \
      -d '{"email":"definitely-not-a-member@example.com"}' "$D/api/auth/start")"

echo
if [ "$fail" -gt 0 ]; then
  echo "DEPLOY FAILED — $fail smoke test(s) failed."
  echo "If 'valid token serves the doc' passed but 'lambda accepts the edge's token' did"
  echo "not, the edge function and the Lambda hold different secrets — publish the edge"
  echo "function first, then update the Lambda. See infra/README.md."
  exit 1
fi
echo "deployed: $D"
