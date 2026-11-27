import { createHash, generateKeyPairSync, verify } from 'node:crypto'
import { build } from 'esbuild'
import { strFromU8, strToU8, unzipSync, zipSync } from 'fflate'
import { Miniflare } from 'miniflare'
import { afterEach, beforeAll, beforeEach, expect, it } from 'vitest'

let script
let mf
let requests
let respond
let failures
const origin = 'https://relay.example'
const ip = '198.51.100.1'
const keys = generateKeyPairSync('rsa', { modulusLength: 2048 })
const signature = { engine: 'Casement', targetExe: 'game.exe', canonicalCrashLine: 'SIMD refill' }
const defaultReport = { title: 'Crash', body: 'Diagnostics', signature }

beforeAll(async () => {
  const output = await build({ entryPoints: ['worker.js'], bundle: true, write: false,
    format: 'esm', external: ['cloudflare:workers'] })
  script = output.outputFiles[0].text
})

beforeEach(() => {
  requests = []
  failures = []
  respond = ({ path, method }) => {
    if (path.endsWith('/access_tokens')) {
      return Response.json({ token: 'mock-installation-token', expires_at: new Date(Date.now() + 3600000).toISOString() })
    }
    if (method === 'GET') return Response.json({ state: 'open' })
    return Response.json({ number: 17 }, { status: 201 })
  }
  mf = new Miniflare({
    modules: true, script, compatibilityDate: '2025-11-28',
    kvNamespaces: ['SIGNATURES'], r2Buckets: ['LOGS'],
    durableObjects: { RELAY: { className: 'Relay', useSQLite: true } },
    bindings: {
      TRACKER_REPO: 'example/triptych-issues', GITHUB_APP_ID: '42', GITHUB_INSTALLATION_ID: '71',
      GITHUB_APP_PRIVATE_KEY: keys.privateKey.export({ type: 'pkcs8', format: 'pem' }),
      HASHCASH_SECRET: 'test-secret-only-for-local-miniflare',
    },
    outboundService: async request => {
      const url = new URL(request.url)
      if (url.origin !== 'https://api.github.com') {
        failures.push(url.origin)
        return new Response(null, { status: 500 })
      }
      const entry = { path: url.pathname, method: request.method, time: Date.now(),
        authorization: request.headers.get('authorization'),
        payload: request.method === 'POST' ? await request.json() : undefined }
      requests.push(entry)
      return respond(entry)
    },
  })
})

afterEach(async () => {
  await mf.dispose()
  expect(failures).toEqual([])
})

async function solve(challenge) {
  const prefix = createHash('sha256').update(challenge + ':')
  for (let i = 0; ; i++) {
    if (i % 16384 === 0) await new Promise(resolve => setImmediate(resolve))
    const nonce = i.toString(16)
    const digest = prefix.copy().update(nonce).digest()
    if (!digest[0] && !digest[1] && digest[2] < 16) return nonce
  }
}

async function proof(client = ip) {
  const response = await mf.dispatchFetch(origin + '/challenge', { headers: { 'CF-Connecting-IP': client } })
  expect(response.status).toBe(200)
  const { challenge, difficulty } = await response.json()
  expect(difficulty).toBe(20)
  return { 'X-Curator-Challenge': challenge, 'X-Curator-Nonce': await solve(challenge) }
}

async function submit({ body = defaultReport, client = ip, headers, form } = {}) {
  const multipart = form && new Request(origin + '/report', { method: 'POST', body: form })
  return mf.dispatchFetch(origin + '/report', {
    method: 'POST',
    headers: { 'CF-Connecting-IP': client,
      'Content-Type': multipart ? multipart.headers.get('content-type') : 'application/json', ...(headers ?? await proof(client)) },
    body: multipart ? await multipart.arrayBuffer() : JSON.stringify(body),
  })
}

