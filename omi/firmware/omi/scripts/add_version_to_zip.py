#!/usr/bin/env python3
"""Append version.txt to a firmware zip. Safe to run multiple times."""
import sys
import zipfile

zip_path, version = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, 'a') as z:
    if 'version.txt' not in z.namelist():
        z.writestr('version.txt', version)
        print(f'Stamped {version} into {zip_path}')
    else:
        print(f'version.txt already present in {zip_path}, skipping')
