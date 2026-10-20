import { reset } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import devWorker, { parseRange } from "../dev/entry";
import { ORIGIN, bytes, env, hexOf, putBlob } from "./helpers";

afterEach(async () => {
  vi.restoreAllMocks();
  await reset();
});

const localEnv = { ...env, BLOB_BASE_URL: "/_dev" };
const get = (path: string, headers: Record<string, string> = {}, method = "GET") =>
  devWorker.fetch(new Request(ORIGIN + path, { method, headers }), localEnv);

describe("parseRange", () => {
  it.each([
    ["bytes=0-9", { offset: 0, length: 10 }],
    ["bytes=5-", { offset: 5, length: 95 }],
    ["bytes=-10", { offset: 90, length: 10 }],
    ["bytes=90-500", { offset: 90, length: 10 }],
    ["bytes=-500", { offset: 0, length: 100 }],
  ])("%s of 100 bytes", (header, expected) => {
    expect(parseRange(header, 100)).toEqual(expected);
  });

  it.each([null, "bytes=0-1,5-6", "items=0-1", "bytes=-", "bytes=9-3"])("ignores %s", (header) => {
    expect(parseRange(header, 100)).toBeNull();
  });

  it.each(["bytes=100-", "bytes=-0"])("rejects %s as unsatisfiable", (header) => {
    expect(parseRange(header, 100)).toBe("invalid");
  });
});

describe("local blob origin", () => {
  it("serves a pull end to end: registry redirect, then the bytes", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    const data = bytes("0123456789abcdef");
    const digest = await putBlob(data);
    const redirect = await get(`/v2/nyra-base/blobs/${digest}`);
    expect(redirect.status).toBe(307);
    const location = redirect.headers.get("Location")!;
    expect(location).toBe(`/_dev/blobs/sha256/${hexOf(digest)}`);

    const full = await get(location);
    expect(full.status).toBe(200);
    expect(await full.text()).toBe("0123456789abcdef");

    const part = await get(location, { Range: "bytes=4-7" });
    expect(part.status).toBe(206);
    expect(part.headers.get("Content-Range")).toBe("bytes 4-7/16");
    expect(await part.text()).toBe("4567");

    const bad = await get(location, { Range: "bytes=16-" });
    expect(bad.status).toBe(416);
    expect(bad.headers.get("Content-Range")).toBe("bytes */16");

    const head = await get(location, {}, "HEAD");
    expect(head.headers.get("Content-Length")).toBe("16");
  });

  it("returns 404 for missing blobs", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {});
    expect((await get(`/_dev/blobs/sha256/${"0".repeat(64)}`)).status).toBe(404);
  });
});
