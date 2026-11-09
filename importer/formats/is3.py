"""InstallShield 3 `.Z` archive extractor (POWER DoLLS 2 plus DASH, Windows CD `data.z`).

Usage:
    python -I -X utf8 is3.py <data.z> <outdir>      extract every file
    python -I -X utf8 is3.py <data.z>               list the contents

Archive layout (worked out 2026-11-08 from the Plus Dash CD):
    header  u32 0x8C655D13, ..., +0x0C u16 file count, +0x12 u32 archive size,
            +0x29 u32 offset of the table of contents, +0x31 u16 directory count
    TOC     directories: u16 file count, u16 entry length, u16 name length, name
            (entries padded to their length; files are assigned to directories
            in order)
            files: u8 volume flag, u16 directory index, u32 original size,
            u32 compressed size, u32 data offset, u16 DOS date, u16 DOS time,
            u32 attributes, u16 entry length, u32 unknown, u8 name length, name
    data    each file is a PKWARE DCL "implode" stream (decoded by `blast` below)

`blast` is a Python port of Mark Adler's public-domain blast.c (zlib contrib).
"""
import os
import struct
import sys

# --- PKWARE DCL decompression (port of blast.c) ------------------------------

_LITLEN = bytes([11, 124, 8, 7, 28, 7, 188, 13, 76, 4, 10, 8, 12, 10, 12, 10, 8, 23, 8,
                 9, 7, 6, 7, 8, 7, 6, 55, 8, 23, 24, 12, 11, 7, 9, 11, 12, 6, 7, 22, 5,
                 7, 24, 6, 11, 9, 6, 7, 22, 7, 11, 38, 7, 9, 8, 25, 11, 8, 11, 9, 12,
                 8, 12, 5, 38, 5, 38, 5, 11, 7, 5, 6, 21, 6, 10, 53, 8, 7, 24, 10, 27,
                 44, 253, 253, 253, 252, 252, 252, 13, 12, 45, 12, 45, 12, 61, 12, 45,
                 44, 173])
_LENLEN = bytes([2, 35, 36, 53, 38, 23])
_DISTLEN = bytes([2, 20, 53, 230, 247, 151, 248])
_BASE = [3, 2, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 40, 72, 136, 264]
_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]
_MAXBITS = 13


def _construct(rep, n):
    length = []
    for b in rep:
        length += [b & 15] * ((b >> 4) + 1)
    length = length[:n]
    count = [0] * (_MAXBITS + 1)
    for ln in length:
        count[ln] += 1
    offs = [0] * (_MAXBITS + 1)
    for ln in range(1, _MAXBITS):
        offs[ln + 1] = offs[ln] + count[ln]
    symbol = [0] * n
    for sym, ln in enumerate(length):
        if ln:
            symbol[offs[ln]] = sym
            offs[ln] += 1
    return count, symbol


_LIT = _construct(_LITLEN, 256)
_LEN = _construct(_LENLEN, 16)
_DIST = _construct(_DISTLEN, 64)


class _Bits:
    def __init__(self, data):
        self.data, self.pos, self.buf, self.cnt = data, 0, 0, 0

    def bits(self, need):
        while self.cnt < need:
            if self.pos >= len(self.data):
                raise EOFError('ran out of input')
            self.buf |= self.data[self.pos] << self.cnt
            self.pos += 1
            self.cnt += 8
        v = self.buf & ((1 << need) - 1)
        self.buf >>= need
        self.cnt -= need
        return v

    def decode(self, table):
        count, symbol = table
        code = first = index = 0
        for ln in range(1, _MAXBITS + 1):
            code |= self.bits(1) ^ 1          # codes are stored inverted
            c = count[ln]
            if code - c < first:
                return symbol[index + (code - first)]
            index += c
            first += c
            first <<= 1
            code <<= 1
        raise ValueError('bad Huffman code')


def blast(data):
    s = _Bits(data)
    lit = s.bits(8)
    if lit > 1:
        raise ValueError('bad literal flag')
    dictbits = s.bits(8)
    if not 4 <= dictbits <= 6:
        raise ValueError('bad dictionary size')
    out = bytearray()
    while True:
        if s.bits(1):
            sym = s.decode(_LEN)
            length = _BASE[sym] + s.bits(_EXTRA[sym])
            if length == 519:
                break
            sym = 2 if length == 2 else dictbits
            dist = (s.decode(_DIST) << sym) + s.bits(sym) + 1
            if dist > len(out):
                raise ValueError('distance too far back')
            start = len(out) - dist
            for k in range(length):
                out.append(out[start + k])
        else:
            out.append(s.decode(_LIT) if lit else s.bits(8))
    return bytes(out)


# --- archive -------------------------------------------------------------------

def read_toc(d):
    if struct.unpack_from('<I', d, 0)[0] != 0x8C655D13:
        raise ValueError('not an InstallShield 3 archive')
    nfiles = struct.unpack_from('<H', d, 0x0C)[0]
    toc = struct.unpack_from('<I', d, 0x29)[0]
    ndirs = struct.unpack_from('<H', d, 0x31)[0]
    p = toc
    dirs = []
    for _ in range(ndirs):
        count, elen, nlen = struct.unpack_from('<HHH', d, p)
        dirs.append((d[p + 6:p + 6 + nlen].decode('cp932'), count))
        p += elen
    files = []
    for _ in range(nfiles):
        _, dir_i, size, csize, off, date, time, attr, elen = struct.unpack_from('<BHIIIHHIH', d, p)
        nlen = d[p + 29]
        name = d[p + 30:p + 30 + nlen].decode('cp932')
        files.append({'dir': dirs[dir_i][0], 'name': name, 'size': size, 'csize': csize,
                      'offset': off, 'date': date, 'time': time})
        p += elen
    return dirs, files


def main():
    d = open(sys.argv[1], 'rb').read()
    dirs, files = read_toc(d)
    if len(sys.argv) < 3:
        for f in files:
            print(f"{f['dir'] + '/' if f['dir'] else ''}{f['name']:20s} {f['size']:9d} {f['csize']:9d}")
        return
    ok = bad = 0
    for f in files:
        data = blast(d[f['offset']:f['offset'] + f['csize']])
        if len(data) != f['size']:
            bad += 1
            print('size mismatch:', f['name'], len(data), f['size'])
        else:
            ok += 1
        path = os.path.join(sys.argv[2], f['dir'], f['name'])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'wb').write(data)
    print(f'{ok} files extracted, {bad} size mismatches')


if __name__ == '__main__':
    main()
