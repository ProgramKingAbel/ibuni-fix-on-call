/**
 * Fix On Call — document API Lambda (Function URL, fronted by CloudFront /api/*).
 *
 * Auth routes
 *   POST /api/auth/start   { email }               → { ok:true }   (always — no enumeration)
 *   POST /api/auth/verify  { email, code }         → { email, name, role } + Set-Cookie
 *   POST /api/auth/logout                          → clears the cookies
 *   GET  /api/me                                   → { email, name, role, exp }
 *   GET  /enter?t=<token>                          → break-glass invite, 302 to /
 *
 * Comment routes (unchanged contract from the front-end storage adapter)
 *   GET  /api/comments?doc_version=v0.1            → { comments: [...] }
 *   POST /api/comments { ...comment }              → { comment }   (add)
 *   POST /api/comments { op:'update', id, patch }  → { comment }   (resolve/reopen)
 *   POST /api/comments { op:'bulkAdd', recs:[] }   → { comments }  (carry-forward)
 *
 * Auth model: an HS256 session JWT in the __Host-focs cookie, minted here and
 * verified BOTH here and at the edge (infra/cf-session-gate.js). The two must
 * agree on SESSION_SECRET — see rotate-secret.sh for the ordering.
 *
 * No CORS headers are set anywhere. /api/* is served from the same CloudFront
 * domain as the page, so it is same-origin and CORS never enters the picture.
 * Do not add a --cors config to the Function URL either.
 *
 * Storage: one DynamoDB table, four partitions —
 *   <anchor id> / <created_at>#<id>   comments
 *   __members   / <email>            allowlist: name, role, active, expires_at?
 *   __otp       / <email>            code_hash, expires_at, attempts, sent_at
 *   __rl        / ip#<ip>#<hour>     rate-limit counters
 *
 * TTL on expires_at is best-effort (up to 48h), so every read checks it
 * explicitly. Never treat TTL deletion as a security control.
 */
import { createHmac, createHash, randomInt, timingSafeEqual } from 'node:crypto';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient, PutCommand, GetCommand, ScanCommand,
  UpdateCommand, DeleteCommand, BatchWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import { SESv2Client, SendEmailCommand } from '@aws-sdk/client-sesv2';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const ses = new SESv2Client({});

const TABLE      = process.env.TABLE || 'foc-doc';
const SECRET     = process.env.SESSION_SECRET || '';
const SECRET_PREV= process.env.SESSION_SECRET_PREV || '';
const PEPPER     = process.env.OTP_PEPPER || '';
const FROM       = process.env.FROM_ADDR || '';
const ISS        = process.env.ISS || 'foc-doc';
const TTL_DAYS   = Number(process.env.TTL_DAYS || 7);
const COOKIE     = '__Host-focs';
const COOKIE_HINT= '__Host-focs_exp';

const OTP_TTL_S      = 600;   // 10 minutes
const OTP_MAX_TRIES  = 5;
const RESEND_COOLDOWN= 60;    // seconds between sends to one address
const SENDS_PER_HOUR = 5;     // per address
const IP_STARTS_HOUR = 20;    // per IP

/* Payload format 2.0 (both API Gateway HTTP APIs and Lambda Function URLs):
   header VALUES must be strings, and multiple Set-Cookie headers go in a
   top-level `cookies` array — NOT as an array under headers['set-cookie'].
   Getting that wrong produces a bare 500 from API Gateway with a completely
   healthy-looking invocation in the logs, which is a miserable thing to debug. */
const json = (code, body, cookies) => {
  const res = {
    statusCode: code,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    body: JSON.stringify(body),
  };
  if (cookies && cookies.length) res.cookies = cookies;
  return res;
};
const now   = () => Math.floor(Date.now() / 1000);
const clamp = (s, n) => (s == null ? '' : String(s)).trim().slice(0, n);
const newId = () => 'c_' + Math.random().toString(36).slice(2, 10);
const b64u  = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/* ---------------- session tokens (HS256, verified here and at the edge) ------ */

