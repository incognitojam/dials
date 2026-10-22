import { readdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectDirectory = dirname(dirname(fileURLToPath(import.meta.url)));
const resourcesDirectory = join(projectDirectory, "Resources");
const [command, inputPath] = process.argv.slice(2);

if (!["title", "matrix"].includes(command) || !inputPath) {
  throw new Error("usage: node scripts/release-apps.mjs <title|matrix> <changesets-json>");
}

const appsByPackage = new Map();
for (const entry of await readdir(resourcesDirectory, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue;

  try {
    const packageJson = JSON.parse(await readFile(join(resourcesDirectory, entry.name, "package.json"), "utf8"));
    appsByPackage.set(packageJson.name, entry.name);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function appFor(packageName) {
  const app = appsByPackage.get(packageName);
  if (!app) throw new Error(`${packageName} is not an app under Resources`);
  return app;
}

const input = JSON.parse(await readFile(inputPath, "utf8"));

if (command === "title") {
  const apps = input.releases
    .filter((release) => release.type !== "none")
    .map((release) => `${appFor(release.name)} v${release.newVersion}`)
    .sort();
  if (apps.length === 0) throw new Error(`${inputPath} has no releases`);
  process.stdout.write(`release: ${apps.join(", ")}`);
} else {
  const releases = input.plan.flat().map((release) => ({
    app: appFor(release.name),
    version: release.version,
    tag: `${release.name}@${release.version}`,
  }));
  process.stdout.write(JSON.stringify(releases));
}
