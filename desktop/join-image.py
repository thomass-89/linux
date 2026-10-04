#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Reassemble release parts and verify the resulting ISO, on Windows or Linux."""
import hashlib
from pathlib import Path
import shutil

folder = Path(__file__).resolve().parent
iso = folder / 'Hayavadan-Desktop-x86_64.iso'
parts = sorted(folder.glob(iso.name + '.part-*'))
expected = (folder / 'ISO-SHA256SUMS').read_text().split()[0]
if not parts:
    raise SystemExit('Download every ISO part into this folder first.')
if iso.exists():
    raise SystemExit(f'{iso.name} already exists. Move it before rebuilding.')
partial = iso.with_suffix('.iso.incomplete')
try:
    with partial.open('wb') as output:
        for part in parts:
            print('Joining', part.name, flush=True)
            with part.open('rb') as source:
                shutil.copyfileobj(source, output, 8 * 1024 * 1024)
    checksum = hashlib.sha256()
    with partial.open('rb') as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b''):
            checksum.update(block)
    if checksum.hexdigest() != expected:
        raise SystemExit('Checksum failed. Check that all parts were downloaded completely.')
    partial.rename(iso)
    print('Verified:', iso)
finally:
    partial.unlink(missing_ok=True)
