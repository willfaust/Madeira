import { DurableObject } from 'cloudflare:workers'
import { base64url, appJWT } from './github.js'
import { readReport, ReportError } from './report.js'

const encoder = new TextEncoder()
const second = 1_000
const hour = 3_600 * second
const day = 24 * hour
const challengeLife = 300
const difficulty = 20
const nowSeconds = () => Math.floor(Date.now() / second)
const json = (data, status = 200, headers = {}) => Response.json(data, {
  status, headers: { 'Cache-Control': 'no-store', ...headers },
})
const fail = (status, message) => json({ message }, status)
const limited = ms => json({ message: 'Report relay is rate limited' }, 429, {
  'Retry-After': String(Math.max(1, Math.ceil(ms / second))),
})
const sha256 = async value => new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value)))

async function signer(secret) {
  if (!secret || secret.length < 32) throw new Error('Missing challenge secret')
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign', 'verify'])
  return key
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname
    if (path !== '/challenge' && path !== '/report') return fail(404, 'Unknown endpoint')
    if (request.method !== (path === '/challenge' ? 'GET' : 'POST')) return fail(405, 'Method not allowed')
    const ip = request.headers.get('CF-Connecting-IP')
    if (!ip) return fail(400, 'Missing client address')
    try {
      const key = await signer(env.HASHCASH_SECRET)
      const client = base64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode('ip:' + ip))))
      if (path === '/challenge') {
        const payload = nowSeconds() + '.' + crypto.randomUUID()
        const tag = await crypto.subtle.sign('HMAC', key, encoder.encode(payload + ':' + client))
        return json({ challenge: payload + '.' + base64url(new Uint8Array(tag)), difficulty })
      }
      const challenge = request.headers.get('X-Curator-Challenge') ?? ''
      const nonce = request.headers.get('X-Curator-Nonce') ?? ''
      if (!/^\d{10}\.[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/.test(challenge) || !/^[0-9a-f]{1,16}$/.test(nonce)) {
        return fail(422, 'Missing or invalid report proof')
      }
      const [timestamp, id, tag] = challenge.split('.')
      const age = nowSeconds() - Number(timestamp)
      if (age < 0 || age >= challengeLife) return fail(422, 'Expired report challenge')
      const valid = await crypto.subtle.verify('HMAC', key,
        Uint8Array.from(atob(tag.replaceAll('-', '+').replaceAll('_', '/') + '='), c => c.charCodeAt(0)),
        encoder.encode(timestamp + '.' + id + ':' + client))
      if (!valid) return fail(422, 'Invalid report challenge')
      const digest = await sha256(challenge + ':' + nonce)
      if (digest[0] || digest[1] || digest[2] >> 4) return fail(422, 'Invalid report proof')
      const headers = new Headers(request.headers)
      headers.set('X-Relay-Client', client)
      headers.set('X-Relay-Proof-ID', id)
      headers.set('X-Relay-Proof-Time', timestamp)
      return await env.RELAY.getByName('github-installation').fetch(new Request(request, { headers }))
    } catch {
      return fail(503, 'Report relay unavailable')
    }
  },
}