function mintToken(email, ttlDays = TTL_DAYS) {
  const header  = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = b64u(JSON.stringify({ sub: email, iss: ISS, exp: now() + ttlDays * 86400, iat: now() }));
  const data = `${header}.${payload}`;
  return `${data}.${b64u(createHmac('sha256', SECRET).update(data).digest())}`;
}

// Accepts the previous key too, so a rotation doesn't sign everyone out.
function verifyToken(tok) {
  if (!tok || typeof tok !== 'string') return null;
  const parts = tok.split('.');
  if (parts.length !== 3) return null;
  const data = `${parts[0]}.${parts[1]}`;
  // The header is never parsed — only HS256 is attempted, so a forged
  // {"alg":"none"} cannot select a different code path.
  const ok = [SECRET, SECRET_PREV].some((k) => {
    if (!k) return false;
    const want = Buffer.from(b64u(createHmac('sha256', k).update(data).digest()));
    const got  = Buffer.from(parts[2]);
    return want.length === got.length && timingSafeEqual(want, got);
  });
  if (!ok) return null;
  let p;
  try { p = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')); } catch { return null; }
  if (p.iss !== ISS) return null;
  if (typeof p.exp !== 'number' || p.exp < now()) return null;
  return p;
}

function sessionCookies(token, maxAge) {
  const exp = now() + maxAge;
  return [
    `${COOKIE}=${token}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=${maxAge}`,
    // Non-HttpOnly hint carrying ONLY the expiry epoch. Leaks nothing, and lets
    // the login page detect "I hold an unexpired cookie but the edge still
    // bounces me" — i.e. an edge/Lambda secret desync — instead of looping.
    `${COOKIE_HINT}=${exp}; Path=/; Secure; SameSite=Lax; Max-Age=${maxAge}`,
  ];
}
const clearCookies = () => [
  `${COOKIE}=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0`,
  `${COOKIE_HINT}=; Path=/; Secure; SameSite=Lax; Max-Age=0`,
];

const readCookie = (event, name) => {
  const raw = event.cookies || [];
  for (const c of raw) {
    const i = c.indexOf('=');
    if (i > 0 && c.slice(0, i).trim() === name) return c.slice(i + 1);
  }
  return null;
};

/* ---------------- members / otp / rate limiting ----------------------------- */

const emailOk = (e) => /^[^@\s]+@[^@\s.]+\.[^@\s]+$/.test(e) && e.length <= 160;

async function getMember(email) {
  const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { anchor_id: '__members', sort_key: email } }));
  const m = r.Item;
  if (!m || m.active === false) return null;
  if (m.expires_at && m.expires_at < now()) return null;   // TTL is best-effort — check explicitly
  return m;
}

const hashCode = (code, email) => createHash('sha256').update(`${code}:${email}:${PEPPER}`).digest('hex');

async function bumpIp(ip) {
  const key = `ip#${ip}#${Math.floor(now() / 3600)}`;
  const r = await ddb.send(new UpdateCommand({
    TableName: TABLE,
    Key: { anchor_id: '__rl', sort_key: key },
    UpdateExpression: 'ADD #n :one SET expires_at = if_not_exists(expires_at, :e)',
    ExpressionAttributeNames: { '#n': 'count' },
    ExpressionAttributeValues: { ':one': 1, ':e': now() + 7200 },
    ReturnValues: 'ALL_NEW',
  }));
  return r.Attributes?.count || 1;
}

