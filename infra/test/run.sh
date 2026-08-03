#!/usr/bin/env bash
# All checks that run without AWS or a browser.
#
#   ./infra/test/run.sh
#
# These are the ones worth running on every change. The live-stack smoke tests
# live at the end of infra/deploy.sh.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
fail=0
run() { echo; echo "── $1"; shift; "$@" || fail=$((fail+1)); }

# --- syntax -------------------------------------------------------------------
echo "── syntax"
TMP="$(mktemp -d)"
node -e "
const fs=require('fs');
const h=fs.readFileSync('index.html','utf8');
fs.writeFileSync(process.argv[1], [...h.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n'));
const l=fs.readFileSync('login/index.html','utf8');
fs.writeFileSync(process.argv[2], [...l.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x=>x[1]).join('\n'));
" "$TMP/page.js" "$TMP/login.js"
node --check "$TMP/page.js"            && echo "  ok   index.html inline script" || fail=$((fail+1))
node --check "$TMP/login.js"           && echo "  ok   login page script"        || fail=$((fail+1))
node --check infra/lambda/index.mjs    && echo "  ok   lambda handler"           || fail=$((fail+1))
node --check infra/build.mjs           && echo "  ok   build.mjs"                || fail=$((fail+1))
rm -rf "$TMP"

# --- CSS brace balance (an unterminated @media kills every rule after it) -----
node -e "
const s=require('fs').readFileSync('index.html','utf8');
const css=s.slice(s.indexOf('<style>')+7, s.indexOf('</style>'));
const o=(css.match(/{/g)||[]).length, c=(css.match(/}/g)||[]).length;
if(o!==c){ console.log('  FAIL CSS braces '+o+' open / '+c+' close'); process.exit(1); }
console.log('  ok   CSS braces balanced ('+o+')');
" || fail=$((fail+1))

# --- security ------------------------------------------------------------------
run "edge gate — forged-token matrix" \
  node infra/test/edge-gate.test.mjs infra/cf-session-gate.js

run "lambda ↔ edge agreement" \
  node infra/test/cross-verifier.test.mjs infra/lambda/index.mjs infra/cf-session-gate.js

# --- no secrets in anything that ships ----------------------------------------
echo
echo "── secret hygiene"
if grep -qE "sharedSecret|x-shared-secret" index.html; then
  echo "  FAIL index.html still references a shared secret"; fail=$((fail+1))
else
  echo "  ok   no shared secret in index.html"
fi
# Test for the ACTUAL secret value, not a pattern that might resemble one.
# (Grepping for "current=" matched `let current=secs[0]` in the scroll-spy.)
if [ -f dist/index.html ] && [ -f infra/.session-secret ]; then
  SEC="$(sed -n 's/^current=//p' infra/.session-secret)"
  if [ -n "$SEC" ] && grep -qF "$SEC" dist/index.html; then
    echo "  FAIL dist/index.html contains the session secret"; fail=$((fail+1))
  else
    echo "  ok   dist/index.html carries no secret"
  fi
  # The edge function is expected to carry it — assert it actually does, since a
  # silently un-templated function would reject every token in production.
  if [ -f dist/cf-session-gate.js ] && grep -qF "$SEC" dist/cf-session-gate.js; then
    echo "  ok   dist/cf-session-gate.js has the signing key templated in"
  elif [ -f dist/cf-session-gate.js ]; then
    echo "  FAIL dist/cf-session-gate.js was not templated"; fail=$((fail+1))
  fi
fi
if git -C "$ROOT" ls-files --error-unmatch infra/.session-secret >/dev/null 2>&1; then
  echo "  FAIL infra/.session-secret is tracked by git"; fail=$((fail+1))
else
  echo "  ok   infra/.session-secret is not tracked"
fi

# --- runtime DOM injection must only ever APPEND -------------------------------
# Comment anchor ids hash each element's index among its same-tag siblings.
# Appending leaves every existing index untouched; inserting before or
# prepending shifts them and silently orphans stored comments. The static anchor
# gate below cannot catch this, because runtime injection is not in the source
# markup — so guard the API instead.
echo
echo "── runtime DOM injection"
if grep -nE "insertBefore|\.prepend\(|insertAdjacent(HTML|Element)\('(afterbegin|beforebegin)'" index.html; then
  echo "  FAIL index.html inserts DOM before existing nodes — this shifts sibling"
  echo "       indices and orphans comment anchors. Append instead."
  fail=$((fail+1))
else
  echo "  ok   no insert-before/prepend anywhere (append-only)"
fi

# --- anchor stability ----------------------------------------------------------
# Comment anchor ids hash each element's ancestor chain, so any structural change
# inside #doc-content orphans stored comments. Compare against the last commit.
echo
echo "── anchor stability"
if git -C "$ROOT" rev-parse HEAD >/dev/null 2>&1 && git -C "$ROOT" cat-file -e HEAD:index.html 2>/dev/null; then
  TMP2="$(mktemp -d)"
  git -C "$ROOT" show HEAD:index.html > "$TMP2/base.html"
  node infra/test/anchor-gate.mjs "$TMP2/base.html" index.html || fail=$((fail+1))
  rm -rf "$TMP2"
else
  echo "  --   skipped (index.html not yet committed)"
fi

echo
if [ "$fail" -gt 0 ]; then echo "$fail CHECK GROUP(S) FAILED"; exit 1; fi
echo "ALL LOCAL CHECKS PASSED"
