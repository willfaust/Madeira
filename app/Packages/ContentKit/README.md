# ContentKit: the store-neutral install core

What every store client (Steam today, GOG and Epic next) shares, so each store
adds only its protocol, its manifests and its chunk source. Foundation only;
`swift test --build-system native` runs its tests on the Linux host, and `pp test`
runs them too. It is compiled with `-O` in every configuration, for the reason in
`app/SteamClient/Package.swift`.

- **The plan** (`ContentPlan.swift`): a title is a list of files, each a list of
  **parts**, `(chunk, offsetInChunk, length, fileOffset)`; a chunk is
  `(key, size, compressedSize, check)` with `check` SHA-1, md5 or none. Steam's and
  GOG's parts are whole chunks; Epic's take slices of them. The store's planner
  checks paths (`SafePath`) and builds the plan; its `ContentChunkSource` fetches,
  decodes and verifies a chunk.
- **The engine** (`InstallEngine.swift`) stages a plan: each unique chunk fetched once
  in a bounded task group and each part written by `pwrite` wherever it occurs,
  data `fsync`ed before the append-only **journal** (`InstallJournal.swift`) vouches
  for it, every finished file hashed (SHA-1 or md5) by streaming `pread`, and free
  space checked before and during the download. A resume re-hashes the journalled
  parts that are whole chunks; a slice has no hash of its own and the file's hash
  checks it. The journal format is the one Steam stages used before the core moved
  here, so a stage left on the phone still resumes.
- **The layout** (`InstallLayout.swift`): staging, `C:\Games` and the non-secret
  state (receipts, retained manifests), on one volume so a commit is one `rename`.
- **Codecs and hashes**: inflate, gzip, single-entry zip, LZMA, zstd; SHA-1, SHA-256,
  md5, CRC-32, AES-256.
- **Network and secrets**: the bounded `HTTPClient`, `Secret<T>`, `Redactor`, `Logger`,
  and the `SecretStore` seam (the Keychain on Apple platforms; memory and file stores
  for tests). `ClientError` is every client's error type.
