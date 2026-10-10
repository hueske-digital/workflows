// Stands in for a site's scripts: build writes dist/ as astro build
// would, with the commit and a mark of where it was built, and keeps a
// file in the cache directory, which the next run finds.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import isNumber from "is-number";

const script = process.argv[2];
if (script === "build") {
  const cached = existsSync(".astro-cache/built") ? readFileSync(".astro-cache/built", "utf8").trim() : "nothing";
  console.log(`the cache held: ${cached}`);
  mkdirSync(".astro-cache", { recursive: true });
  writeFileSync(".astro-cache/built", process.env.GITHUB_SHA ?? "local");
  mkdirSync("dist", { recursive: true });
  writeFileSync("dist/index.html", `${process.env.GITHUB_ACTIONS ? "the runner" : "the Dockerfile"} ${isNumber(1)}\n`);
} else if (script === "after") {
  if (!existsSync("dist/index.html")) process.exit(1);
}
console.log(`${script} ok`);
