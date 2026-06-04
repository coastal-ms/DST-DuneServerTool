// @ts-check
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import tailwindcss from "@tailwindcss/vite";

// GitHub Pages project site — served at /DST-DuneServerTool/.
// If a custom domain is configured later, set SITE_BASE=/ in CI env to override.
const base = process.env.SITE_BASE ?? "/DST-DuneServerTool/";
const site = process.env.SITE_URL ?? "https://coastal-ms.github.io";

export default defineConfig({
  site,
  base,
  trailingSlash: "ignore",
  // Pinned to 127.0.0.1:4321 to stay clear of common dev ports (8080, 3000, 5173).
  // Override with `npm run dev -- --port 1234 --host 0.0.0.0` if needed.
  server: {
    host: "127.0.0.1",
    port: 4321,
  },
  integrations: [mdx()],
  vite: {
    plugins: [tailwindcss()],
  },
});