async function sendCode(email, name, code) {
  await ses.send(new SendEmailCommand({
    FromEmailAddress: FROM,
    Destination: { ToAddresses: [email] },
    Content: {
      Simple: {
        // Code in the subject: visible in the phone's notification, no need to
        // open the mail. Slight shoulder-surfing exposure, worth it.
        Subject: { Data: `Fix On Call — your access code: ${code}` },
        Body: {
          // Deliberately zero links. A link-free mail is far less likely to be
          // rewritten by a URL-defence gateway or scored as phishing, and it
          // structurally removes the "scanner prefetches and consumes the link"
          // failure that kills magic-link flows behind corporate mail security.
          Text: { Data:
`${name ? name + ',' : 'Hello,'}

Your access code for the Fix On Call platform overview is:

    ${code}

Type it into the tab you already have open. The code expires in 10 minutes and
can only be used once.

If you didn't request this, you can ignore this message.

— Fix On Call
This document is confidential.` },
        },
      },
    },
  }));
}

/* ---------------- routes ---------------------------------------------------- */

async function authStart(event, body) {
  const email = clamp(body.email, 160).toLowerCase();
  // Always the same answer, whether or not the address is a member. The login
  // page says "if that address is on the list, a code is on its way".
  const ok = json(200, { ok: true });
  if (!emailOk(email)) return ok;

  const ip = event.requestContext?.http?.sourceIp || 'unknown';
  if (await bumpIp(ip) > IP_STARTS_HOUR) return ok;

  const member = await getMember(email);
  if (!member) return ok;

  const prev = await ddb.send(new GetCommand({ TableName: TABLE, Key: { anchor_id: '__otp', sort_key: email } }));
  const p = prev.Item;
  const hour = Math.floor(now() / 3600);
  if (p) {
    if (p.sent_at && now() - p.sent_at < RESEND_COOLDOWN) return ok;    // silent cooldown
    if (p.sends_hour === hour && (p.sends || 0) >= SENDS_PER_HOUR) return ok;
  }

  const code = String(randomInt(0, 1000000)).padStart(6, '0');
  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: {
      anchor_id: '__otp', sort_key: email,
      code_hash: hashCode(code, email),
      expires_at: now() + OTP_TTL_S,
      attempts: 0, sent_at: now(),
      sends_hour: hour,
      sends: (p && p.sends_hour === hour ? (p.sends || 0) : 0) + 1,
    },
  }));
  await sendCode(email, member.name, code);
  return ok;
}

async function authVerify(event, body) {
  const email = clamp(body.email, 160).toLowerCase();
  const code  = clamp(body.code, 12);
  // One generic failure for every cause: unknown address, wrong code, expired
  // code, too many attempts. Never distinguish them.
  const bad = json(401, { error: 'invalid' });
  if (!emailOk(email) || !/^\d{6}$/.test(code)) return bad;

  const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { anchor_id: '__otp', sort_key: email } }));
  const otp = r.Item;
  if (!otp || otp.expires_at < now()) return bad;
  if ((otp.attempts || 0) >= OTP_MAX_TRIES) {
    await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { anchor_id: '__otp', sort_key: email } }));
    return bad;
  }

  const want = Buffer.from(otp.code_hash || '');
  const got  = Buffer.from(hashCode(code, email));
  if (want.length !== got.length || !timingSafeEqual(want, got)) {
    await ddb.send(new UpdateCommand({
      TableName: TABLE, Key: { anchor_id: '__otp', sort_key: email },
      UpdateExpression: 'ADD attempts :one', ExpressionAttributeValues: { ':one': 1 },
    }));
    return bad;
  }

  // Re-check membership at verify time — someone removed between start and
  // verify must not get in.
  const member = await getMember(email);
  if (!member) return bad;

  await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { anchor_id: '__otp', sort_key: email } })); // single use

  // Access log. This is the record of who opened the document and when.
  console.log(JSON.stringify({
    evt: 'login', email,
    ip: event.requestContext?.http?.sourceIp,
    ua: event.headers?.['user-agent'], ts: new Date().toISOString(),
  }));

  const maxAge = TTL_DAYS * 86400;
  return json(200, { email, name: member.name || email, role: member.role || '' },
    sessionCookies(mintToken(email), maxAge));
}

