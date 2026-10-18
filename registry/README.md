# The Nyra registry (a read-only Worker over R2)

The server from which `bootc` (and any `containers/image` client: skopeo, podman) downloads the
Nyra OS images. It speaks the **download** half of the OCI Distribution protocol; it has no upload
path. CI writes directly to R2 and KV.

**Status:** code and tests are done and verified locally (including `bootc switch` from a VM). The
IDs in `wrangler.toml` are real. The Worker is deployed at `updates.nyraos.com` by
`.github/workflows/registry-deploy.yml` on `main`, never from a developer machine.

## How it works

| Request | Response |
|---|---|
| `GET /v2/` without `Authorization` | `401` + `WWW-Authenticate: Basic`, so the client sends its install code (see "The anonymous install code") |
| `GET /v2/` with any `Basic` (even empty) | `200 {}` |
| `GET`/`HEAD /v2/<repo>/manifests/<tag>` | the tag is read from KV (for a channel in gradual rollout, the digest is chosen by the client's group), the manifest from R2; `Content-Type` = the manifest's `mediaType`, `Docker-Content-Digest`, `Cache-Control: private, no-store` |
| `GET`/`HEAD /v2/<repo>/manifests/sha256:<hex>` | the manifest from R2, `Cache-Control: immutable` |
| `HEAD /v2/<repo>/blobs/sha256:<hex>` | answered directly: the size and the digest (from the R2 metadata) |
| `GET /v2/<repo>/blobs/sha256:<hex>` | **`307` to the public R2 domain**; the bytes do not pass through the Worker |
| `GET /v2/<repo>/tags/list` | all the tags of the repository, sorted (the system versions and the channels) |
| `GET`/`HEAD /channels/<repo>/<channel>` | **the signed channel sheet**, exactly as CI wrote it to KV; the same for everybody, `Cache-Control: public, max-age=60`; see "The signed channel sheet" |
| `POST`, `PUT`, `PATCH`, `DELETE` | `405 UNSUPPORTED` ("read-only") |

Checks done by the Worker:
- **The digest of every manifest** is recomputed before it is served (manifests are a few KB). If
  the bytes in R2 do not match the digest, the response is `500`, not a corrupt manifest.
- An object larger than 4 MiB, or one that is not a known manifest (a layer, a config), is not
  served as a manifest and is not read.
- The repository name must be in `REPOSITORIES`; the only accepted digests are `sha256`.
- Layers are not verified by the Worker (they do not pass through it); **the client verifies the
  digest** of everything it downloads, and the image signature (cosign) covers the manifest.

### Why a redirect to a public R2 domain, not presigned URLs

Layers go to `https://blobs.nyraos.com/blobs/sha256/<hex>` (a custom domain bound to the bucket,
with the Cloudflare cache in front):
- **No secrets in the Worker.** A presigned URL needs the bucket's S3 key in the Worker and SigV4
  signing code.
- **CDN cache.** On a custom domain Cloudflare caches the layers; a download served from cache
  costs no R2 operation. Presigned URLs (`*.r2.cloudflarestorage.com`) do not go through the cache.
- **Range requests work natively** (`Range`), which `zstd:chunked` needs. The client resends the
  `Range` header after the redirect (verified, see below).
- **No expiry.** A presigned URL expires; a long or resumed download would fail (bootc already
  gets stuck when the server goes down in the middle of a download, as seen in an earlier VM test).
- **The install code does not reach the blob domain:** it is a different host name than the
  registry (`updates.nyraos.com`), and Go clients do not resend `Authorization` to another host.

What we accept: anyone who knows the digest of a layer can download it. The Nyra image is public
anyway (the base is GPL, the image is shipped to everybody) and contains no secrets. Gradual
rollout decides **which manifest** a computer gets, not who may read a layer.

### Why not `serverless-registry`

`cloudflare/serverless-registry` is Apache-2.0 licensed (we could have used it), but it is a full
registry built for uploads: chunked upload sessions, a garbage collector, users and JWT, pull-through
from other registries. For downloads it **sends the layers through the Worker** (no redirect, no
`Range`) and keeps the tags as R2 objects. We would have had to delete almost everything and
rewrite exactly the read path. The implementation here is ~250 lines with **zero runtime
dependencies**; from `serverless-registry` we kept only the ideas (R2 as the blob store, the OCI
error format).

## The layout in R2 and KV

```
R2 bucket nyra-images
  blobs/sha256/<hex>          any blob: layers, configs, manifests, indexes
                              (exactly the blobs/ directory of an OCI image layout)
KV namespace TAGS
  tag/<repo>/<tag>            {"digest":"sha256:<hex>"}                    a version, or a channel without a rollout
                              {"digest":"sha256:<new>","previous":"sha256:<old>",
                               "percent":25,"halted":false}                a channel in gradual rollout
  sheet/<repo>/<channel>      the signed channel sheet (DSSE envelope), served as is; written by CI only
```

KV is only the **output** for the rollout state: its source is in git (`channels/`, see "The
signed channel sheet"), and nothing in KV is read in order to be signed.

- **Tags:** versions (`2026.10.3`, never moved), channels (`dev`, `beta`, `stable`, moved) and, once
  image signatures are served, the cosign signatures (`sha256-<hex>.sig`). All of them are pointers
  in KV to a manifest in R2.
- **Why KV, not D1:** cheap reads, cached at the edge, one key per tag. The gradual rollout state
  lives in the same value as the tag, so a request still does a single KV read and a state change
  is a single write, with no half-applied states. KV is "eventually consistent": a channel change
  (promotion, stop, revert) reaches everywhere in **up to ~60 s**, acceptable for updates. D1 would
  make sense for history or queries; we need neither (the history is in the log of the CI run that
  makes the change).
- A single prefix for all blobs: layers shared between versions and repositories are uploaded only
  once.

## Publishing from CI

Order matters: **blobs first, the tag last**, so a tag never points to something that is missing.

1. **The image as an OCI layout:** `skopeo copy containers-storage:localhost/nyra:<version> oci:out:<version>`.
2. **Blobs to R2 and the version tag to KV, in one script:**
   ```bash
   scripts/publish-image.sh --remote out nyra 2026.10.3
   ```
   `scripts/publish-image.sh` first checks the whole layout (every blob against its SHA-256 file
   name, and that the manifest, its config and its layers are present with the right sizes) and
   refuses before uploading anything. It then uploads the blobs with `aws s3 cp` against the R2 S3
   endpoint (the `aws` CLI is preinstalled on the ubuntu-24.04 runners; rclone is not), with
   `Cache-Control: public, max-age=31536000, immutable`, skipping the objects that already exist,
   so nothing is overwritten. The key (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) is an R2 token
   with write permission **only** on the `nyra-images` bucket. Last, it does a HEAD of every
   object (the size must match) and only then writes `tag/nyra/2026.10.3` to KV
   (`CLOUDFLARE_API_TOKEN`, used by wrangler).
3. **The version-to-digest pair in git:** the script prints the line
   `"2026.10.3": "sha256:…"`; a commit adds it to `channels/nyra/releases.json` (the script does
   not edit that file). **Channels are not written to KV by hand:** promotion to `dev`/`beta`/`stable` and revert are commits to
   the channel files, and CI publishes the signed sheet and the channel tag from them (see
   "Operation").
4. **Who writes what:** the build machine may upload blobs (they are content-addressed, and the
   client verifies the digest), but **only the signing job on the GitHub runners** writes the tags
   and the signatures. Recommendation: a lock rule on the bucket (R2 bucket lock) on `blobs/`, so
   that a compromised build machine cannot overwrite or delete existing blobs.
5. **Deleting** old blobs (the retention rule) is done only for blobs that no kept tag points to
   any more; it is a separate task.

The Cloudflare configuration to be done at publication: the `nyra-images` bucket with the
`blobs.nyraos.com` domain (no `r2.dev`), a "Cache everything" cache rule with a long TTL on
`blobs.nyraos.com/blobs/*`, the `TAGS` KV namespace, the Worker on `updates.nyraos.com`. The
account and KV namespace IDs are already in `wrangler.toml`; the route is added at publication.

## The anonymous install code

The registry keeps no per-machine identifier: the install code is anonymous, and the server does
not store, log or look it up.

- The client sends it as the HTTP Basic password. The user is either ignored or `sha256-<hex>`, the
  digest the client runs (see "Stopping"). `containers/image` sends credentials **only after a
  `401` challenge**, which is why `GET /v2/` without `Authorization` gets a `401`. A client without
  a code sends empty credentials (`Basic Og==`) and is served normally; the other paths never ask
  for authentication.
- The code is read only for manifests and immediately turned into the rollout group (`rolloutGroup`
  in `src/auth.ts`, see "Gradual rollout, stop and revert"); it does not leave `src/auth.ts`. **It
  is not written to logs, KV, R2 or responses**; the test `the install code is never logged,
  stored or echoed` checks this on the successful and the error paths, including on a channel in
  gradual rollout.
- Workers invocation logs are **off** (`[observability] enabled = false`) until we verify that they
  do not record the `Authorization` header.

## Gradual rollout, stop and revert

> The first implementation, with the group computed by the server. It stays until `nyra-updated`
> uses the signed channel sheet, and is then removed: see "The signed channel sheet" › "Simplifying
> the Worker".

Channels (`dev`, `beta`, `stable`) are tags like any other. In addition, a channel can be **in
gradual rollout**: the tag in KV then also carries the previous version, the percentage and the
stop flag. Versions (`2026.10.3`) never have these fields.

### The rollout group

- The group (0–99) = **HMAC-SHA256(salt, code) mod 100**, from the first 32 bits of the result
  (the bias, ~2·10⁻⁸, does not matter). The same code always gives the same group, so a computer
  does not "jump" in and out of the rollout.
- **The salt is a Worker secret** (`ROLLOUT_SALT`, `wrangler secret put ROLLOUT_SALT`, for example
  `openssl rand -hex 32`). It is not in the repository; locally the obviously fake value in
  `[env.local.vars]` is used, and in tests `test-salt`. Without the salt the group cannot be
  computed from the code, and the group reveals nothing about the code. Changing the salt
  reshuffles all computers into new groups: do it only between rollouts.
- **Without the salt** (the secret forgotten at publication), nobody has a group: during a rollout
  everybody gets the previous version, until it reaches 100%. The rollout is merely delayed, and
  revert keeps working (a 500 would have blocked reverts too).

### What each client gets

The Worker chooses the digest in `chooseDigest` (`src/index.ts`), in this order:

| Channel state | Client | Gets |
|---|---|---|
| no `previous` (a version, a channel without rollout, a reverted channel) | anybody | `digest` |
| in rollout | says it already runs `digest` (see below) | `digest`: nobody is taken back, except by a revert |
| stopped (`halted`) | anybody else | `previous` |
| `percent` = 100 (or missing) | anybody else | `digest` |
| `percent` < 100 | group < `percent` | `digest` |
| `percent` < 100 | group ≥ `percent` or **no code** | `previous` |

**Clients without a code** (no `Authorization`, empty credentials, empty password, another
authentication type) are treated as the **last group**: they get the new version only when the
rollout reaches 100%. This is the simplest safe choice: we do not know what they are (a broken
install, a manual `skopeo`, a test), so they get the proven version; nobody enters the rollout
earlier by dropping their code, and at 100% nobody is left behind.

### Stopping: "clients that already took it keep it"

> **A dangerous version (compromised, with a vulnerability, corrupting data) is withdrawn with
> `revert`, not with `stop`.** With `stop`, anybody who says they run the new version (including a
> client that lies) still gets it. `stop` is for "let us look first", `revert` for "nobody should
> run this any more".

The server keeps nothing about clients (the registry keeps no per-machine identifier), so it cannot
know by itself who already took the new version. That is why **the client says what it runs**: the
HTTP Basic user name (ignored until now) can be `sha256-<hex>`, the digest of the manifest it
runs. The password stays the install code. For `bootc`, `nyra-updated` writes
`/run/ostree/auth.json` before every check, with the user = the digest from `bootc status --json`
(to be done together with the `nyra-updated` support for the channel sheet).

- On **stop**, whoever says they run the new version keeps getting it; everybody else (including
  those in groups already included that have not yet checked) gets the previous version. This way
  "a stopped rollout no longer reaches new computers", nor those in groups already included.
- A client that does **not** send the digest (for example an install with an old `auth.json`) is
  treated as one that has not taken the new version: on stop it gets the previous version, so for
  it a stop is a revert. This is the safe direction.
- A client that lies ("I run the new version") only gets the new version for itself, which anybody
  can do anyway by asking for it by digest. Gradual rollout decides which manifest a computer gets,
  not who may read a version.
- The same rule means that **lowering the percentage** takes nobody back.
- Mind this at publication (image signatures and the production publishing job): the channel must
  point to **a platform's manifest** (as `skopeo copy --override-arch` does now), not to a
  multi-arch index, so that the digest reported by bootc is the same as `digest`.

Rejected alternatives: (1) stop only as "the percentage no longer grows": clients in the included
groups that have not checked yet would keep getting the suspect version; (2) stop as "everybody
gets the previous version": it would be a revert also for those who already took it; (3) a server
list of who took what: it would mean keeping a per-computer identifier, which the anonymity of the
install code forbids.

### Revert

Revert writes the channel as `{"digest": <previous>}`: a single version for everybody. Computers
that took the bad version get the old version as an update (its layers are still on disk), whatever
their group and whatever they say they run. The older-version protection in `nyra-updated` will
accept this "downgrade" only if it is signed by us; the cryptographic binding of the channel, the
signed revert and freshness are in the channel sheet (below).

### Cache

Every response for a manifest **by tag** has `Cache-Control: private, no-store`, on GET and HEAD,
**including errors** (400, 404, 500; in fact any registry error is `no-store`, since an error by
tag can depend on the group too): with gradual rollout the response depends on the group, and a
shared cache (CDN, proxy) must not serve one group's digest to another group (a requirement from a
security review). Manifests by digest stay `public, immutable`: they are the same for everybody.

### Operation: state in git, signed by CI

**The source of truth is in git, never in KV** (Security's veto in review: a signer that reads KV
signs whatever anybody with a Cloudflare token puts there).

```
channels/<repo>/releases.json     {"2026.10.3": "sha256:<hex>", …}    version → digest, written by the publishing job
channels/<repo>/<channel>.json    {"current": "2026.10.3", "previous": "2026.10.1",
                                   "percent": 25, "halted": false, "retracted": ["2026.10.2"]}
```

A channel file cannot say "no release yet" (`valid_state` needs a `current` that is in
`releases.json`), so a channel has no file until `rollout.sh set` creates it, and CI skips it. Today
only `channels/nyra/releases.json` exists, empty (`{}`).

A rollout change is a **commit** (pull request, review, merge by the coordinator). On `main`, CI
builds the sheet from these files, signs it and **only writes it** to KV
(`scripts/publish-sheet.sh`); it re-signs daily from the same git state. And the **emergency stop
is a commit too** (`rollout.sh stop`, PR, merge): it takes as long as a review and a CI job, not a
KV write. Whatever somebody else writes to KV is overwritten at the next publication, not signed.

`scripts/rollout.sh` only edits the channel file (versions, no digests; the diff is easy to read
in review):

```bash
scripts/rollout.sh set     nyra:stable 2026.10.2     # everybody on 2026.10.2; going back = retracts the newer served versions; creates the channel
scripts/rollout.sh start   nyra:stable 2026.10.3 5   # 2026.10.3 at 5%; the current version becomes "previous"
scripts/rollout.sh percent nyra:stable 25            # raise to 25% (or resume a stopped rollout at 25%)
scripts/rollout.sh percent nyra:stable 100           # rollout finished; "previous" stays as the revert target
scripts/rollout.sh stop    nyra:stable               # stop
scripts/rollout.sh revert  nyra:stable               # revert to "previous"; the current version goes into "retracted"
scripts/rollout.sh show    nyra:stable
scripts/publish-sheet.sh   nyra:stable               # CI: the sheet from git → signed → KV (locally: the local KV)
```

- **Versions come only from `releases.json`** (in git): `rollout.sh` refuses a version that is
  missing, and `publish-sheet.sh` takes the digests from there too. A version tag moved in KV
  changes nothing of what is signed. (Later, the digest can also be checked against the version
  label of the signed image.)
- **The same rules as the client:** `scripts/sheet-rules.jq` has `valid_state` (the channel file)
  and `valid_payload` (a copy of `Sheet::check`, plus the channel binding). An invalid state is
  refused by `rollout.sh` and not signed by `publish-sheet.sh`.
- **`set` keeps the `retracted` list**, and when it takes the channel **back**, it also retracts
  the served versions newer than the chosen one (`current`, `previous`). Otherwise computers left
  on a retracted version or on the newest one would refuse the step down as a downgrade (the case
  found in QA review: `revert`, `start`, `set` two versions back). On a broken file, `set` says
  that the list is lost.
- It also refuses: a percentage outside 0–100, `start` on a channel without a file (`set` first),
  `start` while a rollout is in progress or stopped (`percent 100` or `revert` first), `start` with
  a version **older than or equal to** the current one, `start`/`set` with a retracted version (a
  new one is published), `revert` without a previous version.
- **Sequence = the Unix time of signing** (`sequence` = `issued_at`). CI runs are serialized
  (`concurrency:` with `cancel-in-progress: false`) and take more than a second, so the sequence
  grows; a sheet rebuilt after any loss still comes out above the earlier ones. No old sequence is
  read from KV.
- **Signing** (`scripts/sign-sheet.sh`): KMS in CI, with the signature verified against the
  trusted public key (`SHEET_PUBLIC_KEY`) before it is written to KV; locally, a throwaway test key
  (`SHEET_TEST_KEY`). **Without a signer it refuses**; an unsigned sheet comes out only with
  `SHEET_UNSIGNED=1`, explicitly, locally.
- `publish-sheet.sh` also writes the **channel tag** (`tag/<repo>/<channel>`) used by the
  server-side rollout above, computed from the same state.
- **Tests:** `bash scripts/test-rollout.sh` (run in CI, ~2 s) on a temporary directory instead of
  `channels/` (`CHANNELS_DIR`) and files instead of KV (`ROLLOUT_KV_DIR`), with a test key
  generated at that moment: the `rollout.sh` scenarios, the signed sheet (verified with openssl),
  **a state and a version tag injected into KV do not reach signing**, an invalid state is not
  signed, the refusal without a signer.

### Local proof (8 October 2026, with the script of that time, which took digests)

The local Worker (`npm run dev`), two busybox versions published with `seed-local.sh` as
`2026.10.1` (`bd44eb13…`) and `2026.10.2` (`d82c2ab9…`), `stable` on `2026.10.1`, two codes chosen
on either side of the 50% threshold (with the local salt, `vm-code-3` falls in group 41,
`vm-code-4` in group 54). The client: `skopeo inspect --creds <user>:<code>` from the Podman
machine.

| Step | `vm-code-3` (41) | `vm-code-4` (54) | others |
|---|---|---|---|
| before | 2026.10.1 | 2026.10.1 | |
| `start … 50` | **2026.10.2** | 2026.10.1 | no credentials: 2026.10.1 |
| `stop` | 2026.10.1 (had not taken it); **2026.10.2** with user `sha256-d82c…` (had taken it) | 2026.10.1 | |
| `percent … 60` | 2026.10.2 | **2026.10.2** | |
| `revert` | 2026.10.1, also with user `sha256-d82c…` | 2026.10.1 | |
| `start … 99`, then `percent … 100` | 2026.10.2 | | empty password (`nyra:`): 2026.10.1 at 99%, 2026.10.2 at 100% |

The response has `Cache-Control: private, no-store`, and the `wrangler dev` log contains neither
the codes in clear nor in base64.

## The signed channel sheet

The cosign signature (on the image) covers the image, not the channel. Without a sheet, whoever
can write to KV can move `stable` to a signed `dev` build, a fake tag (`2099.1.1` pointing to an
old build) can bypass the refusal of older versions, and an old channel served forever
("freeze") is not noticed. The sheet solves all three and moves the computation of the rollout
group onto the computer: the install code no longer goes over the network.

### The format

A small JSON document for each channel, the same for everybody, in a **DSSE** envelope (the signed
envelope format used by in-toto and Sigstore):

```json
{"payloadType": "application/vnd.nyra.channel-sheet.v1+json",
 "payload": "<base64 of the sheet>",
 "signatures": [{"keyid": "", "sig": "<base64 of the Ed25519 signature, 64 bytes>"}]}
```

The signature covers `DSSEv1 <type length> <type> <sheet length> <sheet>`: the exact bytes of the
sheet (no "canonical" JSON problem), and a signature made with the same key for something else
cannot be reused as a sheet. The sheet:

```json
{"schema": 1, "repository": "nyra", "channel": "stable",
 "sequence": 1791498540, "issued_at": 1791498540, "expires_at": 1792103340,
 "current":  {"digest": "sha256:<hex>", "version": "2026.10.3"},
 "previous": {"digest": "sha256:<hex>", "version": "2026.10.1"},
 "percent": 25, "halted": false, "retracted": ["sha256:<hex>"]}
```

| Field | Meaning |
|---|---|
| `schema` | `1`; any other value is refused; **unknown fields are refused**, so every new field comes with a new `schema` (a security field cannot be silently ignored by an old client) |
| `repository`, `channel` | the sheet's channel; the computer refuses the sheet of another channel or repository |
| `sequence` | grows with every new sheet of the channel (CI puts the Unix time of signing); at most `expires_at`; the computer does not accept one lower than the last accepted |
| `issued_at`, `expires_at` | Unix seconds; from `expires_at` the sheet is refused; `issued_at` may be at most one day in the future (clocks running behind); the maximum validity is 31 days |
| `current` | the new version (the manifest digest and the release version) |
| `previous` | the last good version, for those outside the rollout; `null` = no rollout (then `percent` = 100 and `halted` = `false`) |
| `percent` | groups `0..percent-1` get `current` |
| `halted` | stopped: nobody new gets `current`, whoever runs it keeps it |
| `retracted` | the digests of retracted versions: only computers that run one of them may step down to an older version |

The release version has exactly three numbers (`year.month.build`, no leading zeros) and is
compared number by number (`2026.10.10` > `2026.10.9`). **The order of versions comes only from the
signed sheet**, never from tag names.

### The signature: Ed25519, with the key in Google Cloud KMS

The options weighed: `cosign sign-blob` keyless, with the same identity as the images (the keyless
signing identity of the image signatures), or a minimal Ed25519 scheme, with the public key in
`/usr`. We chose **Ed25519**:

- **Verification on the computer is a single call** (`verify_strict` from `ed25519-dalek`, an
  audited library, no unsafe code). Keyless would require in `nyra-updated`, which runs as root:
  validating the X.509 chain up to the Fulcio CA, reading the certificate extensions (the OIDC
  issuer, the account address), verifying the Rekor SET (ECDSA over canonical JSON) and the
  certificate time against the SET. Either the `sigstore` crate (many dependencies, network, async),
  or hundreds of lines of hand-written ASN.1. KISS and a small attack surface.
- **The sheet is re-signed often** (daily, for expiry). With keyless, every re-signing depends on
  the public Fulcio and Rekor, which have no SLA: an outage longer than the validity would stop
  updates on all computers. KMS has an SLA.
- **The Sigstore roots** in `/usr` already carry their own rotation risk (for the image
  signatures); the sheet does not double it.
- **The same identity path, no key in CI:** CI gets a token only through GitHub OIDC → Workload
  Identity Federation → a service account, as for the images. The private key stays in KMS and
  cannot be exported; the account has only `roles/cloudkms.signer` on that key. No key in the
  repository, on the build machine or with the agents.

The key and rotation:
- **The public key** is shipped in the image, in `/usr/lib/nyra/updates/channel-sheet.pem`
  (nyra-base, with the production publishing job), like the `subjectEmail` in `policy.json`: it
  changes only through a reviewed commit. The file may have several `PUBLIC KEY` blocks; any key in
  it is accepted.
- **With no key installed, every sheet is refused** (`NoTrustedKeys`, fail closed), as
  `signer-not-configured@nyra.invalid` makes images be refused.
- **Rotation:** an image with the old and the new key, then signing with the new one after the
  image has reached everywhere, then an image without the old key.
- **Who can sign:** the same people who can obtain a token for the service account (see
  `docs/SIGNING.md` in nyra-base, "Who can sign"). That is why signing stays **off until `main` is
  protected**: whoever can commit to `main` could get a sheet signed.
- **To verify at setup:** the `EC_SIGN_ED25519` algorithm in KMS (it signs the data, not a hash)
  and its availability at the HSM level; the cost of a KMS key is of the order of cents or a few
  dollars per month. If Ed25519 were not available, the fallback is ECDSA P-256 (it changes only
  the verification in the library).

### What a computer verifies (`updated/channel-sheet` in `NyraOS/nyra-base`)

The Rust library that `nyra-updated` will use. `verify`, in this order:
1. the size (at most 64 KiB), the envelope, `payloadType`;
2. the signature with a trusted key (nothing in the sheet is read before);
3. `schema`, the expected repository and channel;
4. consistency: `sha256` digests, valid versions, `previous` older than `current`, `percent` ≤ 100,
   stop or partial rollout only with `previous`, no retracted version served, `expires_at` after
   `issued_at`, validity ≤ 31 days, `sequence` ≤ `expires_at`;
5. **expiry** and **issued in the future** (at most one day, `NotYetValid`), against the computer's
   clock;
6. the **sequence**, against the last sheet accepted for the channel (equal is accepted: the same
   sheet downloaded again).

**The lock-out limit:** with issuance at most one day in the future, validity at most 31 days and
`sequence` ≤ `expires_at`, no accepted sheet has a sequence greater than "now + 32 days". A wrongly
signed sheet (or one made by someone who got signing once) with a huge sequence is refused; the
worst acceptable sheet blocks a computer for at most 32 days, after which the legitimate sheets
(sequence = issue time) overtake it.

**A wrong clock:** a computer with its clock more than a day behind refuses new sheets
(`NotYetValid`), one with its clock ahead sees them as expired (`Expired`). In both cases it saves
nothing, so it does not get stuck: it resumes updates as soon as the clock is correct (network time
synchronization). One day of tolerance covers dual-boot computers, whose hardware clock is on local
time (Windows) until synchronization. The remaining limit: a computer with its clock far ahead may
accept a sheet issued wrongly in its future, and then stays blocked until real time reaches that
sequence; this needs both a wrongly signed sheet and a wrong clock.

**On expiry** (or any other error) the computer does nothing: it does not update, does not step
down, and stays on the version it runs. After a few days without a valid sheet, Settings says "We
could not check for updates". A freeze can keep a computer behind for at most the validity of a
sheet (7 days).

Then `rollout_group` and `Sheet::decide`:

| The computer runs | Gets |
|---|---|
| `current` | nothing (stays), also when the rollout is stopped |
| anything else | the target: `previous` if the rollout is stopped or the group ≥ `percent`, otherwise `current` (the same rule as `chooseDigest`) |
| the target is newer than what runs | `Update(target)` |
| the target is not newer, but what runs is in `retracted` | `Retract(target)`: the step down signed by us |
| the target is not newer and what runs is not retracted | refused (`Downgrade`): a compromised server, a channel moved back in KV, or a user who came from `beta` |

### The rollout group, computed on the computer

**group = HMAC-SHA256(key = the install code, message = `nyra-rollout-group-v1\n<repo>:<channel>\n<current digest>`) mod 100**,
from the first 32 bits.

- **No secret on the server:** the HMAC key is the install code itself (at least 128 random bits,
  at least 16 bytes accepted), which does not leave the computer. Without the code the group
  cannot be computed; nothing about the code can be learned from the group. The server cannot target
  a specific computer.
- **Stable across the whole rollout of a version** (the `current` digest does not change while it
  lasts), so a computer does not enter and leave the rollout when the percentage grows or on stop.
- **Different for every version:** it is not always the same 5% of computers that take a new
  version first (the risk is spread). And on different channels the groups are independent.
- A client that changes its code to get in earlier only gets the new version for itself, which
  anybody can do anyway by asking for it by digest.

### Signing in CI (designed, off until `main` is protected)

The job arrives together with production publishing, because it also needs the Cloudflare token for
KV (write only). Its design:

The workflow is `.github/workflows/channel-publish.yml` (the sketch below is its first design; it
differs in the details: the path filter also covers `keys/**`, a channel without a file is skipped,
the Cloudflare secret is `CLOUDFLARE_KV_TOKEN`, and the public key is `keys/channel-sheet.pem`,
at the root of this repository). It stays off until the owner sets `SHEET_KMS_KEY`, together with
`SHEET_WIF_PROVIDER` and `SHEET_SIGNER_SA`. `.github/workflows/registry-deploy.yml` deploys the
Worker on `main` only when the variable `REGISTRY_DEPLOY` is `on`.

```yaml
# .github/workflows/channel-publish.yml (the first design)
on:
  push: { branches: [main], paths: ["channels/**"] }   # a rollout change = a commit on main
  schedule: [{ cron: "23 4 * * *" }]                    # daily re-signing of the state in git: the sheet does not expire
concurrency: { group: channel-publish, cancel-in-progress: false }
jobs:
  publish:
    if: github.ref == 'refs/heads/main' && vars.SHEET_KMS_KEY != ''   # off while the variable is missing
    runs-on: ubuntu-24.04                        # GitHub-hosted, never a runner on the build machine
    permissions: { contents: read, id-token: write }
    steps:
      - uses: actions/checkout@…                 # the state comes from main, not from KV
      - uses: google-github-actions/auth@…        # WIF → the sheet service account
        id: google
        with: { workload_identity_provider: …, service_account: …, token_format: access_token, create_credentials_file: false }
      - run: for f in channels/*/{dev,beta,stable}.json; do …/publish-sheet.sh "<repo>:<channel>"; done   # --remote
        env:
          SHEET_KMS_KEY: ${{ vars.SHEET_KMS_KEY }}
          SHEET_KMS_TOKEN: ${{ steps.google.outputs.access_token }}
          SHEET_PUBLIC_KEY: …/channel-sheet.pem                  # the committed public key, the same as in the image
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_KV_TOKEN }}  # write only on the TAGS namespace
```

No `workflow_dispatch` inputs: there is no way to sign anything other than what is on `main`.

Setup, by the owner, after `main` is protected: a `EC_SIGN_ED25519` KMS key (no export), a
`nyra-sheet-signer` service account with `roles/cloudkms.signer` only on it, a WIF provider
conditioned on this repository (by ID), `main`, the workflow above, the `push` and `schedule` events
and a hosted runner; the public key (`gcloud kms keys versions get-public-key`) goes in by commit
to nyra-base and to this repository; only then the `SHEET_KMS_KEY` variable.
`scripts/sign-sheet.sh` does the signing (the `asymmetricSign` REST API, the token passed through a
header file, not on the command line) and verifies the signature before writing it.

**Cloudflare tokens, one per job, each as small as possible:**

| Secret | Used by | May do |
|---|---|---|
| `CLOUDFLARE_KV_TOKEN` | `channel-publish.yml` | **KV only:** write on the `TAGS` namespace, nothing else (no Workers scripts, no routes, no R2) |
| `CLOUDFLARE_API_TOKEN` | `registry-deploy.yml` only | deploy the Worker (Workers scripts and routes) |

The signing job never gets the deploy token, so a change to that workflow cannot reach the Worker
code. In `publish-sheet.sh` the Google token (`SHEET_KMS_TOKEN`) is passed only to `sign-sheet.sh`:
wrangler does not inherit it, and the Google credentials file is not created.

**Scheduled runs stop by themselves:** GitHub disables scheduled workflows in a public repository
after 60 days without activity. Then the daily publication stops, the sheets expire after 7 days
and computers stop updating (safe: they stay on their version), but it must be watched: any commit
or re-enabling the workflow in the Actions tab restarts it.

**What stays in our trust:** who can commit to `main` (which is why signing is off until it is
protected) and who can obtain a token for the service account. A KV writer can only delete or
corrupt the served sheet (computers refuse it and stay on their version) until the next
publication.

### Simplifying the Worker, once `nyra-updated` uses the sheet

The server-side rollout code **stays for now**: no image has `nyra-updated` yet. It is removed in a
separate step, once the shipped images verify the sheet and pull the version by digest
(`updates.nyraos.com/nyra@sha256:…`):
1. `chooseDigest`, `src/auth.ts` (the install code, the group, the digest from the user), the
   `ROLLOUT_SALT` secret and their tests (`test/rollout.test.ts`, `test/auth.test.ts`);
2. the `401` challenge on `/v2/` (computers no longer send anything; anonymous clients go straight
   through);
3. the channel tag becomes just `{"digest": <current>}` (for people and `skopeo`), and
   `publish-sheet.sh` no longer writes the rollout fields in it;
4. manifests by tag can become briefly cacheable again (the response no longer depends on the
   client).

`nyra-updated` no longer writes `/run/ostree/auth.json` (the requirement for the server-side
rollout disappears).

## Running locally and tests

```bash
npm ci
npm test            # vitest in workerd (Workers pool), local R2 and KV
npm run typecheck
npm run dev         # wrangler dev on :8787, with the state in .wrangler/state
bash scripts/test-publish-image.sh   # publish-image.sh into a temporary local state, read back through wrangler dev
```

`npm run dev` uses `dev/entry.ts`, which adds `/_dev/blobs/...` in place of the public R2 domain
(it serves the blobs from the local R2, with `Range`). The redirect is relative, so it works from
the Mac (`localhost`), from the Podman machine (`host.containers.internal`) and from the test VM
(`192.168.127.254`). The code in `dev/` does not go into the published Worker.

Loading a real image into the local state:

```bash
podman machine ssh skopeo copy --override-arch arm64 \
  docker://docker.io/library/busybox:latest oci:$PWD/.wrangler/oci:busybox
bash scripts/seed-local.sh .wrangler/oci nyra stable=busybox
podman machine ssh skopeo inspect --tls-verify=false docker://host.containers.internal:8787/nyra:stable
podman machine ssh skopeo copy --src-tls-verify=false docker://host.containers.internal:8787/nyra:stable dir:/tmp/bb
```

### What was verified locally (8 October 2026)

- `skopeo inspect` and `skopeo copy` through the Worker, with and without an install code, by tag
  and by digest; the digest of the downloaded layer is correct.
- `skopeo copy` **to** the registry fails when writing the manifest: "unsupported: this registry is
  read-only".
- **`zstd:chunked`**: `podman pull` with partial download enabled reported "Retrieved partial
  blob"; `Range` requests reached the blob origin after the redirect (`206`). The first request has
  several ranges (`bytes=a-b,c-d`); the local origin then answers with the whole file, and the
  client coped.
- **bootc from a VM** (TCG emulation): a system installed from one image build, `bootc switch` to
  `nyra:stable` from the Worker with the channel on the next build → **only 3 layers downloaded
  (~51 MB)**, not the 388 MB base layer; a reboot into the new build, then `bootc upgrade`: "No
  changes" (only the manifest and the config requested).

**The channel sheet (9 October 2026, after Security's veto):** a temporary channels directory
(`releases.json` with `2026.10.1`–`2026.10.3`), then `rollout.sh set`, `start … 50`, `revert`,
`start … 25` on the channel file and `publish-sheet.sh` with a throwaway test key
(`SHEET_TEST_KEY`, openssl) into the local KV. The sheet served by `npm run dev` at
`/channels/nyra/stable` (`200`, `Cache-Control: public, max-age=60`) is saved in
`updated/channel-sheet/tests/data/stable.sheet.json` (`NyraOS/nyra-base`) and verified by the Rust
library (`tests/fixture.rs`): jq + openssl and Rust agree on the envelope, the DSSE encoding and
the sheet.

### What was not verified

- Nothing in the real Cloudflare: the public R2 domain, the cache, the R2/CDN behaviour on requests
  with **several ranges**, KV consistency, the plan limits.
- Signatures through the registry (image signatures).
- Signing the sheet through Cloud KMS (`EC_SIGN_ED25519`, `asymmetricSign` with `data`):
  unconfigured, off (until `main` is protected).
- Gradual rollout with `bootc` from a VM (verified with `skopeo`, which uses the same
  `containers/image` library) and `nyra-updated` writing `/run/ostree/auth.json`.

## Estimated costs

Public Cloudflare prices known at the time of writing (to be verified at activation): Workers Free
100,000 requests/day, Workers Paid $5/month with 10 million requests included, then $0.30/million;
R2 $0.015/GB-month (10 GB free), class A operations $4.50/million (1 million free/month), class B
$0.36/million (10 million free/month), **free egress**; KV free 100,000 reads/day, on the paid plan
10 million/month included, then $0.50/million.

What an update check with no new version costs (measured with bootc): 3 requests to the Worker
(`/v2/`, the manifest, the config) + 1 KV read + 2 class B R2 operations; the config comes from the
CDN cache. Gradual rollout adds no operations: the state is in the same KV value, and the HMAC takes
microseconds. With signatures (image signatures), ~2 more requests. An update adds 1 request to
the Worker + 1 class B operation per changed layer; the bytes come from cache or from R2, with no
egress cost.

| Computers (check every 6 h, weekly update) | Worker | R2 | KV | Total per month |
|---|---|---|---|---|
| 1,000 | ~20,000 requests/day, on the free plan | storage ~20–50 GB ≈ $0.15–0.60; operations within the free quota | within the free quota | **< $1** |
| 10,000 | ~200,000/day → Workers Paid | the same | within the included quota | **~$5–6** |
| 100,000 | ~60 million/month ≈ $20 | ~36 million class B ≈ $9 | ~24 million reads ≈ $7 | **~$40** |

Traffic is the big part of a distribution: 100,000 computers × 4 updates × 100 MB = 40 TB/month,
free on R2 (at a provider charging $0.09/GB it would be ~$3,600). Storage grows with the layers
that change from one version to the next (tens to hundreds of MB per version) and the retention rule
keeps it in check. The CDN cache has a size limit per file (512 MB on the Free/Pro/Business plans):
larger layers are served directly from R2, still with no egress cost, only one extra class B
operation; the image's layers are kept below this limit.
