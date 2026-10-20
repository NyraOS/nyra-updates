import { reset } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_MANIFEST_BYTES } from "../src/oci";
import {
  MISSING_DIGEST,
  OCI_MANIFEST,
  basic,
  bytes,
  call,
  env,
  errorCode,
  hexOf,
  pointTag,
  putBlob,
  putImage,
  setTag,
} from "./helpers";

afterEach(async () => {
  vi.restoreAllMocks();
  await reset();
});

const MISSING = MISSING_DIGEST;

describe("GET /v2/", () => {
  it("challenges clients that sent no credentials", async () => {
    const res = await call("GET", "/v2/");
    expect(res.status).toBe(401);
    expect(res.headers.get("WWW-Authenticate")).toBe('Basic realm="Nyra OS updates"');
    expect(res.headers.get("Docker-Distribution-API-Version")).toBe("registry/2.0");
    expect(await errorCode(res)).toBe("UNAUTHORIZED");
  });

  it("accepts empty credentials (anonymous) and an install code", async () => {
    for (const auth of ["Basic Og==", basic("nyra", "code-1")]) {
      const res = await call("GET", "/v2/", { Authorization: auth });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("{}");
    }
  });

  it("answers /v2 without the slash and HEAD without a body", async () => {
    expect((await call("GET", "/v2", { Authorization: "Basic Og==" })).status).toBe(200);
    const head = await call("HEAD", "/v2/", { Authorization: "Basic Og==" });
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
  });
});

describe("read-only", () => {
  it.each([
    ["POST", "/v2/nyra-base/blobs/uploads/"],
    ["PUT", "/v2/nyra-base/manifests/stable"],
    ["PATCH", "/v2/nyra-base/blobs/uploads/x"],
    ["DELETE", "/v2/nyra-base/manifests/stable"],
    ["DELETE", `/v2/nyra-base/blobs/${MISSING}`],
  ])("refuses %s %s", async (method, path) => {
    const res = await call(method, path);
    expect(res.status).toBe(405);
    expect(res.headers.get("Allow")).toBe("GET, HEAD");
    expect(await errorCode(res)).toBe("UNSUPPORTED");
  });

  it("does not change storage on refused writes", async () => {
    await call("PUT", "/v2/nyra-base/manifests/stable");
    expect((await env.TAGS.list()).keys).toHaveLength(0);
    expect((await env.IMAGES.list()).objects).toHaveLength(0);
  });

  it.each(["/", "/v2/_catalog", `/v2/nyra-base/referrers/${MISSING}`, "/v2/nyra-base/blobs/uploads/x/y"])(
    "returns 404 for %s",
    async (path) => {
      expect((await call("GET", path)).status).toBe(404);
    },
  );
});

describe("repository names", () => {
  it("rejects invalid names", async () => {
    const res = await call("GET", "/v2/Nyra/manifests/stable");
    expect(res.status).toBe(400);
    expect(await errorCode(res)).toBe("NAME_INVALID");
  });

  it("returns NAME_UNKNOWN for repositories not served", async () => {
    const res = await call("GET", "/v2/library/busybox/manifests/latest");
    expect(res.status).toBe(404);
    expect(await errorCode(res)).toBe("NAME_UNKNOWN");
  });

  it("serves nyra-base and nyra-base-arm64, each with its own tags, and no third repository", async () => {
    const { manifest } = await putImage();
    await pointTag("nyra-base-arm64", "stable", manifest);
    const arm = await call("GET", "/v2/nyra-base-arm64/manifests/stable");
    expect(arm.status).toBe(200);
    expect(arm.headers.get("Docker-Content-Digest")).toBe(manifest);
    expect((await call("GET", "/v2/nyra-base/manifests/stable")).status).toBe(404);
    for (const third of ["nyra-base-x86", "nyra"]) {
      const res = await call("GET", `/v2/${third}/manifests/stable`);
      expect(res.status).toBe(404);
      expect(await errorCode(res)).toBe("NAME_UNKNOWN");
    }
  });

  it("serves nested names listed in REPOSITORIES", async () => {
    const { manifest } = await putImage();
    await pointTag("nyra-base/desktop", "stable", manifest);
    const res = await call("GET", "/v2/nyra-base/desktop/manifests/stable", {}, { REPOSITORIES: "nyra-base, nyra-base/desktop" });
    expect(res.status).toBe(200);
    expect(res.headers.get("Docker-Content-Digest")).toBe(manifest);
  });
});

