"""Exercise SVN blame across saved edits through a real Neovim terminal."""

import json
import os
import pathlib
import sys
import time

import pexpect


artifacts = pathlib.Path(sys.argv[1]).resolve()
artifacts.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["TERM"] = "xterm-256color"
child = pexpect.spawn(
    "nvim", ["-i", "NONE"], env=env, dimensions=(40, 160), encoding="utf-8", timeout=30
)
sequence = 0


def drain(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            child.read_nonblocking(65536, timeout=0.05)
        except pexpect.TIMEOUT:
            pass


def ex(command):
    child.send(":" + command + "\r")


def snapshot(kind="inline"):
    global sequence
    sequence += 1
    path = artifacts / f"blame-state-{sequence}.json"
    path.unlink(missing_ok=True)
    # Read the public command's result and the screen that Neovim drew. Wait for
    # current attribution, not a previous generation with the same row count.
    ex(
        "lua local ok,value=pcall(function() "
        "local b=require('lazyvcs.blame'); local k=" + json.dumps(kind) + "; "
        "assert(vim.wait(15000,function() "
        "if k=='inline' then local v=b._test_inline_state().views[fixture.buf]; "
        "return v and (v.error or (v.entries and vim.deep_equal(v.identity,"
        "require('lazyvcs.compare_text').identity(fixture.buf)))) end; "
        "if k=='split' then local v=b._test_blame_views()[fixture.buf]; return v and v.winid end; "
        "if k=='selection' then local v=require('lazyvcs.blame_selection')._test_requests()[fixture.buf]; "
        "return v and not v.handle end; "
        "local v=b._test_line_log_views()[fixture.buf]; return v and v.winid end,10),'blame timed out'); "
        "local v=b._test_inline_state().views[fixture.buf]; local revisions={}; "
        "for _,e in ipairs(v and v.entries or {}) do revisions[#revisions+1]=e.revision end; "
        "local s=b._test_blame_views()[fixture.buf]; "
        "local r=require('lazyvcs.blame_selection')._test_requests()[fixture.buf]; "
        "local h=b._test_line_log_views()[fixture.buf]; "
        "vim.cmd('redraw'); local screen={}; for row=1,vim.o.lines do local chars={}; "
        "for col=1,vim.o.columns do chars[#chars+1]=vim.fn.screenstring(row,col) end; "
        "screen[#screen+1]=table.concat(chars) end; "
        "return {revisions=revisions,error=v and v.error,notices=blame_notices,screen=screen,"
        "text=vim.api.nvim_buf_get_lines(fixture.buf,0,-1,false),disk=vim.fn.readfile(fixture.file),"
        "modified=vim.bo[fixture.buf].modified,cursor=vim.api.nvim_win_get_cursor(fixture.win),"
        "split=s and vim.api.nvim_buf_get_lines(s.bufnr,0,-1,false),"
        "selection=r and vim.api.nvim_buf_get_lines(r.buf,0,-1,false),"
        "history=h and vim.api.nvim_win_get_config(h.winid).title} end); "
        "vim.fn.writefile({vim.json.encode({ok=ok,value=value})}," + json.dumps(str(path)) + ")"
    )
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size:
            result = json.loads(path.read_text())
            assert result["ok"], result
            return result["value"]
        drain(0.05)
    raise AssertionError(f"missing {path}")


def expect_inline(revisions, text):
    state = snapshot()
    assert state["revisions"] == revisions, state
    assert state["text"] == text, state
    assert state["disk"] == text and not state["modified"], state
    assert not state.get("error") and not state["notices"], state
    return state


with (artifacts / "blame-terminal.log").open("w") as transcript:
    child.logfile = transcript
    try:
        ex("set nomore noswapfile noundofile")
        # Fixture setup may use Lua. Editing and feature actions below use keys
        # and public Ex commands, including normal write and undo events.
        ex(
            "lua local root=vim.env.LAZYVCS_E2E_PLUGIN_ROOT or '/work/lazyvcs.nvim'; "
            "package.path=root..'/tests/?.lua;'..package.path; local h=require('helpers'); "
            "fixture=h.make_svn_fixture(); h.write_file(fixture.file,'one\\nTWO\\nthree\\n'); "
            "h.exec({'svn','commit','-m','second line',fixture.file},fixture.root); "
            "h.write_file(fixture.file,'one\\nTWO\\nTHREE\\n'); "
            "h.exec({'svn','commit','-m','third line',fixture.file},fixture.root); "
            "vim.cmd.edit(vim.fn.fnameescape(fixture.file)); "
            "fixture.buf=vim.api.nvim_get_current_buf(); fixture.win=vim.api.nvim_get_current_win(); "
            "require('lazyvcs.config').get().blame.persist=false; "
            "blame_notices={}; local u=require('lazyvcs.util'); local notify=u.notify; "
            "u.notify=function(m,l) blame_notices[#blame_notices+1]=m; return notify(m,l) end"
        )
        ex("LazyVCS blame clear")
        ex("LazyVCS blame toggle")
        expect_inline(["1", "2", "3"], ["one", "TWO", "THREE"])

        child.send("2GO// testing\x1b:w\r")
        inserted = expect_inline(["1", "-", "2", "3"], ["one", "// testing", "TWO", "THREE"])
        assert inserted["cursor"][0] == 2, inserted
        assert "Uncommitted line" in "\n".join(inserted["screen"]), inserted
        child.send("u:w\r")
        expect_inline(["1", "2", "3"], ["one", "TWO", "THREE"])
        child.send("\x12:w\r")
        expect_inline(["1", "-", "2", "3"], ["one", "// testing", "TWO", "THREE"])

        child.send("2Gdd:w\r")
        expect_inline(["1", "2", "3"], ["one", "TWO", "THREE"])
        child.send("2GOnew\x1bGdd:w\r")
        expect_inline(["1", "-", "2"], ["one", "new", "TWO"])
        child.send("3G")
        unchanged = expect_inline(["1", "-", "2"], ["one", "new", "TWO"])
        assert "r2" in "\n".join(unchanged["screen"]), unchanged

        ex("LazyVCS blame clear")
        ex("LazyVCS blame split")
        split = snapshot("split")
        assert len(split["split"]) == 3 and split["split"][1] == "Uncommitted line", split
        assert split["split"][2].lstrip().startswith("2 "), split
        ex("wincmd l")
        ex("LazyVCS blame split")
        ex("2,3LazyVCS blame")
        selected = snapshot("selection")
        assert "Uncommitted line | new" in selected["selection"][2], selected
        assert selected["selection"][3].startswith("3  2  "), selected
        child.send("q")
        child.send("3G")
        ex("LazyVCS blame log")
        history = snapshot("history")
        assert "SVN 2" in json.dumps(history["history"]) and not history["notices"], history
        child.send("q")
        ex("lua require('helpers').cleanup()")
        ex("qa!")
        child.expect(pexpect.EOF)
        child.close()
        assert child.exitstatus == 0, child.exitstatus
    finally:
        if child.isalive():
            child.send("\x1b:qa!\r")
            drain(0.2)
            child.close(force=True)

print("SVN blame terminal E2E passed: saved edits, undo/redo, inline, split, selection, and history")
