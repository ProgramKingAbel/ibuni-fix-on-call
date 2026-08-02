/**
 * foc-session-gate — CloudFront Function, viewer-request, runtime cloudfront-js-2.0.
 *
 * Attached to the DEFAULT behaviour only. Never attach it to /api/* (the Lambda
 * checks the cookie itself and must be reachable to issue one) or to /login*
 * (that page must be reachable to log in at all — attaching it there is an
 * infinite redirect).
 *
 * Verifies an HS256 JWT carried in the __Host-focs cookie. Anything wrong → 302
 * to /login?r=<uri>. A valid token passes the request through untouched.
 *
 * KEYS are injected at deploy time from infra/.session-secret by infra/build.mjs,
 * which writes dist/cf-session-gate.js (gitignored). CloudFront Functions have no
 * environment variables and no Secrets Manager access, so the secret lives in the
 * published function source. Anyone with cloudfront:GetFunction can read it —
 * the same trust boundary as lambda:GetFunctionConfiguration reading the env var.
 *
 *   KEYS[0] = current  (what the Lambda signs with now)
 *   KEYS[1] = previous (accepted during a rotation overlap; may be empty)
 *
 * Rotation ordering is load-bearing — see infra/rotate-secret.sh. Publish this
 * function BEFORE updating the Lambda, or every user is bounced in a loop that
 * looks exactly like a cookie bug.
 */
import crypto from 'crypto';

var KEYS   = ['__SECRET_CURRENT__', '__SECRET_PREV__'];
var ISS    = 'foc-doc';   // logical issuer, NOT the hostname — so adding a custom
                          // domain later does not invalidate every live session
var COOKIE = '__Host-focs';
var LOGIN  = '/login';
var SKEW   = 60;          // seconds of clock leeway on exp

function b64uPad(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return s;
}

function sign(data, key) {
  return crypto.createHmac('sha256', key).update(data).digest('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// constant-time compare — a length check leaks only the length, which is fixed here
function eq(a, b) {
  if (a.length !== b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function bounce(uri) {
  return {
    statusCode: 302,
    statusDescription: 'Found',
    headers: {
      'location':        { value: LOGIN + '?r=' + encodeURIComponent(uri) },
      'cache-control':   { value: 'no-store' },
      'referrer-policy': { value: 'no-referrer' }
    }
  };
}

function handler(event) {
  var req = event.request;
  var uri = req.uri;

  var c = req.cookies[COOKIE];
  if (!c || !c.value) return bounce(uri);

  var t = c.value.split('.');
  if (t.length !== 3) return bounce(uri);

  /* The header segment is deliberately never parsed. Only HS256 is ever
     attempted, so a forged {"alg":"none"} or {"alg":"RS256"} header cannot
     change the code path taken. That closes the whole alg-confusion class. */
  var data = t[0] + '.' + t[1];
  var ok = false;
  for (var k = 0; k < KEYS.length; k++) {
    if (KEYS[k] && eq(sign(data, KEYS[k]), t[2])) { ok = true; break; }
  }
  if (!ok) return bounce(uri);

  /* Buffer.from, NOT String.bytesFrom. The latter is what the CloudFront
     Functions docs show, but the live runtime now throws
     "String.bytesFrom() is deprecated, please use another method Buffer.from()".
     Because the throw lands in this catch, the symptom was a correctly-signed
     token being bounced — signature verified, payload never parsed. */
  var p;
  try { p = JSON.parse(Buffer.from(b64uPad(t[1]), 'base64').toString('utf8')); }
  catch (e) { return bounce(uri); }

  var now = Math.floor(Date.now() / 1000);
  if (p.iss !== ISS) return bounce(uri);
  if (typeof p.exp !== 'number' || p.exp + SKEW < now) return bounce(uri);

  return req;
}
