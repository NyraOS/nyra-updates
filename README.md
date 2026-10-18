# nyra-updates

How Nyra OS updates reach a machine: the read-only registry (a Cloudflare Worker over R2 and KV),
the release channels (dev, beta, stable) kept as files in this repository, and the CI jobs that
publish image blobs and sign the channel sheets. The client that reads them, `nyra-updated`, is in
[NyraOS/nyra-base](https://github.com/NyraOS/nyra-base) (`updated/`, `docs/UPDATES.md`).

Nothing is deployed from a developer machine: every change goes through a pull request, and only
CI on `main` publishes. Signing keys are never in this repository or on a build machine.

Licence: GPL-3.0-or-later (LICENSE).
