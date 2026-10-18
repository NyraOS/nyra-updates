// The registry is public: anyone may pull. A Nyra install sends HTTP Basic credentials:
//   password = its anonymous install code, turned into a rollout group 0-99;
//   user     = "sha256-<hex>", the manifest digest it runs (optional), so a halted rollout can
//              keep serving the new version to clients that already took it.
// The code is never logged, stored or sent back; it does not leave this file.

/** User and password of `Authorization: Basic base64(user:password)`, or null. */
function parseBasic(header: string | null): { user: string; password: string } | null {
  const m = /^Basic +([A-Za-z0-9+/]+={0,2}) *$/i.exec(header ?? "");
  if (!m) return null;
  let decoded: string;
  try {
    const raw = Uint8Array.from(atob(m[1]!), (c) => c.charCodeAt(0));
    decoded = new TextDecoder().decode(raw);
  } catch {
    return null;
  }
  const colon = decoded.indexOf(":");
  if (colon < 0) return null;
  return { user: decoded.slice(0, colon), password: decoded.slice(colon + 1) };
}

/**
 * The install code (the Basic password), or null for anything else: no header, another scheme,
 * bad base64, empty or over-long password.
 */
export function parseInstallCode(header: string | null): string | null {
  const code = parseBasic(header)?.password ?? "";
  return code.length > 0 && code.length <= 256 ? code : null;
}

/** The digest the client says it runs (Basic user "sha256-<hex>"), or null. */
export function parseRunningDigest(header: string | null): string | null {
  const m = /^sha256-([a-f0-9]{64})$/.exec(parseBasic(header)?.user ?? "");
  return m ? `sha256:${m[1]}` : null;
}

/**
 * Rollout group 0-99: HMAC-SHA256(salt, code) mod 100. Null without a code or without a salt.
 * The salt is a Worker secret: without it the group of a code cannot be computed, and the group
 * reveals nothing about the code.
 */
export async function rolloutGroup(code: string | null, salt: string | undefined): Promise<number | null> {
  if (code === null || !salt) return null;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(salt), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(code));
  // First 32 bits mod 100: the bias (2^32 mod 100 = 96 values) is ~2e-8, irrelevant here.
  return new DataView(mac).getUint32(0) % 100;
}
