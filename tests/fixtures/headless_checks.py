"""Inject an assertion failure into each shell smoke's actual Lua command."""
import pathlib
import shlex
import subprocess
import sys

root, binary = pathlib.Path(sys.argv[1]), sys.argv[2]
for name in ["ubuntu-native.sh", "ubuntu-astronvim.sh"]:
    lines = (root / "tests/e2e" / name).read_text().splitlines()
    line = next(line for line in lines if '"+lua ' in line and ("source_control_open" in line or "mounted plugin path" in line))
    command = shlex.split(line.rstrip().removesuffix("\\"))[0]
    if "pcall(function()" in command:
        command = command.replace("pcall(function()", "pcall(function() error('forced smoke failure');", 1)
    else:
        command = "+lua error('forced smoke failure'); " + command[5:]
    result = subprocess.run([binary, "--headless", "-u", "NONE", "-i", "NONE", command, "+qa!"], capture_output=True, text=True, timeout=15)
    assert result.returncode != 0, f"{name} ignored headless assertion failure"
print("Headless smoke failures propagate")
