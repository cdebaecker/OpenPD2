"""Import POWER DoLLS 2 plus DASH from your own copy into the engine's data folder.

    python -X utf8 pd2_import.py SOURCE [--out DIR]

SOURCE is any of:
  - the CD image: the CloneCD .img (or its .cue / .ccd), or a .iso of the data track;
  - a copy of the CD's files (a folder with data.z);
  - an extracted or installed game folder (Pd2.exe with the pd2/ and dash/ folders).

DIR defaults to Godot's user folder for the engine (user://import):
  Windows %APPDATA%\\Godot\\app_userdata\\OpenPD2\\import, Linux
  ~/.local/share/godot/app_userdata/OpenPD2/import.

Nothing from the game is in this repository: everything comes from SOURCE. The engine
reads, under import/:
  manifest.json                  versions found, source hashes
  tables/<campaign>.json         names; machines, launchers, ammunition as raw records
                                 (base64; the layouts of RULES.md section 0); the crew
                                 table as Pd2.exe starts with it (the computer's pilots)
  <campaign>/missions/mNN.json   mission record, raw INIT (units 27-254, 64 groups), crew
                                 roster + NPC crew (raw), S/M/H layers (base64), text
  <campaign>/maps/mNN.png        the tactical map, 48 x 36 px tiles, odd rows shifted
  palette.json                   the tactical map palette
The format readers are in formats/.
"""
import argparse
import base64
import hashlib
import json
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'formats'))
import gcp       # noqa: E402
import is3       # noqa: E402
import missions  # noqa: E402
import pd2dt     # noqa: E402
import pd2exe    # noqa: E402

KNOWN = json.load(open(os.path.join(HERE, 'versions.json'), encoding='utf-8'))
CAMPAIGNS = ('pd2', 'dash')
TABLE_SET = {'pd2': 'pd2', 'dash': 'dash'}      # the record block each campaign loads (0x409240, by DS:0x554B10)
SECTOR = 2048
SCRIPT_EXITS = {('pd2', 0): 0x519FE8}           # mission 1's load script (0x49A700): 14 exit hexes
GRAPHICS_CHUNK = [0, 1, 2, 5, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]   # 0x482910's local table


def b64(data):
    return base64.b64encode(bytes(data)).decode('ascii')


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


# --- reading the CD ---------------------------------------------------------------

