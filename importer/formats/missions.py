"""Advanced POWER DoLLS 2 (PC-98) -- mission data export.

Usage:
    python -I -X utf8 missions.py <dir with PD2DT.IDX + PD2DT.000..005> <outdir>
    python -I -X utf8 missions.py --plusdash <dir with Pd2.exe, pd2/, dash/> <outdir>
        (Windows Plus Dash, files extracted by is3.py)

Writes, per campaign part (1-3) and mission index:
    missions/partN_mMM.json   group slots + mission-specific text lines
    missions/partN_mMM.txt    the same text, readable
    maps/map_KK_terrain.png   MISSONMD layer (72x72 tile ids, false colour)
    maps/map_KK_height.png    MISSONHD layer (72x72 heights, greyscale)
    maps/map_KK_<layer>.bin   all five raw layers (S, M, H, P, C)

Status of each table (2026-11-07). "code" = confirmed from the disassembled
loaders (BRIEFING.EXE, TACTICS1.EXE); "data" = confirmed against the data or the
game's art; "inferred" = a consistent pattern not yet confirmed from code.

SCN_MISn.PCK  one 548-byte record per mission (7, 7, 3 missions). BRIEFING.EXE
              reads it whole: fread(DS:0x60E2, 1, 0x224).                  [code]
    +0    28 B  mission header (not read directly by BRIEFING)            [unknown]
    +28   15 group slots x 28 B (slot k at 28 + 28k):
            +0  u16 earliest start, +2 u16 latest start, both in 5-minute
                steps after the mission start time; the player picks one   [code]
            +4  u8 task type 0-4. 0 = enters at the fixed entry point,
                2 / 3 = choose a point from list A / B; 1 and 4 are
                handled elsewhere                                          [code]
            +5  u8, low nibble copied to the group (+33 high nibble)       [code]
            +6.. role-specific bytes                                       [unknown]
    +448  6 B   unknown
    +454  u16 x, y   fixed entry point (task type 0)                     [code]
    +458  3 x (u16 x, y)   point table (copied to DS:0x48E8)             [code]
    +470  3 x (u16 x, y)   point table (copied to DS:0x48F4)             [code]
    +482  8 x (u16 x, y)   point list A (task type 2, e.g. drop points)  [code]
    +514  8 x (u16 x, y)   point list B (task type 3)                    [code]
    +546  u16 mission start time in 5-minute steps (72 = 06:00)          [code]
INITn.PCK     7 x 14780 B per part: a straight memory image of DS:0x0819-0x41D5
              in TACTICS.EXE.                                              [code]
    +0      254 units x 55 B                                              [code]
              +0 flags (bits 0, 2, 3 tested), +2 bits 4-5 a 2-bit field  [code]
              +9/+10 map x, y: plotted over map 0, mission 1-1's enemies
              ring the fortress hill and roads                           [code+data]
              +7/+8 a second x, y pair (destination?)                    [inferred]
              +11 crew index into the 16-byte crew table (TACTICS DS:0x2BA,
                  BRIEFING DS:0x288); NPCn fills entries 27-36            [code]
              +13 condition, 100 = intact                                [code+data]
              +17..+50 equipment area: (item, slot 6-11) pairs           [data]
              +54 status 0-3, units with status 3 are skipped            [code]
    +13970  5 B
    +13975  23 groups x 35 B (same layout as BRIEFING's groups)          [code]
              +6..+21 member unit indices (0xFF = empty)                 [data]
              +26/+27 entry point, +29 u16 start time, +31 chosen point,
              +33 low nibble = mission slot, high nibble = slot +5        [code]
MISSON?D.PCK  18 chunks x 5 layers, loaded by TACTICS (overlay 0x3414) with
              fixed sizes. Chunk per global mission g comes from the tables
              LAYER_TABLE_MHS / LAYER_TABLE_CP (chunk = value - 1). Mission 2
              reuses mission 1's C and P (its own C/P chunks are empty);
              chunk 7 is never used.                                       [code]
              M (5184 B) 72x72 tile ids; H (5184 B) 72x72 heights         [code+data]
              C (2048 B) 256 tile ids x 4 u16 = the tile's 2x2 P blocks
                         (TL, TR, BL, BR)                                [code+data]
              P (65448 B) 303 graphics blocks x 216 B: 24x18 px, 4 planes
                         plane-major (B, R, G, I), hex-screen palette    [code+data]
                         Tile = 48x36 px; odd rows shifted 24 px; map 3480x2592.
              S (976 B; 912 for chunk 11) copied to far 0x160:0x30.
                +0    848 B  unknown (53 x 16 B?, values 0-27)            [unknown]
                +848  16 sets x 4 (u8 x, u8 y) AI waypoints. A unit uses set
                      (unit+4 & 0xF), +8 while the alert flag DS:0x4972 is
                      set, and picks one of the 4 at random              [code]
NPCn.PCK      7 x 160 B per part. BRIEFING loads chunk (mission within part)
              of NPC<part>.PCK to DS:0x438 = entries 27-36 of the 16-byte crew
              table at DS:0x288 (TACTICS: DS:0x2BA).                       [code]
              Crew record (16 B), same for the initial roster (27 entries at
              offset 260 of SAVEDATA.TMP) and the NPC entries:
              +0 name id into the name tables at TACTICS DS:0x57D6/0x5822:
                 0 commander ﾊｰﾃﾞｨ ﾆｭｰﾗﾝﾄﾞ, 1-26 DoLLS, 27-36 allied units
                 (TFW19 ｼﾙﾊﾞｰﾅｲﾂ ... 3/122 Wｾｲﾊﾞｰｽﾞ)                     [code]
              +1 portrait id (members: name id - 1)                       [inferred]
              +2 non-zero = not a player character (no weapon choice)     [code]
              +3 1 = air crew, 0 = ground (TFW NPCs 1, 7/213 NPCs 0)    [code+data]
              +4 availability: usable when +4 <= the campaign counter at
                 BRIEFING DS:0x48E1 (the same test is used on weapons and
                 machines); FF = never. TACTICS sets it to 15 for a group's
                 members                                                  [code]
              +5 assigned group (group number + 1, written at formation)  [code]
              +8 skill flags: bit 0 索敵 recon, 1 工兵 engineering, 2 通信
                 communications, 3 隠蔽 concealment                       [book]
              +9 AP (action points); has its own experience routine
                 (TACTICS 0x58:0xDA)                                 [book+code]
              +10 ATTACK: grows when firing at ground targets (mode 5)    [code]
              +11 ANTI AIRCRAFT: grows when firing at air targets (mode 10;
                  machine categories 2-5 and 9 are airborne)             [code]
              +12 CLOSE-COMBAT: +4 to the winner of a melee exchange;
                  shown as 白兵戦補正 on the melee screen                [code]
              +13 DEFENSE: +2 to the unit hit in melee, +1 to the target of
                  fire on some outcomes                                  [code]
              (Combat reads these abilities raw. The 0x58:0x235/0x303/0x3D1/
              0x49F functions return experience still needed for the next
              level: threshold DS:0x5F18[level] minus exp from the 13-byte
              per-crew table at DS:0x6BA + 13 * crew[+15]; level 10 gives 0.
              See RULES.md.)
              +15 index of the crew's experience record; 0xFF = none (generic
                  NPCs, whose getters always return 1)                  [code]
              +14 low 5 bits = rank, index into the string table at
                 TACTICS DS:0x5E28: 0 大佐 1 中佐 2 少佐 3 大尉 4 中尉 5 少尉
                 6 准尉 7 特務軍曹 8 曹長, 9-15 none                       [code]
              +14 bits 5-6 = branch: 0 陸軍 Army, 1 海軍 Navy, 2 海兵隊
                 Marines, 3 防空軍 Air Defence                             [book]
              Book check (Plus Dash Data Book pp. 32-39): Hardy Newland
              海兵隊 大佐 AP 37, 9/7/9/9, all four skills = record exactly;
              Millicent, Ayase and Melissa also match exactly. Some values
              differ slightly (e.g. Yao's AP 33 in the book, 35 here) because
              the book documents Plus Dash.
Machine types (TACTICS DS:0x4976, 31 x 31 B, index = unit +12; names at
              DS:0x5AAE, short codes at DS:0x5AEE). Exported to
              crew/machines.json. Field layout checked against the Plus Dash
              Data Book pp. 41-47 (every listed machine matches):
              +0 high nibble armour type (0 PLD, 1 hard, 2 soft, 3 aircraft,
                 4 helicopter); low nibble category (0 PLD, 1 SPG, 2 transport
                 aircraft, 3 assault aircraft, 4 fighter, 5 transport heli /
                 VTOL, 6 tank / AA gun, 7 IFV / recon, 8 trailer, 9 attack heli)
              +4 ground defense, +5 air defense, +6 close combat, +7 recon
                 range, +8 recon penetration, +23 pockets, +24 mobility / 10
              +1 (speed?), +3 (endurance?), +9, +10, +11..+22 (six u16
                 hardpoint masks?), +25..+29                             [open]
Weapons (TACTICS; exported to crew/weapons.json):
              launchers 96 x 17 B at DS:0x4D56 (80 used), ammunition 96 x 11 B
              at DS:0x53B6; names from the master table DS:0x586E (launchers
              0-95, codes 96-; machines 288-, codes 320-; ammunition 352-,
              codes 448-; call signs 640-; group names 694-; ranks 733-;
              branches 749-; tasks 756-774).
              Ammo: +0 rounds, +1 ground attack, +2 air attack, +3 range.
              Launcher: +2 ground accuracy, +3 ground attack bonus, +4 range
              bonus, +5 air accuracy, +6 air attack bonus, +7 AP cost (bits
              5-6) / AP load, +10..+12 loadable ammo ids, +14 = 3 for Zias.
              Final value = ammo + launcher bonus: DSG10/11/12 with 25mm and
              ARX2 with 20mm reproduce the Plus Dash Data Book exactly.  [book]
              (Same table: 16-20 branch 陸軍 海軍 海兵隊 防空軍 ジアス; 23-31
              task names 通常降下 高々度降下 爆薬設置 高々度降下爆薬設置
              人員救出 輸送護衛 上空援護 対地砲撃支援 対地支援任務.)
MESn.PCK      486 strings per mission; the lines not shared by every mission are
              that mission's constraints, role texts, orders and briefing. In
              mission 1-1 the role texts are in group-slot order.         [data]
MAP_CHG.PCK   159 chunks, a global library read by TACTICS (name via DS:0x60A8)
              with two record shapes:                                     [code]
              - terrain change: 4 B (u8 x, u8 y, u8 new tile, u8 height).
                Each chunk matches one map's heights exactly while its tiles
                differ: destruction states (blast damage on buildings, breached
                canal walls on map 13). Sets 110-158 come in stages.     [code+data]
              - cell list: 2 B (u8 x, u8 y). Map areas, used with a "unit at
                hex" lookup (chunks 0, 6-9, 62-68, 84-98).               [code+data]
              Callers pick chunk 0, 5 (loaded whole), n+1, n+6, n+51 and 139.
              Which map each chunk belongs to is inferred from the heights
              (exported as best_map).                                    [inferred]
"""
import colorsys
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gcp     # noqa: E402
import pd2dt   # noqa: E402

