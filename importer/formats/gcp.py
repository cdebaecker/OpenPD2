"""Kogado PC-98 .GCP image decoder (Advanced POWER DoLLS 2).

Reverse-engineered from the GRCG blitter in INST.EXE (code 0x9398 / 0x943b).

Header
  0   u8   flags: low nibble = GRCG plane-disable mask (bit set = plane not
           read, previous byte reused); bit 7 = RMW/transparent mode
  1   u8   width in bytes (x8 pixels)
  2   u16  height in lines
  4   4B   transparent key pattern (RMW mode only)
  8   u8   length of the extra block that follows (0x22 = 34)
  9   u16  (unknown; default position?)
  11  16 x u16 palette: (index << 12) | (G << 8) | (R << 4) | B, 4 bits each
  9+len    pixel stream
  Post-pass: (flags >> 4) & 3 rounds of vertical XOR (row ^= row above),
  over the image width, on every enabled plane.

Pixel stream (VRAM byte addressing, stride 80 bytes = 640 px)
  Phase 1, repeated per colour layer:
    tile    one byte per enabled plane, order B R G I
    codes   c >= 0x80          : skip c-0x80 bytes, write 1 byte of tile
            c <  0x7D          : skip (c << 8 | next) bytes, write 1 byte
            c == 0x7D, n       : run of N+2 bytes of tile, where
                                 N = n-0x80 if n >= 0x7D else (n << 8 | next)
            c == 0x7E          : end of layer; position resets, next tile
            c == 0x7F          : go to phase 2
  Phase 2, literal bytes, position reset to start:
            c >= 0x80 skip c-0x80 / c < 0x7F skip (c << 8 | next),
            then a tile (own 4-plane pattern) for that single byte
            c == 0x7F          : end
"""
import struct

STRIDE = 80


def parse_header(d):
    flags, wbytes, height = d[0], d[1], struct.unpack_from('<H', d, 2)[0]
    key = d[4:8]
    extra = d[8]
    pal = []
    for k in range(16):
        v = struct.unpack_from('<H', d, 11 + 2 * k)[0]
        pal.append(((v >> 4) & 15, (v >> 8) & 15, v & 15, v >> 12))  # R, G, B, idx
    return dict(flags=flags, wbytes=wbytes, height=height, key=key,
                field9=struct.unpack_from('<H', d, 9)[0], palette=pal, data=9 + extra)


def xor_rows(planes, h):
    """Vertical XOR delta: (flags >> 4) & 3 passes over enabled planes (INST.EXE 0x8eb1)."""
    w, ht, mask = h['wbytes'], h['height'], h['flags'] & 0x0F
    for _ in range((h['flags'] >> 4) & 3):
        for p in range(4):
            if mask & (1 << p):
                continue
            pl = planes[p]
            for y in range(1, ht):
                o = y * STRIDE
                for x in range(w):
                    pl[o + x] ^= pl[o + x - STRIDE]


def decode(d):
    h = parse_header(d)
    mask = h['flags'] & 0x0F
    rows = h['height'] + 2
    planes = [bytearray(STRIDE * rows) for _ in range(4)]   # B R G I
    size = STRIDE * rows
    tile = [0, 0, 0, 0]
    si = h['data']

    def read_tile(si):
        for p in range(4):
            if not mask & (1 << p):
                tile[p] = d[si]; si += 1
            else:
                tile[p] = tile[p - 1] if p else tile[0]  # GRCG reuses last value written
        return si

    def put(di):
        if 0 <= di < size:
            for p in range(4):
                if not mask & (1 << p):      # GRCG does not write disabled planes
                    planes[p][di] = tile[p]

    # phase 1
    while True:
        di = 0
        si = read_tile(si)
        while True:
            c = d[si]; si += 1
            if c == 0x7E:
                break
            if c == 0x7F:
                break
            if c == 0x7D:
                n = d[si]; si += 1
                if n >= 0x7D:
                    cnt = n - 0x80
                else:
                    cnt = (n << 8) | d[si]; si += 1
                for _ in range(cnt + 2):
                    put(di); di += 1
                continue
            if c >= 0x80:
                di += c - 0x80
            else:
                di += (c << 8) | d[si]; si += 1
            put(di); di += 1
        if c == 0x7F:
            break
    # phase 2
    di = 0
    while True:
        c = d[si]; si += 1
        if c == 0x7F:
            break
        if c >= 0x80:
            di += c - 0x80
        else:
            di += (c << 8) | d[si]; si += 1
        si = read_tile(si)
        put(di); di += 1
    xor_rows(planes, h)
    return h, planes, si


def to_indexed(h, planes):
    w, ht = h['wbytes'] * 8, h['height']
    px = bytearray(w * ht)
    for y in range(ht):
        for xb in range(h['wbytes']):
            o = y * STRIDE + xb
            b, r, g, i = (planes[p][o] for p in range(4))
            for bit in range(8):
                m = 0x80 >> bit
                px[y * w + xb * 8 + bit] = ((b & m) and 1) | ((r & m) and 2) | ((g & m) and 4) | ((i & m) and 8)
    return w, ht, px


def palette_rgb(h, order='RGB'):
    out = [(0, 0, 0)] * 16
    for r, g, b, idx in h['palette']:
        out[idx] = (r * 17, g * 17, b * 17)
    return out


def write_png(path, w, h, px, pal):
    import zlib
    raw = b''.join(b'\0' + bytes(px[y * w:(y + 1) * w]) for y in range(h))
    def chunk(t, data):
        c = struct.pack('>I', len(data)) + t + data
        return c + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 3, 0, 0, 0))
    png += chunk(b'PLTE', b''.join(bytes(c) for c in pal))
    png += chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


# --- Sprite chunks inside .PCK (faces, characters, weapons, map tiles) --------
#   0  u32  pixel bytes = ceil(w*h/2)
#   4  u16  x, u16 y   (position on the source sheet / screen)
#   8  u16  w, u16 h
#   12      LZSS stream (same codec as .SLD) -> pixel bytes
# Pixels are planar per 8-pixel group: 4 bytes B, R, G, I (MSB = leftmost).
# No palette is stored: the game draws them over a screen whose .GCP set it.

def is_sprite(d):
    if len(d) < 12:
        return False
    sz = struct.unpack_from('<I', d, 0)[0]
    w, h = struct.unpack_from('<HH', d, 8)
    return w > 0 and h > 0 and w % 8 == 0 and (w * h + 1) // 2 == sz


def decode_sprite(d, lzss):
    sz = struct.unpack_from('<I', d, 0)[0]
    x, y, w, h = struct.unpack_from('<4H', d, 4)
    b = lzss(d[12:])
    if len(b) != sz:
        raise ValueError(f'sprite: got {len(b)} bytes, expected {sz}')
    wb = w // 8
    px = bytearray(w * h)
    for yy in range(h):
        for xb in range(wb):
            o = (yy * wb + xb) * 4
            pb, pr, pg, pi = b[o], b[o + 1], b[o + 2], b[o + 3]
            base = yy * w + xb * 8
            for bit in range(8):
                m = 0x80 >> bit
                px[base + bit] = ((pb & m) and 1) | ((pr & m) and 2) | ((pg & m) and 4) | ((pi & m) and 8)
    return dict(x=x, y=y, w=w, h=h), px


def is_gcp(d):
    return len(d) >= 43 and d[8] == 0x22 and 0 < d[1] <= 80 and 0 < struct.unpack_from('<H', d, 2)[0] <= 400
