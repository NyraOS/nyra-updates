// Nyra OS registry: a read-only OCI Distribution API over R2 (blobs) and KV (tags).
// Pull only. There are no push endpoints; CI writes R2 and KV directly (README.md).
//
// Storage layout, written by CI:
//   R2   blobs/sha256/<hex>       every blob: layers, configs, manifests (= blobs/ of an OCI layout)
//   KV   tag/<repository>/<tag>   {"digest": "sha256:<hex>"}, plus rollout fields on channel tags:
//                                 "previous", "percent", "halted" (see chooseDigest, README.md)
//   KV   sheet/<repository>/<channel>   the signed channel sheet, served as is

import { parseInstallCode, parseRunningDigest, rolloutGroup } from "./auth";
import {
  BASE_HEADERS,
  MAX_MANIFEST_BYTES,
  errorResponse,
  isValidName,
  isValidTag,
  manifestMediaType,
  sha256Digest,
  sha256Hex,
} from "./oci";

export interface Env {
  IMAGES: R2Bucket;
  TAGS: KVNamespace;
  /** Comma-separated repositories served, e.g. "nyra-base". */
  REPOSITORIES: string;
  /** Where blob downloads are redirected: the public custom domain of the R2 bucket. */
  BLOB_BASE_URL: string;
  /** Secret salt of the rollout group (`wrangler secret put ROLLOUT_SALT`). Missing = no groups. */
  ROLLOUT_SALT?: string;
}

/** A tag in KV. Version tags have only `digest`; a channel in a staged rollout has the rest. */
interface TagPointer {
  /** The channel's current (newest) version. */
  digest: string;
  /** The last good version: served to clients outside the rollout, and the target of a revert. */
  previous?: string;
  /** Groups 0..percent-1 get `digest`. */
  percent?: number;
  /** Stopped: nobody new gets `digest`; clients that run it keep it. */
  halted?: boolean;
}

const IMMUTABLE = "public, max-age=31536000, immutable";
// Short: a halt or a revert must reach machines within minutes (KV itself takes up to ~60 s).
const SHEET_CACHE = "public, max-age=60";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handle(request, env);
    } catch (err) {
      // Never log the request or its headers: Authorization carries the install code.
      console.error("registry: internal error:", err instanceof Error ? err.message : "unknown");
      return errorResponse(500, "UNKNOWN", "internal error", request.method);
    }
  },
} satisfies ExportedHandler<Env>;

async function handle(request: Request, env: Env): Promise<Response> {
  const method = request.method;
  const url = new URL(request.url);
  const path = url.pathname;

  const sheet = /^\/channels\/(.+)\/([^/]+)$/.exec(path);
  if (!sheet && path !== "/v2" && !path.startsWith("/v2/")) return errorResponse(404, "UNSUPPORTED", "not found", method);
  if (method !== "GET" && method !== "HEAD") {
    return errorResponse(405, "UNSUPPORTED", "this registry is read-only", method, { Allow: "GET, HEAD" });
  }
  if (sheet) return channelSheet(env, method, sheet[1]!, sheet[2]!);

  if (path === "/v2" || path === "/v2/") {
    // containers/image (bootc, skopeo, podman) sends credentials only after a challenge, so a
    // request without Authorization gets one. Any Basic header, even empty credentials, passes.
    if (!request.headers.has("Authorization")) {
      return errorResponse(401, "UNAUTHORIZED", "send the install code as the Basic password, or empty credentials", method, {
        "WWW-Authenticate": 'Basic realm="Nyra OS updates"',
      });
    }
    return new Response(method === "HEAD" ? null : "{}", { headers: { ...BASE_HEADERS, "Content-Type": "application/json" } });
  }

  const m = /^\/v2\/(.+)\/(manifests\/[^/]+|blobs\/[^/]+|tags\/list)$/.exec(path);
  if (!m) return errorResponse(404, "UNSUPPORTED", "endpoint not supported by this registry", method);
  const [, name, rest] = m as unknown as [string, string, string];
  if (!isValidName(name)) return errorResponse(400, "NAME_INVALID", "invalid repository name", method);
  if (!isServed(env, name)) return errorResponse(404, "NAME_UNKNOWN", "repository name not known to registry", method);

  if (rest === "tags/list") return tagsList(env, method, name);
  const [kind, reference] = rest.split("/") as [string, string];
  if (kind === "blobs") return blob(env, method, reference);
  return manifest(env, method, name, reference, request.headers.get("Authorization"));
}

const isServed = (env: Env, name: string) => env.REPOSITORIES.split(",").map((s) => s.trim()).includes(name);

/**
 * GET /channels/<repository>/<channel>: the signed channel sheet (README.md), served exactly
 * as CI stored it. It is the same document for everybody (no credentials, no per-client logic),
 * so shared caches may keep it briefly; machines verify the signature, expiry and sequence.
 */
async function channelSheet(env: Env, method: string, name: string, channel: string): Promise<Response> {
  if (!isValidName(name) || !isValidTag(channel)) return errorResponse(400, "NAME_INVALID", "invalid channel", method);
  if (!isServed(env, name)) return errorResponse(404, "NAME_UNKNOWN", "repository name not known to registry", method);
  const value = await env.TAGS.get(`sheet/${name}/${channel}`);
  if (value === null) return errorResponse(404, "SHEET_UNKNOWN", "no sheet for this channel", method);
  return new Response(method === "HEAD" ? null : value, {
    headers: { "Content-Type": "application/json", "Cache-Control": SHEET_CACHE },
  });
}