it('signs RS256, scopes the token, scrubs public text, deduplicates and paces GitHub globally', async () => {
  const headers = await proof()
  const response = await submit({ headers, body: {
    ...defaultReport,
    title: 'Crash for alice@example.com',
    body: 'opened /Users/alice/private.iso\npassword=hidden\n@someone <img src=x> 203.0.113.2',
    log: 'debug me@example.com from /home/alice/file',
    labels: ['send-to-autofix'],
  } })
  expect(response.status).toBe(201)
  expect(await response.json()).toEqual({ url: 'https://github.com/example/triptych-issues/issues/17', archiveStored: true })
  const [token, issue] = requests
  expect(token.path).toBe('/app/installations/71/access_tokens')
  expect(token.payload).toEqual({ repositories: ['triptych-issues'], permissions: { issues: 'write' } })
  const [header, claims, jwtSignature] = token.authorization.slice(7).split('.')
  expect(JSON.parse(Buffer.from(header, 'base64url'))).toEqual({ typ: 'JWT', alg: 'RS256' })
  const { iat, exp, iss } = JSON.parse(Buffer.from(claims, 'base64url'))
  expect(iss).toBe('42')
  expect(exp - iat).toBe(600)
  expect(verify('RSA-SHA256', Buffer.from(header + '.' + claims), keys.publicKey, Buffer.from(jwtSignature, 'base64url'))).toBe(true)
  expect(issue.authorization).toBe('Bearer mock-installation-token')
  expect(issue.payload).toEqual({ title: 'Crash for [redacted email]', labels: ['curator', 'anonymous'],
    body: 'Anonymous Triptych Curator report\n\n    opened [redacted path]\n    [redacted credential]\n    @someone  [redacted IP]' })
  const bucket = await mf.getR2Bucket('LOGS')
  const { objects } = await bucket.list()
  expect(objects).toHaveLength(1)
  expect(objects[0].key).toMatch(/^reports\/17\/.+\.zip$/)
  const stored = await bucket.get(objects[0].key)
  const archive = unzipSync(new Uint8Array(await stored.arrayBuffer()))
  expect(strFromU8(archive['curator-diagnostics.txt'])).toBe('debug [redacted email] from [redacted path]')
  expect((await submit({ headers })).status).toBe(422)
  expect((await submit()).status).toBe(200)
  expect(requests.map(request => request.path)).toEqual([
    '/app/installations/71/access_tokens', '/repos/example/triptych-issues/issues',
    '/repos/example/triptych-issues/issues/17', '/repos/example/triptych-issues/issues/17/comments',
  ])
  expect(requests[3].payload.body).toContain('Reports received: 2')
  for (let i = 1; i < requests.length; i++) expect(requests[i].time - requests[i - 1].time).toBeGreaterThanOrEqual(2000)
  const kv = await mf.getKVNamespace('SIGNATURES')
  const { keys: entries } = await kv.list()
  expect(entries).toHaveLength(1)
  expect(await kv.get(entries[0].name, 'json')).toEqual({ number: 17, count: 2 })
}, 30000)

it('rejects unsigned, cross-IP, forged and expired challenges and enforces the IP window', async () => {
  expect((await submit({ headers: {} })).status).toBe(422)
  const headers = await proof()
  const challenge = headers['X-Curator-Challenge']
  expect((await submit({ headers, client: '198.51.100.2' })).status).toBe(422)
  expect((await submit({ headers: { ...headers, 'X-Curator-Challenge': challenge.replace(/^./, '0') } })).status).toBe(422)
  expect((await submit({ headers: { ...headers, 'X-Curator-Challenge': challenge.replace(/^\d{10}/, '1'.repeat(10)) } })).status).toBe(422)
  for (let i = 0; i < 3; i++) expect((await submit({ body: { title: 'Missing body' } })).status).toBe(422)
  const blocked = await submit()
  expect(blocked.status).toBe(429)
  expect(Number(blocked.headers.get('Retry-After'))).toBeGreaterThan(3500)
  expect(requests).toHaveLength(0)
}, 30000)

it('validates the summary byte cap and archive entries, and archives only rewritten text', async () => {
  expect((await submit({ body: { ...defaultReport, body: '界'.repeat(11000) } })).status).toBe(413)
  const form = new FormData()
  form.set('report', JSON.stringify(defaultReport))
  form.set('logs', new Blob([zipSync({ 'bad.exe': strToU8('binary') })]), 'invalid.zip')
  expect((await submit({ form })).status).toBe(422)
  form.set('logs', new Blob([zipSync({ 'alice/session.log': strToU8('auth from 2001:db8::5') })]), 'valid.zip')
  expect((await submit({ form })).status).toBe(201)
  const bucket = await mf.getR2Bucket('LOGS')
  const { objects } = await bucket.list()
  const archive = unzipSync(new Uint8Array(await (await bucket.get(objects[0].key)).arrayBuffer()))
  expect(Object.keys(archive)).toEqual(['log-1.txt'])
  expect(strFromU8(archive['log-1.txt'])).toBe('auth from [redacted IP]')
}, 30000)

it('honors GitHub Retry-After across different IPs', async () => {
  respond = () => Response.json({ message: 'Secondary rate limit' }, { status: 403, headers: { 'Retry-After': '90' } })
  const first = await submit()
  expect(first.status).toBe(429)
  expect(Number(first.headers.get('Retry-After'))).toBe(90)
  const second = await submit({ client: '198.51.100.2' })
  expect(second.status).toBe(429)
  expect(Number(second.headers.get('Retry-After'))).toBeGreaterThan(80)
  expect(requests).toHaveLength(1)
}, 30000)
