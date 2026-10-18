import { env as testEnv } from "cloudflare:workers";
import worker, { type Env } from "../src/index";
import { rolloutGroup } from "../src/auth";
import { sha256Digest } from "../src/oci";

export const env = testEnv as unknown as Env;

export const ORIGIN = "https://updates.nyraos.test";

export function bytes(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

export const OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json";

export function hexOf(digest: string): string {
  return digest.slice("sha256:".length);
}

/** Stores a blob under its own digest and returns the digest. */
export async function putBlob(data: Uint8Array): Promise<string> {
  const digest = await sha256Digest(data);
  await env.IMAGES.put(`blobs/sha256/${hexOf(digest)}`, data);
  return digest;
}

/** Builds and stores a small image (config + one layer + manifest); returns the digests. */
export async function putImage(
  extra: Record<string, unknown> = {},
): Promise<{ manifest: string; manifestBytes: Uint8Array; config: string; layer: string }> {
  const layer = await putBlob(bytes(`layer ${crypto.randomUUID()}`));
  const config = await putBlob(bytes(JSON.stringify({ architecture: "arm64", os: "linux" })));
  const manifestDoc = {
    schemaVersion: 2,
    mediaType: OCI_MANIFEST,
    config: { mediaType: "application/vnd.oci.image.config.v1+json", digest: config, size: 34 },
    layers: [{ mediaType: "application/vnd.oci.image.layer.v1.tar+zstd", digest: layer, size: 42 }],
    ...extra,
  };
  const manifestBytes = bytes(JSON.stringify(manifestDoc));
  const manifest = await putBlob(manifestBytes);
  return { manifest, manifestBytes, config, layer };
}

export async function setTag(repository: string, tag: string, value: string): Promise<void> {
  await env.TAGS.put(`tag/${repository}/${tag}`, value);
}

export async function pointTag(repository: string, tag: string, digest: string): Promise<void> {
  await setTag(repository, tag, JSON.stringify({ digest }));
}

export async function call(
  method: string,
  path: string,
  headers: Record<string, string> = {},
  overrides: Partial<Env> = {},
): Promise<Response> {
  const request = new Request(ORIGIN + path, { method, headers });
  return worker.fetch(request, { ...env, ...overrides });
}

export function basic(user: string, password: string): string {
  const raw = new TextEncoder().encode(`${user}:${password}`);
  return "Basic " + btoa(String.fromCharCode(...raw));
}

export async function errorCode(res: Response): Promise<string | undefined> {
  const body = (await res.json()) as { errors?: { code: string }[] };
  return body.errors?.[0]?.code;
}

export const MISSING_DIGEST = "sha256:" + "0".repeat(64);

/** The salt the tests run with (vitest.config.ts). */
export const TEST_SALT = "test-salt";

/** An install code that falls in rollout group `group` under TEST_SALT. */
export async function codeInGroup(group: number): Promise<string> {
  for (let i = 0; ; i++) {
    if ((await rolloutGroup(`code-${i}`, TEST_SALT)) === group) return `code-${i}`;
  }
}

/** The Basic user with which a client says it runs `digest`. */
export function runningUser(digest: string): string {
  return "sha256-" + hexOf(digest);
}
