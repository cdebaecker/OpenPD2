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
import pac       # noqa: E402

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
# The mission scripts' own words: the unit menu's entry 11 (the menu hooks of table
# 0x51EF18 point DS:0x517F1C at it) and the scripts' choice lists (pointer arrays at
# DS:0x517F78 ..., resolved at import).
SCRIPT_TEXTS = {0x51A020, 0x51A368, 0x51A4E8, 0x51A6B0, 0x51A770, 0x51A7B8, 0x51AB38, 0x51AB48, 0x51B0F0, 0x51AEC8, 0x51BAC0, 0x51C4E8, 0x51CAF0, 0x51CB00, 0x51D240, 0x51D250, 0x51D598,   # the menu entries
                0x510444, 0x51044C, 0x510454, 0x51045C,   # ui_message_box's buttons
                0x51A6C0, 0x51A6D4,                       # lines shown by 0x4521C0
                0x51AEFC,                                 # questions shown by 0x43BA20
                0x51C8AC, 0x51C8BC,                       # mission 14's "Bad condition" lines
                0x51D6B0, 0x51C7A4,                       # mission 18's and DASH 13's "no members left"
                0x51C6F0, 0x51C728, 0x51C730, 0x51C788,   # DASH 13's menu entry and talk lines
                0x51E1E8, 0x51E200, 0x51E210, 0x51E220, 0x51E230,   # DASH 9's menu entry, its questions' labels
                0x51D838, 0x51D848, 0x51D864, 0x51D87C, 0x51D894, 0x51D8AC,   # DASH 8's menu entries, the survey's choices
                0x51F224, 0x51F230, 0x51F23C,             # DASH 8 / 10's squad names (DS:0x51F218)
                0x51E848, 0x51E858, 0x51E908, 0x51E928, 0x51E894, 0x51E8AC, 0x51E8CC, 0x51E8EC,
                0x51E948, 0x51E964,                       # DASH 10's menu entries and labels
                0x51EAA8, 0x51EAB8}                       # script 22's menu entries
SCRIPT_CHOICES = {0x517F78: 2, 0x517F80: 2, 0x517F88: 2, 0x50CBC1: 2, 0x50CBB9: 2, 0x51AD78: 3, 0x51E840: 2}   # pointers each (MissionScripts.CHOICES)
# The title (0x487D70 / 0x46D780, core/title.gd): its list (DS:0x50D86C: start the campaign,
# scenario select, rescue mission), the data question (0x5173A0), the missions' names by
# number (0x50CB4E, 23 pointers: the scenario list, the save's name), the sortie's system
# menu (0x50D70D: abort the operation, save, load).
SCRIPT_CHOICES.update({0x50D86C: 3, 0x5173A0: 2, 0x50CB4E: 23, 0x50D70D: 3})
# The operation plan (0x443F60, core/plan.gd): the objective dialog's buttons (DS:0x50E06D),
# the directions (0x50E009), the sites (0x50E075) and the plan types' names (0x50C965, the
# record entries' +0: 18 in use); its titles, the site question and the XMS box's lines.
SCRIPT_CHOICES.update({0x50E06D: 2, 0x50E009: 8, 0x50E075: 8, 0x50C965: 18})
PLAN_TEXTS = {0x50E029, 0x50E032, 0x50E03B, 0x50E046, 0x50E053, 0x50E060, 0x514BB8, 0x514AA4, 0x514A98}
# ... and its notes (0x46D780, the pickers 0x4985A0 / 0x4983A0, the save 0x497F60 and the
# slot's header line 0x498070).
TITLE_TEXTS = {0x518A08, 0x517448, 0x5174F8, 0x5174D8, 0x517490, 0x5174AC, 0x517474, 0x517458,
               0x517508, 0x517534, 0x517560, 0x51759C, 0x517574, 0x5175C8, 0x517644, 0x517664,
               0x519EB0, 0x519F24, 0x519F44, 0x519ED8, 0x519EE8, 0x519EF0, 0x519F0C,
               0x50CBF2, 0x50CBFB, 0x50CC04}

