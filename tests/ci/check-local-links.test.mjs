import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const checker = fileURLToPath(
	new URL("./check-local-links.mjs", import.meta.url),
);
function check(t, markdown, files = [], setup = () => {}) {
	const root = mkdtempSync(join(tmpdir(), "lazyvcs-links-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const env = { ...process.env };
	for (const key of Object.keys(env))
		if (key.startsWith("GIT_")) delete env[key];
	writeFileSync(join(root, "README.md"), markdown);
	for (const file of files) writeFileSync(join(root, file), "");
	setup(root);
	for (const args of [
		["init", "--quiet"],
		["add", "."],
	]) {
		const result = spawnSync("git", args, { cwd: root, env, encoding: "utf8" });
		assert.equal(result.status, 0, result.stderr);
	}
	return spawnSync(process.execPath, [checker], {
		cwd: root,
		env,
		encoding: "utf8",
	});
}

test("ignores code examples while checking real links", (t) => {
	const result = check(
		t,
		"`[example](missing.md)`\n\n```md\n![sample](absent.png)\n```\n\n[real](present.md)\n",
		["present.md"],
	);
	assert.equal(result.status, 0, result.stderr);
});
test("checks reference links and images", (t) => {
	const result = check(
		t,
		"[guide][doc]\n\n![image][picture]\n\n[doc]: absent.md\n[picture]: absent.png\n",
	);
	assert.equal(result.status, 1);
	assert.match(result.stderr, /absent\.md/);
	assert.match(result.stderr, /absent\.png/);
});
test("handles balanced parentheses, spaces, queries, and fragments", (t) => {
	const result = check(
		t,
		"[one](guide(one).md) [two](<space name.md>) [three](present.md?raw=1#intro)\n",
		["guide(one).md", "space name.md", "present.md"],
	);
	assert.equal(result.status, 0, result.stderr);
});
test("reports malformed URL escapes with a source line", (t) => {
	const result = check(t, "intro\n\n[bad](absent%ZZ.md)\n");
	assert.equal(result.status, 1);
	assert.match(result.stderr, /README\.md:3: invalid URL escape/);
});
test("skips external and protocol-relative URLs", (t) => {
	const result = check(
		t,
		"[web](https://example.com/x) [relative](//example.com/x) [mail](mailto:user@example.com)\n",
	);
	assert.equal(result.status, 0, result.stderr);
});

test("rejects existing absolute and parent targets outside the repository", (t) => {
	const outside = mkdtempSync(join(tmpdir(), "lazyvcs-outside-"));
	t.after(() => rmSync(outside, { recursive: true, force: true }));
	const file = join(outside, "present.md");
	writeFileSync(file, "outside");
	const result = check(
		t,
		`[absolute](<${file.replaceAll("\\", "/")}>) [parent](../${basename(outside)}/present.md)`,
	);
	assert.equal(result.status, 1);
	assert.equal(
		(result.stderr.match(/outside the repository/g) || []).length,
		2,
	);
});
test("rejects symbolic links to targets outside the repository", (t) => {
	const outside = mkdtempSync(join(tmpdir(), "lazyvcs-outside-"));
	t.after(() => rmSync(outside, { recursive: true, force: true }));
	writeFileSync(join(outside, "present.md"), "outside");
	const result = check(t, "[linked](linked/present.md)", [], (root) =>
		symlinkSync(outside, join(root, "linked"), "dir"),
	);
	assert.equal(result.status, 1);
	assert.match(result.stderr, /outside the repository/);
});