describe("manifests", () => {
  it("serves a manifest by tag", async () => {
    const { manifest, manifestBytes } = await putImage();
    await pointTag("nyra-base", "stable", manifest);
    const res = await call("GET", "/v2/nyra-base/manifests/stable");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe(OCI_MANIFEST);
    expect(res.headers.get("Docker-Content-Digest")).toBe(manifest);
    expect(res.headers.get("Content-Length")).toBe(String(manifestBytes.byteLength));
    expect(res.headers.get("Cache-Control")).toBe("private, no-store");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(manifestBytes);
  });

  it("answers HEAD by tag with the same headers and no body", async () => {
    const { manifest, manifestBytes } = await putImage();
    await pointTag("nyra-base", "stable", manifest);
    const res = await call("HEAD", "/v2/nyra-base/manifests/stable");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe(OCI_MANIFEST);
    expect(res.headers.get("Docker-Content-Digest")).toBe(manifest);
    expect(res.headers.get("Content-Length")).toBe(String(manifestBytes.byteLength));
    expect(await res.text()).toBe("");
  });

  it("serves a manifest by digest (GET and HEAD), cacheable forever", async () => {
    const { manifest, manifestBytes } = await putImage();
    const res = await call("GET", `/v2/nyra-base/manifests/${manifest}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Docker-Content-Digest")).toBe(manifest);
    expect(res.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(manifestBytes);
    const head = await call("HEAD", `/v2/nyra-base/manifests/${manifest}`);
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
  });

  it.each([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
  ])("serves %s with its own content type", async (mediaType) => {
    const digest = await putBlob(bytes(JSON.stringify({ schemaVersion: 2, mediaType, manifests: [] })));
    await pointTag("nyra-base", "beta", digest);
    const res = await call("GET", "/v2/nyra-base/manifests/beta");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe(mediaType);
  });

  it("follows the channel when the tag moves", async () => {
    const v1 = await putImage();
    const v2 = await putImage();
    await pointTag("nyra-base", "stable", v1.manifest);
    expect((await call("HEAD", "/v2/nyra-base/manifests/stable")).headers.get("Docker-Content-Digest")).toBe(v1.manifest);
    await pointTag("nyra-base", "stable", v2.manifest);
    expect((await call("HEAD", "/v2/nyra-base/manifests/stable")).headers.get("Docker-Content-Digest")).toBe(v2.manifest);
  });

  it("returns MANIFEST_UNKNOWN for unknown tags and digests", async () => {
    for (const ref of ["nope", MISSING]) {
      const res = await call("GET", `/v2/nyra-base/manifests/${ref}`);
      expect(res.status).toBe(404);
      expect(await errorCode(res)).toBe("MANIFEST_UNKNOWN");
      const head = await call("HEAD", `/v2/nyra-base/manifests/${ref}`);
      expect(head.status).toBe(404);
      expect(await head.text()).toBe("");
    }
  });

  it("does not serve tags of another repository", async () => {
    const { manifest } = await putImage();
    await pointTag("nyra-base", "stable", manifest);
    const res = await call("GET", "/v2/other/manifests/stable", {}, { REPOSITORIES: "nyra-base,other" });
    expect(res.status).toBe(404);
  });

  it("logs and returns 404 when a tag points to a missing manifest", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    await pointTag("nyra-base", "stable", MISSING);
    const res = await call("GET", "/v2/nyra-base/manifests/stable");
    expect(res.status).toBe(404);
    expect(error).toHaveBeenCalledOnce();
  });

  it("refuses to serve a stored manifest whose bytes do not match its digest", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { manifest } = await putImage();
    const other = bytes(JSON.stringify({ schemaVersion: 2, mediaType: OCI_MANIFEST, config: {}, layers: [] }));
    await env.IMAGES.put(`blobs/sha256/${hexOf(manifest)}`, other); // corrupted in storage
    await pointTag("nyra-base", "stable", manifest);
    for (const ref of [manifest, "stable"]) {
      const res = await call("GET", `/v2/nyra-base/manifests/${ref}`);
      expect(res.status).toBe(500);
      expect(await res.text()).not.toContain("schemaVersion");
    }
  });

  it("does not serve layers or configs as manifests", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { layer, config } = await putImage();
    const unknownType = await putBlob(bytes(JSON.stringify({ schemaVersion: 2, mediaType: "text/plain" })));
    const big = await putBlob(new Uint8Array(MAX_MANIFEST_BYTES + 1));
    for (const digest of [layer, config, unknownType, big]) {
      expect((await call("GET", `/v2/nyra-base/manifests/${digest}`)).status).toBe(404);
    }
    await pointTag("nyra-base", "stable", layer);
    expect((await call("GET", "/v2/nyra-base/manifests/stable")).status).toBe(404);
  });

  it.each([
    ["sha256:abc", "DIGEST_INVALID"],
    ["sha256:" + "A".repeat(64), "DIGEST_INVALID"],
    ["sha512:" + "a".repeat(128), "DIGEST_INVALID"],
    ["md5:xyz", "DIGEST_INVALID"],
    ["-bad", "TAG_INVALID"],
    ["t".repeat(129), "TAG_INVALID"],
  ])("rejects reference %s with %s", async (ref, code) => {
    const res = await call("GET", `/v2/nyra-base/manifests/${ref}`);
    expect(res.status).toBe(400);
    expect(await errorCode(res)).toBe(code);
  });

  it.each([["not json"], [JSON.stringify({ digest: "sha256:abc" })], [JSON.stringify({})]])(
    "returns 500 for a corrupt tag pointer %s",
    async (value) => {
      vi.spyOn(console, "error").mockImplementation(() => {});
      await setTag("nyra-base", "stable", value);
      const res = await call("GET", "/v2/nyra-base/manifests/stable");
      expect(res.status).toBe(500);
      expect(await errorCode(res)).toBe("UNKNOWN");
    },
  );
});

describe("blobs", () => {
  it("redirects GET to the public R2 domain", async () => {
    const { layer } = await putImage();
    const res = await call("GET", `/v2/nyra-base/blobs/${layer}`);
    expect(res.status).toBe(307);
    expect(res.headers.get("Location")).toBe(`https://blobs.nyraos.com/blobs/sha256/${hexOf(layer)}`);
    expect(res.headers.get("Docker-Content-Digest")).toBe(layer);
    expect(await res.text()).toBe("");
  });

  it("redirects range requests too (the client re-sends Range to the R2 domain)", async () => {
    const { layer } = await putImage();
    const res = await call("GET", `/v2/nyra-base/blobs/${layer}`, { Range: "bytes=0-9" });
    expect(res.status).toBe(307);
    expect(res.headers.get("Location")).toBe(`https://blobs.nyraos.com/blobs/sha256/${hexOf(layer)}`);
  });

  it("answers HEAD itself with size and digest", async () => {
    const data = bytes("some layer bytes");
    const digest = await putBlob(data);
    const res = await call("HEAD", `/v2/nyra-base/blobs/${digest}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Length")).toBe(String(data.byteLength));
    expect(res.headers.get("Docker-Content-Digest")).toBe(digest);
    expect(await res.text()).toBe("");
  });

  it("returns BLOB_UNKNOWN for missing blobs", async () => {
    const res = await call("GET", `/v2/nyra-base/blobs/${MISSING}`);
    expect(res.status).toBe(404);
    expect(await errorCode(res)).toBe("BLOB_UNKNOWN");
    expect((await call("HEAD", `/v2/nyra-base/blobs/${MISSING}`)).status).toBe(404);
  });

  it.each(["sha256:abc", "latest", "sha512:" + "a".repeat(128), "sha256:" + "G".repeat(64)])(
    "rejects bad digest %s",
    async (digest) => {
      const res = await call("GET", `/v2/nyra-base/blobs/${digest}`);
      expect(res.status).toBe(400);
      expect(await errorCode(res)).toBe("DIGEST_INVALID");
    },
  );
});

describe("tags/list", () => {
  it("lists the tags of one repository, sorted", async () => {
    const { manifest } = await putImage();
    for (const tag of ["stable", "2026.10.2", "beta", "2026.10.3"]) await pointTag("nyra-base", tag, manifest);
    await pointTag("nyra-base/desktop", "dev", manifest); // a different repository, same KV prefix
    const res = await call("GET", "/v2/nyra-base/tags/list");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ name: "nyra-base", tags: ["2026.10.2", "2026.10.3", "beta", "stable"] });
  });

  it("returns an empty list for a repository without tags", async () => {
    expect(await (await call("GET", "/v2/nyra-base/tags/list")).json()).toEqual({ name: "nyra-base", tags: [] });
  });
});

describe("unexpected errors", () => {
  it("returns 500 and logs no request data when storage fails", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const broken = { ...env.TAGS, get: () => Promise.reject(new Error("KV down")) } as unknown as KVNamespace;
    const res = await call("GET", "/v2/nyra-base/manifests/stable", { Authorization: basic("nyra", "code") }, { TAGS: broken });
    expect(res.status).toBe(500);
    expect(error).toHaveBeenCalledWith("registry: internal error:", "KV down");
  });
});
