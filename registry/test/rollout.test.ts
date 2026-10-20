import { reset } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { chooseDigest, type Env } from "../src/index";
import { ORIGIN, basic, call, codeInGroup, env, errorCode, putImage, runningUser, setTag } from "./helpers";

afterEach(async () => {
  vi.restoreAllMocks();
  await reset();
});

const OLD = "sha256:" + "1".repeat(64);
const NEW = "sha256:" + "2".repeat(64);
const OTHER = "sha256:" + "3".repeat(64);

describe("chooseDigest", () => {
  it.each([
    // [label, tag, group, running, expected]
    ["a version tag", { digest: NEW }, 7, null, NEW],
    ["a version tag, no code", { digest: NEW }, null, null, NEW],
    ["group below the percent", { digest: NEW, previous: OLD, percent: 25 }, 24, null, NEW],
    ["group at the percent", { digest: NEW, previous: OLD, percent: 25 }, 25, null, OLD],
    ["0%", { digest: NEW, previous: OLD, percent: 0 }, 0, null, OLD],
    ["100%, last group", { digest: NEW, previous: OLD, percent: 100 }, 99, null, NEW],
    ["no code during a rollout", { digest: NEW, previous: OLD, percent: 99 }, null, null, OLD],
    ["no code at 100%", { digest: NEW, previous: OLD, percent: 100 }, null, null, NEW],
    ["previous without percent (= 100%)", { digest: NEW, previous: OLD }, null, null, NEW],
    ["already on the new version, outside the percent", { digest: NEW, previous: OLD, percent: 5 }, 50, NEW, NEW],
    ["halted, inside the percent", { digest: NEW, previous: OLD, percent: 50, halted: true }, 3, null, OLD],
    ["halted, at 100%", { digest: NEW, previous: OLD, percent: 100, halted: true }, 3, null, OLD],
    ["halted, running the old version", { digest: NEW, previous: OLD, percent: 50, halted: true }, 3, OLD, OLD],
    ["halted, already on the new version", { digest: NEW, previous: OLD, percent: 50, halted: true }, 80, NEW, NEW],
    ["halted, running something else", { digest: NEW, previous: OLD, percent: 50, halted: true }, 3, OTHER, OLD],
    ["reverted, running the bad version", { digest: OLD }, 3, NEW, OLD],
  ])("%s", (_label, tag, group, running, expected) => {
    expect(chooseDigest(tag, group, running)).toBe(expected);
  });
});

