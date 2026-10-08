// @ts-check
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import sitemap from "@astrojs/sitemap";
import tailwindcss from "@tailwindcss/vite";

// Primary website, served at the domain root.
const base = process.env.SITE_BASE ?? "/";
const site = process.env.SITE_URL ?? "https://duneservertool.com";

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
  integrations: [
    mdx(),
    sitemap({
      // The 404 page shouldn't be indexable.
      filter: (page) => !page.endsWith("/404"),
    }),
  ],
  vite: {
    plugins: [tailwindcss()],
  },
});
