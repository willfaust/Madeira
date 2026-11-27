import { unzipSync, zipSync } from 'fflate'

export const summaryLimit = 32 * 1024
const archiveLimit = 25 * 1024 * 1024
const expandedArchiveLimit = 8 * 1024 * 1024
const logLimit = 3 * 1024 * 1024
const utf8 = new TextEncoder()
const decoder = new TextDecoder('utf-8', { fatal: true })

export class ReportError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

export function scrub(text) {
  return text.normalize('NFKC')
    .replace(/[\p{Cf}\p{Cs}\x00-\x08\x0B-\x1F\x7F]/gu, '')
    .replace(/<!--[^]*?(?:-->|$)|<[^<>\n]*>/g, '')
    .replace(/-----BEGIN [^-\n]{1,64}-----[\s\S]*?(?:-----END [^-\n]{1,64}-----|$)/gi, '[redacted key]')
    .replace(/\b(?:github_pat_|gh[pousr]_|ghs_|sk-(?:proj-)?|AKIA)[\w-]+/gi, '[redacted token]')
    .replace(/\b(?:authorization|bearer|(?:api[-_ ]?key|password|passwd|secret|(?:access_|refresh_)?token|cookie|udid|ecid|serial(?:\s?(?:number|no\.?))?|imei|meid|apple\s?id|icloud\s?account)\s*[:=])\s*[^\n]+/gi, '[redacted credential]')
    .replace(/\b[A-Z0-9._%+-]{1,64}@[A-Z0-9.-]{1,253}\.[a-z]{2,63}\b/gi, '[redacted email]')
    .replace(/\b(?:udid|ecid)\s+(?:0x)?[a-f0-9-]{8,}\b/gi, '[redacted ID]')
    .replace(/(?<![\w:])(?:[a-f0-9]{2}[:-]){5}[a-f0-9]{2}(?![\w:])/gi, '[redacted MAC]')
    .replace(/\b(?:https?|ftp):\/\/[^\s<>]+/gi, '[redacted URL]')
    .replace(/(?:[a-z]:[\\/](?:Users|Documents and Settings)[\\/]|\/(?:Users|home|private\/var|var\/mobile|Volumes)\/)[^\n"'<>]*/gi, '[redacted path]')
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '[redacted IP]')
    .replace(/(?<![\w:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*(?:%[\w.-]+)?(?![\w:])/gi, '[redacted IP]')
    .replace(/\b(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{32,}|[0-9a-f]{8}-[0-9a-f]{16})\b/gi, '[redacted ID]')
    .replace(/(?<![\w+/_=-])[A-Za-z0-9+/_-]{40,}={0,2}(?![\w+/_=-])/g, value =>
      /[a-z]/.test(value) && /[A-Z]/.test(value) && /\d/.test(value) ? '[redacted key]' : value)
}

async function boundedBody(request, limit) {
  if (Number(request.headers.get('content-length')) > limit) throw new ReportError(413, 'Report too large')
  const reader = request.body?.getReader()
  if (!reader) throw new ReportError(400, 'Missing report')
  const parts = []
  let size = 0
  let timer
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new ReportError(408, 'Report upload timed out')), 15_000)
  })
  try {
    for (;;) {
      const { value, done } = await Promise.race([reader.read(), deadline])
      if (done) return new Blob(parts)
      size += value.byteLength
      if (size > limit) throw new ReportError(413, 'Report too large')
      parts.push(value)
    }
  } catch (error) {
    void reader.cancel().catch(() => {})
    throw error
  } finally {
    clearTimeout(timer)
  }
}

