import { cp, mkdir, rm } from "node:fs/promises";

const files = [
  "404.html",
  "_headers",
  "assets",
  "docs.html",
  "index.html",
  "privacy.html",
  "robots.txt",
  "sitemap.xml",
  "terms.html",
];

await rm("dist", { force: true, recursive: true });
await mkdir("dist");

await Promise.all(
  files.map((file) => cp(file, `dist/${file}`, { recursive: true })),
);
