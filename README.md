# nyra-updates

How Nyra OS updates reach a machine: the read-only registry (a Cloudflare Worker over R2 and KV),
the release channels (dev, beta, stable) kept as files in this repository, and the CI jobs that
publish image blobs and sign the channel sheets. The client that reads them, `nyra-updated`, is in
[NyraOS/nyra-base](https://github.com/NyraOS/nyra-base) (`updated/`, `docs/UPDATES.md`).

Nothing is deployed from a developer machine: every change goes through a pull request, and only
CI on `main` publishes. Signing keys are never in this repository or on a build machine.

## Layout

- `registry/`: the Cloudflare Worker (TypeScript) that serves the images and the channel sheets,
  with its tests and the scripts that edit and sign the channel state. Its README explains the design.
- `channels/`: the channel states: the released versions (`releases.json`) and which version
  beta and stable serve; dev always serves the newest release (`registry/README.md`, "The dev channel").

Licence: GPL-3.0-or-later (LICENSE).
