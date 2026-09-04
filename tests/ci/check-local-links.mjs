import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, relative, resolve } from "node:path";
import process from "node:process";

const root = process.cwd();
const tracked = process.platform === "win32" ? ["git", "ls-files", "-z"] : ["git", "ls-files", "-z"];
const { spawnSync } = await import("node:child_process");
const result = spawnSync(tracked[0], tracked.slice(1), {
  cwd: root,
  encoding: "utf8",
});

if (result.status !== 0) {
  process.stderr.write(result.stderr || "git ls-files failed\n");
  process.exit(result.status || 1);
}

const markdownFiles = result.stdout
  .split("\0")
  .filter((path) => extname(path).toLowerCase() === ".md");
const failures = [];
const linkPattern = /!?\[[^\]]*]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/g;

for (const file of markdownFiles) {
  const absoluteFile = resolve(root, file);
  const source = readFileSync(absoluteFile, "utf8");
  for (const match of source.matchAll(linkPattern)) {
    const destination = match[1].replace(/^<|>$/g, "");
    if (
      destination.startsWith("#") ||
      destination.startsWith("mailto:") ||
      /^[a-z][a-z0-9+.-]*:/i.test(destination)
    ) {
      continue;
    }

    const decoded = decodeURIComponent(destination.split("#", 1)[0]);
    if (!decoded) continue;
    const target = resolve(dirname(absoluteFile), decoded);
    if (!existsSync(target)) {
      const line = source.slice(0, match.index).split("\n").length;
      failures.push(`${file}:${line}: missing local link target ${destination}`);
      continue;
    }
    if (destination.endsWith("/") && !statSync(target).isDirectory()) {
      const line = source.slice(0, match.index).split("\n").length;
      failures.push(`${file}:${line}: expected directory link target ${destination}`);
    }
  }
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join("\n")}\n`);
  process.exit(1);
}

process.stdout.write(
  `Validated local Markdown links in ${markdownFiles.length} tracked files (${relative(root, root) || "."}).\n`,
);
