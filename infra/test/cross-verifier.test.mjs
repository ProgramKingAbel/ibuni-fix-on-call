/**
 * Cross-verifier agreement test.
 *
 * The worst silent failure in this design is the Lambda and the CloudFront
 * Function disagreeing about token format or signing: the user logs in
 * successfully, the edge bounces them anyway, and it looks exactly like a cookie
 * bug. deploy.sh checks this against the live stack; this checks it locally,
 * before anything is deployed.
 *
 * It extracts the REAL mint/verify functions out of infra/lambda/index.mjs
 * (rather than reimplementing them) and runs their output through the REAL
 * CloudFront Function source.
 */
import { readFileSync } from 'node:fs';
import { createHmac, timingSafeEqual } from 'node:crypto';

const [, , lambdaSrc, edgeSrc] = process.argv;
const KEY = 'shared-key-for-the-cross-verifier-test-xxxxx';
const OLD = 'the-previous-key-during-a-rotation-yyyyyyyyyy';

/* ---- pull the real functions out of the Lambda ---------------------------- */
const lam = readFileSync(lambdaSrc, 'utf8');
const grab = (name) => {
  const m = lam.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n\\}`, 'm'));
  if (!m) throw new Error(`could not extract ${name}() from the Lambda source`);
  return m[0];
};

const lambdaCtx = new Function('createHmac', 'timingSafeEqual', 'SECRET', 'SECRET_PREV', `
  const ISS = 'foc-doc';
  const TTL_DAYS = 7;
  const now = () => Math.floor(Date.now() / 1000);
  const b64u = (buf) => Buffer.from(buf).toString('base64').replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
  ${grab('mintToken')}
  ${grab('verifyToken')}
  return { mintToken, verifyToken };
`)(createHmac, timingSafeEqual, KEY, OLD);

/* ---- load the real edge function ------------------------------------------ */
let edge = readFileSync(edgeSrc, 'utf8')
  .replace('__SECRET_CURRENT__', KEY)
  .replace('__SECRET_PREV__', OLD)
  .replace(/^import crypto from 'crypto';$/m, '');
const edgeHandler = new Function('__createHmac', `
  const crypto = { createHmac: __createHmac };
  String.bytesFrom = (s, enc) => Buffer.from(s, enc).toString('latin1');
  ${edge}
  return handler;
`)(createHmac);

const edgeAccepts = (tok) => {
  const out = edgeHandler({ request: { method:'GET', uri:'/', headers:{}, querystring:{},
    cookies: tok == null ? {} : { '__Host-focs': { value: tok } } } });
  return !(out && out.statusCode === 302);
};

let fail = 0;
const check = (name, cond) => {
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}`); fail++; }
};

console.log('Lambda ↔ edge cross-verifier agreement\n');

// 1. what the Lambda mints, the edge must accept — the whole ballgame
const tok = lambdaCtx.mintToken('abel@example.com');
check('edge accepts a token the Lambda minted', edgeAccepts(tok));
check('Lambda accepts its own token', !!lambdaCtx.verifyToken(tok));

// 2. the subject survives the round trip (it becomes the comment author)
const p = lambdaCtx.verifyToken(tok);
check('subject round-trips intact', p && p.sub === 'abel@example.com');
check('issuer is the constant, not a hostname', p && p.iss === 'foc-doc');
check('expiry is ~7 days out', p && Math.abs((p.exp - p.iat) - 7 * 86400) < 5);

// 3. rotation overlap: a token signed with the OLD key must still be accepted by
//    BOTH sides, or a graceful rotation signs everyone out.
const ctxOld = new Function('createHmac', 'timingSafeEqual', 'SECRET', 'SECRET_PREV', `
  const ISS='foc-doc'; const TTL_DAYS=7;
  const now = () => Math.floor(Date.now()/1000);
  const b64u = (buf) => Buffer.from(buf).toString('base64').replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
  ${grab('mintToken')}
  return { mintToken };
`)(createHmac, timingSafeEqual, OLD, '');
const oldTok = ctxOld.mintToken('abel@example.com');
check('edge accepts a prev-key token (rotation overlap)', edgeAccepts(oldTok));
check('Lambda accepts a prev-key token (rotation overlap)', !!lambdaCtx.verifyToken(oldTok));

// 4. both must reject the same forgeries — a gap on either side is a hole
const attacker = new Function('createHmac', 'timingSafeEqual', 'SECRET', 'SECRET_PREV', `
  const ISS='foc-doc'; const TTL_DAYS=7;
  const now = () => Math.floor(Date.now()/1000);
  const b64u = (buf) => Buffer.from(buf).toString('base64').replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
  ${grab('mintToken')}
  return { mintToken };
`)(createHmac, timingSafeEqual, 'attacker-controlled-key', '');
const forged = attacker.mintToken('attacker@evil.example');
check('edge rejects a foreign-key token', !edgeAccepts(forged));
check('Lambda rejects a foreign-key token', !lambdaCtx.verifyToken(forged));

const expired = new Function('createHmac', 'SECRET', `
  const b64u = (buf) => Buffer.from(buf).toString('base64').replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
  const h = b64u(JSON.stringify({alg:'HS256',typ:'JWT'}));
  const p = b64u(JSON.stringify({sub:'x',iss:'foc-doc',exp:Math.floor(Date.now()/1000)-99999}));
  const d = h + '.' + p;
  return d + '.' + b64u(createHmac('sha256', SECRET).update(d).digest());
`)(createHmac, KEY);
check('edge rejects an expired token', !edgeAccepts(expired));
check('Lambda rejects an expired token', !lambdaCtx.verifyToken(expired));

// 5. a desync must be *detectable*, not silent — this is what deploy.sh catches
const desynced = new Function('createHmac', 'SECRET', `
  const b64u = (buf) => Buffer.from(buf).toString('base64').replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');
  const h = b64u(JSON.stringify({alg:'HS256',typ:'JWT'}));
  const p = b64u(JSON.stringify({sub:'x',iss:'foc-doc',exp:Math.floor(Date.now()/1000)+3600}));
  const d = h + '.' + p;
  return d + '.' + b64u(createHmac('sha256', SECRET).update(d).digest());
`)(createHmac, 'a-key-neither-side-knows');
check('a desynced token is rejected by both (deploy.sh would fail)',
  !edgeAccepts(desynced) && !lambdaCtx.verifyToken(desynced));

console.log(fail ? `\n${fail} CHECK(S) FAILED` : '\nLAMBDA AND EDGE AGREE');
process.exit(fail ? 1 : 0);
