import { readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectDirectory = dirname(dirname(fileURLToPath(import.meta.url)));
const resourcesDirectory = join(projectDirectory, "Resources");
const versionKey = /(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*(<\/string>)/g;
const checkOnly = process.argv.slice(2).includes("--check");

if (process.argv.slice(2).some((argument) => argument !== "--check")) {
  throw new Error("usage: node scripts/sync-app-versions.mjs [--check]");
}

for (const entry of await readdir(resourcesDirectory, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;

  const appDirectory = join(resourcesDirectory, entry.name);
  const packagePath = join(appDirectory, "package.json");
  let packageJson;

  try {
    packageJson = JSON.parse(await readFile(packagePath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") continue;
    throw error;
  }

  if (!/^\d+\.\d+\.\d+$/.test(packageJson.version)) {
    throw new Error(`${packagePath} has an invalid macOS app version: ${packageJson.version}`);
  }

  const plistPath = join(appDirectory, "Info.plist");
  const plist = await readFile(plistPath, "utf8");
  const matches = [...plist.matchAll(versionKey)];

  if (matches.length !== 1) {
    throw new Error(`${plistPath} must contain exactly one CFBundleShortVersionString`);
  }

  const updatedPlist = plist.replace(versionKey, `$1${packageJson.version}$2`);
  if (updatedPlist === plist) continue;

  if (checkOnly) {
    throw new Error(
      `${entry.name} version mismatch: package.json is ${packageJson.version}. Run npm run version:sync.`,
    );
  }

  await writeFile(plistPath, updatedPlist);
}
