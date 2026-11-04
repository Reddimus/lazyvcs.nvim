import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import {
	dirname,
	extname,
	isAbsolute,
	relative,
	resolve,
	sep,
} from "node:path";
import process from "node:process";
import { fromMarkdown } from "mdast-util-from-markdown";

const root = process.cwd();
const realRoot = realpathSync(root);
function outside(base, target) {
	const path = relative(base, target);
	return isAbsolute(path) || path === ".." || path.startsWith(`..${sep}`);
}
const { spawnSync } = await import("node:child_process");
const result = spawnSync("git", ["ls-files", "-z"], {
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

for (const file of markdownFiles) {
	const absoluteFile = resolve(root, file);
	const source = readFileSync(absoluteFile, "utf8");
	const nodes = [fromMarkdown(source)];
	while (nodes.length > 0) {
		const node = nodes.pop();
		if (node.children) nodes.push(...node.children);
		if (!["link", "image", "definition"].includes(node.type)) continue;
		const destination = node.url;
		const line = node.position.start.line;
		if (
			destination.startsWith("#") ||
			destination.startsWith("//") ||
			/^[a-z][a-z0-9+.-]*:/i.test(destination)
		) {
			continue;
		}

		const pathname = destination.split(/[?#]/, 1)[0];
		let decoded;
		try {
			decoded = decodeURIComponent(pathname);
		} catch {
			failures.push(`${file}:${line}: invalid URL escape in ${destination}`);
			continue;
		}
		if (!decoded) continue;
		const target = resolve(dirname(absoluteFile), decoded);
		if (outside(root, target)) {
			failures.push(
				`${file}:${line}: local link target outside the repository ${destination}`,
			);
			continue;
		}
		if (!existsSync(target)) {
			failures.push(
				`${file}:${line}: missing local link target ${destination}`,
			);
			continue;
		}
		if (outside(realRoot, realpathSync(target))) {
			failures.push(
				`${file}:${line}: local link target outside the repository ${destination}`,
			);
			continue;
		}
		if (decoded.endsWith("/") && !statSync(target).isDirectory()) {
			failures.push(
				`${file}:${line}: expected directory link target ${destination}`,
			);
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