PARTS = {1: 7, 2: 7, 3: 3}
MAP = 72


def chunks(by_name, name):
    return pd2dt.split_pck(by_name[name])


def decoded(by_name, name):
    return [pd2dt.decode_chunk(c) if pd2dt.decode_chunk(c) is not None else c
            for c in chunks(by_name, name)]


def fmt_time(steps):
    m = steps * 5
    return f'{(m // 60) % 24:02d}:{m % 60:02d}'


def points(rec, off, n):
    return [list(struct.unpack_from('<HH', rec, off + 4 * i)) for i in range(n)]


def parse_mission(rec):
    """548-byte Advanced record, or the 454-byte Plus Dash record (no start time and
    no point tables: those 94 bytes were added in Advanced)."""
    advanced = len(rec) >= 548
    start = struct.unpack_from('<H', rec, 546)[0] if advanced else None
    slots = []
    for k in range(15):
        s = rec[28 + 28 * k: 56 + 28 * k]
        lo, hi = struct.unpack_from('<HH', s, 0)
        slots.append({
            'slot': k,
            'active': any(s[:7]),
            'start_window': [fmt_time(start + lo), fmt_time(start + hi)] if advanced else None,
            'start_steps': [lo, hi],
            'task_type': s[4],
            'param5': s[5] & 0x0F,
            'raw': s.hex(' '),
        })
    out = {'header_raw': rec[:28].hex(' '), 'groups': slots}
    if advanced:
        out.update({
            'mission_start': fmt_time(start),
            'entry_point': list(struct.unpack_from('<HH', rec, 454)),
            'points_458': points(rec, 458, 3),
            'points_470': points(rec, 470, 3),
            'point_list_A': points(rec, 482, 8),
            'point_list_B': points(rec, 514, 8),
        })
    else:
        out['tail_raw'] = rec[448:].hex(' ')
    return out


