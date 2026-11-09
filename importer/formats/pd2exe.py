"""POWER DoLLS 2 plus DASH (Windows) -- game tables from Pd2.exe and the campaign saves.

Usage:
    python -I -X utf8 pd2exe.py <dir with Pd2.exe, pd2/, dash/> <outdir>

Writes <outdir>/tables.json with names, machines, launchers, ammunition (one set
per table copy) and the starting crew roster of each campaign.

Layout (2026-11-08; Pd2.exe is MSVC 5 / PE32, image base 0x400000; offsets below
are file offsets):

Names
    0x10A0B5  master pointer table (unaligned): 0-37 given names, 38-75 family
              names, 76-171 launcher names (96 slots), 172- launcher codes
    0x0FF5A8  (VA 0x5011A8) the pd2 set's name tables (see below)
Records (same layouts as Advanced PC-98 unless noted). There are three copies
of the machine / launcher / ammunition block. 0x409240 copies one set into the
working copy by the campaign flag DS:0x554B10, which also picks the data folder
(0x408BE0: flag 1 = folder pd2, 0 = folder dash):
    0x0FE6E8  pd2 set,  flag 1 (F224, TS3, M2IC, M150 trailer: matches the Data Book)
    0x0FFC50  dash set, flag 0 (PCH50, M103 trailer, M3IC, HA21T)
    0x1091F5  working copy (identical to the dash set in the file)
    with each set its machine names, machine codes and ammunition names (pointer
    tables at VA 0x5011A8 / 0x502710, copied to 0x50C265: +0, +0x80, +0x100).
    each copy: 32 machines x 31 B, then 96 launchers x 17 B (at +0x3E0),
    then 96 ammunition records x 12 B (at +0x3E0 + 0x660).
    Launcher +7 AP load (low 5 bits), +8 AP cost (low 5 bits) and kind (bits 5-7, 2 = missile), +9 class (low 3 bits; 1 = direct fire). Advanced packs these differently.
    Ammunition is 12 B here (11 B in Advanced): +0 rounds, +1 ground attack,
    +2 air attack, +3 range, +4 recon range, +5 recon penetration, rest open.
Crew
    pd2/SAVEDATA.ORG and dash/SAVEDATA.ORG ("PD2DATA" header): 27 crew records
    x 16 B at offset 260, same layout as Advanced. The DASH roster matches the
    Data Book (pp. 32-39) exactly; the PD2 roster has lower starting values.
Missions
    No per-mission layer tables after "MISSON?D.PCK" (unlike Advanced); each
    campaign has as many map chunks as missions (PD2 10, DASH 12), so mission n
    most likely uses chunk n.                                         [inferred]
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import missions  # noqa: E402  (shared enums and the crew record parser)

COPIES = {'pd2': 0x0FE6E8, 'dash': 0x0FFC50, 'working': 0x1091F5}     # 0x409240
NAME_TABLES = {'pd2': 0x5011A8, 'dash': 0x502710, 'working': 0x50C265}  # VAs, same copy
FILE_FROM_VA = 0x401C00     # .data: file offset = VA - this


class Pe:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        pe = struct.unpack_from('<I', self.d, 0x3C)[0]
        n = struct.unpack_from('<H', self.d, pe + 6)[0]
        opt = pe + 24
        self.base = struct.unpack_from('<I', self.d, opt + 28)[0]
        sec = opt + struct.unpack_from('<H', self.d, pe + 20)[0]
        self.sections = [struct.unpack_from('<8sIIII', self.d, sec + 40 * i) for i in range(n)]

    def v2f(self, va):
        rva = va - self.base
        for _, vs, sva, rs, ro in self.sections:
            if sva <= rva < sva + max(vs, rs):
                return rva - sva + ro
        return None

    def ptr_str(self, file_off):
        va = struct.unpack_from('<I', self.d, file_off)[0]
        f = self.v2f(va)
        if f is None:
            return None
        return self.d[f:f + 40].split(b'\0')[0].decode('cp932', 'replace')


def names(pe, table, start, count):
    out = []
    for i in range(count):
        s = pe.ptr_str(table + 4 * (start + i))
        out.append(s if s and all(c.isprintable() for c in s) else '')
    return out


def read(src):
    pe = Pe(os.path.join(src, 'Pd2.exe'))
    d = pe.d
    given = names(pe, 0x10A0B5, 0, 38)
    family = names(pe, 0x10A0B5, 38, 38)
    launcher_names = names(pe, 0x10A0B5, 76, 96)
    launcher_codes = names(pe, 0x10A0B5, 172, 96)
    crew_names = [(g, f) for g, f in zip(given, family)]

    sets = {}
    for label, base in COPIES.items():
        nt = NAME_TABLES[label] - FILE_FROM_VA
        machine_names = names(pe, nt, 0, 32)
        machine_codes = names(pe, nt + 0x80, 0, 32)
        ammo_names = names(pe, nt + 0x100, 0, 96)
        machines = []
        for i in range(31):
            e = d[base + 31 * i: base + 31 * (i + 1)]
            machines.append({
                'type': i, 'name': machine_names[i], 'code': machine_codes[i],
                'armor_type': missions.ARMOR_TYPES[e[0] >> 4] if e[0] >> 4 < 5 else e[0] >> 4,
                'category': missions.CATEGORIES[e[0] & 15] if (e[0] & 15) < 10 else e[0] & 15,
                'ground_defense': e[4], 'air_defense': e[5], 'close_combat': e[6],
                'recon_range': e[7], 'recon_penetration': e[8],
                'pockets': e[23], 'mobility_pct': e[24] * 10, 'raw': e.hex(' ')})
        lb = base + 32 * 31
        launchers = []
        for i in range(96):
            e = d[lb + 17 * i: lb + 17 * (i + 1)]
            if not launcher_names[i]:
                continue
            launchers.append({
                'id': i, 'name': launcher_names[i], 'code': launcher_codes[i],
                'ground_accuracy': e[2], 'ground_attack_bonus': e[3], 'range_bonus': e[4],
                'air_accuracy': e[5], 'air_attack_bonus': e[6],
                'ap_load': e[7], 'ap_cost': e[8], 'class_9': e[9],
                'ammo_ids': [x for x in e[10:13] if x != 0xFF],
                'side': 'Zias' if e[14] == 3 else 'Omni', 'raw': e.hex(' ')})
        ab = lb + 96 * 17
        ammo = []
        for i in range(96):
            e = d[ab + 12 * i: ab + 12 * (i + 1)]
            if not ammo_names[i]:
                continue
            ammo.append({'id': i, 'name': ammo_names[i], 'rounds': e[0], 'ground_attack': e[1],
                         'air_attack': e[2], 'range': e[3], 'recon_range': e[4],
                         'recon_penetration': e[5], 'raw': e.hex(' ')})
        sets[label] = {'machines': machines, 'launchers': launchers, 'ammunition': ammo}

    rosters = {}
    for camp in ('pd2', 'dash'):
        p = os.path.join(src, camp, 'SAVEDATA.ORG')
        if os.path.exists(p):
            s = open(p, 'rb').read()
            rosters[camp] = [missions.parse_crew_record(s[260 + 16 * i: 276 + 16 * i], i, crew_names)
                             for i in range(27)]
    return {'crew_names': crew_names, 'sets': sets, 'rosters': rosters}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    t = read(src)
    os.makedirs(dst, exist_ok=True)
    with open(os.path.join(dst, 'tables.json'), 'w', encoding='utf-8') as f:
        json.dump(t, f, ensure_ascii=False, indent=1)
    s = t['sets']['dash']
    print(f"{len(s['machines'])} machines, {len(s['launchers'])} launchers, "
          f"{len(s['ammunition'])} ammunition types per set; rosters: {list(t['rosters'])}")
    for a, b in (('pd2', 'dash'), ('dash', 'working')):
        diff = sum(x['raw'] != y['raw'] for k in ('machines', 'launchers', 'ammunition')
                   for x, y in zip(t['sets'][a][k], t['sets'][b][k]))
        print(f'records differing {a} vs {b}: {diff}')


if __name__ == '__main__':
    main()
