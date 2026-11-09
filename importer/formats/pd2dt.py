"""Advanced POWER DoLLS 2 (PC-98) -- PD2DT archive extractor.

Usage:
    python -I -X utf8 pd2dt.py <dir with PD2DT.IDX + PD2DT.000..005> <outdir>

Formats (reverse-engineered from the data and PD2SHELL.EXE, 2026-11-07):

PD2DT.000..005  "BIGFILE" multi-volume archive.
    Every volume starts with an 8-byte tag b'BIGFILE\\0'. Strip it from each
    volume and concatenate. Volume 0 then has a further 43-byte header
    (volume name "PD2DT.BND", date, etc.). File data follows directly.
PD2DT.IDX       169 x 24-byte entries: name[16] (NUL-padded, CP932),
                size u32, offset u32 (offset is relative to the end of the
                43-byte header in the stripped/concatenated stream).
.SLD            u32 decompressed size + LZSS stream.
.PCK            u32 table_bytes, then table_bytes/8 x (offset u32, size u32),
                then chunk data (offsets relative to 4 + table_bytes).
                Each chunk is either an SLD-style LZSS chunk (text, unit and
                mission tables) or a still-unknown image encoding.
LZSS            Okumura variant: N=4096, F=18, ring zero-filled, r starts at
                0xFEE, flag byte LSB-first (1 = literal), reference =
                pos 12 bits (lo | (hi & 0xF0) << 4), length (hi & 0x0F) + 3.
Text            Shift-JIS (CP932), strings NUL-terminated.

Images: see gcp.py (.GCP screens and sprite chunks) -> PNG under <outdir>/png.
Not decoded yet: ST??.ASK, SCN_MIS/MAP_CHG/ANIME tables, Kogado .MID (not SMF),
.CMD FM music.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcp  # noqa: E402

VOLUME_TAG = b'BIGFILE\0'
MAIN_HEADER = 43


def read_index(path):
    d = open(path, 'rb').read()
    out = []
    for i in range(0, len(d), 24):
        name = d[i:i+16].split(b'\0')[0].decode('cp932')
        size, off = struct.unpack_from('<II', d, i+16)
        out.append((name, size, off))
    return out


def read_volumes(src_dir, base='PD2DT'):
    parts = []
    i = 0
    while os.path.exists(os.path.join(src_dir, f'{base}.{i:03d}')):
        v = open(os.path.join(src_dir, f'{base}.{i:03d}'), 'rb').read()
        if not v.startswith(VOLUME_TAG):
            raise ValueError(f'{base}.{i:03d}: missing BIGFILE tag')
        parts.append(v[len(VOLUME_TAG):])
        i += 1
    return b''.join(parts)[MAIN_HEADER:]


def lzss(src, n=4096, f=18, fill=0):
    ring = bytearray([fill]) * n
    r = n - f
    out = bytearray()
    i, flags, ln = 0, 0, len(src)
    while i < ln:
        flags >>= 1
        if not flags & 0x100:
            flags = src[i] | 0xFF00
            i += 1
            if i >= ln:
                break
        if flags & 1:
            c = src[i]; i += 1
            out.append(c); ring[r] = c; r = (r + 1) & (n - 1)
        else:
            if i + 1 >= ln:
                break
            lo, hi = src[i], src[i+1]; i += 2
            pos = lo | ((hi & 0xF0) << 4)
            for k in range((hi & 0x0F) + 3):
                c = ring[(pos + k) & (n - 1)]
                out.append(c); ring[r] = c; r = (r + 1) & (n - 1)
    return bytes(out)


def decode_chunk(c):
    """Return decompressed bytes if c is a size-prefixed LZSS chunk, else None."""
    if len(c) < 5:
        return None
    want = struct.unpack_from('<I', c)[0]
    if not 0 < want < 4_000_000:
        return None
    out = lzss(c[4:])
    return out if len(out) == want else None


def split_pck(raw):
    table = struct.unpack_from('<I', raw)[0]
    base = 4 + table
    return [raw[base+o: base+o+s]
            for o, s in (struct.unpack_from('<II', raw, 4 + 8*k) for k in range(table // 8))]


def looks_like_text(b):
    if not b:
        return False
    t = b.decode('cp932', 'replace')
    bad = t.count('�') + sum(1 for ch in t if ord(ch) < 32 and ch not in '\0\r\n\t')
    return bad / len(t) < 0.02


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'wb').write(data)


def save_text(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(data.decode('cp932', 'replace').replace('\r\n', '\n').replace('\0', '\n'))


# Sprites carry no palette; the game draws them over a screen whose .GCP set it.
# Mapping worked out from which executable loads each set and which screens that
# executable shows, then checked visually (2026-11-07).
DEFAULT_SPRITE_PALETTE = 'HENSEI_G.GCP'   # main UI palette, shared by 16 screens
SPRITE_PALETTES = {
    'DFACE.PCK': 'HEX_G.GCP',      # portraits on the tactical hex screen (confirmed: skin tones)
    'HIDAN.PCK': 'HEX_G.GCP',      # damage report, tactical hex screen (inferred from module)
    'STAFF_P.PCK': 'APD_STF1.GCP',  # ending credits over the APD_STF* backgrounds (confirmed)
    # Everything else uses the UI palette (confirmed visually): FACE CHARA WEAPON
    # ARMS BLANC DATAU EVKAO EVENT MMAP* AMAP* SCORE_*. SMAP* is also shown on the
    # hex screen (HEX_G palette) in game; the UI palette is how it appears in
    # briefing and on the movement screen.
}


def try_image(data, out_stem, sprite_pal):
    """Write a PNG if data is a GCP screen or a sprite chunk. Returns kind or None."""
    if gcp.is_gcp(data):
        try:
            h, planes, end = gcp.decode(data)
        except (IndexError, ValueError):
            end = -1
        if end == len(data):
            w, ht, px = gcp.to_indexed(h, planes)
            os.makedirs(os.path.dirname(out_stem), exist_ok=True)
            gcp.write_png(out_stem + '.png', w, ht, px, gcp.palette_rgb(h))
            return 'gcp'
    if gcp.is_sprite(data):
        try:
            info, px = gcp.decode_sprite(data, lzss)
        except ValueError:
            return None
        os.makedirs(os.path.dirname(out_stem), exist_ok=True)
        gcp.write_png(out_stem + '.png', info['w'], info['h'], px, sprite_pal)
        return 'sprite'
    return None


def main():
    src, dst = sys.argv[1], sys.argv[2]
    idx = read_index(os.path.join(src, 'PD2DT.IDX'))
    blob = read_volumes(src)
    end = max(o + s for _, s, o in idx)
    if end != len(blob):
        raise ValueError(f'archive size mismatch: index ends at {end}, data is {len(blob)}')
    stats = {'files': 0, 'lzss': 0, 'raw': 0, 'text': 0, 'gcp': 0, 'sprite': 0}
    by_name = {n: blob[o: o + s] for n, s, o in idx}
    palettes = {}

    def pal_for(pck_name):
        src = SPRITE_PALETTES.get(pck_name, DEFAULT_SPRITE_PALETTE)
        if src not in palettes:
            palettes[src] = gcp.palette_rgb(gcp.parse_header(by_name[src]))
        return palettes[src]
    sprite_pal = pal_for(None)
    for name, size, off in idx:
        raw = blob[off: off + size]
        stats['files'] += 1
        save(os.path.join(dst, 'raw', name), raw)
        ext = name.rsplit('.', 1)[-1].upper()
        if ext == 'PCK':
            for k, chunk in enumerate(split_pck(raw)):
                d = decode_chunk(chunk)
                stem = os.path.join(dst, 'pck', name, f'{k:03d}')
                if d is None:
                    kind = try_image(chunk, os.path.join(dst, 'png', name, f'{k:03d}'), pal_for(name))
                    if kind:
                        stats[kind] += 1
                    else:
                        save(stem + '.chunk', chunk); stats['raw'] += 1
                else:
                    save(stem + '.bin', d); stats['lzss'] += 1
                    if looks_like_text(d):
                        save_text(stem + '.txt', d); stats['text'] += 1
        else:
            kind = try_image(raw, os.path.join(dst, 'png', name[:-4]), sprite_pal) if ext == 'GCP' else None
            if kind:
                stats[kind] += 1
                continue
            d = decode_chunk(raw)
            if d is not None:
                save(os.path.join(dst, 'decoded', name + '.bin'), d); stats['lzss'] += 1
                if looks_like_text(d):
                    save_text(os.path.join(dst, 'decoded', name + '.txt'), d); stats['text'] += 1
            elif ext in ('CFG', 'MAKEFILE') or name == 'MAKEFILE':
                save_text(os.path.join(dst, 'decoded', name + '.txt'), raw); stats['text'] += 1
    print(f"{stats['files']} files; {stats['lzss']} LZSS chunks decoded ({stats['text']} text); "
          f"images: {stats['gcp']} GCP screens + {stats['sprite']} sprites; "
          f"{stats['raw']} PCK chunks left undecoded")


if __name__ == '__main__':
    main()