def parse_init(d):
    units = []
    for i in range(254):
        u = d[i * 55:(i + 1) * 55]
        if u[11] == 0xFF:
            continue
        units.append({'index': i, 'flags': u[0], 'type': u[11], 'pos': [u[9], u[10]],
                      'pos2': [u[7], u[8]], 'condition': u[13], 'status': u[54],
                      'raw': u.hex(' ')})
    groups = []
    for g in range(23):
        r = d[13975 + g * 35: 13975 + (g + 1) * 35]
        members = [b for b in r[6:22] if b != 0xFF]
        if members or any(b not in (0, 0xFF) for b in r[22:]):
            groups.append({'index': g, 'members': members, 'slot': r[33] & 0x0F,
                           'raw': r.hex(' ')})
    return units, groups


def mission_texts(mes_chunks):
    tables = [c.split(b'\0') for c in mes_chunks]
    common = set.intersection(*[set(t) for t in tables])
    out = []
    for t in tables:
        out.append([(i, s.decode('cp932', 'replace')) for i, s in enumerate(t)
                    if s not in common and s.strip()])
    return out


def write_rgb_png(path, w, h, rgb):
    import zlib
    raw = b''.join(b'\0' + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def ck(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ck(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + ck(b'IDAT', zlib.compress(raw, 9)) + ck(b'IEND', b''))


def render_layer(layer, kind, zoom=4):
    """Hex layout: odd rows shifted half a cell. 0xFF / 0 off-map cells are black."""
    w, h = MAP * zoom + zoom // 2, MAP * zoom
    rgb = bytearray(w * h * 3)
    vals = sorted(set(layer) - {0xFF})
    hv = [v for v in layer if v not in (0, 0xFF)]
    lo, hi = (min(hv), max(hv)) if hv else (0, 1)
    for y in range(MAP):
        for x in range(MAP):
            v = layer[y * MAP + x]
            if kind == 'terrain':
                if v == 0xFF:
                    c = (0, 0, 0)
                else:
                    r, g, b = colorsys.hsv_to_rgb((vals.index(v) * 0.618) % 1, 0.6, 0.95)
                    c = (int(r * 255), int(g * 255), int(b * 255))
            else:
                g = 0 if v in (0, 0xFF) else int(40 + 215 * (v - lo) / max(1, hi - lo))
                c = (g, g, g)
            ox = x * zoom + (zoom // 2 if y % 2 else 0)
            for yy in range(zoom):
                o = ((y * zoom + yy) * w + ox) * 3
                rgb[o:o + zoom * 3] = bytes(c) * zoom
    return w, h, rgb


# Map layer chunk per global mission number (part 1 = 1-7, part 2 = 8-14,
# part 3 = 15-17). Copied from the four 19-byte tables after "MISSON?D.PCK" in
# TACTICS1/2/3.EXE (identical in all three); the loader uses chunk = value - 1.
LAYER_TABLE_CP = [1, 1, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]   # C and P
LAYER_TABLE_MHS = [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]  # M, H, S
TILE_W, TILE_H, BLOCK_W, BLOCK_H = 48, 36, 24, 18


def global_mission(part, m):
    return sum(c for p, c in PARTS.items() if p < part) + m   # 0-based


def p_block(P, i):
    """One 24x18 graphics block: 216 bytes, plane-major (B, R, G, I), 3 bytes per row."""
    b = P[i * 216:(i + 1) * 216]
    px = bytearray(BLOCK_W * BLOCK_H)
    for y in range(BLOCK_H):
        for xb in range(3):
            pb, pr, pg, pi = b[y * 3 + xb], b[54 + y * 3 + xb], b[108 + y * 3 + xb], b[162 + y * 3 + xb]
            for bit in range(8):
                m = 0x80 >> bit
                px[y * BLOCK_W + xb * 8 + bit] = ((pb & m) and 1) | ((pr & m) and 2) | ((pg & m) and 4) | ((pi & m) and 8)
    return px


def render_tactical(M, C, P):
    """Full tactical map: tile id (M) -> C entry (4 u16 P-block ids, 2x2) -> pixels.
    Odd rows are shifted right by half a tile. Returns (w, h, indexed pixels)."""
    nblocks = len(P) // 216
    cache = {}
    w, h = MAP * TILE_W + TILE_W // 2, MAP * TILE_H
    img = bytearray(w * h)
    for ty in range(MAP):
        for tx in range(MAP):
            t = M[ty * MAP + tx]
            if t == 0xFF:
                continue
            q = struct.unpack_from('<4H', C, t * 8)
            ox = tx * TILE_W + (TILE_W // 2 if ty % 2 else 0)
            oy = ty * TILE_H
            for k, (dx, dy) in enumerate(((0, 0), (BLOCK_W, 0), (0, BLOCK_H), (BLOCK_W, BLOCK_H))):
                bi = q[k]
                if bi >= nblocks:
                    continue
                if bi not in cache:
                    cache[bi] = p_block(P, bi)
                px = cache[bi]
                for y in range(BLOCK_H):
                    o = (oy + dy + y) * w + ox + dx
                    img[o:o + BLOCK_W] = px[y * BLOCK_W:(y + 1) * BLOCK_W]
    return w, h, img


RANKS = ['大佐', '中佐', '少佐', '大尉', '中尉', '少尉', '准尉', '特務軍曹', '曹長']


BRANCHES = ['陸軍', '海軍', '海兵隊', '防空軍']            # crew +14 bits 5-6 (TACTICS DS:0x5E28 + 16)
SKILLS = ['recon', 'engineering', 'communications', 'concealment']  # crew +8 bits 0-3
ARMOR_TYPES = ['機動歩兵 (PLD)', '硬装甲 (hard)', '軟装甲 (soft)', '航空機 (aircraft)', 'ヘリ (helicopter)']
CATEGORIES = ['PLD', 'self-propelled gun', 'transport aircraft', 'assault aircraft', 'fighter',
              'transport helicopter / VTOL', 'tank / AA gun', 'IFV / recon / missile vehicle',
              'trailer', 'attack helicopter']


def tactics_ds(tactics_exe):
    d = open(tactics_exe, 'rb').read()
    hdr = struct.unpack_from('<H', d, 8)[0] * 16
    ip, cs = struct.unpack_from('<HH', d, 0x14)
    seg = struct.unpack_from('<H', d, hdr + cs * 16 + ip + 1)[0]   # mov dx, DGROUP
    return d[hdr + seg * 16:]


def read_machines(tactics_exe, count=31):
    """Machine type records: 31 B each at TACTICS DS:0x4976 (index = unit +12).
    Field meanings matched against the Plus Dash Data Book pp. 41-47."""
    ds = tactics_ds(tactics_exe)
    def s(p):
        return ds[p:p + 32].split(b'\0')[0].decode('cp932', 'replace')
    out = []
    for i in range(count):
        e = ds[0x4976 + 31 * i: 0x4976 + 31 * (i + 1)]
        out.append({
            'type': i,
            'name': s(struct.unpack_from('<H', ds, 0x5AAE + 2 * i)[0]),         # [code+book]
            'short': s(struct.unpack_from('<H', ds, 0x5AEE + 2 * i)[0]),        # [code]
            'armor_type': ARMOR_TYPES[e[0] >> 4] if e[0] >> 4 < len(ARMOR_TYPES) else e[0] >> 4,  # [book]
            'category': CATEGORIES[e[0] & 15] if (e[0] & 15) < len(CATEGORIES) else e[0] & 15,     # [code+book]
            'airborne': (e[0] & 15) in (2, 3, 4, 5, 9),                       # [code]
            'value_1': e[1],             # [inferred] speed? PLD 12, fighters 120, helicopters 40-60
            'max_condition': e[2],       # [inferred] always 100
            'value_3': e[3],             # [inferred] endurance? 250 for ground, 85-150 for aircraft
            'ground_defense': e[4],      # [book] 対地防御力
            'air_defense': e[5],         # [book] 対空防御力
            'close_combat': e[6],        # [book] 白兵戦能力
            'recon_range': e[7],         # [book] 索敵距離
            'recon_penetration': e[8],   # [book] 索敵貫通力
            'value_9': e[9],             # [unknown] AC17 2, C559 6
            'value_10': e[10],           # [unknown] 1 ground, 3 M151, 0xFF aircraft
            'slot_masks': list(struct.unpack_from('<6H', e, 11)),  # [inferred] per-hardpoint weapon masks
            'pockets': e[23],            # [book] ポケット数
            'mobility_pct': e[24] * 10,  # [book] 機動力
            'ids_25_27': list(e[25:28]), # [unknown] graphics / name indices
            'side': 'Zias' if e[28] == 3 else 'Omni',  # [inferred] 3 for all Zias machines
            'value_29': e[29],
            'raw': e.hex(' '),
        })
    return out


def _name(ds, index):
    """Master name table at TACTICS DS:0x586E (pointer list). Indices:
    0 launchers, 96 launcher codes, 192 tags, 288 machines, 320 machine codes,
    352 ammunition, 448 ammo codes, 544 ammo tags, 640 call signs, ..."""
    q = struct.unpack_from('<H', ds, 0x586E + 2 * index)[0]
    return ds[q:q + 32].split(b'\0')[0].decode('cp932', 'replace')


def read_weapons(tactics_exe):
    """Launchers (96 x 17 B at DS:0x4D56) and ammunition (96 x 11 B at DS:0x53B6).
    Final stat = ammunition base + launcher bonus; verified against the Plus Dash
    Data Book pp. 48-49 (DSG10/11/12, ARX2: every value matches)."""
    ds = tactics_ds(tactics_exe)
    ammo = []
    for i in range(96):
        e = ds[0x53B6 + 11 * i: 0x53B6 + 11 * (i + 1)]
        nm = _name(ds, 352 + i)
        if not nm:
            continue
        ammo.append({
            'id': i, 'name': nm, 'code': _name(ds, 448 + i),
            'rounds': e[0],            # [book] 弾数
            'ground_attack': e[1],     # [book] base 対地攻撃力
            'air_attack': e[2],        # [book] base 対空攻撃力
            'range': e[3],             # [book] base 射程距離
            'recon_range': e[4],       # [inferred] probes / sensors only
            'recon_penetration': e[5], # [inferred]
            'flags_6': e[6], 'warhead_7': e[7],   # [inferred] attack / warhead type bits
            'value_8': e[8], 'value_9': e[9],     # [unknown]
            'raw': e.hex(' '),
        })
    launchers = []
    for i in range(96):
        e = ds[0x4D56 + 17 * i: 0x4D56 + 17 * (i + 1)]
        nm = _name(ds, i)
        if not nm:
            continue
        launchers.append({
            'id': i, 'name': nm, 'code': _name(ds, 96 + i),
            'mount_mask_air': e[0],             # [inferred] aircraft pylons
            'mount_mask_pld': e[1],             # [inferred] PLD hardpoints / hands
            'ground_accuracy': e[2],            # [book] 対地精度
            'ground_attack_bonus': e[3],        # [book] + ammo ground_attack
            'range_bonus': e[4],                # [book] + ammo range
            'air_accuracy': e[5],               # [book] 対空精度
            'air_attack_bonus': e[6],           # [book] + ammo air_attack
            'ap_cost': (e[7] >> 5) & 3,         # [book] AP消費
            'ap_load': e[7] & 0x1F,             # [book] AP負荷
            'attack_type_8': e[8],              # [inferred] D0 / D1 / R1 … bits
            'class_9': e[9],                    # [inferred] weapon class
            'ammo_ids': [x for x in e[10:13] if x != 0xFF],   # [book] loadable ammunition
            'icon_13': e[13],                   # [inferred] ARMS.PCK sprite index
            'side': 'Zias' if e[14] == 3 else 'Omni',          # [data]
            'value_15': e[15], 'value_16': e[16],              # [unknown]
            'raw': e.hex(' '),
        })
    return launchers, ammo


def read_crew_names(tactics_exe):
    """Name id -> (given, family) from TACTICS1.EXE DS:0x57D6 / DS:0x5822 (38 entries).
    0 = commander, 1-26 = DoLLS members, 27-36 = allied units (designation, nickname)."""
    d = open(tactics_exe, 'rb').read()
    hdr = struct.unpack_from('<H', d, 8)[0] * 16
    ip, cs = struct.unpack_from('<HH', d, 0x14)
    seg = struct.unpack_from('<H', d, hdr + cs * 16 + ip + 1)[0]   # mov dx, DGROUP
    ds = d[hdr + seg * 16:]
    def s(p):
        return ds[p:p + 40].split(b'\0')[0].decode('cp932', 'replace')
    a = struct.unpack_from('<38H', ds, 0x57D6)
    b = struct.unpack_from('<38H', ds, 0x5822)
    return [(s(a[i]), s(b[i])) for i in range(38)]


def parse_crew_record(r, index, names):
    rk = r[14] & 0x1F
    nm = names[r[0]] if names and r[0] < len(names) else None
    return {
        'crew_index': index,
        'name_id': r[0],                                  # [code]
        'name': ' '.join(x for x in nm if x) if nm else None,
        'portrait_id': r[1],                              # [inferred]
        'non_player': r[2],                               # [code] non-zero: no weapon choice
        'air_crew': r[3] == 1,                            # [code+data]
        'availability': r[4],                             # [code] usable when <= DS:0x48E1; FF never
        'assigned_group': r[5],                           # [code] group number + 1
        'unknown_6_7': [r[6], r[7]],
        'skills': [n for b, n in enumerate(SKILLS) if r[8] >> b & 1],  # [book]
        'ap': r[9],                                       # [book+code] AP, grows with experience
        'attack': r[10],                                  # [code]
        'anti_aircraft': r[11],                           # [code]
        'close_combat': r[12],                            # [code]
        'defense': r[13],                                 # [code]
        'rank': RANKS[rk] if rk < len(RANKS) else None,   # [code]
        'branch': BRANCHES[(r[14] >> 5) & 3],             # [book] 所属
        'experience_index': r[15],                        # [code] 0xFF = none (generic)
        'raw': r.hex(' '),
    }


def parse_npc(d, names=None):
    return [parse_crew_record(d[i * 16:(i + 1) * 16], 27 + i, names) for i in range(len(d) // 16)]


def parse_map_changes(chunks_, heights, tiles):
    """Classify MAP_CHG chunks and find the map whose heights match each change set."""
    out = []
    for i, c in enumerate(chunks_):
        n = len(c)
        rec4 = n and n % 4 == 0 and all(c[j] < MAP and c[j + 1] < MAP for j in range(0, n, 4))
        rec2 = n and n % 2 == 0 and all(c[j] < MAP and c[j + 1] < MAP for j in range(0, n, 2))
        entry = {'chunk': i, 'size': n}
        best = None
        if rec4:
            recs = [c[j:j + 4] for j in range(0, n, 4)]
            for k, h in enumerate(heights):
                if len(h) != MAP * MAP:
                    continue
                hm = sum(h[r[1] * MAP + r[0]] == r[3] for r in recs) / len(recs)
                tm = sum(tiles[k][r[1] * MAP + r[0]] == r[2] for r in recs) / len(recs)
                if best is None or hm > best[0]:
                    best = (hm, tm, k)
        plausible4 = rec4 and all(c[j + 3] < 90 for j in range(0, n, 4)) and \
            len(set(c[3::4])) <= max(3, n // 16)   # heights repeat; cell-list y's don't
        if rec4 and best and (best[0] >= 0.5 or (plausible4 and best[0] >= 0.2)):
            entry.update(kind='terrain_change' if best[0] >= 0.5 else 'terrain_change_uncertain',
                         best_map=best[2],
                         height_match=round(best[0], 2), tile_match=round(best[1], 2),
                         records=[list(c[j:j + 4]) for j in range(0, n, 4)])
        elif rec2:
            entry.update(kind='cells', cells=[list(c[j:j + 2]) for j in range(0, n, 2)])
        else:
            entry.update(kind='other' if n else 'empty', raw=c.hex(' '))
        out.append(entry)
    return out


def waypoints(S):
    """Last 128 bytes from offset 848: up to 16 sets x 4 (x, y) byte points.
    Sets 0-7 normal, 8-15 used while the alert flag DS:0x4972 is set."""
    tail = S[848:]
    return [[list(tail[s * 8 + 2 * i: s * 8 + 2 * i + 2]) for i in range(4)]
            for s in range(len(tail) // 8)]


PLUS_DASH_CAMPAIGNS = ('pd2', 'dash')


def main_plusdash(src, dst):
    """Plus Dash (Windows): <src> holds Pd2.exe and the pd2/ and dash/
    folders extracted by is3.py. Same outputs as the Advanced export, per campaign.
    Map chunk = mission index (no layer tables in Pd2.exe); an empty C/P chunk falls
    back to the previous non-empty one, as Advanced does for its mission 2. [inferred]"""
    import pd2exe
    # 16-colour tactical map palette: RGBQUAD (B, G, R, 0) x 16 at Pd2.exe file 0x10C0F8
    # (the PC-98 hex-screen palette scaled to 8 bits, a few entries retuned).
    exe = open(os.path.join(src, 'Pd2.exe'), 'rb').read()
    hex_pal = [(exe[0x10C0F8 + 4 * i + 2], exe[0x10C0F8 + 4 * i + 1], exe[0x10C0F8 + 4 * i])
               for i in range(16)]
    names = pd2exe.read(src)['crew_names']

    def files_of(camp):
        folder = os.path.join(src, camp)
        return {f.upper(): os.path.join(folder, f) for f in os.listdir(folder)}

    def pck(fs, name, decode=True):
        data = open(fs[name], 'rb').read()
        out = []
        for c in pd2dt.split_pck(data):
            dc = pd2dt.decode_chunk(c) if decode else None
            out.append(dc if dc is not None else c)
        return out

    total = 0
    for camp in PLUS_DASH_CAMPAIGNS:
        fs = files_of(camp)
        cdir = os.path.join(dst, camp)
        os.makedirs(os.path.join(cdir, 'missions'), exist_ok=True)
        os.makedirs(os.path.join(cdir, 'maps'), exist_ok=True)
        recs = pck(fs, 'SCN_MIS.PCK', decode=False)
        texts = mission_texts(pck(fs, 'MES.PCK'))
        inits = pck(fs, 'INIT.PCK')
        npcs = pck(fs, 'NPC.PCK')
        layers = {k: pck(fs, f'MISSON{k}D.PCK') for k in 'SMHPC'}
        for m, rec in enumerate(recs):
            mis = parse_mission(rec)
            units, groups = parse_init(inits[m]) if m < len(inits) else ([], [])
            cp = m
            while cp > 0 and (not layers['C'][cp] or not layers['P'][cp]):
                cp -= 1
            stem = os.path.join(cdir, 'missions', f'm{m:02d}')
            if len(layers['M'][m]) == MAP * MAP and layers['P'][cp]:
                w, h, img = render_tactical(layers['M'][m], layers['C'][cp], layers['P'][cp])
                gcp.write_png(stem + '_tactical_map.png', w, h, img, hex_pal)
            mis['map_chunks'] = {'M_H_S': m, 'C_P': cp}
            mis['ai_waypoint_sets'] = waypoints(layers['S'][m])
            active = [g for g in mis['groups'] if g['active']]
            doc = {'campaign': camp, 'mission': m, **mis,
                   'init_units': units, 'init_groups': groups,
                   'npc_crew': parse_npc(npcs[m], names) if m < len(npcs) else [],
                   'text': [{'index': i, 'text': t} for i, t in texts[m]] if m < len(texts) else [],
                   'note': 'see missions.py docstring; Plus Dash records have no start time'}
            with open(stem + '.json', 'w', encoding='utf-8') as f:
                json.dump(doc, f, ensure_ascii=False, indent=1)
            with open(stem + '.txt', 'w', encoding='utf-8') as f:
                f.write(f"{camp} mission {m}: {len(active)} group slots, {len(units)} units in INIT, "
                        f"map chunk {m} (graphics {cp})\n\n")
                for g in active:
                    f.write(f"  slot {g['slot']:2d}  start steps {g['start_steps']}  task {g['task_type']}"
                            f"  p5 {g['param5']}\n")
                f.write('\n')
                for i, t in (texts[m] if m < len(texts) else []):
                    f.write(f'[{i:3d}] {t}\n')
            total += 1
        for k in range(len(layers['M'])):
            for name, data in layers.items():
                if k < len(data):
                    open(os.path.join(cdir, 'maps', f'map_{k:02d}_{name}.bin'), 'wb').write(data[k])
        if 'MAP_CHG.PCK' in fs:
            changes = parse_map_changes(pck(fs, 'MAP_CHG.PCK', decode=False), layers['H'], layers['M'])
            with open(os.path.join(cdir, 'maps', 'map_changes.json'), 'w', encoding='utf-8') as f:
                json.dump(changes, f, indent=1)
        print(f'{camp}: {len(recs)} missions, {len(layers["M"])} maps')
    print(f'{total} Plus Dash missions written to {dst}')


def main():
    if sys.argv[1] == '--plusdash':
        return main_plusdash(sys.argv[2], sys.argv[3])
    src, dst = sys.argv[1], sys.argv[2]
    idx = pd2dt.read_index(os.path.join(src, 'PD2DT.IDX'))
    blob = pd2dt.read_volumes(src)
    by_name = {n: blob[o:o + s] for n, s, o in idx}
    os.makedirs(os.path.join(dst, 'missions'), exist_ok=True)
    os.makedirs(os.path.join(dst, 'maps'), exist_ok=True)

    layers = {k: decoded(by_name, f'MISSON{k}D.PCK') for k in 'SMHPC'}
    hex_pal = gcp.palette_rgb(gcp.parse_header(by_name['HEX_G.GCP']))
    tac = os.path.join(src, 'TACTICS1.EXE')
    names = read_crew_names(tac) if os.path.exists(tac) else None
    # Initial roster: 27 crew records (commander + 26 DoLLS) in SAVEDATA.TMP (offset 260),
    # found by their name ids counting 0..26. SAVEDATA.ORG does not hold them in plain form.
    roster, roster_src = [], None
    for src_name in ('SAVEDATA.TMP', 'SAVEDATA.ORG'):
        save = by_name.get(src_name, b'')
        for off in range(0, max(0, len(save) - 16 * 27)):
            if all(save[off + 16 * i] == i for i in range(27)):
                roster = [parse_crew_record(save[off + 16 * i: off + 16 * (i + 1)], i, names)
                          for i in range(27)]
                roster_src = f'{src_name} @ {off}'
                break
        if roster:
            break
    os.makedirs(os.path.join(dst, 'crew'), exist_ok=True)
    with open(os.path.join(dst, 'crew', 'initial_roster.json'), 'w', encoding='utf-8') as f:
        json.dump({'source': roster_src, 'names': names, 'roster': roster}, f,
                  ensure_ascii=False, indent=1)
    if os.path.exists(tac):
        with open(os.path.join(dst, 'crew', 'machines.json'), 'w', encoding='utf-8') as f:
            json.dump(read_machines(tac), f, ensure_ascii=False, indent=1)
        launchers, ammo = read_weapons(tac)
        with open(os.path.join(dst, 'crew', 'weapons.json'), 'w', encoding='utf-8') as f:
            json.dump({'launchers': launchers, 'ammunition': ammo}, f, ensure_ascii=False, indent=1)
    n_m = 0
    for part, count in PARTS.items():
        recs = chunks(by_name, f'SCN_MIS{part}.PCK')
        texts = mission_texts(decoded(by_name, f'MES{part}.PCK'))
        inits = decoded(by_name, f'INIT{part}.PCK')
        npcs = decoded(by_name, f'NPC{part}.PCK')
        for m in range(count):
            mis = parse_mission(recs[m])
            units, groups = parse_init(inits[m]) if m < len(inits) else ([], [])
            active = [g for g in mis['groups'] if g['active']]
            g_idx = global_mission(part, m)
            mhs, cp = LAYER_TABLE_MHS[g_idx] - 1, LAYER_TABLE_CP[g_idx] - 1
            stem = os.path.join(dst, 'missions', f'part{part}_m{m:02d}')
            w, h, img = render_tactical(layers['M'][mhs], layers['C'][cp], layers['P'][cp])
            gcp.write_png(stem + '_tactical_map.png', w, h, img, hex_pal)
            mis['map_chunks'] = {'M_H_S': mhs, 'C_P': cp}
            mis['ai_waypoint_sets'] = waypoints(layers['S'][mhs])
            doc = {'part': part, 'mission': m, **mis,
                   'init_units': units, 'init_groups': groups,
                   'npc_crew': parse_npc(npcs[m], names) if m < len(npcs) else [],
                   'text': [{'index': i, 'text': t} for i, t in texts[m]],
                   'note': 'see missions.py docstring for which fields are confirmed'}
            with open(stem + '.json', 'w', encoding='utf-8') as f:
                json.dump(doc, f, ensure_ascii=False, indent=1)
            with open(stem + '.txt', 'w', encoding='utf-8') as f:
                f.write(f"Part {part} mission {m}: start {mis['mission_start']}, "
                        f"{len(active)} group slots, {len(units)} units in INIT, "
                        f"map chunk {mhs} (graphics {cp})\n")
                f.write(f"Entry point {mis['entry_point']}  list A {mis['point_list_A']}\n\n")
                for g in active:
                    f.write(f"  slot {g['slot']:2d}  start {g['start_window'][0]}-{g['start_window'][1]}"
                            f"  task {g['task_type']}  p5 {g['param5']}\n")
                f.write('\n')
                for i, t in texts[m]:
                    f.write(f'[{i:3d}] {t}\n')
            n_m += 1

    for k in range(len(layers['M'])):
        for name, data in layers.items():
            if k < len(data):
                open(os.path.join(dst, 'maps', f'map_{k:02d}_{name}.bin'), 'wb').write(data[k])
        for name, kind in (('M', 'terrain'), ('H', 'height')):
            if len(layers[name][k]) == MAP * MAP:
                w, h, rgb = render_layer(layers[name][k], kind)
                write_rgb_png(os.path.join(dst, 'maps', f'map_{k:02d}_{kind}.png'), w, h, rgb)
    changes = parse_map_changes(chunks(by_name, 'MAP_CHG.PCK'), layers['H'], layers['M'])
    with open(os.path.join(dst, 'maps', 'map_changes.json'), 'w', encoding='utf-8') as f:
        json.dump(changes, f, indent=1)
    kinds = {}
    for c in changes:
        kinds[c['kind']] = kinds.get(c['kind'], 0) + 1
    print(f'{n_m} missions, {len(layers["M"])} maps, map changes {kinds} written to {dst}')


if __name__ == '__main__':
    main()
