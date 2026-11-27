const utf8 = new TextEncoder()

export function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
}

export async function appJWT(appID, pem, now) {
  const key = await crypto.subtle.importKey('pkcs8',
    Uint8Array.from(atob(pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '')), c => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const encode = json => base64url(utf8.encode(JSON.stringify(json)))
  const input = encode({ alg: 'RS256', typ: 'JWT' }) + '.' + encode({ iat: now - 60, exp: now + 540, iss: appID })
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, utf8.encode(input))
  return input + '.' + base64url(new Uint8Array(signature))
}