function scrubZip(data) {
  const files = {}
  let size = 0
  let compressed = 0
  let count = 0
  // fflate reads the central directory and inflates into the advertised-size buffer.
  const entries = unzipSync(data, { filter({ name, size: compressedSize, originalSize }) {
    size += originalSize
    compressed += compressedSize
    if (++count > 64 || size > expandedArchiveLimit || compressed > archiveLimit) throw new Error('Expanded archive too large')
    if (name.endsWith('/') && originalSize === 0) return false
    if (!/\.(log|txt|cfg|ips)$/i.test(name)) throw new Error('Unsupported archive entry')
    return true
  } })
  for (const bytes of Object.values(entries)) {
    files[`log-${Object.keys(files).length + 1}.txt`] = utf8.encode(scrub(decoder.decode(bytes)))
  }
  if (!Object.keys(files).length) throw new Error('Empty archive')
  return zipSync(files, { level: 0 })
}

export async function readReport(request, archivesEnabled) {
  const type = request.headers.get('content-type') ?? ''
  const multipart = /^multipart\/form-data;/i.test(type)
  if (!multipart && !/^application\/json(?:;|$)/i.test(type)) throw new ReportError(415, 'Expected JSON or multipart form data')
  if (multipart && !archivesEnabled) throw new ReportError(422, 'Log archives are disabled')
  const bytes = await boundedBody(request, summaryLimit + (multipart ? archiveLimit + 4096 : 2 * logLimit))
  try {
    const form = multipart ? await new Response(bytes, { headers: { 'content-type': type } }).formData() : null
    const raw = form ? form.get('report') : decoder.decode(await bytes.arrayBuffer())
    if (typeof raw !== 'string') throw new Error('Missing summary')
    if (multipart && utf8.encode(raw).length > summaryLimit) throw new ReportError(413, 'Report summary too large')
    const { title, body, signature, log, labels, ...unknown } = JSON.parse(raw)
    if (Object.keys(unknown).length || typeof title !== 'string' || !title.trim() || title.length > 256 ||
        typeof body !== 'string' || (labels !== undefined && (!Array.isArray(labels) ||
          labels.length > 10 || labels.some(label => typeof label !== 'string' || label.length > 64))) ||
        (log !== undefined && (multipart || typeof log !== 'string' || utf8.encode(log).length > logLimit))) {
      throw new Error('Invalid fields')
    }
    if (utf8.encode(JSON.stringify({ title, body, signature, labels })).length > summaryLimit) {
      throw new ReportError(413, 'Report summary too large')
    }
    let crash = null
    if (signature !== undefined) {
      const { engine, targetExe, canonicalCrashLine, ...extra } = signature
      const fields = [engine, targetExe, canonicalCrashLine]
      if (Object.keys(extra).length || fields.some(value => typeof value !== 'string' || !value.trim() || value.length > 256)) {
        throw new Error('Invalid crash signature')
      }
      crash = fields.map(value => scrub(value).trim().replace(/\s+/g, ' ').toLowerCase())
    }
    let archive
    if (form) {
      const zip = form.get('logs')
      if (!(zip instanceof File) || zip.size > archiveLimit ||
          form.getAll('report').length !== 1 || form.getAll('logs').length !== 1 ||
          [...form.keys()].some(key => key !== 'report' && key !== 'logs')) throw new Error('Invalid archive upload')
      archive = scrubZip(new Uint8Array(await zip.arrayBuffer()))
    } else if (archivesEnabled && log) {
      archive = zipSync({ 'curator-diagnostics.txt': utf8.encode(scrub(log)) }, { level: 0 })
    }
    const cleanTitle = scrub(title).replace(/\s+/g, ' ').replace(/@/g, '＠').trim()
    if (!cleanTitle) throw new Error('Empty title after scrubbing')
    // Indent every line so user-supplied Markdown, links and mentions render as literal text.
    const plainBody = scrub(body).split('\n').map(line => '    ' + line).join('\n')
    const publicBody = plainBody.length > 60_000 ? plainBody.slice(0, 60_000) + '\n    [Report truncated]' : plainBody
    return { title: cleanTitle.slice(0, 256), body: publicBody, crash, archive }
  } catch (error) {
    if (error instanceof ReportError) throw error
    throw new ReportError(422, 'Invalid report fields or log archive')
  }
}
