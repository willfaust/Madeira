// Local stand-in for api.github.com used by e2e-local.sh. It checks the relay's App JWT against the
// throwaway public key, hands out an installation token and records every issue it is asked to create.
import { createServer } from 'node:http'
import { createPublicKey, verify } from 'node:crypto'
import { appendFileSync, readFileSync } from 'node:fs'

const [port, publicKeyPath, logPath] = process.argv.slice(2)
const publicKey = createPublicKey(readFileSync(publicKeyPath))
const token = 'local-installation-token'
let next = 1
const send = (res, status, data) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data)) }
const jwtValid = auth => {
  const [h, p, s] = (auth ?? '').replace(/^Bearer /, '').split('.')
  if (!s) return false
  return verify('RSA-SHA256', Buffer.from(h + '.' + p), publicKey, Buffer.from(s, 'base64url'))
}

createServer((req, res) => {
  let body = ''
  req.on('data', c => { body += c })
  req.on('end', () => {
    const record = { method: req.method, path: req.url, body: body ? JSON.parse(body) : undefined }
    appendFileSync(logPath, JSON.stringify(record) + '\n')
    if (req.method === 'POST' && /^\/app\/installations\/\d+\/access_tokens$/.test(req.url)) {
      if (!jwtValid(req.headers.authorization)) return send(res, 401, { message: 'Bad JWT' })
      return send(res, 201, { token, expires_at: new Date(Date.now() + 3_600_000).toISOString() })
    }
    if (req.headers.authorization !== 'Bearer ' + token) return send(res, 401, { message: 'Bad credentials' })
    if (req.method === 'POST' && /^\/repos\/[\w-]+\/[\w.-]+\/issues$/.test(req.url)) {
      const number = next++
      return send(res, 201, { number, html_url: 'https://github.com' + req.url.replace('/repos', '') + '/' + number })
    }
    if (req.method === 'GET' && /\/issues\/\d+$/.test(req.url)) return send(res, 200, { state: 'open' })
    if (req.method === 'POST' && /\/comments$/.test(req.url)) return send(res, 201, { id: 1 })
    send(res, 404, { message: 'Not Found' })
  })
}).listen(Number(port), '127.0.0.1')
