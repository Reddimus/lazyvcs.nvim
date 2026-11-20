"""Write terminal input to a pexpect child without deadlocking on a full PTY."""

import fcntl
import os
import select
import time

import pexpect


def send(child, text, timeout=30):
    """Write text to the child's terminal while draining its output.

    A blocking write never returns when Neovim is itself blocked writing
    redraws to the terminal output that this process is not reading. Write
    without blocking, read whatever the child prints in between, and fail
    after timeout seconds instead of hanging.
    """
    data = text.encode(child.encoding or "utf-8") if isinstance(text, str) else text
    fd = child.child_fd
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    deadline = time.monotonic() + timeout
    try:
        while data:
            if time.monotonic() > deadline:
                raise AssertionError(f"terminal input stalled with {len(data)} bytes unsent")
            readable, writable, _ = select.select([fd], [fd], [], 0.05)
            if readable:
                try:
                    child.read_nonblocking(65536, timeout=0)
                except (pexpect.TIMEOUT, BlockingIOError):
                    pass
            if writable:
                try:
                    data = data[os.write(fd, data[:256]):]
                except BlockingIOError:
                    pass
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFL, flags)