async function me(event) {
  const p = verifyToken(readCookie(event, COOKIE));
  if (!p) return json(401, { error: 'unauthenticated' });
  const member = await getMember(p.sub);
  if (!member) return json(401, { error: 'unauthenticated' });   // removed since issue

  const out = { email: p.sub, name: member.name || p.sub, role: member.role || '', exp: p.exp };
  // Sliding session: if the token is more than a day old, mint a fresh one so an
  // active reader never has to re-authenticate.
  const maxAge = TTL_DAYS * 86400;
  if (p.iat && now() - p.iat > 86400) {
    return json(200, out, sessionCookies(mintToken(p.sub), maxAge));
  }
  return json(200, out);
}

// Break-glass: a single-use signed invite, sent over Signal/WhatsApp when a mail
// gateway is hostile. Same HMAC machinery, separate purpose claim so a session
// token can never be replayed here and vice versa.
async function enter(event) {
  const t = event.queryStringParameters?.t || '';
  const p = verifyToken(t);
  const home = { statusCode: 302, headers: { location: '/', 'cache-control': 'no-store' } };
  if (!p || p.pur !== 'invite') return { statusCode: 302, headers: { location: '/login', 'cache-control': 'no-store' } };

  const used = await ddb.send(new GetCommand({ TableName: TABLE, Key: { anchor_id: '__invite', sort_key: p.jti || '' } }));
  if (used.Item) return { statusCode: 302, headers: { location: '/login?used=1', 'cache-control': 'no-store' } };
  const member = await getMember(p.sub);
  if (!member) return { statusCode: 302, headers: { location: '/login', 'cache-control': 'no-store' } };

  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: { anchor_id: '__invite', sort_key: p.jti, used_at: now(), expires_at: now() + 30 * 86400 },
  }));
  console.log(JSON.stringify({ evt: 'invite-used', email: p.sub, ts: new Date().toISOString() }));
  return { ...home, cookies: sessionCookies(mintToken(p.sub), TTL_DAYS * 86400) };
}

/* ---------------- comments (inherited contract, now cookie-gated) ----------- */

async function comments(event, method, session, member) {
  if (method === 'GET') {
    const version = event.queryStringParameters?.doc_version;
    if (!version) return json(400, { error: 'doc_version required' });
    // Comments span many partitions, so a Query isn't possible without a GSI.
    // Scan + filter, as in the GCA original — volume is a handful of comments on
    // a stakeholder doc. The `__` guard keeps member/otp/rl items out of the
    // response. Add a GSI on doc_version if volume ever grows.
    const scan = await ddb.send(new ScanCommand({
      TableName: TABLE,
      FilterExpression: 'doc_version = :v AND NOT begins_with(anchor_id, :sys)',
      ExpressionAttributeValues: { ':v': version, ':sys': '__' },
    }));
    const list = (scan.Items || []).sort((a, b) => (a.created_at || '').localeCompare(b.created_at || ''));
    return json(200, { comments: list });
  }

  if (method !== 'POST') return json(405, { error: 'method not allowed' });

  let b;
  try { b = JSON.parse(event.body || '{}'); } catch { return json(400, { error: 'bad json' }); }

  if (b.op === 'update') {
    if (!b.id || !b.patch) return json(400, { error: 'id and patch required' });
    // `id` is a DynamoDB reserved word — must be aliased. No Limit: it applies
    // before the filter and could skip the match.
    const found = await ddb.send(new ScanCommand({
      TableName: TABLE, FilterExpression: '#id = :id',
      ExpressionAttributeNames: { '#id': 'id' },
      ExpressionAttributeValues: { ':id': b.id },
    }));
    const item = (found.Items || [])[0];
    if (!item) return json(404, { error: 'not found' });
    const status = b.patch.status === 'resolved' ? 'resolved' : 'open';
    const upd = await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: { anchor_id: item.anchor_id, sort_key: item.sort_key },
      UpdateExpression: 'SET #s = :s', ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: { ':s': status }, ReturnValues: 'ALL_NEW',
    }));
    return json(200, { comment: upd.Attributes });
  }

  if (b.op === 'bulkAdd') {
    const recs = (Array.isArray(b.recs) ? b.recs : []).slice(0, 25)
      .map((r) => normalise(r, session, member)).filter(Boolean);
    if (!recs.length) return json(400, { error: 'no valid recs' });
    await ddb.send(new BatchWriteCommand({ RequestItems: { [TABLE]: recs.map((Item) => ({ PutRequest: { Item } })) } }));
    return json(201, { comments: recs });
  }

  const rec = normalise(b, session, member);
  if (!rec) return json(400, { error: 'missing fields' });
  await ddb.send(new PutCommand({ TableName: TABLE, Item: rec }));
  return json(201, { comment: rec });
}