describe("staged rollout through the Worker", () => {
  let oldImage: string, newImage: string, below: string, at: string;
  const PERCENT = 30;

  beforeEach(async () => {
    oldImage = (await putImage()).manifest;
    newImage = (await putImage()).manifest;
    below = await codeInGroup(PERCENT - 1);
    at = await codeInGroup(PERCENT);
  });

  const channel = (state: Record<string, unknown>) => setTag("nyra-base", "stable", JSON.stringify(state));
  const digestFor = async (authorization?: string, method = "GET") => {
    const res = await call(method, "/v2/nyra-base/manifests/stable", authorization ? { Authorization: authorization } : {});
    expect(res.status).toBe(200);
    return res.headers.get("Docker-Content-Digest");
  };

  it("serves the new version only to groups below the percent", async () => {
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT });
    expect(await digestFor(basic("nyra", below))).toBe(newImage);
    expect(await digestFor(basic("nyra", at))).toBe(oldImage);
    expect(await digestFor(basic("nyra", below), "HEAD")).toBe(newImage);
    expect(await digestFor(basic("nyra", at), "HEAD")).toBe(oldImage);
  });

  it("raising the percent brings the next groups in, and nobody falls out", async () => {
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT });
    expect(await digestFor(basic("nyra", at))).toBe(oldImage);
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT + 1 });
    expect(await digestFor(basic("nyra", at))).toBe(newImage);
    expect(await digestFor(basic("nyra", below))).toBe(newImage);
  });

  it("gives clients without a code the previous version until 100%", async () => {
    const anonymous = [undefined, "Basic Og==", basic("nyra", ""), "Bearer x", "Basic !!!"];
    await channel({ digest: newImage, previous: oldImage, percent: 99 });
    for (const auth of anonymous) expect(await digestFor(auth)).toBe(oldImage);
    await channel({ digest: newImage, previous: oldImage, percent: 100 });
    for (const auth of anonymous) expect(await digestFor(auth)).toBe(newImage);
  });

  it("treats every client as anonymous when the salt secret is missing", async () => {
    await channel({ digest: newImage, previous: oldImage, percent: 99 });
    const res = await call("GET", "/v2/nyra-base/manifests/stable", { Authorization: basic("nyra", below) }, { ROLLOUT_SALT: undefined });
    expect(res.headers.get("Docker-Content-Digest")).toBe(oldImage);
  });

  it("stop: nobody new gets the new version, clients already on it keep it", async () => {
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT, halted: true });
    expect(await digestFor(basic("nyra", below))).toBe(oldImage); // in the rollout, not updated yet
    expect(await digestFor(basic("nyra", at))).toBe(oldImage);
    expect(await digestFor(undefined)).toBe(oldImage);
    expect(await digestFor(basic(runningUser(oldImage), below))).toBe(oldImage);
    expect(await digestFor(basic(runningUser(newImage), below))).toBe(newImage); // already updated
    expect(await digestFor(basic(runningUser(newImage), ""))).toBe(newImage); // even without a code
  });

  it("revert: everybody gets the last good version, also clients on the bad one", async () => {
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT });
    expect(await digestFor(basic(runningUser(oldImage), below))).toBe(newImage);
    await channel({ digest: oldImage }); // what `rollout.sh revert` writes
    for (const auth of [basic("nyra", below), basic("nyra", at), basic(runningUser(newImage), below), undefined]) {
      expect(await digestFor(auth)).toBe(oldImage);
    }
  });

  it("never lets a shared cache store an answer by tag", async () => {
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT });
    for (const method of ["GET", "HEAD"]) {
      for (const auth of [{}, { Authorization: basic("nyra", below) }] as Record<string, string>[]) {
        const res = await call(method, "/v2/nyra-base/manifests/stable", auth);
        expect(res.headers.get("Cache-Control")).toBe("private, no-store");
      }
    }
    // By digest the answer is the same for everybody, forever.
    const res = await call("GET", `/v2/nyra-base/manifests/${newImage}`, { Authorization: basic("nyra", below) });
    expect(res.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
  });

  it("never lets a shared cache store an error by tag either", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    // Group-dependent error: the new digest is missing, so only clients in the rollout get a 404.
    await channel({ digest: "sha256:" + "0".repeat(64), previous: oldImage, percent: PERCENT });
    await setTag("nyra-base", "corrupt", "null");
    for (const method of ["GET", "HEAD"]) {
      for (const [path, status] of [
        ["/v2/nyra-base/manifests/stable", 404], // in the rollout, new digest missing
        ["/v2/nyra-base/manifests/nope", 404], // unknown tag
        ["/v2/nyra-base/manifests/corrupt", 500], // corrupt state
        ["/v2/nyra-base/manifests/-bad", 400], // invalid tag
      ] as const) {
        const res = await call(method, path, { Authorization: basic("nyra", below) });
        expect(res.status).toBe(status);
        expect(res.headers.get("Cache-Control")).toBe("private, no-store");
      }
    }
  });

  it("computes the group only for tags, not for manifests by digest", async () => {
    // The salt is read exactly where the group is computed.
    let saltReads = 0;
    const counting = Object.defineProperty({ ...env }, "ROLLOUT_SALT", {
      get: () => (saltReads++, "test-salt"),
    }) as Env;
    const get = (path: string) =>
      worker.fetch(new Request(ORIGIN + path, { headers: { Authorization: basic("nyra", below) } }), counting);
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT });
    const byDigest = await get(`/v2/nyra-base/manifests/${newImage}`);
    expect(byDigest.status).toBe(200);
    expect(saltReads).toBe(0);
    const byTag = await get("/v2/nyra-base/manifests/stable");
    expect(byTag.headers.get("Docker-Content-Digest")).toBe(newImage);
    expect(saltReads).toBe(1);
  });

  it.each([
    ["the JSON value null", null],
    ["an array", []],
    ["a string", "sha256:" + "1".repeat(64)],
  ])("returns 500 for a tag whose value is %s", async (_label, value) => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    await setTag("nyra-base", "stable", JSON.stringify(value));
    const res = await call("GET", "/v2/nyra-base/manifests/stable");
    expect(res.status).toBe(500);
    expect(await errorCode(res)).toBe("UNKNOWN");
  });

  it.each([
    ["percent above 100", { percent: 101 }],
    ["negative percent", { percent: -1 }],
    ["fractional percent", { percent: 2.5 }],
    ["percent as text", { percent: "50" }],
    ["invalid previous", { previous: "sha256:abc" }],
    ["halted as text", { halted: "yes" }],
    ["previous null", { previous: null }],
  ])("returns 500 for a corrupt rollout state: %s", async (_label, broken) => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    await channel({ digest: newImage, previous: oldImage, percent: PERCENT, ...broken });
    const res = await call("GET", "/v2/nyra-base/manifests/stable", { Authorization: basic("nyra", below) });
    expect(res.status).toBe(500);
    expect(await errorCode(res)).toBe("UNKNOWN");
  });
});
