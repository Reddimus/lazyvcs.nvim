"""Run the actual terminal smoke driver with reused measurements and a broken key."""

import ast
import os
import pathlib
import subprocess
import sys

root, binary, scratch = sys.argv[1:]
root, scratch = pathlib.Path(root), pathlib.Path(scratch)
for key, name in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                  ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
    os.environ[key] = str(scratch / name)
os.environ["LAZYVCS_E2E_PLUGIN_ROOT"] = str(root)
workspace = scratch / "workspace"
repo = workspace / "team-a/integrated-solutions-rdk-webserver"
repo.mkdir(parents=True)
subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
(repo / "changed.txt").write_text("changed\n")
os.environ["LAZYVCS_E2E_WORKSPACE"] = str(workspace)
config = scratch / "config/nvim"
config.mkdir(parents=True)
init = """
vim.opt.runtimepath:prepend(vim.env.LAZYVCS_E2E_PLUGIN_ROOT)
vim.cmd.runtime('plugin/lazyvcs.lua')
require('lazyvcs').setup({signs={enabled=false},source_control={width=24,remote_refresh='manual'}})
"""
source = (root / "tests/e2e/ubuntu-native.sh").read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
artifacts = scratch / "artifacts"
artifacts.mkdir()


class Paths(ast.NodeTransformer):
    def visit_Constant(self, node):
        if isinstance(node.value, str):
            node.value = node.value.replace("/artifacts", str(artifacts))
        return node

    def visit_Call(self, node):
        if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == "pexpect" and node.func.attr == "spawn":
            node.args[0] = ast.Constant(binary)
        return self.generic_visit(node)


tree = ast.fix_missing_locations(Paths().visit(ast.parse(source)))
driver = scratch / "driver.py"
driver.write_text(ast.unparse(tree))
# Healthy control proves the real key and driver work before injecting the fault.
(config / "init.lua").write_text(init)
healthy = subprocess.run([sys.executable, str(driver)], capture_output=True, text=True, timeout=30)
assert healthy.returncode == 0, healthy.stdout + healthy.stderr
assert int((artifacts / "pty-width-after.txt").read_text()) > 24

# Retain the successful run's artifacts, then disable sidebar expansion.
(config / "init.lua").write_text(init + """
local native = require('lazyvcs.source_control.native')
local dispatch = native.dispatch
native.dispatch = function(action)
  if action ~= 'smart_e' then return dispatch(action) end
end
""")
broken = subprocess.run([sys.executable, str(driver)], capture_output=True, text=True, timeout=30)
assert broken.returncode != 0, "terminal smoke accepted stale widths with expansion disabled"
assert "expected e to expand sidebar" in broken.stderr, broken.stderr
assert (artifacts / "pty-width-after.txt").read_text().strip() == "24"
print("Terminal smoke rejected stale measurements")
