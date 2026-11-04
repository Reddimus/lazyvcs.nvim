"""Quote filesystem strings for Lua 5.1, including arbitrary path bytes."""

import os


def quote(value):
    return '"' + ''.join(
        chr(byte) if 32 <= byte < 127 and byte not in (34, 92) else f'\\{byte:03d}'
        for byte in os.fsencode(value)
    ) + '"'
