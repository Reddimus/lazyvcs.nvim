"""Check command strings against the Neovim interpreter used by the drivers."""

import os
import subprocess
import unittest

from lua_literal import quote


class LuaLiteralTests(unittest.TestCase):
    def test_round_trip_filesystem_bytes(self):
        for value in ['plain/path', 'space é/日本語', 'quote"\\/line\ncontrol\x01', os.fsdecode(b'invalid-\xff')]:
            with self.subTest(value=value):
                result = subprocess.run(
                    ['nvim', '--headless', '-u', 'NONE', '-i', 'NONE',
                     '-c', 'lua io.stdout:write(' + quote(value) + ')', '-c', 'qa!'],
                    capture_output=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, os.fsencode(value))


if __name__ == '__main__':
    unittest.main()
