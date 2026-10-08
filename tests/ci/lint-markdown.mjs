import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { lint } from "markdownlint/promise";

// Match repository files without parsing user-controlled glob patterns.
const files = execFileSync(
	"git",
	["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
	{ encoding: "utf8" },
)
	.split("\0")
	.filter((file) => file.endsWith(".md"));
const config = JSON.parse(readFileSync(".markdownlint.json", "utf8"));
const result = await lint({ files, config });
const diagnostics = Object.entries(result).flatMap(([file, errors]) =>
	errors.map(
		(error) =>
			`${file}:${error.lineNumber} ${error.ruleNames.join("/")} ${error.ruleDescription}${error.errorDetail ? `: ${error.errorDetail}` : ""}`,
	),
);
if (diagnostics.length) {
	console.error(diagnostics.join("\n"));
	process.exitCode = 1;
} else {
	console.log(`Validated Markdown in ${files.length} repository files.`);
}
