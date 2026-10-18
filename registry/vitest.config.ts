import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Tests run inside workerd with local R2 and KV, using the production configuration of
// wrangler.toml (BLOB_BASE_URL = https://blobs.nyraos.com) plus a test value for the secret salt.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: { bindings: { ROLLOUT_SALT: "test-salt" } },
    }),
  ],
});