def data_track(path):
    """The 2048-byte sectors of the data track: from a raw 2352-byte Mode 1 image
    (CloneCD .img, BIN) or a cooked .iso."""
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        head = f.read(16)
        raw = head[:12] == b'\x00' + b'\xff' * 10 + b'\x00'
        f.seek(0)
        if not raw:
            return f.read()
        out = bytearray()
        for _ in range(size // 2352):
            s = f.read(2352)
            if s[:12] != head[:12] or s[15] != 1:
                break                       # end of the data track (audio follows)
            out += s[16:16 + SECTOR]
        return bytes(out)


def iso_files(iso):
    """{UPPER PATH: (offset, size)} for every file in an ISO 9660 image."""
    pvd = iso[16 * SECTOR: 17 * SECTOR]
    if pvd[1:6] != b'CD001':
        raise SystemExit('not an ISO 9660 data track')
    files = {}

    def walk(extent, size, prefix):
        data = iso[extent * SECTOR: extent * SECTOR + size]
        i = 0
        while i < len(data):
            n = data[i]
            if n == 0:
                i = (i // SECTOR + 1) * SECTOR
                continue
            rec = data[i:i + n]
            ext, ln, flags, nl = struct.unpack_from('<I', rec, 2)[0], struct.unpack_from('<I', rec, 10)[0], rec[25], rec[32]
            name = rec[33:33 + nl].decode('latin-1').split(';')[0]
            if name not in ('\x00', '\x01'):
                path = prefix + name.upper()
                if flags & 2:
                    walk(ext, ln, path + '/')
                else:
                    files[path] = (ext * SECTOR, ln)
            i += n

    root = pvd[156:190]
    walk(struct.unpack_from('<I', root, 2)[0], struct.unpack_from('<I', root, 10)[0], '')
    return files


def find_image(path):
    if os.path.isdir(path):
        return None
    low = path.lower()
    if low.endswith(('.cue', '.ccd')):
        img = os.path.splitext(path)[0] + '.img'
        if not os.path.exists(img):
            img = os.path.splitext(path)[0] + '.bin'
        return img
    return path


def extract_game(source, work):
    """Pd2.exe, pd2/ and dash/ in a folder: SOURCE itself, or unpacked from data.z."""
    if os.path.isdir(source) and os.path.exists(os.path.join(source, 'Pd2.exe')):
        return source
    if os.path.isdir(source):
        dz = next((os.path.join(source, f) for f in os.listdir(source) if f.lower() == 'data.z'), None)
        if not dz:
            raise SystemExit('no Pd2.exe or data.z in ' + source)
        z = open(dz, 'rb').read()
    else:
        iso = data_track(find_image(source))
        files = iso_files(iso)
        if 'DATA.Z' not in files:
            raise SystemExit('this disc has no DATA.Z: not the POWER DoLLS 2 plus DASH CD')
        off, n = files['DATA.Z']
        z = iso[off:off + n]
    out = os.path.join(work, 'game')
    _, entries = is3.read_toc(z)
    for e in entries:
        data = is3.blast(z[e['offset']:e['offset'] + e['csize']])
        if len(data) != e['size']:
            raise SystemExit('data.z: %s did not unpack cleanly' % e['name'])
        p = os.path.join(out, e['dir'], e['name'])
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'wb').write(data)
    return out


# --- export -----------------------------------------------------------------------

def exe_va(exe, va, n):
    """n bytes of Pd2.exe's initialised data at virtual address va."""
    pe = struct.unpack_from('<I', exe, 0x3C)[0]
    sec = pe + 24 + struct.unpack_from('<H', exe, pe + 20)[0]
    for i in range(struct.unpack_from('<H', exe, pe + 6)[0]):
        _, vs, rva, rs, ro = struct.unpack_from('<8sIIII', exe, sec + 40 * i)
        if 0x400000 + rva <= va and va + n <= 0x400000 + rva + rs:
            return exe[ro + va - 0x400000 - rva: ro + va - 0x400000 - rva + n]
    raise SystemExit('Pd2.exe: 0x%X is not in its initialised data' % va)


CREW_VA = 0x506734          # crew table, 64 x 16 B: 37-63 are the computer's pilots
# The radio's call signs: load_campaign_set (0x409240) copies 39 string pointers to
# DS:0x50C7E5 and the 34 that follow (DS:0x50C881) from the campaign's set; the radio reads
# sign n from the first, past 38 on into the second, so both are exported as one list.
CALL_SIGNS_VA = {'pd2': 0x501728, 'dash': 0x502C90}
CALL_SIGNS = 39 + 34
# The initialised data around the tables the world models, for code that reads past one
# (Pd2World.mem8 / rules.ds_byte fall back to it).
DATA_IMAGE = (0x506600, 0x514000)


def _exe_str(exe, va):
    """The NUL-terminated cp932 string at va in Pd2.exe ('' outside its data)."""
    try:
        exe_va(exe, va, 1)
    except SystemExit:
        return ''
    n = 0
    while n < 64 and exe_va(exe, va + n, 1) != b'\0':
        n += 1
    return exe_va(exe, va, n).decode('cp932', 'replace')


def export_tables(game, out):
    exe = open(os.path.join(game, 'Pd2.exe'), 'rb').read()
    info = pd2exe.read(game)
    os.makedirs(os.path.join(out, 'tables'), exist_ok=True)
    for camp in CAMPAIGNS:
        base = pd2exe.COPIES[TABLE_SET[camp]]
        doc = {
            'machines': [b64(exe[base + 31 * i: base + 31 * (i + 1)]) for i in range(32)],
            'launchers': [b64(exe[base + 0x3E0 + 17 * i: base + 0x3E0 + 17 * (i + 1)]) for i in range(96)],
            'ammo': [b64(exe[base + 0x3E0 + 0x660 + 12 * i: base + 0x3E0 + 0x660 + 12 * (i + 1)]) for i in range(96)],
            'machine_names': [m['name'] for m in info['sets'][TABLE_SET[camp]]['machines']],
            'launcher_names': {l['id']: l['name'] for l in info['sets'][TABLE_SET[camp]]['launchers']},
            'ammo_names': {a['id']: a['name'] for a in info['sets'][TABLE_SET[camp]]['ammunition']},
            'crew_names': info['crew_names'],
            'crew': b64(exe_va(exe, CREW_VA, 64 * 16)),
            'call_signs': [_exe_str(exe, struct.unpack_from('<I', exe_va(exe, CALL_SIGNS_VA[camp] + 4 * i, 4))[0])
                           for i in range(CALL_SIGNS)],
            'data_image': [DATA_IMAGE[0], b64(exe_va(exe, DATA_IMAGE[0], DATA_IMAGE[1] - DATA_IMAGE[0]))],
        }
        with open(os.path.join(out, 'tables', camp + '.json'), 'w', encoding='utf-8') as f:
            json.dump(doc, f, ensure_ascii=False)
    pal = [(exe[0x10C0F8 + 4 * i + 2], exe[0x10C0F8 + 4 * i + 1], exe[0x10C0F8 + 4 * i]) for i in range(16)]
    json.dump({'tactical': pal}, open(os.path.join(out, 'palette.json'), 'w'))
    return pal


def export_missions(game, out, pal):
    count = {}
    exe = open(os.path.join(game, 'Pd2.exe'), 'rb').read()
    for camp in CAMPAIGNS:
        folder = os.path.join(game, camp)
        fs = {f.upper(): os.path.join(folder, f) for f in os.listdir(folder)}

        def pck(name, decode=True):
            data = open(fs[name], 'rb').read()
            res = []
            for c in pd2dt.split_pck(data):
                dc = pd2dt.decode_chunk(c) if decode else None
                res.append(dc if dc is not None else c)
            return res

        recs = pck('SCN_MIS.PCK', decode=False)
        texts = missions.mission_texts(pck('MES.PCK'))
        inits = pck('INIT.PCK')
        npcs = pck('NPC.PCK')
        layers = {k: pck(f'MISSON{k}D.PCK') for k in 'SMHPC'}
        save = open(fs['SAVEDATA.ORG'], 'rb').read()
        roster = save[260:260 + 27 * 16]
        os.makedirs(os.path.join(out, camp, 'missions'), exist_ok=True)
        os.makedirs(os.path.join(out, camp, 'maps'), exist_ok=True)
        # the new game's state: a memory image of DS:0x506638.. (0x47BD B after the
        # "PD2DATA" header, 0x4987C0), crew, combat records, units, groups, the DS block
        json.dump({'base': 0x506638, 'image': b64(save[8:8 + 0x47BD])},
                  open(os.path.join(out, camp, 'save.json'), 'w'))
        for m, rec in enumerate(recs):
            # the loader 0x482910 takes the P / C chunk from a table with the DASH flag
            # (DS:0x554B10 = 0): mission 3 uses chunk 5's graphics (1-based numbers)
            cp = (GRAPHICS_CHUNK[m + 1] - 1) if camp == 'dash' else m
            if len(layers['M'][m]) == 72 * 72 and layers['P'][cp]:
                w, h, img = missions.render_tactical(layers['M'][m], layers['C'][cp], layers['P'][cp])
                gcp.write_png(os.path.join(out, camp, 'maps', f'm{m:02d}.png'), w, h, img, pal)
            doc = {
                'campaign': camp, 'mission': m,
                'record': b64(rec), 'parsed': missions.parse_mission(rec),
                'init': b64(inits[m]) if m < len(inits) else '',
                'roster': b64(roster), 'npc': b64(npcs[m]) if m < len(npcs) else '',
                'S': b64(layers['S'][m]), 'M': b64(layers['M'][m]), 'H': b64(layers['H'][m]),
                'text': {i: t for i, t in texts[m]} if m < len(texts) else {},
            }
            if (camp, m) in SCRIPT_EXITS:            # the mission's load script copies it to 0x519FB0
                va = SCRIPT_EXITS[(camp, m)]
                raw = exe_va(exe, va, 56)
                doc['exits'] = [list(struct.unpack_from('<hh', raw, 4 * i)) for i in range(14)]
            with open(os.path.join(out, camp, 'missions', f'm{m:02d}.json'), 'w', encoding='utf-8') as f:
                json.dump(doc, f, ensure_ascii=False)
        count[camp] = len(recs)
    return count


def export_messages(game, out):
    """The game's message tables, as message_text (0x471A00) reads them: WMES.PCK (the
    battle's, read when DS:0x50663A is set) and MES.PCK (the others), one LZSS entry per
    index (DS:0x50663D - 1), each a list of strings numbered from 0 (Shift-JIS, decoded)."""
    for camp in CAMPAIGNS:
        folder = os.path.join(game, camp)
        fs = {f.upper(): os.path.join(folder, f) for f in os.listdir(folder)}
        doc = {}
        for key, name in (('wmes', 'WMES.PCK'), ('mes', 'MES.PCK')):
            entries = []
            for c in pd2dt.split_pck(open(fs[name], 'rb').read()):
                dc = pd2dt.decode_chunk(c)
                entries.append([t.decode('cp932', 'replace') for t in dc.split(b'\0')] if dc else [])
            doc[key] = entries
        os.makedirs(os.path.join(out, camp), exist_ok=True)
        with open(os.path.join(out, camp, 'messages.json'), 'w', encoding='utf-8') as f:
            json.dump(doc, f, ensure_ascii=False)


def default_out():
    if os.name == 'nt':
        base = os.path.join(os.environ['APPDATA'], 'Godot', 'app_userdata')
    elif sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Application Support/Godot/app_userdata')
    else:
        base = os.path.expanduser('~/.local/share/godot/app_userdata')
    return os.path.join(base, 'OpenPD2', 'import')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('source')
    ap.add_argument('--out', default=default_out())
    a = ap.parse_args()
    with tempfile.TemporaryDirectory() as work:
        game = extract_game(a.source, work)
        h = sha256(os.path.join(game, 'Pd2.exe'))
        version = KNOWN['Pd2.exe'].get(h)
        if not version:
            raise SystemExit('unknown Pd2.exe (SHA-256 %s): only the versions in versions.json are supported' % h)
        os.makedirs(a.out, exist_ok=True)
        pal = export_tables(game, a.out)
        count = export_missions(game, a.out, pal)
        export_messages(game, a.out)
        manifest = {'format': 1, 'version': version, 'pd2_exe_sha256': h, 'missions': count}
        json.dump(manifest, open(os.path.join(a.out, 'manifest.json'), 'w'), indent=1)
    print('imported %s: %s into %s' % (version, count, a.out))


if __name__ == '__main__':
    main()
