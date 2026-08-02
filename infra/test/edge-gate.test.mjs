/**
 * Runs the real CloudFront Function source against a forged-token matrix, with
 * the CloudFront runtime shimmed. This tests the actual security logic locally —
 * no AWS, no browser.
 *
 * It also mints tokens exactly the way the Lambda does, so a disagreement
 * between the two implementations shows up here rather than as "login works,
 * then bounces you" in production.
 */
import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';

const SRC = process.argv[2];
const KEY = 'test-secret-current-aaaaaaaaaaaaaaaaaaaaaaaa';
const OLD = 'test-secret-previous-bbbbbbbbbbbbbbbbbbbbbbb';

// --- load the function source with secrets injected, as build.mjs does -------
let src = readFileSync(SRC, 'utf8')
  .replace('__SECRET_CURRENT__', KEY)
  .replace('__SECRET_PREV__', OLD)
  .replace(/^import crypto from 'crypto';$/m, '');   // provided by the shim below

// --- CloudFront Functions runtime shim --------------------------------------
// Only `crypto` needs shimming. Buffer is native in both Node and the live
// CloudFront runtime.
//
// Deliberately NOT shimming String.bytesFrom: it is what the CloudFront docs
// show, but the live runtime throws on it. Shimming it here is what let a
// broken function pass this test once — if the source starts using it again,
// this harness must fail rather than paper over it.
const shim = `
const crypto = { createHmac: __createHmac };
`;
// Strip comments before checking — the source legitimately *mentions*
// String.bytesFrom in the comment explaining why it must not be used.
const codeOnly = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
if (/String\.bytesFrom\s*\(/.test(codeOnly)) {
  console.error('FAIL: cf-session-gate.js uses String.bytesFrom(), which throws in the live '
    + 'CloudFront runtime ("deprecated, please use Buffer.from()"). Use Buffer.from instead.');
  process.exit(1);
}
const factory = new Function('__createHmac', shim + src + '\nreturn handler;');
const handler = factory(createHmac);

// --- mint tokens the way infra/lambda/index.mjs does -------------------------
const b64u = (b) => Buffer.from(b).toString('base64')
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

function mint({ key = KEY, iss = 'foc-doc', exp = Math.floor(Date.now() / 1000) + 3600,
                alg = 'HS256', sub = 'abel@example.com' } = {}) {
  const h = b64u(JSON.stringify({ alg, typ: 'JWT' }));
  const p = b64u(JSON.stringify({ sub, iss, exp }));
  const d = `${h}.${p}`;
  return `${d}.${b64u(createHmac('sha256', key).update(d).digest())}`;
}

const req = (cookieValue) => ({
  request: {
    method: 'GET', uri: '/', headers: {}, querystring: {},
    cookies: cookieValue == null ? {} : { '__Host-focs': { value: cookieValue } },
  },
});

// A pass-through returns the request object; a bounce returns a 302 response.
const verdict = (out) => (out && out.statusCode === 302 ? 'BOUNCE' : 'PASS');

let fail = 0;
const check = (name, cookie, want) => {
  const got = verdict(handler(req(cookie)));
  if (got === want) console.log(`  ok   ${name} → ${got}`);
  else { console.log(`  FAIL ${name} → ${got}, expected ${want}`); fail++; }
};

console.log('CloudFront edge gate — security matrix\n');

check('no cookie at all',                 null,                                    'BOUNCE');
check('empty cookie',                     '',                                      'BOUNCE');
check('not a JWT',                        'garbage',                               'BOUNCE');
check('wrong segment count',              'aaa.bbb',                               'BOUNCE');
check('malformed segments',               'aaa.bbb.ccc',                           'BOUNCE');
check('VALID token',                      mint(),                                  'PASS');
check('valid, signed with the PREV key',  mint({ key: OLD }),                      'PASS');
check('signed with an unknown key',       mint({ key: 'attacker-key' }),           'BOUNCE');
check('expired',                          mint({ exp: Math.floor(Date.now()/1e3) - 3600 }), 'BOUNCE');
check('inside the 60s clock skew',        mint({ exp: Math.floor(Date.now()/1e3) - 30 }),   'PASS');
check('wrong issuer',                     mint({ iss: 'evil' }),                   'BOUNCE');
check('exp missing',                      (() => {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64u(JSON.stringify({ sub: 'x', iss: 'foc-doc' }));
  const d = `${h}.${p}`;
  return `${d}.${b64u(createHmac('sha256', KEY).update(d).digest())}`;
})(),                                                                              'BOUNCE');
check('exp as a string, not a number',    (() => {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64u(JSON.stringify({ sub: 'x', iss: 'foc-doc', exp: '99999999999' }));
  const d = `${h}.${p}`;
  return `${d}.${b64u(createHmac('sha256', KEY).update(d).digest())}`;
})(),                                                                              'BOUNCE');
check('tampered signature (last char)',   (() => { const t = mint(); return t.slice(0, -1) + (t.slice(-1) === 'A' ? 'B' : 'A'); })(), 'BOUNCE');
check('tampered payload, old signature',  (() => {
  const t = mint().split('.');
  return [t[0], b64u(JSON.stringify({ sub: 'attacker@evil', iss: 'foc-doc', exp: 9e9 })), t[2]].join('.');
})(),                                                                              'BOUNCE');
// The alg-confusion class: the header is never parsed, so these cannot select a
// different code path however they are forged.
check('alg:none, empty signature',        (() => {
  const h = b64u(JSON.stringify({ alg: 'none' }));
  const p = b64u(JSON.stringify({ sub: 'x', iss: 'foc-doc', exp: 9e9 }));
  return `${h}.${p}.`;
})(),                                                                              'BOUNCE');
check('alg:none, signature dropped',      (() => {
  const h = b64u(JSON.stringify({ alg: 'none' }));
  const p = b64u(JSON.stringify({ sub: 'x', iss: 'foc-doc', exp: 9e9 }));
  return `${h}.${p}.${b64u('')}`;
})(),                                                                              'BOUNCE');
check('header claims RS256',              (() => {
  const h = b64u(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const p = b64u(JSON.stringify({ sub: 'x', iss: 'foc-doc', exp: 9e9 }));
  const d = `${h}.${p}`;
  return `${d}.${b64u(createHmac('sha256', KEY).update(d).digest())}`;
})(),                                                                              'PASS');  // correctly signed — alg field is irrelevant
check('payload is not JSON',              (() => {
  const h = b64u(JSON.stringify({ alg: 'HS256' }));
  const p = b64u('not json at all');
  const d = `${h}.${p}`;
  return `${d}.${b64u(createHmac('sha256', KEY).update(d).digest())}`;
})(),                                                                              'BOUNCE');

// --- the redirect itself ------------------------------------------------------
const bounced = handler({ request: { method: 'GET', uri: '/deep/page', headers: {}, querystring: {}, cookies: {} } });
const loc = bounced.headers?.location?.value;
if (loc === '/login?r=%2Fdeep%2Fpage') console.log(`  ok   redirect preserves the path → ${loc}`);
else { console.log(`  FAIL redirect was ${loc}`); fail++; }
if (bounced.headers?.['cache-control']?.value === 'no-store') console.log('  ok   redirect is not cacheable');
else { console.log('  FAIL redirect is missing cache-control:no-store'); fail++; }

console.log(fail ? `\n${fail} CHECK(S) FAILED` : '\nALL EDGE-GATE CHECKS PASSED');
process.exit(fail ? 1 : 0);