# The radio's call signs: load_campaign_set (0x409240) copies 39 string pointers to
# DS:0x50C7E5 and the 34 that follow (DS:0x50C881) from the campaign's set; the radio reads
# sign n from the first, past 38 on into the second, so both are exported as one list.
CALL_SIGNS_VA = {'pd2': 0x501728, 'dash': 0x502C90}
CALL_SIGNS = 39 + 34
# The initialised data around the tables the world models, for code that reads past one
# (Pd2World.mem8 / rules.ds_byte fall back to it), up to the end of the initialised data:
# it holds the mission scripts' tables too (charge points, layouts, broken tiles ...).
DATA_IMAGE = (0x506600, 0x523000)
# ... and the zeroed data after it (BSS) up to 0x526000, which the scripts use too (mission 18's
# zone counters at DS:0x5242F0, the inits' tables at DS:0x5242A0 ...).
BSS_END = 0x526000
# Pd2.exe's own texts the screens print (not in MES / WMES): the sortie's bulk menu
# (0x462390's lists at DS:0x50D6E1 / 0x50D6ED / 0x50D6F9), the armament screen's template
# menu (0x454E60's right button, 0x45A700), the flight window's and the counter-battery
# pickers' words. GameData.exe_text, exe.csv.
EXE_TEXTS = (0x510474, 0x51047C, 0x510488, 0x510494, 0x5104A0, 0x5104B4, 0x5104C8, 0x5104D4,
             0x51571C, 0x51572C, 0x51573C, 0x515B18, 0x515B44, 0x515B64, 0x515B7C, 0x515B90,
             0x515B9C, 0x515BA8, 0x515BB4, 0x515BC4, 0x515BD0, 0x515BDC, 0x515C0C, 0x515C1C,
             0x515C40, 0x515C6C, 0x515CAC, 0x515CC8, 0x515CEC,
             # the flight window's status list (0x43E9D0): the types, the states
             0x514864, 0x51486C, 0x514874, 0x51487C, 0x514884, 0x514888, 0x514890, 0x514898,
             0x5148A4, 0x5148AC,
             # the counter-battery pickers (0x4E3230's states, 0x4E0450's slot states, kinds
             # and the accuracy of a launcher without one)
             0x51F3B8, 0x51F3C0, 0x51F3C8, 0x51F3D0, 0x51F6B4, 0x51F6B8, 0x51F6BC, 0x50CBAA,
             0x50CBE1,
             # the slot menu's (0x427530) and the pocket menu's (0x427FF0) entries
             0x514008, 0x514018, 0x514028, 0x514038, 0x514048, 0x514058, 0x514068, 0x514078) + tuple(sorted(SCRIPT_TEXTS)) + tuple(sorted(TITLE_TEXTS)) + tuple(sorted(PLAN_TEXTS))


def _exe_ptr_texts(exe, va, n):
    return [struct.unpack_from('<I', exe_va(exe, va + 4 * i, 4))[0] for i in range(n)]


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


