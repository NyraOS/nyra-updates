import { reset } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { parseInstallCode, parseRunningDigest, rolloutGroup } from "../src/auth";
import { MISSING_DIGEST, basic, call, env, pointTag, putImage, setTag } from "./helpers";

afterEach(async () => {
  vi.restoreAllMocks();
  await reset();
});

describe("parseInstallCode", () => {
  it.each([
    [basic("nyra", "abc123"), "abc123"],
    [basic("", "abc123"), "abc123"],
    [basic("nyra", "a:b:c"), "a:b:c"], // only the first colon separates user and password
    [basic("nyra", "cod-ăîșț"), "cod-ăîșț"],
    ["basic " + btoa("nyra:abc"), "abc"], // the scheme is case-insensitive
  ])("reads the password of %s", (header, code) => {
    expect(parseInstallCode(header)).toBe(code);
  });

  it.each([
    ["no header", null],
    ["empty credentials", "Basic Og=="],
    ["empty password", basic("nyra", "")],
    ["no colon", "Basic " + btoa("nyra")],
    ["bad base64", "Basic !!!"],
    ["another scheme", "Bearer abc"],
    ["too long", basic("nyra", "x".repeat(257))],
  ])("treats %s as anonymous", (_label, header) => {
    expect(parseInstallCode(header)).toBeNull();
  });
});

describe("parseRunningDigest", () => {
  const hex = "ab".repeat(32);
  it("reads the Basic user sha256-<hex> as the digest the client runs", () => {
    expect(parseRunningDigest(basic(`sha256-${hex}`, "code"))).toBe(`sha256:${hex}`);
    expect(parseRunningDigest(basic(`sha256-${hex}`, ""))).toBe(`sha256:${hex}`); // works without a code
  });

  it.each([
    ["no header", null],
    ["another user", basic("nyra", "code")],
    ["upper-case hex", basic(`sha256-${hex.toUpperCase()}`, "code")],
    ["short hex", basic("sha256-abc", "code")],
    ["another algorithm", basic(`sha512-${hex}${hex}`, "code")],
    ["trailing characters", basic(`sha256-${hex}00`, "code")], // pins the $ anchor
    ["leading characters", basic(`xsha256-${hex}`, "code")], // pins the ^ anchor
    ["a newline after the hex", basic(`sha256-${hex}\n`, "code")],
    ["another scheme", `Bearer sha256-${hex}`],
  ])("ignores %s", (_label, header) => {
    expect(parseRunningDigest(header)).toBeNull();
  });
});

describe("rolloutGroup", () => {
  it("is null without a code or without a salt", async () => {
    expect(await rolloutGroup(null, "salt")).toBeNull();
    expect(await rolloutGroup("abc", undefined)).toBeNull();
    expect(await rolloutGroup("abc", "")).toBeNull();
  });

  it("is HMAC-SHA256(salt, code) mod 100 (first 32 bits)", async () => {
    // Reference computed outside the Worker: `printf %s abc | openssl dgst -sha256 -hmac test-salt`
    // starts with 8721fe4a, and 0x8721fe4a mod 100 = 46.
    expect(await rolloutGroup("abc", "test-salt")).toBe(46);
  });

  it("is stable for a code and changes with the salt", async () => {
    const codes = Array.from({ length: 200 }, (_, i) => `install-${i}`);
    const a = await Promise.all(codes.map((c) => rolloutGroup(c, "salt-a")));
    const again = await Promise.all(codes.map((c) => rolloutGroup(c, "salt-a")));
    const b = await Promise.all(codes.map((c) => rolloutGroup(c, "salt-b")));
    expect(again).toEqual(a);
    expect(b.filter((g, i) => g === a[i]).length).toBeLessThan(20); // ~2 expected by chance
  });

  it("spreads codes evenly over 0-99", async () => {
    const counts = new Array<number>(100).fill(0);
    for (let i = 0; i < 20000; i++) {
      const g = await rolloutGroup(`code-${i}`, "test-salt"); // fixed codes: the result is deterministic
      expect(Number.isInteger(g) && g! >= 0 && g! <= 99).toBe(true);
      counts[g!]!++;
    }
    // 200 expected per group, standard deviation ~14: [130, 270] is 5 standard deviations.
    expect(Math.min(...counts)).toBeGreaterThanOrEqual(130);
    expect(Math.max(...counts)).toBeLessThanOrEqual(270);
    // 5% of clients in a 5% rollout, give or take.
    const first5 = counts.slice(0, 5).reduce((x, y) => x + y, 0) / 20000;
    expect(first5).toBeGreaterThan(0.04);
    expect(first5).toBeLessThan(0.06);
  });
});

