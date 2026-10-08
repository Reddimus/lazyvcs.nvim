"""Exercise Compare in a real terminal, using the installed Neovim config."""

import json
import os
import pathlib
import sys
import time

import pexpect


artifacts = pathlib.Path(sys.argv[1])
artifacts.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["TERM"] = "xterm-256color"
child = pexpect.spawn("nvim", [], env=env, dimensions=(40, 160), encoding="utf-8", timeout=40)
sequence = 0


def ex(command):
    child.send(":" + command + "\r")


def snapshot():
    global sequence
    sequence += 1
    path = artifacts / f"compare-state-{sequence}.json"
    ex(
        "lua local c=require('lazyvcs.compare'); "
        "assert(vim.wait(15000,function() local s=c.current(); return s and s.preview_result end,10)); "
        "local s=c.current(); local w=vim.api.nvim_get_current_win(); "
        "local p=vim.api.nvim_win_get_position(s.sidewin); "
        "vim.fn.writefile({vim.json.encode({list=w==s.sidewin,saved=w==s.rightwin,"
        "base=w==s.leftwin,line=vim.api.nvim_win_get_cursor(w)[1],"
        "right=vim.api.nvim_win_get_cursor(s.rightwin)[1],"
        "left=vim.api.nvim_win_get_cursor(s.leftwin)[1],"
        "row=p[1]+s.row_by_path['sample.txt']+1,col=p[2]+6,"
        "text=vim.api.nvim_buf_get_lines(s.right,0,-1,false),"
        "readonly=not vim.bo[s.left].modifiable and not vim.bo[s.right].modifiable})},"
        + json.dumps(str(path)) + ")"
    )
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size:
            return json.loads(path.read_text())
        # Drain terminal output so a full PTY cannot block rendering.
        try:
            child.read_nonblocking(65536, timeout=0.05)
        except pexpect.TIMEOUT:
            pass
    raise AssertionError(f"missing {path}")


def expect_focus(kind, line=None):
    state = snapshot()
    assert state[kind], state
    if line is not None:
        assert state["line"] == line, state
    assert state["readonly"], state
    return state


with (artifacts / "compare-terminal.log").open("w") as transcript:
    child.logfile = transcript
    try:
        # Configure only the test fixture and base input. Feature actions below
        # use keyboard or terminal mouse events, never their Lua callbacks.
        ex("set mouse=a nomore")
        for vcs in ("git", "svn"):
            setup = " ".join([
                "local root=vim.env.LAZYVCS_E2E_PLUGIN_ROOT or '/work/lazyvcs.nvim';",
                "package.path=root .. '/tests/?.lua;' .. package.path;",
                "local h=require('helpers');",
                "fixture=h.make_" + vcs + "_fixture(); local lines={};",
                "for i=1,60 do lines[i]='line ' .. i end;",
                "h.write_file(fixture.file,table.concat(lines,'\\n') .. '\\n');",
                "h.exec({'git','add','sample.txt'},fixture.root); h.exec({'git','commit','-m','e2e base'},fixture.root);"
                if vcs == "git" else "h.exec({'svn','commit','-m','e2e base'},fixture.root);",
                "lines[8],lines[30],lines[50]='changed eight','changed thirty','changed fifty';",
                "h.write_file(fixture.file,table.concat(lines,'\\n') .. '\\n');",
                "fixture.before=h.exec({'" + vcs + "','diff'},fixture.root);",
                "vim.ui.input=function(_,cb) cb(" + ("'HEAD'" if vcs == "git" else "h.file_url(fixture.repo) .. '@2'") + ") end;",
                "vim.cmd.edit(vim.fn.fnameescape(fixture.file));",
            ])
            ex("lua " + setup)
            child.send(" vc")
            expect_focus("list")
            ex("lua local s=require('lazyvcs.compare').current(); vim.api.nvim_win_set_cursor(s.sidewin,{s.row_by_path['sample.txt'],0})")
            child.send("P")
            state = expect_focus("list")
            assert state["text"][7] == "changed eight", state
            # SGR mouse coordinates are one-based and include the winbar.
            mouse = f"\x1b[<0;{state['col']};{state['row']}M"
            release = f"\x1b[<0;{state['col']};{state['row']}m"
            child.send(mouse + release)
            expect_focus("list")
            child.send(mouse + release)
            expect_focus("saved", 8)
            for keys, line in (("]v", 30), ("]v", 50), ("]v", 8), ("[v", 50)):
                child.send(keys)
                expect_focus("saved", line)
            child.send("\x1b")
            expect_focus("list")
            child.send("\r")
            expect_focus("saved", 50)
            child.send("\x17h")
            expect_focus("base", 50)
            child.send("]v")
            expect_focus("base", 8)
            child.send("p")
            snapshot()
            child.send("\r")
            expect_focus("base", 8)
            child.send(" vC")
            expect_focus("base", 8)
            ex("lua assert(fixture.before==require('helpers').exec({'" + vcs + "','diff'},fixture.root))")
            child.send("q")
            ex("lua require('helpers').cleanup()")
        ex("qa!")
        child.expect(pexpect.EOF)
    finally:
        if child.isalive():
            child.send("\x1b:qa!\r")
            child.close(force=True)

print("Compare terminal E2E passed for Git and SVN")
