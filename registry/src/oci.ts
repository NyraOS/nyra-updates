// The parts of the OCI Distribution Spec a pull-only registry needs.
// https://github.com/opencontainers/distribution-spec/blob/main/spec.md

export const MANIFEST_MEDIA_TYPES = [
  "application/vnd.oci.image.manifest.v1+json",
  "application/vnd.oci.image.index.v1+json",
  "application/vnd.docker.distribution.manifest.v2+json",
  "application/vnd.docker.distribution.manifest.list.v2+json",
];

/** Bigger objects are never read as manifests (the spec suggests accepting at least 4 MiB). */
export const MAX_MANIFEST_BYTES = 4 * 1024 * 1024;

const NAME_RE = /^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(\/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*$/;
const TAG_RE = /^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$/;
// Only sha256: that is what CI produces and what the R2 layout is keyed on.
const DIGEST_RE = /^sha256:([a-f0-9]{64})$/;

export const isValidName = (name: string) => name.length <= 255 && NAME_RE.test(name);
export const isValidTag = (tag: string) => TAG_RE.test(tag);

/** The hex part of a sha256 digest, or null if `digest` is not one. */
export function sha256Hex(digest: string): string | null {
  return DIGEST_RE.exec(digest)?.[1] ?? null;
}

export async function sha256Digest(data: Uint8Array): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return "sha256:" + Array.from(hash, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** The manifest's own mediaType, or null if the body is not a manifest we serve. */
export function manifestMediaType(body: Uint8Array): string | null {
  try {
    const m = JSON.parse(new TextDecoder().decode(body));
    return m?.schemaVersion === 2 && MANIFEST_MEDIA_TYPES.includes(m.mediaType) ? m.mediaType : null;
  } catch {
    return null;
  }
}

export const BASE_HEADERS = { "Docker-Distribution-API-Version": "registry/2.0" };

export function errorResponse(
  status: number,
  code: string,
  message: string,
  method: string,
  extraHeaders: Record<string, string> = {},
): Response {
  const body = method === "HEAD" ? null : JSON.stringify({ errors: [{ code, message }] });
  // Errors are never cached: an error for a tag can depend on the client's rollout group, and a
  // 404 or 500 cached by a proxy would hide a fixed tag.
  const headers = { ...BASE_HEADERS, "Content-Type": "application/json", "Cache-Control": "private, no-store", ...extraHeaders };
  return new Response(body, { status, headers });
}