describe("tags without a rollout", () => {
  it("serve the same digest with and without an install code", async () => {
    const { manifest } = await putImage();
    await pointTag("nyra-base", "stable", manifest);
    const variants: Record<string, string>[] = [{}, { Authorization: "Basic Og==" }, { Authorization: basic("nyra", "abc") }];
    for (const auth of variants) {
      const res = await call("GET", "/v2/nyra-base/manifests/stable", auth);
      expect(res.headers.get("Docker-Content-Digest")).toBe(manifest);
    }
  });
});

describe("the install code is never logged, stored or echoed", () => {
  it("leaves no trace on success and error paths", async () => {
    const CODE = "SECRET-install-code-7f3a";
    const header = basic("nyra", CODE);
    const logged: unknown[][] = [];
    for (const level of ["log", "info", "warn", "error", "debug"] as const) {
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => void logged.push(args));
    }

    const { manifest, layer } = await putImage();
    const older = await putImage();
    await pointTag("nyra-base", "stable", manifest);
    // A channel in a staged rollout, so the group is really computed from the code.
    await setTag("nyra-base", "beta", JSON.stringify({ digest: manifest, previous: older.manifest, percent: 50 }));
    await setTag("nyra-base", "broken", JSON.stringify({ digest: manifest, previous: older.manifest, percent: 500 })); // logs
    await pointTag("nyra-base", "dangling", MISSING_DIGEST); // logs an error
    await setTag("nyra-base", "corrupt", "not json"); // logs an error
    const tagsBefore = (await env.TAGS.list()).keys.map((k) => k.name);
    const objectsBefore = (await env.IMAGES.list()).objects.map((o) => o.key);

    const responses: Response[] = [];
    for (const [method, path] of [
      ["GET", "/v2/"],
      ["GET", "/v2/nyra-base/manifests/stable"],
      ["HEAD", "/v2/nyra-base/manifests/stable"],
      ["GET", "/v2/nyra-base/manifests/beta"],
      ["HEAD", "/v2/nyra-base/manifests/beta"],
      ["GET", "/v2/nyra-base/manifests/broken"],
      ["GET", "/v2/nyra-base/manifests/dangling"],
      ["GET", "/v2/nyra-base/manifests/corrupt"],
      ["GET", "/v2/nyra-base/manifests/-bad"],
      ["GET", `/v2/nyra-base/blobs/${layer}`],
      ["GET", "/v2/nyra-base/tags/list"],
      ["PUT", "/v2/nyra-base/manifests/stable"],
    ]) {
      responses.push(await call(method!, path!, { Authorization: header }));
    }
    const broken = { ...env.IMAGES, get: () => Promise.reject(new Error("R2 down")) } as unknown as R2Bucket;
    responses.push(await call("GET", "/v2/nyra-base/manifests/stable", { Authorization: header }, { IMAGES: broken }));
    // The same code with a running digest in the user field.
    const withUser = basic("sha256-" + "a".repeat(64), CODE);
    responses.push(await call("GET", "/v2/nyra-base/manifests/beta", { Authorization: withUser }));

    expect(logged.length).toBeGreaterThan(0); // the error paths above did log something
    const encoded = header.slice("Basic ".length);
    const encodedWithUser = withUser.slice("Basic ".length);
    const allLogs = JSON.stringify(logged);
    expect(allLogs).not.toContain(CODE);
    expect(allLogs).not.toContain(encoded);
    expect(allLogs).not.toContain(encodedWithUser);
    for (const res of responses) {
      const text = [...res.headers].join("\n") + (await res.text());
      expect(text).not.toContain(CODE);
      expect(text).not.toContain(encoded);
      expect(text).not.toContain(encodedWithUser);
    }
    expect((await env.TAGS.list()).keys.map((k) => k.name)).toEqual(tagsBefore);
    expect((await env.IMAGES.list()).objects.map((o) => o.key)).toEqual(objectsBefore);
  });
});
