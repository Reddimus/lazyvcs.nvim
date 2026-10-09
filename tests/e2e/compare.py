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
deleted_name = "gone-" + "x" * 70 + ".txt"


def pause(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            child.read_nonblocking(65536, timeout=0.05)
        except pexpect.TIMEOUT:
            pass


def ex(command):
    child.send(":" + command + "\r")


def snapshot():
    global sequence
    sequence += 1
    path = artifacts / f"compare-state-{sequence}.json"
    path.unlink(missing_ok=True)
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
        "path=s.shown_item.relpath,listed=#vim.fn.getbufinfo({buflisted=1}),"
        "width=vim.api.nvim_win_get_width(s.sidewin),auto=s.auto_width==true,"
        "picker=package.loaded['snacks']~=nil,"
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


def assert_editor(name, line):
    path = artifacts / "editor-state.json"
    path.unlink(missing_ok=True)
    ex("lua vim.fn.writefile({vim.json.encode({name=vim.api.nvim_buf_get_name(0),line=vim.api.nvim_win_get_cursor(0)[1],editable=vim.bo.modifiable and vim.bo.buftype==''})}," + json.dumps(str(path)) + ")")
    pause(0.5)
    state = json.loads(path.read_text())
    assert state["name"].endswith("/" + name) and state["line"] == line and state["editable"], state


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
                "fixture.deleted=" + json.dumps(deleted_name) + ";",
                "for i=1,60 do lines[i]='line ' .. i end;",
                "h.write_file(fixture.file,table.concat(lines,'\\n') .. '\\n');",
                "for _,name in ipairs({'second.txt','third.txt',fixture.deleted}) do h.write_file(fixture.root .. '/' .. name,table.concat(lines,'\\n') .. '\\n') end;",
                "h.exec({'git','add','.'},fixture.root); h.exec({'git','commit','-m','e2e base'},fixture.root);"
                if vcs == "git" else "h.exec({'svn','add','second.txt','third.txt',fixture.deleted},fixture.root); h.exec({'svn','commit','-m','e2e base'},fixture.root); h.exec({'svn','update'},fixture.root);",
                "lines[8],lines[30],lines[50]='changed eight','changed thirty','changed fifty';",
                "h.write_file(fixture.file,table.concat(lines,'\\n') .. '\\n');",
                "for _,name in ipairs({'second.txt','third.txt'}) do h.write_file(fixture.root .. '/' .. name,table.concat(lines,'\\n') .. '\\n') end;",
                "h.exec({'" + vcs + "','rm',fixture.deleted},fixture.root);",
                "fixture.before=h.exec({'" + vcs + "','diff'},fixture.root);",
                "vim.ui.input=function(_,cb) cb(" + ("'HEAD'" if vcs == "git" else "h.file_url(fixture.repo) .. '@2'") + ") end;",
                "vim.cmd.edit(vim.fn.fnameescape(fixture.file));",
                "fixture.listed=#vim.fn.getbufinfo({buflisted=1});",
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
            reviewed = expect_focus("saved", 8)
            child.send("e")
            assert expect_focus("saved", 8)["width"] == reviewed["width"]
            child.send("b")
            expect_focus("saved", 8)
            ex("LazyVCS compare width")
            widened = expect_focus("saved", 8)
            assert widened["auto"] and widened["width"] > reviewed["width"], widened
            ex("LazyVCS compare width")
            assert expect_focus("saved", 8)["width"] == reviewed["width"]
            for keys, line in (("]v", 30), ("]v", 50), ("]v", 8), ("[v", 50)):
                child.send(keys)
                expect_focus("saved", line)
            child.send(" vf")
            expect_focus("list")
            child.send("\r")
            expect_focus("saved", 50)
            child.send("\x17h")
            base = expect_focus("base", 50)
            ex("LazyVCS compare width")
            assert expect_focus("base", 50)["width"] > base["width"]
            ex("LazyVCS compare width")
            assert expect_focus("base", 50)["width"] == base["width"]
            child.send("]v")
            expect_focus("base", 8)
            ex("LazyVCS compare metadata")
            snapshot()
            ex("LazyVCS compare metadata")
            expect_focus("base", 8)
            child.send(" vC")
            expect_focus("base", 8)
            child.send("\x17l")
            expect_focus("saved", 8)
            child.send("]v")
            expect_focus("saved", 30)
            for keys, path, line in (("]b", "second.txt", 8), ("[b", "sample.txt", 30), ("2]b", "third.txt", 8)):
                child.send(keys)
                state = expect_focus("saved", line)
                assert state["path"] == path, state
            child.send("]b")
            if vcs == "svn":
                state = expect_focus("saved", 1)
                assert state["path"] == ".", state
                child.send("]b")
            state = expect_focus("base", 1)
            assert state["path"] == deleted_name, state
            child.send("]b")
            state = expect_focus("base", 30)
            assert state["path"] == "sample.txt", state
            child.send(" vf/third.txt\r")
            expect_focus("list")
            child.send("\r")
            expect_focus("saved", 8)
            ex("LazyVCS compare width")
            assert expect_focus("saved", 8)["auto"]
            ex("LazyVCS compare width")
            assert not expect_focus("saved", 8)["auto"]
            ex("lua assert(fixture.listed==#vim.fn.getbufinfo({buflisted=1}))")
            ex("lua assert(fixture.before==require('helpers').exec({'" + vcs + "','diff'},fixture.root))")
            if state["picker"]:
                ex("lua vim.cmd('silent cd ' .. vim.fn.fnameescape(fixture.root))")
                snapshot()
                ex("lua review_win=vim.api.nvim_get_current_win()")
                child.send(" ff")
                pause(0.7)
                child.send("second.txt")
                pause(0.7)
                child.send("\r")
                pause(0.7)
                assert_editor("second.txt", 1)
                ex("lua vim.api.nvim_set_current_win(review_win)")
                picked = expect_focus("saved", 8)
                assert picked["path"] == "third.txt", picked
                ex("lua Snacks.picker.grep({cwd=fixture.root,search='changed thirty',glob='third.txt'})")
                pause(1)
                child.send("\r")
                pause(0.7)
                assert_editor("third.txt", 30)
                ex("lua vim.api.nvim_set_current_win(review_win)")
                expect_focus("saved", 8)
            ex("LazyVCS compare close")
            ex("lua require('helpers').cleanup()")
        ex("qa!")
        child.expect(pexpect.EOF)
    finally:
        if child.isalive():
            child.send("\x1b:qa!\r")
            child.close(force=True)

print("Compare terminal E2E passed for Git and SVN")
