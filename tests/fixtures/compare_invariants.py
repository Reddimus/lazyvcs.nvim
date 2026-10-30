"""Ensure the terminal driver rejects each deliberately broken invariant."""

import ast
import os
import pathlib
import sys

root, binary, scratch, mode = sys.argv[1:]
root, scratch = pathlib.Path(root), pathlib.Path(scratch)
for key, name in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                  ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
    os.environ[key] = str(scratch / name)
os.environ["LAZYVCS_E2E_PLUGIN_ROOT"] = str(root)
config = scratch / "config/nvim"
config.mkdir(parents=True, exist_ok=True)
(config / "init.lua").write_text("""
vim.opt.runtimepath:prepend(vim.env.LAZYVCS_E2E_PLUGIN_ROOT)
vim.cmd.runtime('plugin/lazyvcs.lua')
vim.g.mapleader=' '
vim.keymap.set('n','<leader>vc','<cmd>LazyVCS compare<cr>')
vim.keymap.set('n','<leader>vC','<cmd>LazyVCS compare base<cr>')
require('lazyvcs').setup({signs={enabled=false},source_control={remote_refresh='manual',confirm_mutations=false}})
""")
source = root / "tests/e2e/compare.py"


class Inject(ast.NodeTransformer):
    def visit_Call(self, node):
        if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == "pexpect" and node.func.attr == "spawn":
            node.args[0] = ast.Constant(binary)
        return self.generic_visit(node)

    def visit_Expr(self, node):
        call = node.value
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Name):
            old = call.func.id == "ex" and call.args and isinstance(call.args[0], ast.Constant) and str(call.args[0].value).startswith("lua assert(fixture.listed==")
            new = call.func.id == "check_invariants"
            if (old or new) and mode != "normal":
                value = "fixture.listed=-999" if mode == "listed" else "fixture.before='FORCED_MISMATCH'"
                return [ast.parse(f'ex("lua {value}")').body[0], self.generic_visit(node)]
        return self.generic_visit(node)


tree = ast.fix_missing_locations(Inject().visit(ast.parse(source.read_text())))
sys.argv = [str(source), str(scratch / "artifacts")]
try:
    exec(compile(tree, str(source), "exec"), {"__name__": "__main__"})
except AssertionError as error:
    if mode == "normal" or "invariant" not in str(error):
        raise
    print("Terminal driver rejected", mode, "invariant")
else:
    assert mode == "normal", f"terminal driver ignored broken {mode} invariant"