/**
 * The digest a client gets for a tag. `group` is null for clients without an install code: they
 * are treated as the last group and get a new version only when its rollout reaches 100%.
 */
export function chooseDigest(tag: TagPointer, group: number | null, running: string | null): string {
  if (tag.previous === undefined) return tag.digest; // no rollout (or reverted): one version for all
  if (running === tag.digest) return tag.digest; // never move a client back, except by a revert
  if (tag.halted) return tag.previous;
  const percent = tag.percent ?? 100;
  if (percent >= 100) return tag.digest;
  return group !== null && group < percent ? tag.digest : tag.previous;
}

const isDigest = (v: unknown) => typeof v === "string" && sha256Hex(v) !== null;

// The same rules are checked by scripts/rollout.sh (`valid` in jq) before and after every change.
function isTagPointer(p: unknown): p is TagPointer {
  if (typeof p !== "object" || p === null || Array.isArray(p)) return false;
  const { digest, previous, percent, halted } = p as Record<string, unknown>;
  return (
    isDigest(digest) &&
    (previous === undefined || isDigest(previous)) &&
    (percent === undefined || (typeof percent === "number" && Number.isInteger(percent) && percent >= 0 && percent <= 100)) &&
    (halted === undefined || typeof halted === "boolean")
  );
}

async function manifest(
  env: Env,
  method: string,
  name: string,
  reference: string,
  authorization: string | null,
): Promise<Response> {
  let digest = reference;
  const byTag = sha256Hex(reference) === null;
  if (byTag) {
    if (reference.includes(":")) return errorResponse(400, "DIGEST_INVALID", "only sha256 digests are supported", method);
    if (!isValidTag(reference)) return errorResponse(400, "TAG_INVALID", "invalid tag", method);
    const value = await env.TAGS.get(`tag/${name}/${reference}`); // null only when the key is missing
    if (value === null) return errorResponse(404, "MANIFEST_UNKNOWN", "manifest unknown", method);
    const pointer: unknown = JSON.parse(value); // invalid JSON throws: 500, like any corrupt state
    if (!isTagPointer(pointer)) throw new Error(`tag ${name}:${reference} is not a valid tag pointer`);
    // The install code lives only in this line (and only for tags); it is turned into a group and dropped.
    const group = await rolloutGroup(parseInstallCode(authorization), env.ROLLOUT_SALT);
    digest = chooseDigest(pointer, group, parseRunningDigest(authorization));
  }

  const object = await env.IMAGES.get(`blobs/sha256/${sha256Hex(digest)}`);
  let body: Uint8Array | null = null;
  if (object && object.size <= MAX_MANIFEST_BYTES) body = new Uint8Array(await object.arrayBuffer());
  else await object?.body.cancel(); // too big to be a manifest (a layer): do not read it
  const mediaType = body && manifestMediaType(body);
  if (!body || !mediaType) {
    if (byTag) console.error(`registry: tag ${name}:${reference} points to ${digest}, which is missing or not a manifest`);
    return errorResponse(404, "MANIFEST_UNKNOWN", "manifest unknown", method);
  }
  if ((await sha256Digest(body)) !== digest) {
    console.error(`registry: stored manifest ${digest} failed digest verification`);
    return errorResponse(500, "UNKNOWN", "stored manifest failed digest verification", method);
  }

  return new Response(method === "HEAD" ? null : body, {
    headers: {
      ...BASE_HEADERS,
      "Content-Type": mediaType,
      "Content-Length": String(body.byteLength),
      "Docker-Content-Digest": digest,
      // Digests never change. Tags move, and during a rollout the answer depends on the client's
      // group: a shared cache (CDN, proxy) must never store it and serve it to another client.
      "Cache-Control": byTag ? "private, no-store" : IMMUTABLE,
    },
  });
}

async function blob(env: Env, method: string, digest: string): Promise<Response> {
  const hex = sha256Hex(digest);
  if (hex === null) return errorResponse(400, "DIGEST_INVALID", "invalid or unsupported digest", method);
  const key = `blobs/sha256/${hex}`;
  const object = await env.IMAGES.head(key);
  if (object === null) return errorResponse(404, "BLOB_UNKNOWN", "blob unknown to registry", method);

  if (method === "HEAD") {
    return new Response(null, {
      headers: {
        ...BASE_HEADERS,
        "Content-Type": "application/octet-stream",
        "Content-Length": String(object.size),
        "Docker-Content-Digest": digest,
      },
    });
  }
  // The bytes never pass through the Worker: the client follows the redirect to the public R2
  // domain (cached by Cloudflare) and re-sends its Range header there for partial pulls.
  // The client verifies the digest of what it downloads.
  return new Response(null, {
    status: 307,
    headers: { ...BASE_HEADERS, "Docker-Content-Digest": digest, Location: `${env.BLOB_BASE_URL}/${key}` },
  });
}

async function tagsList(env: Env, method: string, name: string): Promise<Response> {
  const prefix = `tag/${name}/`;
  const tags: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.TAGS.list({ prefix, cursor });
    // "tag/nyra-base/" is also a prefix of "tag/nyra-base/desktop/stable" (repository nyra-base/desktop).
    tags.push(...page.keys.map((k) => k.name.slice(prefix.length)).filter(isValidTag));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  const body = JSON.stringify({ name, tags: tags.sort() });
  return new Response(method === "HEAD" ? null : body, {
    headers: { ...BASE_HEADERS, "Content-Type": "application/json", "Cache-Control": "no-cache" },
  });
}