def _map_chg(game, camp):
    """MAP_CHG.PCK (DASH's tidal flats, mission 17's 0x4C4B70): its raw entries, the T bytes
    of rows 0x24-0x46 for each tide level."""
    folder = os.path.join(game, camp)
    fs = {f.upper(): os.path.join(folder, f) for f in os.listdir(folder)}
    if 'MAP_CHG.PCK' not in fs:
        return []
    return [b64(e) for e in pd2dt.split_pck(open(fs['MAP_CHG.PCK'], 'rb').read())]


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
            'data_image': [DATA_IMAGE[0], b64(exe_va(exe, DATA_IMAGE[0], DATA_IMAGE[1] - DATA_IMAGE[0])
                                              + bytes(BSS_END - DATA_IMAGE[1]))],
            'exe_text': {'%X' % va: _exe_str(exe, va) for va in EXE_TEXTS + tuple(
                p for c, n in SCRIPT_CHOICES.items() for p in _exe_ptr_texts(exe, c, n))},
            'script_choices': {'%X' % c: ['%X' % p for p in _exe_ptr_texts(exe, c, n)] for c, n in SCRIPT_CHOICES.items()},
            'map_chg': _map_chg(game, camp),
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
        # with the armament screen's registers as shipped (REG_UNIT.DAT, 0x186 B read to
        # DS:0x50CCEA by 0x454E60; the engine keeps the player's in user://<campaign>/)
        reg = open(fs['REG_UNIT.DAT'], 'rb').read() if 'REG_UNIT.DAT' in fs else b''
        json.dump({'base': 0x506638, 'image': b64(save[8:8 + 0x47BD]), 'reg_unit': b64(reg)},
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
    index (DS:0x50663D - 1), each a list of strings numbered from 0 (Shift-JIS, decoded);
    and RMES.SLD (one LZSS block: the debrief's texts, which 0x4719D0 loads for 0x48FA40);
    MES0.SLD (one block: the title's notes)."""
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
        if 'RMES.SLD' in fs:
            dc = pd2dt.decode_chunk(open(fs['RMES.SLD'], 'rb').read())
            doc['rmes'] = [t.decode('cp932', 'replace') for t in dc.split(b'\0')] if dc else []
        if 'MES0.SLD' in fs:          # the title's notes (0x471990 loads it; message_text reads it there)
            dc = pd2dt.decode_chunk(open(fs['MES0.SLD'], 'rb').read())
            doc['mes0'] = [t.decode('cp932', 'replace') for t in dc.split(b'\0')] if dc else []
        os.makedirs(os.path.join(out, camp), exist_ok=True)
        with open(os.path.join(out, camp, 'messages.json'), 'w', encoding='utf-8') as f:
            json.dump(doc, f, ensure_ascii=False)


# The flight window (0x43E510, the radar screen): its background ido_g.pac, each
# campaign's mission maps smap.pac (one per chunk, 360 x 360: the 15 x 15 grid of 24 px),
# the counters KOMA.DAT (26 tiles of 8 x 8, four bit planes, 0x43FB20); the radio's talk
# windows (0x488DE0): portraits Evkao.pac (128 x 128) and Event.pac (256 x 128).
SHARED_IMAGES = ('ido_g.pac', 'ido_gb.pac', 'evkao.pac', 'event.pac')
CAMPAIGN_IMAGES = ('smap.pac', 'amap.pac')    # (amap: the operation plan's area maps, 0x444500)


def export_images(game, out):
    """The PAC images above, each entry its own BMP (the game's 8-bit DIBs as they are):
    images/<pac>/NN.bmp, <campaign>/images/<pac>/NN.bmp; KOMA.DAT as <campaign>/koma.dat."""
    def write(folder, name):
        fs = {f.lower(): os.path.join(folder, f) for f in os.listdir(folder)}
        if name not in fs:
            return []
        return pac.split_pac(open(fs[name], 'rb').read())

    def save(dst, entries):
        os.makedirs(dst, exist_ok=True)
        for i, b in enumerate(entries):
            if b:
                open(os.path.join(dst, '%02d.bmp' % i), 'wb').write(b)
    for name in SHARED_IMAGES:
        save(os.path.join(out, 'images', name[:-4]), write(game, name))
    for camp in CAMPAIGNS:
        folder = os.path.join(game, camp)
        for name in CAMPAIGN_IMAGES:
            save(os.path.join(out, camp, 'images', name[:-4]), write(folder, name))
        fs = {f.lower(): os.path.join(folder, f) for f in os.listdir(folder)}
        if 'koma.dat' in fs:
            open(os.path.join(out, camp, 'koma.dat'), 'wb').write(open(fs['koma.dat'], 'rb').read())


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
        export_images(game, a.out)
        manifest = {'format': 1, 'version': version, 'pd2_exe_sha256': h, 'missions': count}
        json.dump(manifest, open(os.path.join(a.out, 'manifest.json'), 'w'), indent=1)
    print('imported %s: %s into %s' % (version, count, a.out))


if __name__ == '__main__':
    main()
