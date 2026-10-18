import { reset } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { basic, call, env, errorCode, runningUser } from "./helpers";

afterEach(async () => {
  await reset();
});

// What CI stores: a DSSE envelope. The Worker never looks inside (machines verify it).
const SHEET = JSON.stringify({
  payloadType: "application/vnd.nyra.channel-sheet.v1+json",
  payload: btoa('{"schema":1,"repository":"nyra","channel":"stable"}'),
  signatures: [{ keyid: "", sig: "c2lnbmF0dXJl" }],
});

const putSheet = (repository: string, channel: string, value: string) => env.TAGS.put(`sheet/${repository}/${channel}`, value);

describe("GET /channels/<repo>/<channel>", () => {
  it("serves the stored sheet byte for byte, cacheable", async () => {
    await putSheet("nyra", "stable", SHEET);
    const res = await call("GET", "/channels/nyra/stable");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    expect(res.headers.get("Cache-Control")).toBe("public, max-age=60");
    expect(await res.text()).toBe(SHEET);
  });

  it("is the same for everybody: credentials change nothing", async () => {
    await putSheet("nyra", "stable", SHEET);
    const auths = [undefined, "Basic Og==", basic("nyra", "code-1"), basic(runningUser("sha256:" + "2".repeat(64)), "code-2")];
    for (const auth of auths) {
      const res = await call("GET", "/channels/nyra/stable", auth ? { Authorization: auth } : {});
      expect(res.status).toBe(200);
      expect(res.headers.get("Cache-Control")).toBe("public, max-age=60");
      expect(await res.text()).toBe(SHEET);
    }
  });

  it("answers HEAD without a body", async () => {
    await putSheet("nyra", "stable", SHEET);
    const res = await call("HEAD", "/channels/nyra/stable");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("");
  });

  it("returns 404 for a channel without a sheet and for unknown repositories", async () => {
    await putSheet("other", "stable", SHEET);
    let res = await call("GET", "/channels/nyra/beta");
    expect(res.status).toBe(404);
    expect(await errorCode(res)).toBe("SHEET_UNKNOWN");
    res = await call("GET", "/channels/other/stable");
    expect(res.status).toBe(404);
    expect(await errorCode(res)).toBe("NAME_UNKNOWN");
  });

  it("refuses invalid names and writes", async () => {
    let res = await call("GET", "/channels/Nyra/stable");
    expect(res.status).toBe(400);
    res = await call("GET", "/channels/nyra/.stable");
    expect(res.status).toBe(400);
    res = await call("PUT", "/channels/nyra/stable");
    expect(res.status).toBe(405);
    expect(res.headers.get("Allow")).toBe("GET, HEAD");
  });

  it("does not serve the sheet under other paths", async () => {
    await putSheet("nyra", "stable", SHEET);
    for (const path of ["/channels/nyra", "/channels/nyra/stable/", "/channel/nyra/stable"]) {
      expect((await call("GET", path)).status).toBe(404);
    }
  });
});