// The client's author_name is IGNORED. Identity comes from the verified session,
// otherwise this is a name label rather than authentication.
function normalise(b, session, member) {
  const body        = clamp(b.body, 2000);
  const anchor_id   = clamp(b.anchor_id, 120);
  const doc_version = clamp(b.doc_version, 40);
  if (!body || !anchor_id || !doc_version) return null;
  if (anchor_id.startsWith('__')) return null;         // no writing into system partitions
  const id = clamp(b.id, 40) || newId();
  const created_at = clamp(b.created_at, 40) || new Date().toISOString();
  return {
    anchor_id,
    sort_key: `${created_at}#${id}`,
    id,
    anchor_label: clamp(b.anchor_label, 200),
    doc_version,
    author_name: clamp(member.name || session.sub, 80),
    author_email: session.sub,
    body,
    created_at,
    status: b.status === 'resolved' ? 'resolved' : 'open',
    carried_from: b.carried_from ? clamp(b.carried_from, 40) : null,
    parent_id: b.parent_id ? clamp(b.parent_id, 40) : null,
  };
}

/* ---------------- entry point ----------------------------------------------- */

export const handler = async (event) => {
  const method = event.requestContext?.http?.method;
  const path   = (event.rawPath || '/').replace(/\/+$/, '') || '/';

  if (!SECRET || !PEPPER) { console.error('SESSION_SECRET / OTP_PEPPER not configured'); return json(500, { error: 'server error' }); }

  try {
    let body = {};
    if (method === 'POST') {
      try { body = JSON.parse(event.body || '{}'); } catch { return json(400, { error: 'bad json' }); }
    }

    if (path === '/api/auth/start'  && method === 'POST') return await authStart(event, body);
    if (path === '/api/auth/verify' && method === 'POST') return await authVerify(event, body);
    if (path === '/api/auth/logout' && method === 'POST') return json(200, { ok: true }, clearCookies());
    if (path === '/api/me'          && method === 'GET')  return await me(event);

    /* Signature-only health check. Exists to disambiguate the one failure that
       is otherwise silent and looks like a cookie bug: the CloudFront Function
       and this Lambda holding different signing secrets.
       /api/comments cannot serve that purpose because it 401s for BOTH a bad
       signature and a valid token whose subject is not a member. This reports
       only whether the signature verifies — it does not check membership, and
       reveals nothing an attacker holding a valid token would not already know. */
    if (path === '/api/health' && method === 'GET') {
      const raw = readCookie(event, COOKIE);
      return json(200, { ok: true, token: !raw ? 'none' : (verifyToken(raw) ? 'valid' : 'invalid') });
    }
    if (path === '/enter'           && method === 'GET')  return await enter(event);

    if (path === '/api/comments') {
      const session = verifyToken(readCookie(event, COOKIE));
      if (!session) return json(401, { error: 'unauthenticated' });
      const member = await getMember(session.sub);
      if (!member) return json(401, { error: 'unauthenticated' });
      return await comments(event, method, session, member);
    }

    return json(404, { error: 'not found' });
  } catch (e) {
    console.error(e);
    return json(500, { error: 'server error' });
  }
};
