#!/usr/bin/env node
// Sync the QwenPaw version from src/qwenpaw/__version__.py into
// console/package.json so electron-builder stamps it onto the artifacts.
import { readFileSync, writeFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, resolve } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const versionFile = resolve(repoRoot, "src", "qwenpaw", "__version__.py");
const pkgFile = resolve(repoRoot, "console", "package.json");

const py = readFileSync(versionFile, "utf-8");
const match = py.match(/__version__\s*=\s*"([^"]+)"/);
if (!match) {
  console.error("Could not parse __version__ from", versionFile);
  process.exit(1);
}
const raw = match[1];
// npm/electron-builder need semver; Python PEP440 (e.g. 1.2.3.dev0) -> 1.2.3-dev0
const semver = raw.replace(/(\d+\.\d+\.\d+)(?:\.([a-z]+)(\d+))?/, (_, core, tag, num) =>
  tag ? `${core}-${tag}${num}` : core,
);

const pkg = JSON.parse(readFileSync(pkgFile, "utf-8"));
pkg.version = semver;
writeFileSync(pkgFile, JSON.stringify(pkg, null, 2) + "\n");
console.log(`Synced console/package.json version -> ${semver}`);
