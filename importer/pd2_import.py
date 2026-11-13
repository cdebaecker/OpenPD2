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
  ui.json, font_ank.dat          the windows' frame tiles, background and scroll bar (from
                                 Pd2.exe), the 8 px font
  images/, <campaign>/images/    the screens' pictures (PAC entries as BMP)
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
# The command menu's entries 0-10 (DS:0x517EF0, unit_command_menu 0x4EE8D0).
SCRIPT_CHOICES.update({0x517EF0: 11})
PLAN_TEXTS = {0x50E029, 0x50E032, 0x50E03B, 0x50E046, 0x50E053, 0x50E060, 0x514BB8, 0x514AA4, 0x514A98}
# ... and its notes (0x46D780, the pickers 0x4985A0 / 0x4983A0, the save 0x497F60 and the
# slot's header line 0x498070).
TITLE_TEXTS = {0x518A08, 0x517448, 0x5174F8, 0x5174D8, 0x517490, 0x5174AC, 0x517474, 0x517458,
               0x517508, 0x517534, 0x517560, 0x51759C, 0x517574, 0x5175C8, 0x517644, 0x517664,
               0x519EB0, 0x519F24, 0x519F44, 0x519ED8, 0x519EE8, 0x519EF0, 0x519F0C,
               0x50CBF2, 0x50CBFB, 0x50CC04, 0x50CBD1,
               # the battle's system menu 0x4847C0: its entries (DS:0x518224..), the save's and load's
               # notes (0x477220 / 0x477370 / 0x477EB0: format and verbs) and KEMURI's (0x484160)
               0x518224, 0x51823C, 0x518250, 0x518264, 0x518278, 0x51828C, 0x5182A0, 0x5182B0,
               0x5178E0, 0x5178EC, 0x5179AC, 0x517990, 0x517978, 0x517988, 0x518154, 0x5181AC}

# The radio's call signs: load_campaign_set (0x409240) copies 39 string pointers to
# DS:0x50C7E5 and the 34 that follow (DS:0x50C881) from the campaign's set; the radio reads
# sign n from the first, past 38 on into the second, so both are exported as one list.
CALL_SIGNS_VA = {'pd2': 0x501728, 'dash': 0x502C90}
CALL_SIGNS = 39 + 34
CAMPAIGN_SET_VA = {'pd2': 0x5011A8, 'dash': 0x502710}    # the set's name tables (pd2exe.NAME_TABLES)
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
EXE_TEXTS = (0x5104E0, 0x5104EC, 0x5104F8, 0x5171DC, 0x5171E0, 0x5171E4, 0x5171E8, 0x5171EC, 0x5171F0, 0x4FD030, 0x519E84, 0x515D38, 0x519728, 0x51975C, 0x519780, 0x5197B8, 0x519810, 0x519814, 0x519818, 0x519850, 0x5198A0, 0x5198D8, 0x5198DC, 0x5198FC, 0x519930, 0x519968, 0x51996C, 0x519970, 0x519974, 0x519978, 0x51997C, 0x519980, 0x5199E0, 0x519A40, 0x519A5C, 0x519A84, 0x516728, 0x5157A8, 0x5156C0, 0x51FB18, 0x51FB20, 0x51FB28, 0x51FB30, 0x51F8C8, 0x51F8E0, 0x51F8F8, 0x510474, 0x51047C, 0x510488, 0x510494, 0x5104A0, 0x5104B4, 0x5104C8, 0x5104D4,
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
             0x514008, 0x514018, 0x514028, 0x514038, 0x514048, 0x514058, 0x514068, 0x514078,
             # the machine status window (0x4E8930: a slot's count -1; 0x467880: a skill
             # held or not, a hidden name)
             0x51F6C0, 0x50CBB3, 0x50CBB6, 0x50CBE0,
             # the reaction menu (0x472ED0): its two entries and a unit's row
             0x517838, 0x517850, 0x517860,
             # the command menu (unit_command_menu 0x4EE8D0): carry / release (0x4DDF70 picks one)
             0x517F20, 0x517F2E,
             # the info panel's weapon list (0x466DF0): blank, "--------", COVER UP, STACK, CARRY
             0x516F48, 0x516F30, 0x516F54, 0x516F60, 0x516F6C,
             # the new campaign's pilot choice (0x422050): the count lines, the list's header,
             # the questions and notes (PD2 / DASH)
             0x513A64, 0x513A80, 0x513A9C, 0x513AF0, 0x513B00, 0x513B18, 0x513B2C, 0x513B44,
             0x513B5C, 0x513B8C, 0x513BA8, 0x513BD8,
             # the debrief's results (0x495B70): the header, its rule, the states
             0x519AF8, 0x519B34, 0x519B88, 0x519B7C, 0x519BA0, 0x519B94, 0x519BC4, 0x519BB0, 0x519BB8) + tuple(sorted(SCRIPT_TEXTS)) + tuple(sorted(TITLE_TEXTS)) + tuple(sorted(PLAN_TEXTS))


