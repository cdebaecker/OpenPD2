"""POWER DoLLS 2 plus DASH (Windows) `.PAC` image container extractor.

Usage:
    python -I -X utf8 pac.py <dir with .pac files> <outdir>

Format (2026-11-08): a list of (u32 offset, u32 size) pairs, then the images.
The first offset equals the header size, so the entry count is offset0 / 8.
Every entry is a plain uncompressed Windows BMP (8-bit with palette); empty
entries have size 0. Images are written as PNG (requires Pillow) in a folder
per .pac file, or as the original .bmp if Pillow is missing.
"""
import io
import os
import struct
import sys


def split_pac(data):
    first = struct.unpack_from('<I', data, 0)[0]
    out = []
    for i in range(first // 8):
        off, size = struct.unpack_from('<II', data, 8 * i)
        out.append(data[off:off + size] if size else b'')
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    try:
        from PIL import Image
    except ImportError:
        Image = None
    images = empty = other = 0
    for root, _, files in os.walk(src):
        for f in sorted(files):
            if not f.lower().endswith('.pac'):
                continue
            rel = os.path.relpath(os.path.join(root, f), src)
            folder = os.path.join(dst, os.path.splitext(rel)[0])
            os.makedirs(folder, exist_ok=True)
            for k, chunk in enumerate(split_pac(open(os.path.join(root, f), 'rb').read())):
                if not chunk:
                    empty += 1
                    continue
                if chunk[:2] != b'BM':
                    other += 1
                    open(os.path.join(folder, f'{k:03d}.bin'), 'wb').write(chunk)
                    continue
                images += 1
                if Image:
                    Image.open(io.BytesIO(chunk)).save(os.path.join(folder, f'{k:03d}.png'))
                else:
                    open(os.path.join(folder, f'{k:03d}.bmp'), 'wb').write(chunk)
    print(f'{images} images, {empty} empty entries, {other} non-BMP entries')


if __name__ == '__main__':
    main()
