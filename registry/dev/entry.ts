// Local development only (wrangler.toml [env.local]); never deployed.
//
// In production, blob redirects go to the public custom domain of the R2 bucket. Locally there
// is no such domain, so this entry point adds /_dev/blobs/sha256/<hex>, which serves blobs from
// the local R2 bucket with single-range support, like the R2 public endpoint does.
// With BLOB_BASE_URL = "/_dev" the redirect is relative and works from any host name
// (localhost on the Mac, host.containers.internal from the Podman machine, 10.0.2.2 from a VM).

import registry, { type Env } from "../src/index";
import { BASE_HEADERS } from "../src/oci";

const DEV_BLOB_PATH = /^\/_dev\/blobs\/sha256\/([a-f0-9]{64})$/;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const m = DEV_BLOB_PATH.exec(url.pathname);
    const response = m ? await devBlob(request, env, m[1]!) : await registry.fetch(request, env);
    // Only whether a code was sent, never the code itself.
    const code = request.headers.has("Authorization") ? "auth header" : "no auth header";
    const range = request.headers.get("Range");
    console.log(`${request.method} ${url.pathname} -> ${response.status} (${code}${range ? `, ${range}` : ""})`);
    return response;
  },
} satisfies ExportedHandler<Env>;

/** Parses a single "bytes=" range. Returns null for no/unsupported ranges, "invalid" for unsatisfiable ones. */
export function parseRange(header: string | null, size: number): { offset: number; length: number } | "invalid" | null {
  if (header === null) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return null; // multiple ranges or another unit: ignored, the full body is sent (RFC 9110 allows it)
  const [, startS, endS] = m;
  if (startS === "" && endS === "") return null;
  if (startS === "") {
    const suffix = Number(endS);
    if (suffix === 0) return "invalid";
    const length = Math.min(suffix, size);
    return { offset: size - length, length };
  }
  const start = Number(startS);
  if (start >= size) return "invalid";
  const end = endS === "" ? size - 1 : Math.min(Number(endS), size - 1);
  if (end < start) return null;
  return { offset: start, length: end - start + 1 };
}

async function devBlob(request: Request, env: Env, hex: string): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
  }
  const key = `blobs/sha256/${hex}`;
  const head = await env.IMAGES.head(key);
  if (head === null) return new Response("not found", { status: 404 });
  const size = head.size;
  const headers: Record<string, string> = {
    ...BASE_HEADERS,
    "Content-Type": "application/octet-stream",
    "Accept-Ranges": "bytes",
    ETag: `"${hex}"`,
  };
  const range = parseRange(request.headers.get("Range"), size);
  if (range === "invalid") {
    return new Response(null, { status: 416, headers: { ...headers, "Content-Range": `bytes */${size}` } });
  }
  if (request.method === "HEAD") {
    return new Response(null, { status: 200, headers: { ...headers, "Content-Length": String(size) } });
  }
  if (range === null) {
    const object = await env.IMAGES.get(key);
    if (object === null) return new Response("not found", { status: 404 });
    return new Response(object.body, { status: 200, headers: { ...headers, "Content-Length": String(size) } });
  }
  const object = await env.IMAGES.get(key, { range });
  if (object === null) return new Response("not found", { status: 404 });
  return new Response(object.body, {
    status: 206,
    headers: {
      ...headers,
      "Content-Length": String(range.length),
      "Content-Range": `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`,
    },
  });
}
