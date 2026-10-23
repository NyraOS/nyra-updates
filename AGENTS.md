# AGENTS.md

Guide for coding agents and people working in this repository. What the project is: [README.md](README.md); the registry in detail: [registry/README.md](registry/README.md).

## What this is

How Nyra OS updates reach a machine: a read-only registry (a Cloudflare Worker in TypeScript over R2 and KV) that serves the images and the signed channel sheets, the channel state (dev, beta, stable) kept as files in git, and the CI jobs that publish image blobs and sign the sheets. The client, `nyra-updated`, is in [NyraOS/nyra-base](https://github.com/NyraOS/nyra-base).

Nothing is deployed from a developer machine: every change is a pull request and only CI on `main` publishes or deploys.

## Map (read in this order)

1. `README.md`, then `registry/README.md` (how it works, the signed channel sheet, gradual rollout, publishing from CI).
2. `registry/src/`: `index.ts` (the Worker), `oci.ts`, `auth.ts`. `registry/dev/`: the local development entry.
3. `registry/scripts/`: `publish-image.sh`, `publish-sheet.sh`, `sign-sheet.sh`, `rollout.sh` and their tests (`test-*.sh`), `seed-local.sh`, `sheet-rules.jq`.
4. `registry/test/`: Worker tests (vitest, in a local workerd with local R2 and KV).
5. `channels/<repo>/releases.json`: the channel state. `keys/channel-sheet.pem`: the public key of the channel sheets.
6. `.github/workflows/`: `registry.yml` (tests), `registry-deploy.yml`, `channel-publish.yml`, `secrets.yml`.

## Build, test, lint

Node 22 or newer (CI uses 24). From `registry/`, as CI runs them (`.github/workflows/registry.yml`):

```sh
npm ci
npm test
bash scripts/test-publish-image.sh
bash scripts/test-rollout.sh
sudo apt-get install -y --no-install-recommends skopeo docker-registry   # for the next one
bash scripts/test-e2e-signed-pull.sh
```

`npm run typecheck` (`tsc --noEmit`) is in the registry README. `scripts/rollout.sh` edits channel state: use it rather than editing `channels/` by hand. None of them needs a secret. Publishing, signing and deploying (`--remote`, the `channel-publish` and `registry-deploy` jobs) run in CI on `main` only.

## Working rules

- Work on a branch, never on `main`. One small, focused change per pull request, with a clear reason. A rollout change is a commit to `channels/`.
- Before you start, read the recent changes (`git log`) and the docs of the area.
- Commit messages: a short imperative subject in plain English. The only trailer is `Co-Authored-By: <model name> <noreply@anthropic.com>`. No "Generated with ..." line and no session link in commits or pull request text.
- A test that fails sometimes is a bug: find the cause, do not rerun until green. Never weaken or skip a test to make it pass.
- Pin what CI runs: actions by commit SHA, npm packages through `package-lock.json`.
- English for code, comments, commits and docs.

## Code rules (KISS: code a person can read)

- Read top to bottom. Functions about 50 lines at most, files short. Each file starts with a short header saying what it does and why it exists.
- Plain loops and `if`/`switch` instead of long chains of `map`/`filter`/`reduce`. No clever types: keep TypeScript `strict`, no `any`, no generics unless needed (with the reason next to them).
- Scripts: bash with `set -euo pipefail`, one thing per script, shellcheck clean, with a `test-*.sh` next to it.
- Comments explain why, not what.
- A dependency that makes the code clearer is fine; do not write your own replacement without a reason.
- No options or layers "for later".

## Security-sensitive areas

Changes here need a security review before merge: the channel state (`channels/`: it decides which version every machine is offered), the sheet key and signing (`keys/`, `registry/scripts/sign-sheet.sh`, `publish-sheet.sh`), the publishing and deploy workflows and their permissions, `registry/wrangler.toml`, the install-code handling in `registry/src/auth.ts` (the code is never logged, stored or sent back), and the checks the Worker does on manifests and digests. Signing keys are never in this repository or on a build machine. Never put secrets, keys or tokens in the repository, tests or logs; test keys are throwaway.

## Docs

`registry/README.md` has the design, the publishing flow and the rollout procedure.
