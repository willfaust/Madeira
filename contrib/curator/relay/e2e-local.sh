#!/bin/bash
# End-to-end check of anonymous reporting without any real account:
#   mock GitHub API (mock-github.mjs) <- relay Worker under `wrangler dev` <- client (curl smoke test, then the app's UI test).
# Usage: tools/curator-relay/e2e-local.sh [simulator-udid]   (with a udid it also runs CuratorUITests.testAnonymousReportThroughLocalRelay)
set -euo pipefail
cd "$(dirname "$0")"
export PATH=/opt/homebrew/opt/node@24/bin:$PATH
WORK=$(mktemp -d)
RELAY_PORT=${RELAY_PORT:-8787}
GH_PORT=${GH_PORT:-8788}
cleanup() { kill ${MOCK_PID:-} ${WRANGLER_PID:-} 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/app.pem" 2>/dev/null
openssl pkey -in "$WORK/app.pem" -pubout -out "$WORK/app.pub"
PEM=$(tr '\n' ' ' < "$WORK/app.pem")
SECRET=$(openssl rand -hex 32)
: > "$WORK/github.log"

node mock-github.mjs "$GH_PORT" "$WORK/app.pub" "$WORK/github.log" & MOCK_PID=$!
npx wrangler dev --local --ip 127.0.0.1 --port "$RELAY_PORT" --persist-to "$WORK/state" \
  --var "HASHCASH_SECRET:$SECRET" --var "GITHUB_API:http://127.0.0.1:$GH_PORT" \
  --var GITHUB_APP_ID:1 --var GITHUB_INSTALLATION_ID:1 --var "GITHUB_APP_PRIVATE_KEY:$PEM" \
  --var TRACKER_REPO:RageMC/triptych-issues > "$WORK/wrangler.log" 2>&1 & WRANGLER_PID=$!
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$RELAY_PORT/challenge" >/dev/null 2>&1 && break; sleep 1; done

# Smoke test: solve the real challenge (difficulty 20) and file one report.
node --input-type=module - "$RELAY_PORT" <<'JS'
import { createHash } from 'node:crypto'
const port = process.argv[2]
const { challenge, difficulty } = await (await fetch(`http://127.0.0.1:${port}/challenge`)).json()
let nonce = 0
for (;; nonce++) {
  const d = createHash('sha256').update(challenge + ':' + nonce.toString(16)).digest()
  if (!d[0] && !d[1] && !(d[2] >> 4)) break
}
const res = await fetch(`http://127.0.0.1:${port}/report`, { method: 'POST',
  headers: { 'Content-Type': 'application/json', 'X-Curator-Challenge': challenge, 'X-Curator-Nonce': nonce.toString(16) },
  body: JSON.stringify({ title: 'e2e smoke: JIT is off', body: 'Local end-to-end smoke test.' }) })
const text = await res.text()
console.log('smoke', res.status, text)
if (res.status !== 201) process.exit(1)
JS

if [ -n "${1:-}" ]; then
  # Each client IP may file 3 reports per hour; the app shares 127.0.0.1 with the smoke test, which is fine.
  cd ../../app
  TEST_RUNNER_CURATOR_LOCAL_RELAY="http://127.0.0.1:$RELAY_PORT/report" xcodebuild test -project Triptych.xcodeproj \
    -scheme Triptych -destination "platform=iOS Simulator,id=$1" ${DERIVED:+-derivedDataPath "$DERIVED"} \
    -only-testing:TriptychUITests/CuratorUITests/testAnonymousReportThroughLocalRelay 2>&1 \
    | grep -E 'Test Case|error:|TEST (SUCC|FAIL)|skipped' || true
fi
echo "--- GitHub mock received:"
cat "$WORK/github.log"
grep -c '"path":"/repos/RageMC/triptych-issues/issues"' "$WORK/github.log"