export class Relay extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env)
    this.sql = ctx.storage.sql
    this.sql.exec('CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, client TEXT, time INTEGER)')
    this.sql.exec('CREATE INDEX IF NOT EXISTS reports_client ON reports (client, time)')
    this.sql.exec('CREATE INDEX IF NOT EXISTS reports_time ON reports (time)')
    this.sql.exec('CREATE TABLE IF NOT EXISTS mutations (time INTEGER)')
    this.sql.exec('CREATE TABLE IF NOT EXISTS signatures (hash TEXT PRIMARY KEY, number INTEGER, count INTEGER)')
  }

  async fetch(request) {
    // Keep one request in flight across token exchange, GitHub calls and the index update.
    if (this.busy) return limited(2 * second)
    this.busy = true
    try {
      const client = request.headers.get('X-Relay-Client')
      const id = request.headers.get('X-Relay-Proof-ID')
      const proofExpires = (Number(request.headers.get('X-Relay-Proof-Time')) + challengeLife) * second
      const now = Date.now()
      if (proofExpires <= now) return fail(422, 'Expired report challenge')
      const blocked = await this.ctx.storage.get('retryUntil')
      if (blocked > now) return limited(blocked - now)
      this.sql.exec('DELETE FROM reports WHERE time <= ?', now - day)
      if (this.sql.exec('SELECT id FROM reports WHERE id = ?', id).toArray().length) {
        return fail(422, 'Report proof already used')
      }
      const recent = this.sql.exec('SELECT time FROM reports WHERE client = ? ORDER BY time DESC', client).toArray()
      const wait = Math.max((recent[2]?.time ?? 0) + hour, (recent[9]?.time ?? 0) + day) - now
      if (wait > 0) return limited(wait)
      // Charge a solved proof even if payload validation fails. Replaying it cannot repeat parsing work.
      this.sql.exec('INSERT INTO reports VALUES (?, ?, ?)', id, client, now)
      const report = await readReport(request, Boolean(this.env.LOGS))
      return await this.publish(report)
    } catch (error) {
      if (error instanceof ReportError) return fail(error.status, error.message)
      if (error instanceof GitHubLimit) return limited(error.retryUntil - Date.now())
      return fail(502, 'Could not complete the report')
    } finally {
      this.busy = false
    }
  }

  async github(path, auth, payload, mutation = false) {
    const storage = this.ctx.storage
    const delay = (await storage.get('nextRequest') ?? 0) - Date.now()
    if (delay > 0) await new Promise(resolve => setTimeout(resolve, delay))
    const now = Date.now()
    if (mutation) {
      this.sql.exec('DELETE FROM mutations WHERE time <= ?', now - hour)
      const { count, oldest } = this.sql.exec('SELECT COUNT(*) AS count, MIN(time) AS oldest FROM mutations').one()
      if (count >= 500) throw new GitHubLimit(oldest + hour)
      this.sql.exec('INSERT INTO mutations VALUES (?)', now)
    }
    await storage.put('nextRequest', now + 2 * second)
    // GITHUB_API is only for local end-to-end runs (wrangler dev against a mock); production leaves it unset.
    const response = await fetch((this.env.GITHUB_API || 'https://api.github.com') + path, {
      method: payload === undefined ? 'GET' : 'POST',
      redirect: 'manual',
      signal: AbortSignal.timeout(15 * second),
      headers: {
        Authorization: 'Bearer ' + auth,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Triptych-Curator-Relay',
        'Content-Type': 'application/json',
      },
      body: payload === undefined ? undefined : JSON.stringify(payload),
    })
    await storage.put('nextRequest', Date.now() + 2 * second)
    const data = await response.json().catch(() => ({}))
    const retry = response.headers.get('Retry-After')
    const exhausted = response.headers.get('X-RateLimit-Remaining') === '0'
    if (response.status === 429 || (response.status === 403 &&
        (retry || exhausted || /rate limit|abuse/i.test(data.message ?? '')))) {
      const reset = exhausted ? Number(response.headers.get('X-RateLimit-Reset')) * second : 0
      const retryAt = retry && (/^\d+$/.test(retry) ? Date.now() + Number(retry) * second : Date.parse(retry))
      const until = Math.max(Date.now() + (retryAt ? second : 60 * second), retryAt || 0, reset || 0)
      await storage.put('retryUntil', until)
      throw new GitHubLimit(until)
    }
    return { response, data }
  }

  async installationToken(repo) {
    if (this.token?.expires > Date.now() + 60 * second) return this.token.value
    const { GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, GITHUB_INSTALLATION_ID } = this.env
    if (!/^\d+$/.test(GITHUB_INSTALLATION_ID ?? '') || !/^\d+$/.test(GITHUB_APP_ID ?? '')) throw new Error('Invalid App configuration')
    const jwt = await appJWT(GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, nowSeconds())
    const { response, data } = await this.github('/app/installations/' + GITHUB_INSTALLATION_ID + '/access_tokens', jwt,
      { repositories: [repo], permissions: { issues: 'write' } })
    if (!response.ok || typeof data.token !== 'string' || !Number.isFinite(Date.parse(data.expires_at))) {
      throw new Error('Token exchange failed')
    }
    this.token = { value: data.token, expires: Date.parse(data.expires_at) }
    return this.token.value
  }

  async publish({ title, body, crash, archive }) {
    const repo = this.env.TRACKER_REPO
    if (!/^[\w-]+\/[\w.-]+$/.test(repo ?? '') || repo.split('/').some(part => part === '.' || part === '..')) {
      throw new Error('Invalid tracker')
    }
    const path = '/repos/' + repo + '/issues'
    const hash = crash?.[2] && base64url(await sha256(JSON.stringify([repo.toLowerCase(), ...crash])))
    const indexKey = 'crash:' + hash
    // The durable index shadows KV to cover its cross-location propagation window.
    let existing = hash && (this.sql.exec('SELECT number, count FROM signatures WHERE hash = ?', hash).toArray()[0]
      ?? await this.env.SIGNATURES.get(indexKey, 'json'))
    const token = await this.installationToken(repo.split('/')[1])
    if (existing) {
      const { response, data } = await this.github(path + '/' + existing.number, token)
      if (response.status === 404 || response.status === 410 || data.state === 'closed') existing = null
      else if (!response.ok || data.state !== 'open') throw new Error('Issue lookup failed')
    }
    let number
    let count = 1
    if (existing) {
      number = existing.number
      count = existing.count + 1
      if (count === 2 || count % 5 === 0) {
        const { response } = await this.github(path + '/' + number + '/comments', token,
          { body: 'Curator received another report for this crash signature. Reports received: ' + count + '.' }, true)
        if (!response.ok) throw new Error('Comment failed')
      }
    } else {
      const { response, data } = await this.github(path, token,
        { title, body: 'Anonymous Triptych Curator report\n\n' + body, labels: ['curator', 'anonymous'] }, true)
      if (!response.ok || !Number.isSafeInteger(data.number) || data.number < 1) throw new Error('Issue creation failed')
      number = data.number
    }
    if (hash) {
      this.sql.exec('INSERT OR REPLACE INTO signatures VALUES (?, ?, ?)', hash, number, count)
    }
    const url = 'https://github.com/' + repo + '/issues/' + number
    // Once GitHub accepts a report, a secondary storage failure must not prompt a duplicate submission.
    const outcomes = await Promise.allSettled([
      hash ? this.env.SIGNATURES.put(indexKey, JSON.stringify({ number, count })) : undefined,
      archive ? this.env.LOGS.put(`reports/${number}/${crypto.randomUUID()}.zip`, archive,
        { httpMetadata: { contentType: 'application/zip' } }) : undefined,
    ])
    return json({ url, ...(archive && { archiveStored: outcomes[1].status === 'fulfilled' }) }, existing ? 200 : 201)
  }
}

class GitHubLimit extends Error {
  constructor(retryUntil) {
    super('GitHub rate limit')
    this.retryUntil = retryUntil
  }
}