def _exe_ptr_texts(exe, va, n):
    return [struct.unpack_from('<I', exe_va(exe, va + 4 * i, 4))[0] for i in range(n)]


def _exe_str(exe, va):
    """The NUL-terminated cp932 string at va in Pd2.exe ('' outside its data)."""
    try:
        exe_va(exe, va, 1)
    except SystemExit:
        return ''
    n = 0
    while n < 160 and exe_va(exe, va + n, 1) != b'\0':
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
            # (the machines' codes, DS:0x50C2E5: the reaction menu's rows, 0x472ED0)
            'machine_codes': [m['code'] for m in info['sets'][TABLE_SET[camp]]['machines']],
            # (the launchers' codes, DS:0x50C0E5: the info panel's weapon list, 0x466DF0)
            'launcher_codes': {l['id']: l['code'] for l in info['sets'][TABLE_SET[camp]]['launchers']},
            # (the launchers' short codes DS:0x50C0E5 and the rounds' codes, the set's +0x400 =
            # DS:0x50C665: the info panel's and the sortie cards' lists)
            'launcher_short': [_exe_str(exe, struct.unpack_from('<I', exe_va(exe, 0x50C0E5 + 4 * i, 4))[0]) for i in range(96)],
            # the pilot data window's branch and rank (0x46B200: DS:0x50C949[crew +0xE >> 5],
            # DS:0x50C909[crew +0xE & 0x1F])
            'branches': [_exe_str(exe, struct.unpack_from('<I', exe_va(exe, 0x50C949 + 4 * i, 4))[0]) for i in range(8)],
            'ranks': [_exe_str(exe, struct.unpack_from('<I', exe_va(exe, 0x50C909 + 4 * i, 4))[0]) for i in range(16)],
            'ammo_long': [_exe_str(exe, struct.unpack_from('<I', exe_va(exe, CAMPAIGN_SET_VA[camp] + 0x280 + 4 * i, 4))[0]) for i in range(96)],
            'ammo_codes': [_exe_str(exe, struct.unpack_from('<I', exe_va(exe, CAMPAIGN_SET_VA[camp] + 0x400 + 4 * i, 4))[0]) for i in range(96)],
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
# The operation plan (0x443F60): its background plan_g.pac (640 x 400), the orders' panel
# plan_gb.pac and the panel it puts back plan_gc.pac (264 x 160 at (0x178, 0xF0)), each
# campaign's mini-maps mmap.pac (144 x 144, by chunk: the pages' blinks).
# The battle's machine status window (0x467880): the damage diagrams hidan.pac (by machine
# +0x19, 0-7); its info panel (0x466790): the pilots' faces dface.pac and each campaign's
# machine pictures datau.pac (by machine +0x19).
# The battle's info panel (0x4830E0): hex_g.pac (208 x 400).
SHARED_IMAGES = ('ido_g.pac', 'ido_gb.pac', 'evkao.pac', 'event.pac', 'plan_g.pac', 'plan_gb.pac', 'plan_gc.pac',
                 'hidan.pac', 'dface.pac', 'hex_g.pac',
                 # the debrief's score cards (0x468490): the marks, the characters
                 'score_p.pac', 'chara.pac',
                 # the sortie's cards (0x4485E0) and its panel (0x45ED60)
                 'face.pac', 'hensei_g.pac',
                 # the armament screen (0x454E60): its background and the three layouts' panels,
                 # the machines' pictures, the weapons' and empty slots' pictures, the air
                 # machines' second pictures (st07-st12.pac, 0x4561F0) and the slots' blanks
                 'busou_b.pac', 'busou_g0.pac', 'busou_g1.pac', 'busou_g2.pac', 'weapon.pac',
                 'arms.pac', 'blanc.pac', 'st07.pac', 'st08.pac', 'st09.pac', 'st10.pac',
                 'st11.pac', 'st12.pac', 'k_blanc0.pac', 'k_blanc1.pac', 'k_blanc2.pac',
                 # the ending and the credits (0x48FA40): PD2's end0 / staff_g / staff_p, DASH's
                 # staff2_g / staff2_p and the staff roll
                 'end0.pac', 'staff_g.pac', 'staff_p.pac', 'staff2_g.pac', 'staff2_p.pac', 's_roll.pac',
                 # the debrief's new items / recruits screens (kabe0) and DASH's hand-over (op2)
                 'kabe0.pac', 'op2.pac')
