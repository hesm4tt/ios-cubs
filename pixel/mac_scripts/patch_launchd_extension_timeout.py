"""Patch a disposable launchd copy's embedded plist without shifting Mach-O data.

The caller must preserve entitlements and re-sign the result before testing it.
This deliberately refuses any binary whose section layout differs from the
locally inspected iOS 16.5 executable.
"""
import plistlib
import sys
from pathlib import Path

src, dst = map(Path, sys.argv[1:3])
data = bytearray(src.read_bytes())
offset, length = 395359, 0x2056
original = bytes(data[offset:offset + length])
config = plistlib.loads(original)
assert config.get('ExtensionWatchdog') is True
assert 'ExtensionWatchdogTimeout' not in config
config['ExtensionWatchdogTimeout'] = 30
encoded = plistlib.dumps(config, sort_keys=False)
# Indentation between XML elements is not part of the represented plist.
encoded = b'\n'.join(line.lstrip(b'\t') for line in encoded.split(b'\n'))
assert len(encoded) <= length
encoded += b' ' * (length - len(encoded))
assert plistlib.loads(encoded) == config
data[offset:offset + length] = encoded
dst.write_bytes(data)
print('extension watchdog timeout set to 30 in private copy')
