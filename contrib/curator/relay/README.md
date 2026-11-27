# Curator anonymous reporting relay

The Worker accepts user-reviewed Curator reports and publishes scrubbed text to one public GitHub tracker. Its GitHub App token is scoped to the configured repository and Issues write access. The relay sets the `curator` and `anonymous` labels itself. The app sends no GitHub credentials in anonymous mode.

## Setup for the maintainer

1. Create or select the public tracker (for example, `RageMC/triptych-issues`). Enable Issues and add the `curator` and `anonymous` labels.
2. In GitHub **Settings → Developer settings → GitHub Apps**, create a dedicated GitHub App. Use the tracker URL for Homepage, disable the webhook, leave the callback URL empty, set **Repository permissions → Issues** to **Read and write**, and choose **Only on this account**. Record the numeric **App ID**. Generate a private key and keep the downloaded PEM outside the checkout. Install the app under **Install App → Only select repositories** and select only the public tracker. Record the numeric installation ID from the installation settings URL. [GitHub App setup and authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
3. Create or open your Cloudflare account, enable Workers, and sign in to Wrangler yourself. From `tools/curator-relay`, use Node.js 22 or later and run:

   ```sh
   npm ci
   npm test
   npx wrangler login
   npx wrangler kv namespace create SIGNATURES
   ```

   Set `TRACKER_REPO` and the returned KV namespace ID in `wrangler.toml`. Keep a single Worker deployment per GitHub App installation so all submissions share the same Durable Object and pacing budget.
4. For optional private log storage, enable R2, choose a bucket name, and run:

   ```sh
   npx wrangler r2 bucket create YOUR_PRIVATE_BUCKET
   npx wrangler r2 bucket lifecycle add YOUR_PRIVATE_BUCKET expire-curator-reports reports/ --expire-days 30
   npx wrangler r2 bucket lifecycle list YOUR_PRIVATE_BUCKET
   ```

   Keep public bucket access disabled, verify the 30-day rule, and uncomment the `LOGS` binding with that bucket name. Maintainers can locate attachments under `reports/<issue-number>/` in the dashboard. [Cloudflare R2 lifecycle rules](https://developers.cloudflare.com/r2/buckets/object-lifecycles/)
5. Deploy the Worker and set its secrets. The relay answers with an unavailable error until its secrets are configured.

   ```sh
   npx wrangler deploy
   npx wrangler secret put GITHUB_APP_ID
   npx wrangler secret put GITHUB_INSTALLATION_ID
   openssl pkcs8 -topk8 -nocrypt -in /path/outside/checkout/github-app.pem | npx wrangler secret put GITHUB_APP_PRIVATE_KEY
   openssl rand -hex 32 | npx wrangler secret put HASHCASH_SECRET
   ```

   Enter the numeric IDs at the prompts. The private key must be an unencrypted PKCS#8 PEM, which the pipeline converts directly for Web Crypto without writing a second copy. Keep the key and hashcash secret in Worker secrets. [GitHub JWT claim requirements](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app)
6. Set `TriptychReportRelayURL` in `app/project.yml` to your HTTPS Worker URL ending with `/report`. Regenerate the Xcode project, rebuild, and submit a sample report with synthetic data through Curator. Verify that it appears in the public tracker, that a repeat of a known crash uses the existing issue, and that any enabled archive is private.

## Protocol and limits

- `GET /challenge` returns `{challenge, difficulty}`. The challenge is authenticated, bound to the Cloudflare client address, and valid for five minutes.
- `POST /report` requires `X-Curator-Challenge` and `X-Curator-Nonce`. The nonce is 1–16 lowercase hex digits. The SHA-256 of the UTF-8 string `challenge:nonce` must start with 20 zero bits. A valid proof can be used once.
- The JSON report contains `title`, `body`, optional `labels`, optional `signature` (`engine`, `targetExe`, `canonicalCrashLine`), and optional scrubbed text `log`. The summary has a 32 KiB UTF-8 cap. The app supplies a deterministic triage signature for known failures and uses `unknown` when the target executable is unavailable.
- With R2 enabled, JSON log text is scrubbed again and stored in a private ZIP. The relay also accepts multipart form data with JSON in the `report` field and a ZIP in `logs`. ZIP uploads are capped at 25 MiB, with a separate 8 MiB expansion limit. The Worker inspects the central directory, accepts only UTF-8 `.log`, `.txt`, `.cfg`, and `.ips` files, and writes a new scrubbed archive with generic filenames. When R2 is disabled, JSON reports still work and multipart uploads are rejected.
- A successful submission returns `{url}` and, when an archive was requested, `archiveStored`. The canonical crash signature maps to an open issue in KV with a consistent Durable Object index. Curator comments on the first repeat and every fifth report. Reports without a signature create a new issue.
- Per-address admission is limited to three reports in a rolling hour and ten in a rolling day. The relay persists a keyed digest of the client address for that window. GitHub calls are serialized and spaced at least two seconds apart, with a rolling cap of 500 issue and comment mutations per hour. Retryable overloads return HTTP 429 with `Retry-After`.

Local tests use Miniflare's KV, R2, and Durable Object bindings and mock every GitHub response.
