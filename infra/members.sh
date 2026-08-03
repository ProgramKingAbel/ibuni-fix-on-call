#!/usr/bin/env bash
# The allowlist. The DynamoDB __members partition IS the list — there is no
# second copy to drift out of sync.
#
#   ./infra/members.sh list
#   ./infra/members.sh add     <email> "<name>" "<role>" [days]
#   ./infra/members.sh edit    <email> "<name>" "<role>"   # change name/role in place
#   ./infra/members.sh owner   <email> [on|off] # may resolve comments (default on)
#   ./infra/members.sh disable <email>         # revoke access, KEEP the record
#   ./infra/members.sh enable  <email>         # restore access
#   ./infra/members.sh expire  <email> <days>  # time-box access (or 0 to clear)
#   ./infra/members.sh remove  <email>         # delete outright
#   ./infra/members.sh code    <email>         # mint + print a code, no email sent
#   ./infra/members.sh invite  <email>         # single-use break-glass link
#   ./infra/members.sh log     [hours]         # who signed in recently
#
# Prefer `disable` over `remove` — it revokes access identically but keeps the
# record, so the allowlist still shows who used to have access and when.
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
      (if .owner.BOOL == true then "owner" else "-" end),
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

edit)
  # Update name/role in place — an UpdateItem, so added_at and expires_at survive
  # (re-running `add` would overwrite the whole record and reset them).
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  name="${3:?name required}"
  role="${4:-}"
  aws dynamodb update-item --table-name "$TABLE" \
    --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" \
    --update-expression 'SET #n = :n, #r = :r' \
    --condition-expression 'attribute_exists(sort_key)' \
    --expression-attribute-names '{"#n":"name","#r":"role"}' \
    --expression-attribute-values "{\":n\":{\"S\":\"$name\"},\":r\":{\"S\":\"$role\"}}" >/dev/null \
    && echo "updated $email → $name${role:+, $role}" \
    || echo "ERROR: $email is not on the allowlist (use 'add')" >&2
  ;;

owner)
  # Grant or revoke the ability to resolve comments. Everyone can read and
  # comment; only an owner can mark feedback resolved.
  #   ./infra/members.sh owner <email> [on|off]
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  val=$([ "${3:-on}" = "off" ] && echo false || echo true)
  aws dynamodb update-item --table-name "$TABLE" \
    --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" \
    --update-expression 'SET #o = :o' \
    --condition-expression 'attribute_exists(sort_key)' \
    --expression-attribute-names '{"#o":"owner"}' \
    --expression-attribute-values "{\":o\":{\"BOOL\":$val}}" >/dev/null \
    && echo "$email owner=$val" \
    || { echo "ERROR: $email is not on the allowlist" >&2; exit 1; }
  ;;

disable|enable)
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  val=$([ "$cmd" = "enable" ] && echo true || echo false)
  aws dynamodb update-item --table-name "$TABLE" \
    --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" \
    --update-expression 'SET active = :a' \
    --condition-expression 'attribute_exists(sort_key)' \
    --expression-attribute-values "{\":a\":{\"BOOL\":$val}}" >/dev/null \
    && echo "$cmd""d $email" \
    || { echo "ERROR: $email is not on the allowlist" >&2; exit 1; }
  if [ "$cmd" = "disable" ]; then
    echo
    echo "Comment access and sign-in stop immediately. An already-issued session"
    echo "cookie still reads the document until it expires (up to 7 days)."
    echo "To cut that off now: ./infra/rotate-secret.sh --force"
  fi
  ;;

expire)
  email="$(echo "${2:?email required}" | tr '[:upper:]' '[:lower:]')"
  days="${3:?days required (0 to clear)}"
  if [ "$days" = "0" ]; then
    aws dynamodb update-item --table-name "$TABLE" \
      --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" \
      --update-expression 'REMOVE expires_at' \
      --condition-expression 'attribute_exists(sort_key)' >/dev/null \
      && echo "$email now has no expiry"
  else
    until_ts=$(( $(date +%s) + days*86400 ))
    aws dynamodb update-item --table-name "$TABLE" \
      --key "{\"anchor_id\":{\"S\":\"__members\"},\"sort_key\":{\"S\":\"$email\"}}" \
      --update-expression 'SET expires_at = :e' \
      --condition-expression 'attribute_exists(sort_key)' \
      --expression-attribute-values "{\":e\":{\"N\":\"$until_ts\"}}" >/dev/null \
      && echo "$email expires in $days days ($(date -d "@$until_ts" 2>/dev/null || echo "$until_ts"))"
  fi
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
  # Must be /api/enter, not /enter: any other path falls to the default
  # CloudFront behaviour, whose session gate bounces it to /login before the
  # Lambda ever sees it.
  echo "https://$(dist_domain)/api/enter?t=$H.$P.$G"
  echo "(valid 24h, single use. Safe to paste into WhatsApp/Signal: opening"
  echo " the link only shows a confirm page; it is spent on the button press.)"
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
  sed -n '2,26p' "$0"
  exit 1
  ;;
esac
