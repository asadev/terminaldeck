#!/usr/bin/env python3
"""Check a thin keeper's embedded app metadata without executing or signing it."""
import mmap
import os
from pathlib import Path
import re
import plistlib
import struct
import sys


def embedded_info(path):
    with open(path, 'rb') as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
        if data[:4] != b'\xcf\xfa\xed\xfe':
            raise ValueError('keeper must be a thin little-endian 64-bit Mach-O')
        commands = struct.unpack_from('<I', data, 16)[0]
        offset = 32
        for _ in range(commands):
            command, size = struct.unpack_from('<II', data, offset)
            if size < 8 or offset + size > len(data):
                raise ValueError('invalid Mach-O load command')
            if command == 0x19:
                sections = struct.unpack_from('<I', data, offset + 64)[0]
                for index in range(sections):
                    section = offset + 72 + index * 80
                    if section + 80 > offset + size:
                        raise ValueError('invalid Mach-O section')
                    if data[section:section + 16].rstrip(b'\0') == b'__info_plist' and data[section + 16:section + 32].rstrip(b'\0') == b'__TEXT':
                        length = struct.unpack_from('<Q', data, section + 40)[0]
                        start = struct.unpack_from('<I', data, section + 48)[0]
                        if length > 65536 or start + length > len(data):
                            raise ValueError('invalid embedded metadata size')
                        return plistlib.loads(data[start:start + length].rstrip(b'\0'))
            offset += size
    raise ValueError('keeper has no embedded Info.plist; rebuild the session-host product')


def main():
    if sys.argv[1] == '--prepare':
        source, destination, app_id, name = sys.argv[2:]
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', app_id) or not name:
            raise ValueError('invalid scratch app identity')
        info = plistlib.loads(Path(source).read_bytes())
        info.update(CFBundleIdentifier=app_id + '.session-host', CFBundleName=name, CFBundleDisplayName=name)
        output = Path(destination)
        data = plistlib.dumps(info, sort_keys=False)
        if not output.exists() or output.read_bytes() != data:
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = output.with_name(output.name + '.tmp-' + str(os.getpid()))
            try:
                temporary.write_bytes(data)
                temporary.replace(output)
            finally:
                temporary.unlink(missing_ok=True)
        print('Scratch keeper metadata is ready for compilation')
        return
    info = embedded_info(sys.argv[1])
    if info.get('CFBundleIdentifier') != sys.argv[2]:
        raise ValueError('keeper metadata does not match the containing app; rebuild with matching TD_SESSION_HOST_INFO_PLIST')
    if not info.get('CFBundleName') or not info.get('CFBundleDisplayName'):
        raise ValueError('keeper metadata needs a readable privacy name')
    print('Keeper privacy metadata matches its pinned signing identifier')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, struct.error, plistlib.InvalidFileException) as error:
        sys.exit('error: ' + str(error))
