#!/usr/bin/env python3
"""Enable an explicit PosterBoard launch angel for a disposable experiment."""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "    with open(f'{src}/{label}.plist', 'rb') as f:\n        job = plistlib.load(f)"
new = """    job_path = f'{src}/{label}.plist'
    if not os.path.isfile(job_path):
        job_path = f'{angels}/{label}.plist'
    with open(job_path, 'rb') as f:
        job = plistlib.load(f)
    if label == 'com.apple.PosterBoard':
        job['RunAtLoad'] = True
        job['KeepAlive'] = False
""".rstrip("\n")
assert source.count(old) == 1
path.write_text(source.replace(old, new))