CAMPAIGN_IMAGES = ('smap.pac', 'amap.pac', 'mmap.pac', 'datau.pac',
                   # the debrief (0x48FA40): a cleared mission's pictures (by chunk), the failed,
                   # the game over, a single mission's end
                   'm_clr.pac', 'm_fail.pac', 'gameover.pac', 'single.pac',
                   # the score cards' background and the pilots' names
                   'score_g.pac', 'score_n.pac')    # (amap: the operation plan's area maps, 0x444500)


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


# The game's windows (ui_window_create 0x4528B0, drawn by 0x4F0DB0 / 0x4F0C00): the frame's
# eight 8 x 8 tiles in Pd2.exe (5 bytes a row: four colour planes and a mask, 0x4F0AC0),
# top-left, top, top-right, left, right, bottom-left, bottom, bottom-right, and the
# windows' background (DS:0x50C9E8: two rows of four planes repeated, 0x4F0860);
# FONT_ANK.DAT, the 8 px font (8 bytes a character, DS:0x523E80) of 8 px windows.
WINDOW_TILES = ('tl', 'top', 'tr', 'left', 'right', 'bl', 'bottom', 'br')
WINDOW_TILES_VA = 0x51FB78
WINDOW_BACK_VA = 0x50C9E8
# ... and the select windows' scroll bar (0x40B6D0: 27 shapes at DS:0x5129B8, six int32
# each: x0, y0, x1, y1, colour, type 0 line / 1 outline / 2 fill)
SCROLL_VA = 0x5129B8


def _planes(b0, b1, b2, b3, m=0xFF):
    """one 8 px row: the colours 0-15 as 0x4F0AC0 / 0x4F0860 combine the planes"""
    row = []
    for _ in range(8):
        v = ((((((m & b0) >> 1) | (m & b1 & 0xBF)) >> 1 | (m & b2 & 0x9F)) >> 1) | (m & b3 & 0x8F)) & 0xFF
        row.append(v >> 4)
        b0, b1, b2, b3, m = (b0 << 1) & 0xFF, (b1 << 1) & 0xFF, (b2 << 1) & 0xFF, (b3 << 1) & 0xFF, (m << 1) & 0xFF
    return row


def export_ui(game, out):
    exe = open(os.path.join(game, 'Pd2.exe'), 'rb').read()
    tiles = {}
    for k, name in enumerate(WINDOW_TILES):
        raw = exe_va(exe, WINDOW_TILES_VA + 0x28 * k, 0x28)
        tiles[name] = [_planes(*raw[5 * r: 5 * r + 5]) for r in range(8)]
    raw = exe_va(exe, WINDOW_BACK_VA, 8)
    # (0x4F0860 combines the planes as 0x4F0AC0 does without a mask)
    back = [_planes(*raw[0:4]), _planes(*raw[4:8])]
    scroll = [list(struct.unpack('<6i', exe_va(exe, SCROLL_VA + 24 * k, 24))) for k in range(27)]
    # the base screens' window patterns (the sortie DS:0x50D719 / 0x50D721 / 0x50D729 /
    # 0x50D731 / 0x50D739, the plan DS:0x50D699): two rows of four planes each
    patterns = {}
    for va in (0x50D699, 0x50D719, 0x50D721, 0x50D729, 0x50D731, 0x50D739, 0x5156A0, 0x5156A8):
        raw = exe_va(exe, va, 8)
        patterns['%X' % va] = [_planes(*raw[0:4]), _planes(*raw[4:8])]
    # the sortie screen's 79 click regions (DS:0x515FC8: x0, y0, x1, y1, type; 0x45ED60)
    raw = exe_va(exe, 0x515FC8, 79 * 20)
    sortie_regions = [list(struct.unpack_from('<5i', raw, 20 * i)) for i in range(79)]
    # the armament screen's regions by layout (0x454E60 hands them to 0x438210 as they are:
    # 18 bytes each, x0, y0, x1, y1, type, colour): ground 25, armoured 9, air 12
    equip_regions = []
    for va, n in ((0x515358, 25), (0x515520, 9), (0x5155C8, 12)):
        raw = exe_va(exe, va, 18 * n)
        equip_regions.append([list(struct.unpack_from('<4iB', raw, 18 * i)) for i in range(n)])
    # other screens' 16 window colours (0x487120's tables, B, G, R, pad): the debrief's
    # kabe0 screens DS:0x518F48
    pals = {}
    for va in (0x518F48,):
        raw = exe_va(exe, va, 64)
        pals['%X' % va] = [[raw[4 * i + 2], raw[4 * i + 1], raw[4 * i]] for i in range(16)]
    json.dump({'frame': tiles, 'back': back, 'scroll': scroll, 'patterns': patterns, 'palettes': pals,
               'sortie_regions': sortie_regions, 'equip_regions': equip_regions},
              open(os.path.join(out, 'ui.json'), 'w'))
    fs = {f.lower(): os.path.join(game, f) for f in os.listdir(game)}
    if 'font_ank.dat' in fs:
        open(os.path.join(out, 'font_ank.dat'), 'wb').write(open(fs['font_ank.dat'], 'rb').read())


