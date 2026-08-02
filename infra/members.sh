#!/usr/bin/env bash
# The allowlist. The DynamoDB __members partition IS the list — there is no
# second copy to drift out of sync.
#
#   ./infra/members.sh list
#   ./infra/members.sh add    <email> "<name>" "<role>" [days]
#   ./infra/members.sh remove <email>
#   ./infra/members.sh code   <email>          # mint + print a code, no email sent
#   ./infra/members.sh invite <email>          # single-use break-glass link
#   ./infra/members.sh log    [hours]          # who signed in recently
#
# `code` and `invite` are the escape hatches for when SES is quarantined or a
# recipient's mail gateway is hostile — read the code down the phone, or send the
# link over Signal/WhatsApp.

source "$(dirname "$0")/env.sh"

cmd="${1:-list}"

case "$cmd" in

list)
  aws dynamodb query --table-name "$TABLE" \
    --key-condition-expression 'anchor_id = :m' \
    --expression-attribute-values '{":m":{"S":"__members"}}' \
    --output json \
  | jq -r '.Items[] | [
      .sort_key.S,
      (.name.S // "-"),
      (.role.S // "-"),
      (if .active.BOOL == false then "INACTIVE" else "active" end),
      (if .expires_at then "expires " + (.expires_at.N|tonumber|todate) else "no expiry" end)
    ] | @tsv' | column -t -s $'\t'
  ;;

add)
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  name="${3:?name required}"
  role="${4:-}"
  days="${5:-}"
  extra=""
  [ -n "$days" ] && extra=",\"expires_at\":{\"N\":\"$(( $(date +%s) + days*86400 ))\"}"
  aws dynamodb put-item --table-name "$TABLE" --item "{
    \"anchor_id\":{\"S\":\"__members\"},
    \"sort_key\":{\"S\":\"$email\"},
    \"name\":{\"S\":\"$name\"},
    \"role\":{\"S\":\"$role\"},
    \"active\":{\"BOOL\":true},
    \"added_at\":{\"N\":\"$(date +%s)\"}$extra
  }" >/dev/null
  echo "added $email ($name)${days:+ — expires in $days days}"
  echo "note: they must also be a verified SES recipient while the account is in the sandbox."
  ;;

remove)
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  aws dynamodb delete-item --table-name "$TABLE" \
    --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" >/dev/null
  echo "removed $email"
  echo
  echo "They lose comment access and the ability to sign in again immediately."
  echo "An already-issued session cookie still reads the document until it expires"
  echo "(up to 7 days). To cut that off now: ./infra/rotate-secret.sh"
  echo "— everyone re-authenticates once."
  ;;

code)
  # Mints an OTP and prints it instead of emailing. For when the code is stuck in
  # a spam quarantine and you need to read it to someone on a call.
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  load_secrets
  member="$(aws dynamodb get-item --table-name "$TABLE" \
    --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" --output json)"
  [ "$(echo "$member" | jq -r '.Item // empty')" ] || { echo "ERROR: $email is not a member" >&2; exit 1; }

  CODE="$(od -An -N4 -tu4 < /dev/urandom | tr -d ' \n' | awk '{printf "%06d", $1 % 1000000}')"
  HASH="$(printf '%s:%s:%s' "$CODE" "$email" "$OTP_PEPPER" | openssl dgst -sha256 -hex | awk '{print $NF}')"
  aws dynamodb put-item --table-name "$TABLE" --item "{
    \"anchor_id\":{\"S\":\"__otp\"},
    \"sort_key\":{\"S\":\"$email\"},
    \"code_hash\":{\"S\":\"$HASH\"},
    \"expires_at\":{\"N\":\"$(( $(date +%s) + 600 ))\"},
    \"attempts\":{\"N\":\"0\"},
    \"sent_at\":{\"N\":\"$(date +%s)\"}
  }" >/dev/null
  echo "code for $email: $CODE   (valid 10 minutes, single use)"
  ;;

invite)
  # Single-use signed link, 24h. Send over Signal/WhatsApp — not email.
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  load_secrets
  b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  JTI="i_$(od -An -N8 -tx1 < /dev/urandom | tr -d ' \n')"
  H="$(printf '{"alg":"HS256","typ":"JWT"}' | b64u)"
  P="$(printf '{"sub":"%s","iss":"foc-doc","pur":"invite","jti":"%s","exp":%d}' \
        "$email" "$JTI" $(( $(date +%s) + 86400 )) | b64u)"
  G="$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -hmac "$SESSION_CURRENT" -binary | b64u)"
  echo "https://$(dist_domain)/enter?t=$H.$P.$G"
  echo "(valid 24h, single use — send over Signal/WhatsApp, not email)"
  ;;

log)
  hours="${2:-24}"
  echo "sign-ins in the last ${hours}h:"
  aws logs filter-log-events --log-group-name "/aws/lambda/$FUNC" \
    --start-time "$(( ($(date +%s) - hours*3600) * 1000 ))" \
    --filter-pattern '"\"evt\":\"login\""' \
    --query 'events[].message' --output text 2>/dev/null \
  | tr '\t' '\n' | sed 's/^[[:space:]]*//' | grep -o '{.*}' \
  | jq -r '[.ts, .email, .ip] | @tsv' 2>/dev/null | column -t -s $'\t' \
  || echo "  (none, or the log group does not exist yet)"
  ;;

*)
  sed -n '2,20p' "$0"
  exit 1
  ;;
esac