# The map window's pieces (redraw_hex 0x4F2xxx): the unit sprites (get_unit_addr 0x4F1390:
# MUNIT.PCK by machine kind < 8, TUNIT.PCK by kind - 8, HUNIT.SLD's blocks for the kinds
# above; 0xC00 bytes each: six facings of 0x200, a mask plane and three colour planes of
# 32 x 32), the smoke's pattern KIRI.SLD (36 x 48, a mask and three planes); and Pd2.exe's
# bitmaps: the hex mark DS:0x518CE8 (47 x 48, 0x48EBA0), the small digits DS:0x518CA8 (4 x
# 5, 0x48E640), the large DS:0x518C60 (8 x 7, 0x48E480), the cover / carry icons
# DS:0x518CE0 (8 x 5, 0x48E800), the mine and strike marks DS:0x518E08 (two of 0x60: 12 x
# 16, 0x48ECA0).
def export_map_pieces(game, out):
    exe = open(os.path.join(game, 'Pd2.exe'), 'rb').read()
    doc = {'hexmark': b64(exe_va(exe, 0x518CE8, 47 * 6)), 'digits': b64(exe_va(exe, 0x518CA8, 50)),
           'digits_large': b64(exe_va(exe, 0x518C60, 70)), 'icons': b64(exe_va(exe, 0x518CE0, 5)),
           'marks': b64(exe_va(exe, 0x518E08, 0xC0))}
    json.dump(doc, open(os.path.join(out, 'map_pieces.json'), 'w'))
    for camp in CAMPAIGNS:
        folder = os.path.join(game, camp)
        fs = {f.upper(): os.path.join(folder, f) for f in os.listdir(folder)}
        units = {}
        for key, name in (('m', 'MUNIT.PCK'), ('t', 'TUNIT.PCK')):
            units[key] = [b64(pd2dt.decode_chunk(c) or b'') for c in pd2dt.split_pck(open(fs[name], 'rb').read())] if name in fs else []
        h = pd2dt.decode_chunk(open(fs['HUNIT.SLD'], 'rb').read()) if 'HUNIT.SLD' in fs else b''
        units['h'] = [b64(h[i:i + 0xC00]) for i in range(0, len(h or b''), 0xC00)]
        k = pd2dt.decode_chunk(open(fs['KIRI.SLD'], 'rb').read()) if 'KIRI.SLD' in fs else b''
        units['kiri'] = b64(k or b'')
        json.dump(units, open(os.path.join(out, camp, 'units.json'), 'w'))


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
        export_ui(game, a.out)
        export_map_pieces(game, a.out)
        manifest = {'format': 1, 'version': version, 'pd2_exe_sha256': h, 'missions': count}
        json.dump(manifest, open(os.path.join(a.out, 'manifest.json'), 'w'), indent=1)
    print('imported %s: %s into %s' % (version, count, a.out))


if __name__ == '__main__':
    main()
