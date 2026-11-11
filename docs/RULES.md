# POWER DoLLS 2: combat rules spec

> The rules as OpenPD2's engine (`godot/core`) implements them. The text names the
> project's Python reference implementation (`rules.py`) and the emulator checks behind
> each "Emulated" rule. Those, and the other reverse‑engineering tools, are not part of
> OpenPD2.

Read from `Pd2.exe` (*Plus Dash*, Windows, MSVC 5) and compared with
`TACTICS1.EXE` (*Advanced*, PC‑98, Borland C with overlays). The Python
reference implementation is `tools/rules.py`.

**Confidence levels**
- **Emulated:** the real machine code was run under Unicorn and matched the Python reference over many inputs.
- **Code:** read from the disassembly.
- **Inferred:** a consistent interpretation that the code has not fully confirmed yet.

Addresses are virtual addresses in `Pd2.exe` (image base 0x400000), plus PC‑98
overlay segment and offset (`ovseg N 0xOFS`, resolved with `tools/fbov.py`).

---

## 0. The unit record: Code (fields named from the code, the game messages and the manual)

Each unit is 55 bytes (Pd2.exe DS:0x506C93; PC‑98 DS:0x819, same layout).

**Where the records come from on Windows** (`load_init_npc`, 0x417030, Code; checked against the data):
- **Units:** the table holds 255 units (0–254), and the 64 group records follow it
  directly at DS:0x50A35C. `INIT` (14,780 B) loads at **unit 27** (DS:0x507260): 228
  unit records (units 27–254), then the 64 group records.
  - Units 0–26 are the player's, filled in by the briefing.
  - In the data, units 27–38 are allied support and enemies start at 40.
  - This differs from the PC‑98 reading of `INIT` (254 units + 5 B + 23 groups).
- **Crew table** (64 × 16 B, DS:0x506734): it starts as `Pd2.exe`'s initialised data.
  Crews 37–63 are the computer's pilots, graded by AP and abilities. Over that:
  - the roster goes in crews 0–26;
  - `NPC` goes in crews 27–36.
- **Ammunition:** 96 records (DS:0x50B835 up to the name pointers at 0x50BCB5), not 72.
  Only ids 0–71 have names. The missions' enemy units carry ids up to 92.

The
names below come from three sources:
- the code that reads each field;
- the in‑game messages in `WMES.PCK` that the same code shows;
- the manual's rules chapter (14.3.3, equipment damage).

**Part states** (2 bits each): 0 good (良好), 1 malfunction (不調: no effect yet,
a warning), 2 broken (故障).

| Field | Meaning | Evidence |
|---|---|---|
| +0 bit 0x01 | destroyed | set when condition reaches 0 |
| +0 bits 0x04, 0x08 | both needed for "active" (deployed on the map) | 0x482FD0 |
| +0 bit 0x10 | spotted by the enemy | set by the spotting roll after a hit |
| +0 bit 0x20 | concealed | the 隠蔽 command sets it ("既に隠蔽済みです" = already concealed). Manual: concealment doubles terrain cover |
| +0 bit 0x40 | has made a reaction shot | set on the shooter after opportunity fire |
| +1 bits 0–1 | **head: recon unit (sensor)** | broken: recon range drops to 2 and penetration to its minimum (`recon_range`, 0x450A80 / `recon_penetration` (0x450AF0)). Manual: only the absolute recon range is left. The EMP round targets it |
| +1 bits 2–3, 4–5 | **right / left movement gear** | an airdrop landing failure shows "移動装置損傷！" (movement gear damaged!) and damages one side. Once one is broken, "移動装置が故障しています" and the unit cannot move. Both sides malfunction before either breaks (manual 14.3.3.2) |
| +1 bits 6–7, +2 bits 0–1 | **right / left manipulator (hands)** | each broken hand costs one melee strike (¼ of melee, as the manual says). Both broken: "両腕が故障しているので…" refuses hand weapons, items and magazine swaps, and the unit can no longer carry another |
| +2 bits 2–3 | **torso: fire control unit** | broken: −15 to hit (−35 for missiles). Manual: accuracy drops sharply |
| +2 bits 4–5, 6–7 | PC‑98 only: EMP counter / saved sensor state | §4.5 |
| +4 bits 4–5 | **movement mode**: 0 high‑speed, 1 normal, 2 careful, 3 searching | stored by each movement step and by the search (索敵) command, cleared by an airdrop. The move cost factors ×1 / ×2 / ×3 (§5.2) confirm the order against the manual (14.2). Also sets the evasion AP paid under opportunity fire: 4 / 2 / 1 / 2 |
| +5 bits 0–2 | facing | randomised on landing |
| +9, +10 | x, y | |
| +0xB / +0xC / +0xD | crew index / machine type / condition (HP) | |
| +0xE | **current AP** | `spend_ap` (0x47CC60) spends it (floored at 0); an airdrop refills it to the maximum (0x450690); the carry command needs 8, or 4 with engineering, as the manual says |
| +0xF + 2k | slot k launcher | slots 0–1 shoulders, 2–3 hands (manual: shoulders, hands and pockets give up to 10 weapons) |
| +0x10 + 2k | slot k: pocket index (bits 0–3), state (bits 4–5) | |
| +0x1B + 2p / +0x1C + 2p | pocket p: ammo id / count (bits 0–5, signed), state (bits 6–7) | |
| +0x34 | **carried unit** (0xFF = none) | the carry and release (搬送 / 放棄) commands. A carrying unit is +15 to hit and pays double evasion AP |
| +0x36 | side / status (≥ 3 = enemy) | |

---

## 1. Random numbers: Emulated

Combat does not use the C runtime `rand()`, which serves only new‑game setup and
between‑mission bookkeeping. It uses the game's own generator, **`random(n)`**:

- **Where:** `Pd2.exe` `random` (0x48F800), called from 86 functions. On the PC‑98 the same
  role is played by `0x118:6`.
- **State:** a 16‑bit word (Pd2.exe DS:0x50AD90). Each call:
  1. byte‑swaps the state into `s`;
  2. does 4 × `x = (x << 15) | (x16 >> 1)` on a 32‑bit register to extract a feedback bit;
  3. sets the new state to `rotl16(s, 1) ^ bit`.
- **Result:** `state % n` (0 … n−1).
- **Verification:** the Python port `rules.Random` matches the machine code on
  all 65,536 states × 2 moduli.
- **Not yet confirmed:** that the PC‑98 `random()` is the same generator.

## 2. Experience and levels: Code (identical on PC‑98)

Each crew member has a 13‑byte experience record (Pd2.exe DS:0x506B34; PC‑98
DS:0x6BA), indexed by crew byte +15. Offsets 0–4 hold experience for AP,
ATTACK, ANTI AIRCRAFT, CLOSE‑COMBAT and DEFENSE.

`grow(ability, amount)`:
1. `exp = min(255, exp + amount)`.
2. If `exp ≥ T[level]`, then `exp = 0` and `level = min(10, level + 1)`.

`T = [75, 86, 98, 112, 128, 146, 167, 191, 218, 250]`. The table is the same in
both versions (Pd2.exe DS:0x50CC4C, PC‑98 DS:0x5F18).

Generic NPCs (crew +15 = 0xFF) have no experience record and always count as
level 1.

## 3. Melee: Emulated; identical on PC‑98

**Machine melee value** `M(unit)` (`machine_melee_of`, 0x4509E0; PC‑98 0x38:0x499):
- For a PLD (machine byte +26 = 6): machine close‑combat (+6) minus 3 × total
  load. The load is the sum of launcher +7 (signed 5‑bit) over the six fitted
  launchers, plus ammo +6 (low 5 bits) over the twelve pocketed rounds.
- For any other machine: machine +6.

**One exchange**, attacker A against defender B (0x424290; PC‑98 ovseg 8 0x4D6):
```
e   = (M(A)² / M(B)) / 2
c   = A pilot CLOSE-COMBAT (crew +12), +1 if A's pilot is Yao Feilun (name id 1)
sq  = c·|c|
dmg = ( (100−sq)·e/4 + (100+sq)·e/2 + (100+sq)·e/4 ) / 100 / 4      (C integer division)
```
- **Easy‑mode option** (DS:0x551D29 bit 1; PC‑98 DS:0x9B2D bit 1): damage to a
  non‑enemy unit is ÷4, and damage by a non‑enemy unit is ×4. A unit counts as
  "enemy" when its status (unit +54) is ≥ 3.
- **Special case:** if A is an enemy and B's unit +3 nibble is 0xF, then
  `dmg = 100`. The nibble is selected by a global flag (PC‑98: the alert flag
  DS:0x4972).
- **Apply:** `B.condition (unit +13) −= dmg`, floored at 0.
- **Experience:** A's pilot +1 CLOSE‑COMBAT, B's pilot +1 DEFENSE.

Verified by emulating 0x424290: 392 / 392 cases match (PLD types 0–6 against
each other, close‑combat 1/4/7/10, with and without Yao).

**Melee sequence** (0x424490, one strike 0x425170; `rules.melee` / `melee_strike`;
PC‑98 ovseg 8 0x77A): Emulated 299 / 299, with the windows stubbed and the experience
recorded. 0x4235B0 / 0x424290 are a second copy of the same code.
1. **Melee weapon:** the attacker's first pocket holding a warhead‑11 round (stun pod
   etc.) that is not broken and has rounds.
   - An enemy attacker always uses it. A player attacker is asked first (message
     0x1A7).
   - If used, the defender gets 3 strikes instead of 4, and one round is spent.
   - If the pocket is then empty it is cleared, whether or not the weapon was used.
2. **Strikes:** the attacker gets 4 (3 with the right manipulator broken), −1 with the
   left one broken. The defender gets its 4 or 3, −1 per broken manipulator. If Yao
   attacks and the defender has strikes, `random(100) < 40` takes one more.
3. **First strike:** the attacker strikes once. If the defender is destroyed, the
   result is 0.
4. **Rounds:** up to 3 while both stand. `random(100) < 50`: the attacker strikes
   first and the defender replies; otherwise the other way round. A side with no
   strikes left does not strike, but its count still goes down. The count then goes
   negative and that side strikes again on later turns (a quirk).
5. **Final strike:** if both still stand and the defender has strikes left, it
   strikes once more.
6. **Result:** 0 defender destroyed, 1 both stand, 2 attacker destroyed, 3 both.
   - The winner's pilot gets +4 CLOSE‑COMBAT and the loser's +2 DEFENSE; for 3, both.
   - The winner's crew gets a kill credit (§4.4).
   - Result 2 credits the defender's crew with the defender itself as the victim (a quirk).

**One strike** (`melee_strike`, 0x425170): the exchange formula above, with two differences:
- the final ÷4 is an arithmetic shift for any sign;
- in easy mode the damage to a player unit is `d >> 4`, taken from the undivided `d`.

An enemy defender whose order nibble is 0xF takes 100. Each strike gives +1
CLOSE‑COMBAT to the striker and +1 DEFENSE to the target.

## 4. Ranged fire: Emulated; identical on PC‑98 except a movement‑mode quirk and the EMP round

**How this was checked:** `tools/verify_rules.py` builds random game states
(units, crew, map layers, terrain block, RNG state). It runs each one through the
game's own functions and through `rules.py`, then compares results, unit bytes
and the RNG state afterwards. Every case matches:
- hit chance 0x415B50: about 16,000 cases;
- damage 0x413A90: about 18,000;
- interception 0x4149F0: 10,000;
- applying a hit 0x413D90: 10,000.

**Final weapon stats** (getters `gnd_attack_of` (0x450940) / `aa_attack_of` (0x4509B0) / `range_of` (0x4508D0); PC‑98 the
same): attack = ammo base + launcher bonus, and range likewise. They reproduce
the Data Book exactly.

**Fire resolution** (`fire_resolution`, 0x415150(area, s, slot, mode, x, y), `rules.fire_resolution`;
PC‑98 ovseg 5 0x1781, same structure): Emulated with the AI fire command below.

**Before the hexes:**
- **Reveal:** the shooter is revealed if its hex is in the other side's view.
- **Experience** (jump table 0x415B04 / 0x415B18): modes 0, 1 and 5 grow ATTACK
  +1, and 6 and 10 grow ANTI AIRCRAFT +1, whatever happens.
- **Shots counter:** the crew's shots counter goes up (see the combat record
  below).
- **Mode with bit 0x80:** the mode is `arg − 0x80` and move = 0. Otherwise
  move = −1, except in modes 5 and 10, where it is the shooter's movement mode.

**Then, for each hex of the area** (skipped if 30+ levels above the shooter):
1. **Smoke** (warhead 8): sets F‑layer bit 0 there. Nothing else happens.
2. **A unit there:**
   - *Valid targets:* direct fire (launcher kind 0) only hits spotted units of
     the other side. AA modes only hit aircraft; the other modes only hit
     ground units.
   - *Interception:* missiles not fired in reaction go through interception
     first (§4.4).
   - *Hit roll:* the roll (§4.2) is **always made**, even after an
     interception, so it moves the random stream.
   - *Miss:* a shot‑down or decoyed missile, or a missed roll, gives the
     target's crew +1 DEFENSE.
   - *Hit:*
     1. The crew's hits counter goes up.
     2. Damage is rolled (§4.3, 0x413A90), and experience grows by mode
        (0x415B24: ATTACK for 0, 1, 5; ANTI AIRCRAFT for 6, 10).
     3. If the target would die, the shooter's crew gets a kill credit by the
        target's machine category (`_kill_credit`, 0x480B10).
     4. The hit is applied (§4.5, 0x413D90). A destroyed target is removed
        at once (`destroy`, 0x480140). The shooter, if it hit itself, is removed after
        the loop.
3. **An empty hex,** DASH campaign only (campaign flag 0; always on PC‑98):
   warhead 13 lays a mine of the shooter's side (F‑layer bit 7 enemy, bit 6
   player). If one is already there it is set off instead (next step).
4. **Mines,** DASH campaign only: after a miss, a decoy or an empty hex, a shot
   with warhead below 3 or 13 sets off a mine on the hex. The blast hits a
   ground unit there (unowned ammo 12, mode 4).

**The AI fire command** (0x415D50(u, slot, x, y), `rules.ai_fire`): Emulated
2812 / 2812. Area, interception, smoke and mines all occur; the shot‑down
path only once.
1. **Mode:** an aircraft on the hex means mode 6 with radius 0. Otherwise it is
   mode 0 with the launcher's blast radius.
2. **Area** (`fire_area`, 0x47DFC0): (x, y) first, then the rest of the blast area (§5.8)
   shuffled with `random()`. An area of 2 hexes or fewer is just (x, y).
3. **Resolve, then pay:** run the resolution, pay the launcher's AP and use a
   round.
4. **Return fire:** a spotted shooter that has not reacted draws reaction fire.

**Combat record** (DS:0x506B39, 26 × 13 B, indexed by crew +15):
- +0 to +3: kills by target category (0: category 0; 1: 6; 2: 1, 7, 8;
  3: aircraft and others);
- +4: shots (16‑bit);
- +6: hits (16‑bit).

All counters saturate.

**Warhead types** (ammo +8 low nibble; PC‑98 ammo +7 bits 2–5), from the round
names: 7 = guided missile warheads (ATM / SAM), 11 = stun pod (melee pocket
weapon), 12 = decoy (DM1 / DM2), 13 = mines and high explosive. PC‑98 only:
14 = passive sensor (L200E), 15 = `.80W800` 電障弾 (electronic disruption round).

**Reaction fire and the 0x80 bit** (`reaction_shot`, 0x4731F0; see §5.4):
- **Reaction against a move** (trigger flag 0): a plain reaction shot (mode 5,
  or 10 against aircraft). Afterwards the moving target pays its evasion AP: 4 / 2
  / 1 / 2 by its movement mode, doubled while carrying.
- **Other triggers** (flag 1, return fire at a unit that just fired; flag 10,
  the other move routines): the mode argument carries bit 0x80. The mode is then
  `arg − 0x80`, and **move** = unit +4 bits 4–5 *of the shooter*, so the
  shooter's movement mode sets the evasion term, and no evasion AP is spent.

For normal fire, move = −1. Both versions behave the same way.

### 4.1 Common helpers

| Helper | Address | Definition |
|---|---|---|
| Hex distance | `hexdist` (0x47D8C0) | Offset‑row hex distance (`rules.hexdist`); the row parity of the *shooter* matters |
| Active | `active` (0x482FD0) | On the map (`0 < x < 71 − (y & 1)`, `0 < y < 71`), flags & 8, condition ≠ 0, not flags & 1, flags & 4 |
| Class | 0x4538A0 | Machine +0 low nibble → `[0,1,2,2,2,2,1,1,1,3,2,2,2,2,2,2]`; class ≥ 2 is airborne |
| Armour type | `armour` (0x47C900) | Machine +0 high nibble (0–4) |
| Warhead | `warhead` (0x47C690) | Ammo +8 low nibble. The round in slot *k* is `unit[0x1B + 2·(unit[0x10 + 2k] & 15)]`; the launcher is `unit[0xF + 2k]` |
| Skill curve | `skill_table` (0x412EF0) | `f(a) = a(a+1)` (kind 0) or `a(a+1)/2` (kind 1), keeping the sign |
| Terrain cover | 0x47CD20 | `S[608 + 16·(5 + class) + S[tile]]`, where tile = the T layer at the unit |

### 4.2 Hit chance (0x415B50)

```
ace(x)   = crew name id of x ∈ {0 Hardy, 4 Fan, 6 Alice, 7 Selma}
base     = max(0, (45 if mode == 1 else 0) + 20·ace(shooter) − 20·ace(target))
total    = accuracy + base + fire control + skill + height + evasion − cover − defense − range
eff      = EFFECTIVENESS[armour(target)][warhead]
eff 1    → never hits (no roll)
eff 2    → hits on random(100) < 98 (one roll)
otherwise: chance = clamp(total·10 / eff, 15, 98)
           r = random(100)
           an ace shooter hits outright on a second random(100) < 30
           hit if r < chance
```
All divisions are C integer divisions (they truncate toward zero). AA modes are
6 and 10; an "air target" has class ≥ 2.

| Term | Function | Value |
|---|---|---|
| accuracy | 0x413090 | Launcher AA accuracy (+5) for AA modes or air targets, else ground accuracy (+2) |
| fire control | 0x413050 | Shooter's fire control unit (+2 bits 2–3) broken: −15 (−35 for missiles); else 0 |
| skill | 0x412FF0 | `f(crew ATTACK)`, or `f(crew ANTI AIRCRAFT)` for AA modes; 0 with warhead 7 |
| height | 0x413380 | `H(shooter) − H(target)`: ≤ −2 → −10, −1 → −5, 0 → 0, 1 → +5, ≥ 2 → +10. 0 for AA modes, air or inactive targets, or warhead 7 |
| evasion | 0x4132F0 | See the evasion rule below the table |
| cover | 0x412E60 | Terrain cover of the target's tile for its class. If the target is concealed (flags bit 0x20): `2·cover + 7·(F & 1)`. 0 for AA modes, air or inactive targets |
| defense | 0x4130F0 | Target crew `DEFENSE·(DEFENSE+1)/2` |
| range | 0x413250 | `max(0, 10·(dist − 3) / weapon range)` if dist > 0 and the shooter is active; 0 with warhead 7. A range‑0 weapon divides by zero (the game crashes too) |

**Evasion rule:**
- `m` = 15 if the target is carrying a unit (+0x34 ≠ 0xFF), else 0.
- Move −1 (normal fire): the term is `m`.
- Move 0, 1, 2: the evasion cost is 4, 2 or 1 AP, doubled if carrying.
  - If the target's current AP (+0xE) ≥ the cost, it can dodge: the term is 0.
  - Otherwise it is `m` + 50 (move 0), + 20 (move 1) or + 5 (move 2).
- Move 3 (searching) has no cost of its own here and uses a unit index instead (the quirk in §6); its bonus is `m` + 5.

Guided missiles (warhead 7) ignore the fire control, skill, height and range terms.

**Effectiveness** (0x412840; PC‑98 ovseg 5 0x132, table DS:0x8B1C): armour type
× warhead.
- Plus Dash has a second table, selected by the campaign flag DS:0x554B10 = 1 (the
  PD2 campaign: see §5.7). It differs only at warhead 13, where armours 0–2
  get 2 instead of 7.
- PC‑98 has only the first table.
```
warhead:  0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
armour 0  7  7  7 20 10 10 40 10  1  1  1  1  1  7  1 10
armour 1  2  2  2 10  7  7 10  7  1  1  1  1  1  7  1 10
armour 2  2  2  2 10  7  7 10  7  1  1  1  1  1  7  1 10
armour 3  1  1  1 10 10 10 10 10  1  1  1  1  1  1  1 10
armour 4  1  1  1 10 10 10 40 10  1  1  1  1  1  1  1 10
```

### 4.3 Damage (0x413A90)

Arguments: shooter, slot, target and mode. A shooter of −1 means no shooting
unit (e.g. scripted fire); the slot is then an ammo id and the warhead counts
as 13.

```
class   = DAMAGE_CLASS[armour(target)][warhead]                     (0x413650)
A       = attack power                                              (attack_power, 0x413540)
          ground (mode 9, or not an AA mode and target class ≤ 1, or no shooter):
              launcher +3 + ammo +1;  mode 3: crew ATTACK + ammo +1;  mode 4: ammo +1
          air:  launcher +6 + ammo +2;  mode 3: crew ANTI AIRCRAFT/2 + ammo +2;  mode 4: ammo +2
if A == 0: no damage
D       = target machine +4 (ground armour), or +5 if the shooter is airborne
cd      = target crew DEFENSE
class 200 ("soft target"):
    div = (cover' + 10) / 10   if the target is active, else 1      (cover_divisor, 0x413490)
          cover' = terrain cover (×2 if concealed) + 7·(F & 1)
    n   = ((A − cd) / div) · (100 − D) / 100
    dmg = (random(n) + random(n) + random(n)) / 2
other classes (0, 20, 50, 100, 201):
    if class 201 and no shooter: A = A / 2
    v      = (A − cd) · (100 − D) · class / 10000
    spread = clamp(v / 4, 2, 10)
    dmg    = max(1, v − spread/2 + 1 + random(spread))
then, by the target's condition (unit +13) before the hit:
    < 11:  enemy ×2,   player ÷2
    < 21:  enemy ×3/2, player ×8/10
easy mode (DS:0x551D29 bit 1): player units take dmg >> 4
dmg is at least 1
```
"Enemy" means unit status (+54) ≥ 3. Each roll keeps only the low 16 bits of the
generator's result; as in the game, a negative `n` wraps to 16 bits.

**Damage class** (PC‑98 table DS:0x8B96, identical for warheads 0–13):
```
warhead:   0   1   2   3   4   5   6   7  8  9 10 11 12  13
armour 0 200 200 200 100 100 100  50 100  0  0  0  0  0 200
armour 1 200 200 200  20  20 100 201 201  0  0  0  0  0 201
armour 2 200 200 200 201 100 201 201 201  0  0  0  0  0 200
armour 3   0   0   0 100 100 100 100 100  0  0  0  0  0   0
armour 4   0   0   0 100 100 100 100 201  0  0  0  0  0   0
```
Warheads 8–12 (class 0) do no fire damage. With no shooting unit the warhead
counts as 13, so mines use the row for 13.

### 4.4 Missile interception (0x4149F0)

Arguments: shooter, slot, target. Checked by emulation over 10,000 random cases,
with the UI calls (prompt, weapon picker, animation) stubbed. All outcomes
occurred: shot down, decoyed and not stopped.

**1. Shoot it down.** Only a target of class 0 can do this.
- **Candidates:** weapon slots 0–3. A slot is excluded if:
  - it has no launcher, or the slot is broken (state 2);
  - its launcher kind is 2 or 3;
  - its pocket is empty, or its round has no AA attack.
  The hand slots 2–3 are also lost when both manipulators are broken.
- **Choice:** score = round AA attack + launcher kind. The first slot with the
  highest score wins. Computer units (status 3+) fire it automatically. A player
  unit is asked "intercept the missile?" (message 0x1E5, with the pilot's given and
  family names and the machine's name), then the weapon picker opens in mode 7 until
  it returns a slot 0–3 or a cancel (−2: no interception). Declining is −2 too.
- **Firing:** one round is spent. `sq = (crew ANTI AIRCRAFT)²` (the code takes
  `abs()` of the square, so the sign is lost). Two percentages:
  - `track = clamp(launcher AA accuracy + sq, 15, 100)`;
  - `kill = clamp(final AA attack + sq, 15, 100)`, where final AA attack = launcher +6 + round +2.
- **Ace target:** if `random(100) < 50`, both percentages get +30 (after the clamp, so they can pass 100).
- **Roll:** shot down if `random(100) < track` **and** `random(100) < kill`.
  The second roll happens only if the first succeeds. The target's pilot gets
  +1 ANTI AIRCRAFT experience.

**2. Decoy.** If the missile was not shot down, the target uses a decoy if it has
one, of any class. A decoy is a pocket with a warhead‑12 round, rounds left, and
state ≠ 2; the last such pocket is used. There is no roll: the missile is
decoyed. One round is spent, and an emptied pocket's ammo id is set to 0xFF.

**Result:** 2 = shot down, 0 = decoyed, 1 = not stopped (the normal hit roll follows).

### 4.5 Applying a hit (0x413D90)

Arguments: target, damage, shooter, slot. The shooter is −1 for no shooting unit;
with slot 12 this is a mine blast. Checked by emulation over 10,000 random cases.

1. **Destroyed:** if condition ≤ damage, condition = 0 and flags |= 1. The game
   then runs its destruction handler (`destroy`, 0x480140). Otherwise:
2. **Mine blast** (target class ≤ 1, no shooter, slot 12): the **movement gear**
   is damaged (below).
3. **Spotting:** if the unit is not yet spotted (flags bit 0x10 clear), compute
   `hide = (cover + 10) × (2 if concealed) × (2 if the pilot has the concealment skill, crew +8 bit 3) + (30 if F & 1)`.
   The unit is spotted (flags |= 0x10) if `random(70) ≥ hide`.
4. **Condition** −= damage.
5. **Critical check:**
   - Damage ≤ 10 causes part damage only on `random(100) ≥ 100 − damage`, i.e. damage %.
   - Easy mode: player units never take part damage.
   - **Count:** 1 critical. If the damage class is not 200, it is 3 on `random(100) < 10`, or, for an ace shooter, on a further `random(100) < 60`.
   - An **ace target** ignores all of it on `random(100) < 20`.
6. **Each critical:** `k = random(13)`. A "step" takes a part from 0 → 1
   (always), or 1 → 2 on `random(100) < 50`; a part at 2 stays at 2.

| k | Part stepped | Condition |
|---|---|---|
| 0 | sensor (head; unit +1 bits 0–1) | — |
| 1 | movement gear (unit +1 bits 2–3 / 4–5) | class ≠ 3 |
| 2–5 | weapon slot k−2 state (slot byte bits 4–5) | class ≠ 3, the slot has a launcher |
| 6–9 | pocket k−6 state (pocket count byte bits 6–7) | the pocket holds a round |
| 10 | right manipulator (unit +1 bits 6–7) | class 0 |
| 11 | left manipulator (unit +2 bits 0–1) | class 0 |
| 12 | fire control unit (torso; unit +2 bits 2–3) | — |

**Movement gear** (`damage_pair`, 0x414310): if either side is already broken, nothing happens.
Otherwise the less damaged side is stepped; when both are equal, `random(2)` picks one.
Melee strikes and interception slots 2–3 depend on the same part bytes. They
look like arms, legs and sensors, but the names are still inferred.

**PC‑98 only, EMP round (warhead 15):** before the mine check, a hit from it does three things:
- breaks the sensor (unit +1 bits 0–1 = 2);
- saves the old value in unit +2 bits 6–7, if +2 bits 4–5 was 0;
- sets +2 bits 4–5 to 3 (what reads them on PC‑98 is not traced yet).

`apply_hit(..., pc98=True)` models this.

**The player's fire command** (`cmd_fire`, 0x425AF0, behind the menu's normal / aimed /
anti‑air fire; `rules.fire_target_map` / `fire_check` / `player_fire`): Emulated 51 / 51
whole commands with the UI scripted, and the target map 60 / 60 on its own.
1. **Weapon:** the picker offers slots 0–3; choices 4+ are its magazine swaps (they pay
   their AP and never fire). A hand weapon (slot 2–3) with both manipulators broken is
   refused (message 0x1A8).
2. **Target map** (0x4118C0): an aircraft counts 6 levels higher while it is built.
   - **Direct fire:** the search map of the weapon's range with penetration 1.
   - **Indirect fire:** the spiral of the range, every hex with a clear arc.
   - **Missiles:** hexes on that spiral less than 30 levels above the shooter and more
     than 5 hexes away, holding a spotted unit of the other side, with a clear arc.
     Armour type 4 counts only in mode 6, and mode 6 only at armour type 4.

   Only hexes of this map can be clicked.
3. **Decision** for the clicked hex. Its unit counts as none if it is an unspotted enemy.
   - **Direct fire:**
     - a smoke round fires at any hex;
     - no unit or a friend: refused (0x1A9);
     - an enemy on the ground fires;
     - in mode 6, any enemy of armour type 4 fires; any other enemy is refused (0x1AB);
     - an airborne enemy outside mode 6 is refused (0x1AA for armour type 4, no message
       otherwise).
   - **Indirect fire:** always asks first (0x1AC if the target is within the blast
     radius, else 0x1AD with the AP).
   - **Missiles:** ask first for an enemy on the ground, or any enemy in mode 6 (0x1AD);
     otherwise refused (0x1A9).
4. **Shot:**
   - the fire area around the hex: blast radius 0 in modes 6 / 7 / 10, else the
     launcher's;
   - the fire resolution;
   - the launcher's AP (doubled for aimed fire) and one round;
   - if the shooter is spotted and has not reacted, the other side's return fire: the
     reaction candidates shoot by the computer's rule (flag 1).
5. The command repeats on the same weapon while the AP, the rounds and the unit last.

**The player's move command** (unit menu entries 0–2: normal speed, high speed,
careful; `unit_command_menu` 0x4EE8D0; `rules.move_refusal` / `can_move` /
`move_destinations` / `move_click` / `player_move`). Emulated whole, menu included,
with every answer scripted: 499 / 499 matching.
1. **Refused:** both manipulators broken while carrying a unit (0x1DA); movement gear
   broken, +1 bits 2–3 at 2 or bits 4–5 at 2 (0x1DB).
2. **Marked hexes** (0x47CED0): every reachable hex of the move map. For machines other
   than wheeled / tracked (category 2–5) a hex held by a unit of the same side is left
   out, the unit's own hex too; helicopters and machine 12 count as "other". With no
   marked hex the command does nothing. Only marked hexes take a click.
3. **The click:**
   - **An adjacent hex**, with a height step below 2 (any step for class 2+ machines):
     a plain step (`ai_walk`) when it is empty, its unit is not spotted, or the mover
     flies (class 3). A spotted unit there: "melee?" (0x1E4, with the hex's AP), then
     the melee. **Results:** 0 the defender is removed and the mover steps in; 1 the
     mover pays the hex's AP; 2 the mover is removed; 3 both.
   - **Any other hex:** "move here?" (0x1DC, with the hex's AP), then the path
     (`ai_path`). A spotted unit on the hex: nothing happens.
4. The command asks for the next click while the unit has AP, is not destroyed and its
   movement gear holds (0x47D780). A right click ends it.

**Mines in the player's phase** (phase flag DS:0x50DDC8 = 0; `step_mine_found` 0x4756A0,
`rules.step_mine_found`). In careful mode a mine of the other side is found:
- **On a single step:** "mine found" (0x1A6), then:
  - with more than 3 AP and the engineering skill (crew +8 bit 1): "clear it?" (0x1A3).
    Yes: 4 AP, the mine is gone, result 2;
  - otherwise, or on no: "destroy it by shooting?" (0x1A4). Yes opens the weapon picker
    (mode 3). The chosen slot pays its launcher's AP and one round; the mine is
    destroyed (0x1A5), result 2;
  - no (or cancel): the mine stays, result 0, and the unit stands on it unharmed.
- **On a path** (with 4+ AP and the skill): "clear it?" (0x1C9). Yes: 4 AP, the mine is
  gone and the walk **stops** (result 1). No: the unit walks on over it.
- **Outside the player's phase** the mine is cleared without asking (result 2). Emulated
  for player movers in the player's phase: 988 / 988 steps matching.

**The player's search, conceal, carry and release** (unit menu entries 8, 9 and 10;
`rules.player_search` / `conceal_check` / `carry_candidates` / `player_carry` /
`release_candidates` / `player_release`). Emulated whole with their prompts answered:
search 306, conceal 290, carry 282 and release 322, all matching.
- **Search** (`cmd_search`, 0x426B10 → `step_search` (0x47F950) in mode 8):
  - **Cost:** 8 AP, 4 with the recon skill; with less the command refuses.
  - **Area:** the unit's own search map, shown with "search here?" (0x1C8). An aircraft
    counts 6 levels higher meanwhile.
  - **On yes:** the area goes into the side's view, and the other side's units in it are
    spotted (as `spot_in_map`, mode 8). The unit pays the AP and its movement mode
    becomes "searching". A window shows each enemy found.
- **Conceal** (`cmd_conceal`, 0x426C00): the AI's rule (`ai_conceal`: 6 AP, 3 with
  crew +8 bit 3), after a prompt showing the cover (0x1B0). Already concealed: 0x1AF.
- **Carry** (entry 10 when the unit carries nobody; `cmd_carry`, 0x427150):
  - **Refused:** both manipulators broken (0x1DD); short of 8 AP (4 with the
    engineering skill); an aircraft (0x212); no candidate (0x1B3).
  - **Candidates:** a neighbouring player PLD (class 0, status 0) at most one level up
    or down. A candidate that carries a unit itself is refused (0x1B4).
  - **On confirmation** (0x1B5): the carrier's +0x34 = the unit, which leaves the map
    (x = y = −1, its hex cleared). The carrier pays the AP.
- **Release** (entry 10 when carrying; `cmd_release`, 0x426D70):
  - **Cost:** 2 AP.
  - **Candidates:** an empty neighbour the carrier's machine category can enter, at most
    one level up or down. None: 0x1B1.
  - **On confirmation** (0x1B2): the unit takes the hex and is spotted only if the hex
    is in the enemy's view. It loses its concealment, and the carrier pays 2 AP.

**Hits without a shooter** (mines, map hazards; 0x413D90 with shooter −1): the
"shooter is an ace" test still runs, on **unit −1**. Its crew byte is the byte just
before the unit table: combat‑record byte 302 (DS:0x506C67). When that crew is an
ace, the hit can damage three parts (`random(100) < 60`), with an extra roll.
Emulated with mine blasts during steps: 2,073 / 2,073 after the fix
(`rules.crew_memory` maps a crew index past 63 onto the combat records and units, as
the game's memory runs on).

## 5. AP and movement: Emulated; identical on PC‑98

Checked with `tools/verify_rules.py` over 5,000 random maps and crowds of units:
max AP (0x450690) and the whole movement map (`make_move_map()`, 0x471C40, named
by the game's own debug string) match byte for byte.

### 5.1 AP per turn (0x450690; PC‑98 res 4E8:4)

```
base   = crew AP (crew +9) × machine +0x18 / 10          (no machine: crew AP)
load   = Σ fitted launchers: launcher +7, signed 5 bits
       + Σ pockets: min(L, (count·200 / capacity) · L / 100)
                    L = round +6 low 5 bits, capacity = round +0 (rounds per pocket)
max AP = base − load                                     (byte arithmetic)
```
A pocket at half capacity or more weighs its full load; an emptier one weighs
proportionally less. The current AP is unit +0xE. Every action spends it
(`spend_ap`, 0x47CC60, floored at 0), and it is refilled to the maximum at the start of the
unit's turn (seen on airdrop landing).

PC‑98 computes the same values in 16‑bit arithmetic. It differs only for
impossible data, such as a pocket holding more rounds than its capacity.

### 5.2 Movement cost map (`make_move_map`, 0x471C40, step costs `move_map_expand` (0x471F10); PC‑98 ovseg 0 0x3A)

The game builds the AP cost to reach every hex this turn with a bucket‑queue
Dijkstra search:
- 64 buckets, indexed by cost mod 64;
- bounded by the unit's current AP;
- over a window around the unit, `move_box` (0x47D7E0).

The move prompt then reads the cost of the chosen hex from this map ("必要ＡＰ /
現在ＡＰ / 地形防御 / 移動・中止").

**Neighbours** (`hex_step`, 0x47D930), odd rows offset right:
- even rows: (−1,−1) (0,−1) (+1,0) (0,+1) (−1,+1) (−1,0);
- odd rows: (0,−1) (+1,−1) (+1,0) (+1,+1) (0,+1) (−1,0).

**Movement type:**
- air: machine categories 2–5;
- "other": category 9, or machine type 12 (no terrain flag, height or blocking rules apply to it);
- ground: everything else.

**Cost of one step** into hex g (from hex c, with `cur` AP already spent):
```
cost = S[528 + 16·category + kind(T[g])]       terrain row by machine category; 0 = impassable
       0 if H[g] = 0                            (height 0 is impassable)
ground: ×2 if F[g] & 1
        height step H[g] − H[c]: −1, 0 → ×1;  +1 → ×2;  other → impassable
× movement mode: high‑speed ×1, normal ×2, careful ×3   (unit +4 bits 4–5)
× 2 while carrying a unit (+0x34 ≠ 0xFF)
```
**Units in the way** (ground and "other"):
- **First step (`cur = 0`) into an enemy‑side unit:** +2 AP, and the hex is
  flagged 0x80 if that unit is spotted. Entering it starts a melee; the manual's
  melee rule is "2 AP more than a normal move".
  - Not allowed when carrying, for non‑ground types, or against armour type 4.
- **Later steps:** a spotted enemy blocks the hex. An unspotted one doesn't (you
  find it by bumping into it).
- **Status:** a unit with status 1 always blocks.

Then `total = cur + step`. It is dropped if it exceeds the current AP, and kept
only if it beats the hex's existing value (compared on the low 7 bits). Melee
hexes (flag 0x80) are never expanded further.

**Result:** the unit's own hex = 0, unreachable = 0xFF, otherwise the cost (with
0x80 for a melee step).

The movement mode factors match the manual (14.2): high‑speed costs about half
of normal, and careful about 1.5×. This confirms the mode order 0 = high‑speed,
1 = normal, 2 = careful. Search mode 3 has no factor (an uninitialised
variable), so it is never used for moving.

**S map layer** (as the move and cover code read it):
- bytes 0–255: terrain kind per tile id;
- bytes 528–847: 20 rows × 16 kinds, through the pointer table DS:0x50D8D8:
  - rows 0–9: movement cost by machine category;
  - rows 10–13: cover by unit class;
  - rows 14–19: unknown;
- bytes 848+: AI waypoints;
- bytes 512–527: **sight blocking** per terrain kind (bit 0; §5.5);
- bytes 256–511: still unknown.

### 5.3 Action AP costs: Code

| Action | AP | Source |
|---|---|---|
| Normal fire (mode 0) / AA fire (mode 6) | the launcher's AP cost: launcher +8 low 5 bits, signed (`launcher_ap`, 0x47C450) | `cmd_fire` (0x425AF0), the fire‑command routine shared by all three fire commands |
| Aimed fire (mode 1; +45 to hit) | 2 × the launcher's AP cost | same; the manual: "twice a normal shot" |
| Move | the move map (§5.2) | |
| Melee | the step cost + 2 (§5.2) | the "消費ＡＰは%3dです" prompt |
| Carry / release | 8 (4 with engineering) / 2 | `cmd_search` (0x426B10); the manual |
| Clear a mine | 4 | messages 0x1A3, 0x1C9 |
| Use an item (throw, place a sensor) | the round's ammo +7 low 5 bits (§5.16) |
| Conceal, lay mines | shown in their prompts; not yet decoded | `cmd_conceal` (0x426C00), 0x428D80, 0x46A6D0 |

Each shot also uses one round from the slot's pocket. Launcher +8 bits 5–7 are
the launcher **kind** (2 = missile, which triggers interception), and launcher
+9 low 3 bits its **class** (1 = direct fire; only class‑1, kind‑0 weapons react
against ground targets).

### 5.4 Reaction fire: Emulated (weapon choice and the computer's rolls)

**When reactions are checked** (`reaction_candidates`, 0x472410 builds the list, `reaction_loop` (0x472920) resolves it):
- after each movement step (trigger flag 0);
- after a unit fires, if it is **spotted** and has not itself reacted this turn
  (flag 1; the fire command `cmd_fire` (0x425AF0) and others);
- from the other move routines (flag 10).

**The player's reaction menu** (`reaction_loop`, 0x472920, when the target is an enemy;
`rules.player_reactions` / `weapon_choices`). Emulated: the menu loop 600 / 600 with the
player's answers scripted, and the weapon picker 600 / 600.
1. **Menu** (`reaction_menu_list`, 0x472ED0): the candidates (`reaction_candidates`, in
   order) that have not reacted yet, after two fixed entries:
   - entry 0 marks the *target* as having reacted (flag 0x40, through 0x4EE870), then ends;
   - entry 1 just ends.
2. **Weapon picker** (`ui_reaction_weapon_picker`, 0x4E7EE0, mode 5, or 10 at an
   aircraft, at the reactor's distance to the target). Items 0–3 are the slots, 4–7
   their magazine swaps. Slot k is disabled when:
   - its range is 0, or below the distance in modes 5 / 10;
   - it is a hand slot and both manipulators are broken;
   - in anti‑air modes (6 / 7 / 10): the launcher's AA accuracy is 0 or the AA attack is 0;
   - in the other modes: the ground accuracy or attack is 0 (smoke exempt), aimed fire
     uses a blast radius, or a ground reaction uses a launcher of radius other than 1;
   - the AP is short, except in modes 5 / 7 / 10;
   - the launcher kind is 3, is not direct in modes 1 / 5, or is a missile in mode 7;
   - the slot is empty, its pocket is broken, or the slot is broken.

   A swap item is disabled when the launcher takes no magazines (+9 bit 3), takes a
   single round type (+0xB = 0xFF), or the count reads −1. An empty slot reads launcher
   −1, the 17 bytes before the launcher table (machine 31's tail).
3. **Choice:** a slot fires a reaction shot (`reaction_shot`). A swap item only reopens
   the picker; no magazine is changed here. Cancel goes back to the menu.
4. **Repeat:** the menu comes back after each shot until it is empty, the player ends it,
   or the target is destroyed. Unlike the computer's branch, this one writes nothing to
   the AI memory.

The same picker, in modes 0 / 1 / 6, offers the weapons of the fire command.

**Who can react** (`reaction_candidates`, 0x472410): every unit that meets all of these:
- on the other side, status ≠ 1, active;
- its order nibble (unit +3, low or high nibble by the alert flag DS:0x50ADF1)
  is not 0xF;
- it has a reaction weapon (below);
- it is not 30 or more height levels below the target;
- it can see the target (§5.5):
  - a class‑2 target (aircraft) is always seen;
  - within 2 hexes, the short trace decides;
  - otherwise the line of sight decides.

**The weapon** (`reaction_weapon`, 0x472790): a unit that has already reacted this turn (flags
0x40) cannot react again. Otherwise it picks, among slots 0–3, the weapon with
the highest final attack (AA attack against aircraft, ground attack otherwise).
A slot qualifies when:
- it has a launcher, the slot isn't broken, it has rounds, and its pocket isn't broken;
- for a hand slot 2–3, the unit has a working manipulator;
- against a ground target, the launcher is class 1 and kind 0;
- its range reaches the target.

**Computer units** (`reaction_loop`, 0x472920, when the target is a player unit): each candidate,
in list order, fires if `random(100) ≤ p`:
- `p = 100` if its condition is below 40;
- else `p = 80` for flag 1 or 10;
- else by the target's movement mode: high‑speed 90, normal 75, careful 60.

  While the target is searching, `p` keeps its previous value: initially the
  target's index in Plus Dash, an uninitialised local on PC‑98.

Each shot sets the shooter's 0x40 flag. Reactions stop once the target is
destroyed. A target with index < 40 has its position recorded for the AI
(DS:0x551DA0, 3 B per unit).

**Player units** reacting to an enemy get prompts instead (`reaction_menu_list`, 0x472ED0 / `ui_reaction_menu` (0x4730E0)
and the weapon picker). These are not modelled.

### 5.5 Line of sight: Emulated; identical on PC‑98

Checked with `tools/verify_rules.py`: 18,000 random lines (both variants) and
1,500 full reaction‑candidate lists (`reaction_candidates`, 0x472410) match the game.

**Line of sight** (`line_of_sight`, 0x410A90; PC‑98 res DDF:A), from a viewer hex to a target hex:
- **Heights:** the eye is the viewer hex's height + 1. An aircraft (class ≥ 2)
  standing on the viewer hex raises it to 31, or one more if already 31 or
  above. The target point is the target hex's height (no +1).
- **The line:** it runs in doubled‑x coordinates (X = 2x + row offset), stepping
  along the major axis (`line_point`, 0x4DE4A0), for `max(2·|Δx| + 2, |Δy| + 1)` steps. Each
  step's point is turned back into a hex. Hexes repeated in a row, and hexes
  farther than the target, are skipped.
- **Two variants:** the game runs the line twice, once with each rounding for
  points between hexes. Sight is clear if **either** line is clear.
- **At each hex** on the line, at distance `d` from the viewer (`D` = viewer to
  target):
  - **Height 0:** blocks.
  - **Terrain:** blocks if `(h − eye)·D > d·(target − eye)`, i.e. the ground
    rises above the sight line.
  - **Obstacles:** F‑layer bit 0 (smoke or cover) and sight‑blocking terrain
    (S bytes 512 + kind, bit 0) each count as one obstacle. They count only if
    they reach the line (`(h − eye + 1)·D ≥ d·(target − eye)`) and `h ≥ eye − 1`.
  - **Obstacle limit:** more obstacles than the limit (callers pass 1) block. Reaching
    the limit is allowed only on the target hex itself, so a target can stand in
    a forest, but you can't see through one.

**Short range** (≤ 2 hexes, inside `reaction_candidates` (0x472410)):
- The game traces from the *target* toward the viewer with both line variants
  until each leaves the target hex.
- The viewer sees the target unless **both** first hexes are 2 or more levels
  above the target hex.
- Both traces take the target's starting row parity from its *x* coordinate
  instead of its y. This is a quirk of the original code; PC‑98 has it too.

**Other gates for reactions:** the reactor is not 30 or more levels below the
target. Class‑2 targets skip the sight test entirely.

### 5.6 Recon and spotting: Emulated; same structure on PC‑98

Checked with `tools/verify_rules.py`, all matching the game:
- 600 sight‑level lines (`sight_levels`, 0x410F30);
- 285 search maps, both the raw builder `search_map` (0x4114C0) and the unit search `unit_search_map` (0x411760);
- 300 recon range readings;
- 800 unit‑sees‑unit tests (`sees_unit`, 0x412190);
- 135 spotting passes (`spot_in_map`, 0x47EDC0), with 512 units spotted.

**Recon range and penetration** (`unit_search_map`, 0x411760 picks them by search mode):

| Mode | Range / penetration |
|---|---|
| 0 | 2 / 2 (the absolute range only) |
| 1 (while moving), 2, 8 (search command) | the unit's own: machine +7 / +8 plus round +4 / +5 of each fitted, unbroken weapon slot (`recon_range`, 0x450A80 / `recon_penetration` (0x450AF0)). A broken sensor gives 2 / 2 |
| 12 | a pocket item's round +4 / +5 (probes) |
| 13 | a placed item's round +4 / +5, at the given position |

**The search map** (`search_map`, 0x4114C0):
- **Window:** the same window as the move map (§5.2), sized by the range. The
  own hex starts at 6.
- **Rings:** for each ring r from the range down to 1 (`ring_start`, 0x480EA0 corner, 0x4113D0
  ring), it takes each ring hex not yet decided (level < 6 and ≠ 4).
- **Lines:** it traces a sight line to that hex with both variants (`sight_levels`, 0x410F30).
  - **First variant:** level 4 sets 4; other levels add to the hex.
  - **Second variant:** level 4 sets 4; level 6 overrides; level 1 is ignored.
  - In both, a hex already at 6 or more, or at 4 meeting a level 1, is left alone.
- **Result:** a hex is **seen** if its total is 6 or more, compared as a signed byte.

**Sight levels along a line** (`sight_levels`, 0x410F30): it uses the same line, eye and target
heights as the line of sight (§5.5), with the obstacle limit set to the
penetration. Each hex gets a level:

| Level | When |
|---|---|
| 4 | height 0, or height 60 or more |
| 1 | below the running horizon (the highest slope met so far), unless within 2 hexes with no rise yet |
| 1 | past more obstacles than the penetration (beyond 2 hexes), or anything beyond once blocked |
| 6 | otherwise (seen) |

**Spotting** (`spot_in_map`, 0x47EDC0): every unit on a seen hex that is on the other side and
not yet spotted becomes spotted (flags |= 0x10). Armour type 3 is never spotted
this way. By mode:
- **Search command (8; also 0 and 2):** everything seen is spotted. It costs 8 AP,
  or 4 with the recon skill (crew +8 bit 0), from `search_command` (0x47F500).
- **While moving (1):** a unit is spotted only within 2 hexes, or when its
  **concealment** (terrain cover, doubled when concealed, + 7 on the F‑layer
  flag) is below 10.

These are the manual's two rules: the search command finds everything in range,
while moving finds only units in the absolute range or on open terrain.

**Aircraft** (still `spot_in_map` (0x47EDC0)): every active aircraft on the other side (class
≥ 2) that the searcher **sees directly** is also spotted:
- the searcher's own recon range must reach it;
- then the unit‑to‑unit sight line (0x411EC0) with the penetration as the obstacle limit.

The unit‑to‑unit line differs from §5.5 in three ways: the eye is the viewer's
ground height (no +1), the aim point is the target's height + 1, and height‑0
hexes do not block. During the search command, an airborne searcher's hex is
raised 6 levels for this check (manual: "helicopters climb 6 to search").

### 5.7 Turn flow: Code; upkeep, recon pass and the passes around the AI Emulated

The mission routine (`mission_loop`, 0x436690) sets up the mission, runs the mission script with
stage 2, then loops. The loop is a state machine on a command code, but one turn
runs in this order. `phase` is DS:0x50DDC8: 0 = player, 3 = enemy.

**1. Turn start** (before the player acts):

| Step | Routine |
|---|---|
| airdrop approaches (§5.17) | 0x44AEA0 |
| the player side's fire‑support strikes (§5.13) | `strike_executor` (0x4E37A0(0)) |
| the player side's strike marks again (as `refresh_strikes`) | 0x483ED0(0) |
| reinforcements enter or leave the map ("進入開始!!", §5.14) | 0x44F2E0 |
| sensors rescan their area, then count down (§5.16) | 0x480910, table DS:0x50AC58 |
| timed explosives (bombs set with a fuse) go off (§5.15) | 0x480280, table DS:0x50AC1C |
| every unit's "has reacted" flag is cleared | `clear_reacted_all` (0x4361A0) |
| the view centres on the first player unit | 0x436360 |

**2. Player phase:** the "user turn start" banner, then commands (`command_loop`, 0x4EF600)
until the turn ends. A command that leaves the end code DS:0x50ADF2 set ends the phase
(§5.18). (Table 0x51EC68, once taken for a state check here, is the sortie screen's
deploy check.)

**3. End of the player's turn**, in order:
1. mission state (`mission_state`, 0x484160);
2. player‑side support fire (`support_fire`, 0x4E0BF0);
3. mission script stage 1;
4. **every spotted flag is cleared** (`clear_spotted_all`, 0x437440), so spotting lasts one turn.
   Option bit 0x80 keeps enemies spotted.
5. the turn recon pass for the player side (`recon_pass`, 0x483490);
6. phase := 3; upkeep and AP refill for the enemy side;
7. the recon pass for the enemy side;
8. the enemy side's fire‑support strikes (`strike_executor` (0x4E37A0(3)), §5.13), the AI
   memory aged, then "has reacted" cleared again;
9. **the computer's units act** (`ai_turn`, 0x42A950, the generic AI in §5.8);
10. enemy support fire;
11. phase := 0; upkeep and AP refill for the player side;
12. phase := 3; mission script stage 0 (the mission's events for this turn).

Every mission also has its own **event scripts** (§5.8), called at fixed points
through 16 tables indexed by the mission number (DS:0x50CE72).

**Turn recon pass** (`recon_pass`, 0x483490, stage 0): every active unit of the phase's side
runs a search (`search_command`, 0x47F500) with its **movement mode** as the search mode:
- high‑speed → range 2 / 2 only;
- normal → its own recon with the "while moving" spotting rule;
- careful → its own recon, spotting everything it sees.

This is the manual's table of movement modes (§14.2).

**Upkeep** (`turn_upkeep`, 0x483250), emulated 150 / 150. For each active unit:
- AP experience +2 if it ends the phase with at most 1/16 of its max AP left;
- on the **supply tile** (tile id 0xFE), condition is repaired up to 100;
- with option bit 0x20, when the selected unit's pilot is an ace, +5
  experience in all five abilities.

The details depend on the campaign flag DS:0x554B10. It is 1 for the missions numbered
1–10 (the PD2 campaign) and 0 for 11–22 (DASH), set in 0x46D780. The file opener
(0x408BE0) reads from the `pd2\` folder when it is set and from `dash\` when clear, and
0x409240 copies that campaign's record block and name tables into the working copy.
PC‑98 has only the flag‑0 version:

| | flag 0 (DASH; PC‑98) | flag 1 (PD2) |
|---|---|---|
| Units | 0–63 | all |
| AP refill | separate, in `refill_ap` (0x483090) only | also here, for every active unit |
| Repair per phase | 1 + random(5) | 1, not in the enemy phase |
| Aces for the training bonus | name ids 0, 4, 6, 7; not in the enemy phase | 4, 6, 7 |

**AP refill** (`refill_ap`, 0x483090), emulated 150 / 150: every unit of the side whose phase
begins gets its AP set to the maximum (§5.1).

**The passes around the computer's turn**, read in `mission_loop` and emulated one by one
(`rules.py`; `verify_turn_passes`, `verify_recon_pass`, `verify_support_fire`):
- **View reset** before each recon pass: `clear_view` (0x47D5C0) clears the side's view
  marks on the map; with option bit 0x80, `view_all` (0x437370) marks the whole map
  instead.
- **Spotted flags** (`clear_spotted_all`, 0x437440): cleared for units 0–253; with
  option bit 0x80 the computer's units (status 3+) are set spotted instead.
- **Turn recon pass** (`recon_pass`, 0x483490(0)), emulated 300 / 300: see above. The
  side is the current phase's. With the campaign flag, F‑layer bit 5 is first cleared
  on the map. Each unit's search is `search_command` without its prompt, which for
  movement modes 0–3 is `step_search`. It ends with the sensor list DS:0x50AC58
  (42 × 4 B: x, y, turns, ammo id, filled by the item command 0x4ECC60): its on‑map
  entries with turns > 0 search from their hex (0x4806A0: unit −1, mode 13, the
  ammo's recon range; §5.16).
- **AI memory pruned** (0x480BF0), just before the computer's turn: entry k of the 40
  is cleared to −1 unless unit k is an active player‑side unit whose remembered hex
  is on the map and **not** in the computer's view.
- **AI memory recorded** (0x480C60), at each turn start: an active, spotted
  player‑side unit standing in the computer's view is remembered at its hex.
- **Strike marks** (0x46F590(0)) are cleared on the map after the player's upkeep.
- **Smoke clears** (0x483B50) at each turn start: every hex with smoke (F‑layer
  bit 0) loses it with `random(100) < 25`, in row order.
- **Support state** (`support_fire`, 0x4E0BF0(side)), after each side's turn: in every
  group with members, a support state (+0x21 high nibble) of 3, 4 or 5 and +0x16 set,
  the first member that changes something decides: a unit of the side (status side to
  side + 2) with support order +6 = 1 sets the group's +2 high nibble to 0xA; in state
  5, a unit of another side sets it to 2 when +2 has bits 4–5 = 2 and bits 6–7 = 1.
- **Turn start** (`LAB_00436b39`, also reached at a new mission after the player's
  upkeep and AP): smoke clears; spotted flags; the computer's view reset and recon pass
  (phase 3); AI memory recorded; phase := 0; the player's view reset and recon pass.
- 0x483AD0 lists the active flying units at DS:0x551D60, but nothing in the exe reads
  the list. 0x4361C0 (the date window), 0x436360 (the camera) and 0x4F3DA0 (a map
  built for the display) are UI.

**Unit removal** (`destroy`, 0x480140), emulated 1,000 / 1,000:
1. +0 bit 0 (destroyed) and condition 0;
2. the unit leaves the map (0x47FEE0): its hex is emptied (0x46ED80, the edge hexes
   too), a unit it carries is put down there (not concealed), its status is reset to
   its crew's +2, then x = y = −1;
3. a player unit (status 0, after the reset) loses its weapons (+0xF.., 6 slots) and
   pockets (+0x1B.., 12) to 0xFF (0x43BD60);
4. the first group (of 64) with members and +2 bits 4–5 set that lists it drops it:
   - status ≤ 2 (0x4549B0): members are crew numbers below 27 (28 with the campaign
     flag) and unit numbers above. The rest of the list moves up, freed slots get 0xFF
     and the count drops. The crew goes back to the free‑pilot pool (crew +5 = 0xFF,
     appended to DS:0x50AD02, count DS:0x50AD00); with the campaign flag, a member
     listed by unit number keeps its crew while DS:0x50663A is set (it is 1 in the
     battle: 0x487D70 sets it before 0x436530 runs `mission_loop`), and a pool of more
     than 64 is first rebuilt from the crews whose +4 is not after DS:0x50AD92, with
     +2 ≤ 2, +5 = 0xFF and +6 bits 0–1 clear;
   - status 3+ (0x441F40): groups below 20 as above; others clear the member slot and
     drop the count, and the unit leaves the map again.

**A new mission** (`mission_loop` with DS:0x50AD94 = 0), emulated where it is rules:
1. the mission's data is loaded (0x482910): the S, M and H layers from chunk
   DS:0x50663D − 1 of `MISSON?D.PCK`; the map graphics (P, C) from the same chunk, except
   that with the DASH flag (0) they go through a table in which mission 3 uses chunk
   5's graphics. The occupancy layer is emptied and every F‑layer bit but bit 5 is
   cleared (smoke, views, strikes and mines included);
2. `start_units` (0x437490): every unit (0–253) carries nobody and gets its maximum AP;
3. the mission script, stage 2 (§5.8, for the missions ported);
4. the occupancy layer is rebuilt from the active units (0x483030, units 0–253 in order);
5. the mission's start script (table 0x51F0F8; §5.8, for the missions ported);
6. phase 0: upkeep and AP refill; phase 3; then the turn start (see the passes above).

**When the mission ends** (`mission_loop` returning anything but 0xC0), emulated:
0x4373B0 resets every unit (0–253): movement mode 0, not concealed, not reacted,
carrying nobody, +6 = 0, all parts and slot / pocket states repaired (0x429950), off the
map; the timed‑explosive list (DS:0x50AC1C, 15 × 4 B) and the sensor list are emptied.
Then 0x4374C0 marks units 0–39 whose machine has +0x1C set as destroyed (a unit with
no machine reads the end code DS:0x50ADF2 there: §5.18).

### 5.8 The computer side: generic AI and per‑mission event scripts

**Mission numbering.** The global mission number (DS:0x50CE72, 1–22) indexes
every per‑mission table:
- scripts 1–10 are the PD2 campaign's mission chunks 0–9, played in the order
  1, 3, 2, 5, 7, 8, 6, 4, 9, 10 (step table DS:0x50CC0D, then 0x50CC17 after step 7);
- scripts 11–22 are the DASH campaign's chunks 0–11 (step table 0x50CC14);
- the data chunk is DS:0x50663D − 1.

Partly inferred: the DASH chunk numbering is not fully traced.

**The generic AI** (`ai_turn`, 0x42A950, run once in the computer's phase) moves and fights
the computer's units. It walks the **order codes** in a fixed priority:

`8, 3, 4, 9, 0, 7, 10, 2, 1, 5, 6, 11`

For each code, every active enemy unit whose order matches runs that code's
behaviour (`_ai_dispatch`, 0x42B990). The order is the unit's +3 low nibble, or the high nibble
once the alert flag DS:0x50ADF1 is set (the S layer has 8 normal and 8 alert
waypoint sets to match). Order 0xF never reacts (§5.4).

**The turn driver** (0x42A950, `rules.ai_turn`): Emulated 24 / 24 whole turns, and
the sight map 30 / 30 on its own.
1. **Player sight map** (`player_sight_map`, 0x42B440 → `player_sight_bits` (0x42B4A0) → `unit_sight_cells` (0x42B5C0), `rules.player_sight_map`).
   Each active player unit 0–24 with status 0 marks what it sees within 14 hexes:
   - within 2 hexes: everything not 30+ levels below it. At exactly 2 hexes a short
     two‑variant trace hides the hex when both first steps are 2+ levels below the
     viewer;
   - farther out: a line of sight (limit 1) *from the hex to the unit*, unless the
     hex is 30+ levels below.

   Units 0–15 set a 16‑bit mask and 16–23 a byte. Unit 24's bit falls off the byte.
2. **Strike marks** (0x483CB0(3), `rules.refresh_strikes`): the F‑layer strike bits are
   cleared and set again around the aims of enemy fire‑support members still under
   orders.
3. **The behaviours:** for each order code in priority order, units 0–253 with
   status ≥ 3 that are active and carry that order run its behaviour (`_ai_dispatch`, 0x42B990). A UI
   abort code ends the turn.
4. **Groups arriving at the fire point:** groups at DS:0x50AD95 with units, type 0xF
   (+33) and +2 bits 4–5 = 2. Their enemy members that are neither destroyed nor
   deployed, but stand on the map, are deployed (flags | 0x0C) and run their order:
   - **Where:** on their own hex if it is free and reachable (class 3 or height ≥ 30);
   - **else** on the edge columns 1 / 69 / 70, the hex above or below;
   - **else** on the edge rows 1 / 70, the hex left or right.

   The scan of a group stops at its first member below status 3. The reachability
   test reads the unit class of the **group index**, a quirk.

**The behaviours:** Code (structure); names inferred.

Every behaviour is built from the same blocks, in its own order and with its own
branches:

| Block | Routine | What it does |
|---|---|---|
| reload | `ai_reload` (0x42D140) | reload empty slots from compatible pockets, or drop the launcher (`rules.ai_reload`) |
| fire support | `ai_fire_support` (0x42C850) | **call in fire support** from artillery‑type groups (`rules.ai_fire_support`; see below) |
| engage | `ai_engage` (0x42D770) | pick a target among three kinds of candidate (`ai_pick_indirect`, 0x42DFF0 / `ai_pick_direct` (0x42DD50) / `ai_pick_aa` (0x42DA50)) and act, with `random()`; takes (radius, threshold, shots), e.g. (2, 80, 2), (1, 300, 2), (0, 40, 2) |
| conceal | 0x42D3D0 | conceal (`rules.ai_conceal`) |
| search | 0x42D430 | the search command (`rules.ai_search`) |
| weapon check | `ai_longest_range` (0x42D700) | longest non‑missile range with a ground attack (`rules.ai_longest_range`) |
| enemy near | `ai_player_within` (0x42C790) / `ai_any_player` (0x42C810) | a player unit within r hexes / any player unit active (`rules.ai_player_within`, `ai_any_player`) |
| destination | `ai_destination` (0x42E310) | a destination of a given **type** |
| move | `ai_move` (0x42EE00) | move toward it: move map (§5.2), destination choice, `random()` |

The table counts the enemy units with each order across the 22 missions' `INIT`
data, so it doubles as a porting priority:

| Order | Routine | Size | Units (normal / alert) | Destination type, move | Notes |
|---|---|---|---|---|---|
| 1 | `ai_behaviour_1` (0x42BA90) | 3.3 KB | 726 / 1177 | type 6 (hunt) or 0 | **ported** (`rules.ai_behaviour_1`). Charges when strong (condition ≥ 55 / 60 and melee value > 60); engages, searches. The main **alert / attack** behaviour |
| 2 | `ai_behaviour_2` (0x430A80) | 1.9 KB | 943 / 397 | type 1, then stay | **ported** (`rules.ai_behaviour_2`). Reload, search, conceal, support, engage. The main **normal / guard‑post** behaviour |
| 3 | `ai_behaviour_3` (0x4311C0) | 3.1 KB | 160 / 195 | type 2, move mode 6 → 7 / 8 | **ported** (`rules.ai_behaviour_3`). Hunt the hidden: goes for the nearest unspotted player; a 40 % branch |
| 4 | `ai_behaviour_4` (0x431770) | 1.7 KB | 117 / 89 | type 3 then 1, move mode 6 | **ported** (`rules.ai_behaviour_4`). Advance, then hold: 50 % and 20 % branches |
| 5 | `ai_behaviour_5` (0x432350) | 0.8 KB | 13 / 262 | type 3, move mode 3 | **ported** (`rules.ai_behaviour_5`). Go to the destination, fighting on the way |
| 6 | `ai_behaviour_6` (0x432690) | 2.4 KB | 367 / 190 | type 3, move mode 3 | **ported** (`rules.ai_behaviour_6`). Patrol: a 30 % search each round, a single opening shot |
| 7 | `ai_behaviour_7` (0x432B40) | 1.2 KB | 129 / 205 | type 3, move mode 4 | **ported** (`rules.ai_behaviour_7`). Careful advance: shoot, move, search |
| 8 | `ai_behaviour_8` (0x431E00) | 1.4 KB | 34 / 23 | type 4, move mode 4 | **ported** (`rules.ai_behaviour_8`). Patrol the waypoints; 50 % and 20 % branches |
| 9 | `ai_behaviour_9` (0x4334F0) | 0.4 KB | 33 / 22 | type 5, move mode 4 | **ported** (`rules.ai_behaviour_9`). Move and dig in: conceal, support, search (PC‑98 also fires once) |
| 10 | `ai_behaviour_10` (0x433020) | 1.2 KB | 37 / 53 | type 1, move mode 1 | **ported** (`rules.ai_behaviour_10`). Hold the post: conceal and search first; one round only (a quirk) |
| 11 | `ai_behaviour_11` (0x433690) | composite | 107 / 1 | type 3 | **ported** (`rules.ai_behaviour_11`). Acts as order 1 when a player unit is in weapon range and some spotted player is active (`_any_spotted_player`, 0x4334A0), else takes destination type 3 and acts as order 5 |
| 0, 12–14 | — | — | 2552 / 2594 (0); 5 / 5 (12–14) | — | no behaviour (12–14 fall outside the dispatcher) |

**Destination types** (0x42E310, `rules.ai_destination`): Emulated 300 / 300
over all 7 types, including the memory updates and the RNG.

"Own destination" is unit +7 / +8; "seen" is the side's view bit in the F layer
(`in_view`, 0x46F2D0: bit 3 for the player side, bit 2 for the enemy side).

| Type | Destination |
|---|---|
| 0 | own destination if on the map, not reached, and **not** in the enemy side's view; else the nearer of the nearest spotted player unit (`ai_nearest_spotted`, 0x42E990) and the nearest remembered one; else a waypoint |
| 1 | none once at the own destination (stay); else the destination if on the map; else a waypoint |
| 2 | the nearest **unspotted** active player unit among units 0–39 (`ai_nearest_unspotted`, 0x42ED30: the AI knows where hidden units are); else the nearest remembered unit; else a waypoint |
| 3, 5 | the own destination while on the map and not reached; else a waypoint |
| 4 | the own destination, unless it is occupied by a unit within 2 hexes of us; once there or if off the map, the **next** waypoint after it. With no waypoint this returns (0, 0), a quirk |
| 6 | the own destination if on the map, unseen and empty; else **hunt**: the spotted player unit with the lowest melee value (below 100), taking a nearer or equal one each time; else as type 0 |

All candidates must stand on terrain the unit's machine category can enter (§5.2).

**Waypoints** (0x42EA60, `rules.ai_waypoint`):
- **Set:** each unit uses one waypoint set, chosen by unit +4's low nibble
  (+ 8 once the alert is raised). Each set is 4 points of (x, y) at S‑layer
  byte 848 + 8·set.
- **Type 4:** the point after the one the unit is heading for, cycling 0 → 1 → 2 → 3 → 0.
- **Other types:** up to 4 tries of `random(4)`, re‑rolled while already tried.
  A point is skipped if it is impassable, off the map, or the current
  destination.

**Enemy memory** (DS:0x551DA0, 3 B per player unit 0–39): a player unit's
position is recorded when it is shot at by reaction fire (§5.4). Emulated: the reaction loop (`reaction_loop`, 0x472920) writes it after its shots when at
least one reactor fired. The AI goes for
the nearest remembered position. An entry is forgotten (set to 0, 0, 0xFF) when
that hex, or the unit's real position, is in the AI side's view.

**Choosing a shot** (0x42DC80, `rules.ai_fire_score`): Emulated 283 / 283.

`score = (AP left / weapon AP cost) × min(estimate, 100) / 10 × expected damage`

AA mode is used against class‑3 targets. The AI estimates with its own copies of
the fire rules, which differ from the real ones:
- **Hit estimate** (`ai_hit_estimate`, 0x413110): the nine hit terms, but **no ace bonuses**, and an
  aimed‑fire base of **+50 in the DASH campaign (flag 0) and +30 in PD2 (flag 1)**. The real roll uses +45.
- **Expected damage** (`ai_expected_damage`, 0x413C80): class 200 gives n with no dice; other classes
  give `v − spread/2`, at least 1, with **no halving for class 201** and no
  low‑condition multipliers. It still calls `random(v − spread/2)` and throws
  the result away, so estimating moves the random stream.

**Engage** (`ai_engage`, 0x42D770(u, radius, threshold, max_shots), `rules.ai_engage`):
Emulated 600 / 600, with the shot itself (`ai_fire`, 0x415D50) and reloading (`ai_reload`, 0x42D140)
stubbed; the stub spends the weapon's AP and a round, and sometimes destroys the
shooter. All three pickers score in the check. Engage fires repeatedly:

1. **No player unit active** (`ai_any_player`, 0x42C810): return 0.
2. **Each round runs the three pickers, in this order.** The order matters
   because every shot score (see Choosing a shot) moves the random stream.
   - **Indirect** (0x42DFF0, `ai_pick_indirect`):
     - *Targets:* spotted ground player units (status 0, class ≤ 1) in range.
     - *Weapon:* launcher kind 1, or kind 2 at 6 hexes or more.
     - *Arc:* the arc from the target to u must be clear (`arc_clear`, 0x410D70). Only a hex
       at least 30 levels above the eye blocks it.
     - *Aim point:* for each hex h of the target's blast area (`blast_area`, 0x47DDB0: the
       spiral of the launcher's blast radius, +9 & 7, filtered by the arc
       check), the score is the sum of the shot scores of the spotted units in
       h's own blast area. Enemy‑side units there (status ≥ 3, u included) are
       **subtracted**. The best h is the aim point.
   - **Direct** (0x42DD50, `ai_pick_direct`):
     - *Targets:* the same kind of target, with launcher kind 0 and line of
       sight either way.
     - *Score:* the sum of the shot scores of the spotted player units on the
       blast spiral around the target, ×3 within 2 hexes.
   - **Anti‑air** (0x42DA50, `ai_pick_aa`):
     - *Targets:* player aircraft (status 0, class ≥ 2) in range and in line of
       sight.
     - *Weapon:* AA accuracy (launcher +5) and an AA attack; missiles only at 6
       hexes or more.
     - *Score:* the shot score, ×3 within 2 hexes.
     - *Quirk:* it tests **u's own** spotted flag instead of the target's, so
       the AI only fires anti‑air while it is itself spotted.
   - `radius` restricts the indirect and direct pickers to launchers of that
     blast radius (−1 = any).
3. **Choice:**
   - **Anti‑air**, if it scores at all.
   - **Indirect**, if it scores more than direct. On a tie, `random(100)` odd
     picks indirect and even picks direct.
   - **Otherwise direct.**
   - The chosen score must reach `threshold`, or engage stops.
4. **After the shot:**
   - u no longer active → return 0.
   - The slot is empty → reload (`ai_reload`, 0x42D140).
   - It stops, returning 1, when nothing qualifies or after max_shots + 1 shots.

The behaviours call engage as (u, radius, threshold, shots), e.g. (2, 100, 3)
then (1, 300, 2) then (0, 65, 3): try the wide‑blast weapons first, at high
thresholds, then smaller ones at lower thresholds (see the behaviours below).

**The AI move** (0x42EE00(mode, u), `rules.ai_move`): Emulated 188 / 188 (148 random cases over modes 0–9 plus 40 mode‑5 cases that reach the melee; 2 mode‑10 cases are now `None`), with
the steps, the melee and unit destruction stubbed and recorded. Its two map
fields (`rules.ai_distance_field`, `rules.ai_tactical_field`) are Emulated
65 / 65, compared cell by cell (the node‑pool overflow never came up). One turn of movement goes like this:

1. **Destination:** unit +7 / +8, or the position of unit +8 when +7 = 0xFF.
   - Already there: return 3.
   - Off the map: the unit's own hex is used.
   - +8 = 0xFF: the game reads uninitialised locals (`None` in the port).
   - Modes above 9: the kind‑0 weight is never set (`None` in the port).
2. **Movement gear broken** (+1 & 0x0C = 8, or +1 & 0x30 = 0x20): return 0.
3. **Weights, by move mode** (jump table 0x42F918, `AI_MOVE_WEIGHTS`):

   | Mode | flag | area | cover | kind‑1 | kind‑0 | Movement mode |
   |---|---|---|---|---|---|---|
   | 0 | 10 | 0 | 1 | 10 | 10 | by nearby players |
   | 1 | 10 | 4 | −8 | 2 | 2 | high speed |
   | 2 | 10 | 1 | 1 | 8 | 8 | normal |
   | 3 | 10 | 1 | 0 | 0 | 0 | by nearby players |
   | 4 | 0 | 1 | 10 | 2 | 2 | high speed; only hexes within 6 |
   | 5 | 6 | −10 | 0 | 0 | 0 | by nearby players; melee charge first |
   | 6 | 10 | 4 | −6 | 3 | 3 | by nearby players |
   | 7 | 10 | 4 | −12 | 2 | 2 | careful |
   | 8 | 8 | 4 | −10 | 4 | 4 | by nearby players |
   | 9 | 10 | 4 | −12 | 0 | 0 | high speed |

   - **By nearby players** (`ai_players_near`, 0x4309D0) counts the spotted active player units
     (0–39) within 4 hexes: none → high speed, 1–3 → normal, 4 → careful.
   - **Five or more** leave the mode as it was: high speed for most modes, but
     6 for mode 6. Movement mode 6 then reaches the step‑cost code (`move_map_expand`, 0x471F10),
     which multiplies by an **uninitialised** local (`None` in the port).
4. **AP reserve:**
   - **Mode 6 at high speed:** `random(100) < 50` keeps 8 AP, or 4 with crew
     +8 bit 0. If that would leave less than half the AP, it keeps nothing and
     moves at normal speed instead.
   - **Mode 9:** keeps 6 AP, or 3 with crew +8 bit 3, on the same half‑AP
     condition.
5. **Move map** (§5.2) for that movement mode. If no hex is reachable, return 0.
6. **Mode 5, melee charge** (0x430660, `rules.ai_charge`):
   - **Target:** an adjacent player unit (status 0), checked in direction
     order. A unit is taken if its condition (+0xD) is below half of ours, or
     if its melee value is lower than the best so far (starting from 100).
   - **No charge:** no target → 0 (carry on moving); target hex unreachable →
     0x7F; our own melee value not higher → 7.
   - **Charge:** spend that hex's AP (`spend_ap`, 0x47CCA0), then fight (`melee`, 0x424490).
     - Result 0: the target is destroyed and we step into its hex if it is free
       → 5.
     - Result 1 → 6.
     - Result 2 (we are destroyed) or 3 (both are) → −1.
     - Any other result → the AP cost.
7. **Distance field** (`ai_distance_field`, 0x42FA20, into the int field at *DS:0x5546A4): a
   bucket‑queue search run **backwards** from the destination.
   - **Step costs:** the terrain cost row of the unit's category. Ground units
     pay ×2 on F‑layer bit 0 and ×2 for a +1 climb, and cannot change height by
     more than 1. Height 0 is impassable. Occupancy is ignored.
   - **Queue:** 64 LIFO buckets and a pool of 512 nodes; running out returns
     0x10000. A popped node is expanded at the bucket's level, even when its own
     cost is 64 higher (a quirk).
   - **Stops** after 64 empty buckets, at level 1024, or 20 levels after the
     unit's own hex first gets a cost.
   - **Afterwards:** other active enemy units (40 and up) become −1, unreached
     hexes −1, and the destination 0.
   - **Mode 5 run‑in:** if the unit's own cost + 2 exceeds its AP, the weights
     become 10 / 0 / 1 / 6 / 6, only hexes within 6 count, and reaching the
     destination returns 10.
8. **Tactical field** (`ai_tactical_field`, 0x42FF00, lower is better). For each on‑map hex:
   - **Base:** 4000 + cover × wCover / 8 + F‑bit‑4 × wFlag.
   - **Exposure:** for each spotted active player unit that sees the hex
     (player sight map *DS:0x554660; only units 0–23 have bits), at distance d,
     and for R = the range of the unit's best kind‑0 weapon, then of its best
     kind‑1 weapon (`ai_best_weapon_k0`, 0x4303F0 / `ai_best_weapon` (0x4304C0): ground accuracy, a ground attack, the
     AP to fire): subtract weight × (d if d ≤ R/2, |R − d| if R/2 < d < R).
     The kind‑1 test reuses the value the kind‑0 test may have replaced.
   - **Plus** the distance field.
   - **Blocked (0x7FFF):** unreached, height 0, outside 0–10000, a unit with
     status > 0 there (the mover's own hex too), F‑layer bit 7 unless the mover
     is class 3. 0 also becomes blocked.
   - **Area pass:** each spotted active player unit adds wArea − distance over
     a spiral of radius wArea (4 if wArea ≤ 0) around itself (0x47DC60).
   - **Destination:** set to the field's minimum (from 5000) − 10.
9. **Choice:** among free move‑map hexes that are not melee hexes and cost at
   most AP − reserve, take the lowest score. On a tie, take the nearer hex; at
   high speed it must also be cheaper.
   - **Fallback:** if none qualifies, the costliest blocked‑free hex in the
     direction (`ai_direction`, 0x47E270) of the nearest player unit (`ai_threat_direction`, 0x42F960, spotted or not).
   - **No move (return 0):** the hex is no closer to the destination than the
     unit, by the distance field, or by hexes when the hex has no distance.
10. **Step:**
    - **Walk** (`ai_walk`, 0x475AE0): an adjacent hex with a height change below 2, or any
      adjacent hex for class ≥ 2.
    - **Path** (`ai_path`, 0x474510): any other hex, following the move map.
    - **Return codes:** UI abort codes pass through. A step result ≥ 4 → −1;
      0 at the destination → 3 (10 after a run‑in); 1 → 1; 2–3 → 2; else 4.

**The small blocks**: Emulated 1500 / 1500, comparing the whole unit table, the
F layer, the heights and the AI memory afterwards.
- **Conceal** (`ai_conceal`, 0x42D3D0): 6 AP, or 3 with crew +8 bit 3. Sets the concealed
  flag (0x20) unless it is already set.
- **Reload** (`ai_reload`, 0x42D140): nothing if the manipulators are broken (`manipulator_state`, 0x47CBD0: +1
  bits 6–7 plus +2 bits 0–1 = 4) or u has no AP. Each empty slot 0–3 whose
  pocket is not state 2 is then handled:
  - **Magazine launcher** (+9 bit 3) with a pocket to reload from (`reload_pockets`, 0x480990):
    the pocket must hold a round the launcher takes (+0xA..+0xC), not be
    state 2, and not feed another fitted slot. If u has the reload AP (round
    +7 & 0x1F of the launcher's first round type), it takes the first such
    pocket with rounds. The slot switches to it and the empty magazine's pocket
    is cleared. Spent or broken pockets met on the way are cleared for 1 AP each.
  - **Otherwise:** the launcher is **dropped** (slot = 0xFF) and its pocket
    cleared, for 1 AP. So the AI throws away empty single‑load weapons.
- **Search** (`ai_search`, 0x42D430), the player's search command (§5.6):
  - **Cost and need:** 8 AP (4 with crew +8 bit 0), and a recon range of 3 or
    more.
  - **Climb:** class‑3 searchers climb 6 levels first. With the mode‑8 climb in
    spotting, that makes 12.
  - **Nothing new:** if no hex of the search map is new to the side's view and
    the caller didn't force it, nothing happens.
  - **Otherwise:** mark the hexes in view, spot units there (`spot_in_map_list`, 0x47F150, which
    matches `spot_in_map` mode 8), store spotted player units 0–39 in the AI
    memory, pay the AP, and set movement mode 3.
  - **Reactions:** a class‑3 searcher that is spotted and has not reacted draws
    reaction fire.
- **Weapon check** (`ai_longest_range`, 0x42D700): the longest range among slots 0–3 that are not
  missiles and have a ground attack.

**Fire support** (0x42C850(u, limit), `rules.ai_fire_support`): Emulated
940 / 940. The check compares the unit table, all 64 group records, the F layer
and the RNG; the missile, area, memory and no‑target paths all occur.

u calls in fire support on the point at DS:0x50AD95 / 97.
- **Cost:** 12 AP per order, 6 with crew +8 bit 2. u's own AP is only
  **checked**: each **member** that takes an order pays the cost, so one call can
  order every member up to `limit` (−1 = all). PC‑98 does the same.
- **Supporting groups** are groups 20–63 (the group table has 64 records). Each
  must have units (+5), +2 & 0x30 = 0x20, and type (+33 high nibble) 3, 4 or 5.
  A group is skipped if a group 1–19 of type 3 or 4 sits on its position
  (+22 / +23). A match with group 0 does not count.
- **Members** (+6..+21) of a group without +2 bits 6–7 that are not already
  ordered (unit +6 ≠ 1, 2) offer their best slot 0–5:
  - ranked by kind × ground attack;
  - the slot needs rounds, must not be broken, and needs ground accuracy or
    warhead 8;
  - for type‑5 groups and missiles, the point must lie within 10 × range,
    measured by a grid line length in hundredths: 100 per straight step, 140
    per diagonal (`grid_distance`, 0x440FA0).
- **Aim** (0x42CD10, `support_target`):
  - **Missiles:** the spotted player unit in the worst condition (+0xD, below
    200). One that can shoot back at aircraft is skipped unless
    `random(100) > 60`. The result is a **unit** target: +7 = 0xFF, +8 = the unit.
  - **Other weapons:** each spotted player unit's blast area (the spiral of the
    launcher's radius) is scored:
    - the damage (the real damage formula, mode 9, with its rolls) to spotted
      units there, minus that to enemy‑side units;
    - minus 5 per occupied hex with F‑layer bit 7;
    - 0 once those reach a fifth of the hexes counted, so an area of fewer than
      5 hexes always scores 0;
    - hexes already struck are skipped unless `random(100) < 5`.

    The best area wins, but the aim point is the **last hex of its spiral**,
    not the target's hex (a quirk).
  - **Nothing found:** with `random(100) < 10`, the last suitable remembered
    position (AI memory of an unspotted active player unit, with no bit‑7 hex
    around it and not struck yet).
- **Order:** the blast area around the aim is marked as struck (F‑layer bit 4,
  `mark_strike` (0x483B90)). The member gets +7 / +8 = the aim, +0x35 = the slot and +6 = 1.
  Its group, if of type 3 or 4, moves its target point to the called point
  (`group_retarget`, 0x4410B0), and its +2 bits 4–5 are kept.

**Behaviours 1 and 2**: Emulated 126 / 126 (63 order 1, 57 order 2 plus 6 earlier), run whole on top of every block above.
Steps, melee, destruction, the shot and the searcher's reactions are stubbed and
recorded. The checks compare the result, the call log, the units, the F layer,
the groups, the AI memory and the RNG.

Shared conventions:
- **Engage** means: if the unit has a weapon (weapon check > 0), a player unit is
  within that range, and, where the code checks it, any player unit is active,
  engage (radius, threshold, shots). Engage firing nothing ends the turn (return 0).
- **A round** has these steps:
  1. Head for the destination of the given type (`ai_destination`, 0x42E310).
  2. Move with the given move mode (`ai_move`, 0x42EE00), unless already there.
  3. Call one fire‑support order.
  4. Act on the move result.

  The turn has at most 3 rounds, while the unit has AP.
- **Abort codes** from any block end the behaviour with that code.

**Order 2** (`ai_behaviour_2`, 0x430A80), the guard post:
1. Reload, search, conceal, fire support (1 order).
2. **Stop** if the unit has no weapon or no player unit is active.
3. Engage (2, 100, 3), (1, 300, 2), (0, 65, 3), (−1, 20, 6).
4. **Rounds:** toward destination type 1 (the own post), in move mode 1. By
   move result:

   | Move result | Then | Ends the rounds |
   |---|---|---|
   | 0 (did not move) | conceal, support (2), engage (−1, 1, 10) | yes |
   | 1 | conceal, search, engage (2, 100, 3), (0, 60, 4), (1, 400, 4) | no |
   | 2 | conceal, search, support (2), engage (−1, 1, 10) | yes |
   | 3 (arrived) | conceal, support (3), engage (−1, 1, 10) | yes |
   | 4 | switch to move mode 2 | no |
   | other | support (all) | yes |

5. **End:** conceal, reload, search (forced), support (all).

**Order 1** (`ai_behaviour_1`, 0x42BA90), the attack:
1. **Opening:**
   - *Strong* (condition ≥ 55 and melee value > 60): it will charge, in move
     mode 5 toward destination type 6 (hunt). It engages (2, 80, 2),
     (1, 300, 2), (0, 40, 2) first.
   - *Otherwise:* a class‑3 unit searches and calls support. It engages
     (2, 80, 3), (1, 300, 3), (0, 40, 3), then moves in mode 0 toward
     destination type 0.
2. **Rounds.** By move result ("strong" now needs condition ≥ 60):

   | Move result | Then | Ends the rounds |
   |---|---|---|
   | 0 | class 3: search, support; engage (−1, 1, 6) | yes |
   | 1, 2 | conceal (not class 3); **dig in** (destination = here); search; engage (2, 60, 2), (1, 150, 3), (0, 40, 5) for 1, or (2, 60, 3), (1, 150, 3), (0, 30, 4) for 2; then strong → charge (mode 5, type 6), else class 3 searches and calls support, and it moves carefully (mode 2, type 0) | no |
   | 3 | strong → charge; class 3 → search, support, mode 0; else mode 2; type 0; engage (−1, 10, 10) with the last range found | no |
   | 4 | as 3, then engage (−1, 10, 2) | no |
   | 5, 6 | strong → charge; else conceal, engage (−1, 10, 10), mode 2 type 0; then engage (−1, 10, 2) | no |
   | 7 | engage (−1, 50, 10); mode 2, type 0 | no |
   | 10 | engage (−1, 5, 10) | no |
   | 8, 9, other | engage (−1, 10, 10) | yes |

3. **End:** conceal (classes 0–1), reload, search (forced), engage (−1, 10, 10).

PC‑98 (ovseg 11 0x483B = order 2, 0x4136 = order 1) calls the same blocks in the
same order, with the same engage parameters and condition tests.

**Orders 5, 6 and 7**: Emulated 159 / 159 (55 order 5, 63 order 6, 41 order 7), whole turns as for orders 1 and 2. All three head for destination type 3
(the own destination, then waypoints) for up to 3 rounds. "Engage" below is
engage (−1, threshold, shots) under the shared conditions. "Support (n)" is a
fire‑support call for n orders (−1 = all).

| | Order 5 (`ai_behaviour_5`, 0x432350): go and fight | Order 6 (`ai_behaviour_6`, 0x432690): patrol | Order 7 (`ai_behaviour_7`, 0x432B40): careful advance |
|---|---|---|---|
| Start | reload | support (1), reload | reload, support (1) |
| Each round, before moving | — | support (1); `random(100) < 30` → search; engage (1, 1) | engage (1, 3) |
| Move mode | 3 | 3 | 4, then search |
| After moving | — | support (1) | — |
| Result 0 (did not move) | support (1), engage (1, 10)\*, done | support (1), engage (1, 10)\*, support (all), done | support (1), conceal, engage (1, 10), support (all), done |
| Result 1, 2 | support (all) | conceal, support (all), engage (1, 10), done | support (all), engage (1, 10), done |
| Result 3 (arrived) | support (all), engage (1, 10), done | as 1–2 | conceal, support (1), engage (1, 10), done |
| Result 4 | support (all) | as 1–2 but going on | support (1), conceal, engage (1, 10), going on |
| Other | support (all), done | support (all), done | done |
| End of round | — | support (1) | support (1) |
| End | conceal, reload, support (all) | conceal, reload, support (all) | conceal, reload, support (all) |

\* also needs some player unit active.

PC‑98 (ovseg 11 0x54F2 / 0x5690 / 0x5983) has the same tables. It also routes
order 5's result 2 to the result‑1 code and fixes order 6's move mode at 3.

**Orders 3, 4 and 11**: Emulated 159 / 159 (60 order 3, 57 order 4, 42 order 11), whole turns as for orders 1 and 2.

**Order 3** (`ai_behaviour_3`, 0x4311C0), hunt the hidden:
1. **Opening:** engage (1, 5), with the any‑player condition, then reload.
2. **Rounds** (up to 3): search; support (1); head for destination type 2 (the
   nearest **unspotted** player, then memory, then waypoints) in the current
   move mode. That starts at **6** (which can hit the undefined movement mode
   of §5.8, step 3), and the unit conceals after each move in mode **7**.

   | Move result | Then | Ends the rounds |
   |---|---|---|
   | 0 | support (1), engage (1, 10)\*, support (all) | yes |
   | 1 | `random(100) < 40`: support (1), switch to mode 8; else support (1), conceal, engage (1, 10)\* | no |
   | 2 | forced search; if it found units, support (1) and switch to mode 7 | no |
   | 3 | search, conceal, support (all), engage (1, 10)\*, switch to mode 8 | no |
   | 4 | support (1) | yes |
   | other | support (all) | yes |

   It reloads between rounds.
3. **End:** conceal, reload, support (all).

**Order 4** (`ai_behaviour_4`, 0x431770), advance then hold:
1. **Opening:** reload, support (1).
2. **Rounds** (up to 3): search; `random(100) < 50` → support (1); engage (1, 1)\*;
   head for destination type 3 (taken only when it is on the map) in move mode 6.

   | Move result | Then | Ends the rounds |
   |---|---|---|
   | 0 | support (all), search, engage (1, 3)\* | yes |
   | 1 | support (1), engage (1, 3)\* | no |
   | 2 | support (1), search, engage (1, 3)\* | no |
   | 3 (arrived) | the destination becomes type 1 (stay); `random(100) < 20` → conceal; support (all), engage (1, 10)\* | yes |
   | 4 | support (1). Its engage only runs on a second visit, which cannot happen since the case ends the turn (dead code, on PC‑98 too) | yes |
   | other | — | yes |

3. **End:** conceal, reload, support (all).

**Order 11** (`ai_behaviour_11`, 0x433690): if u has a weapon, a player unit is within its range,
and a spotted player unit is active, it plays order 1. Otherwise it sets
destination type 3 and plays order 5.

PC‑98 (ovseg 11 0x4BA2 / 0x4E87 / 0x6000) matches, including order 4's dead case.

**Orders 8, 9 and 10**: Emulated 154 / 154 (47 order 8, 57 order 9, 50 order 10; 8 more order‑10 cases hit the undefined path and were skipped).
- **Order 8** (`ai_behaviour_8`, 0x431E00), patrol the waypoints:
  1. Reload, support (1).
  2. **Rounds** (up to 3): search; `random(100) < 50` → support (1); head for
     destination type 4 (the next waypoint) in move mode 4.

     | Move result | Then | Ends the rounds |
     |---|---|---|
     | 0 | support (all) | yes |
     | 1, 2 | search, support (1), engage (1, 10)\* | no |
     | 3 | `random(100) < 20` → conceal; support (all), engage (1, 10)\* | yes |
     | 4 | search, support (all), engage (1, 10)\* | no |
     | other | — | yes |

  3. End as usual.
- **Order 9** (`ai_behaviour_9`, 0x4334F0), move and dig in:
  1. Reload.
  2. Head for destination type 5 in move mode 4.
  3. After a move result 0–4, or no move: conceal, support (all), search.
  4. Conceal, reload, support (2).

  PC‑98 (ovseg 11 0x5EF2) also engages once after the search, E(−1, 1, −1),
  which allows a single shot. Plus Dash dropped that shot.
- **Order 10** (`ai_behaviour_10`, 0x433020), hold the post:
  1. Conceal, search, and support (all) if a spotted player is active.
  2. **Round:** destination type 1 in move mode 1, then by move result: 0 engage
     (1, 5), support (all); 1 support (all), engage (1, 5); 2 search, support
     (all), engage (1, 10); 3 conceal, then as 2; 4 the same as 3 but going on.
     All except 4 end the rounds.
  3. End as usual.

  **Two uninitialised variables:**
  - **The "done" flag.** It is never set before the loop. Plus Dash keeps it in
    the unit‑index argument slot, so any unit other than unit 0 gets exactly one
    round. On PC‑98 it is stack garbage.
  - **The move result.** It is also unset, so a first round without a move
    switches on a stale value. The port returns `AiUndefined` there.

All 11 orders are now ported. The PC‑98 dispatcher pairs them one to one with
the Plus Dash routines.

Its order dispatcher (ovseg 11 0x6095) pairs orders 1–11 with 0x4136, 0x483B,
0x4BA2, 0x4E87, 0x54F2, 0x5690, 0x5983, 0x5227, 0x5EF2, 0x5C4C and 0x6000.

**Cleared pockets.** Reload clears a spent magazine's pocket to ammo id 0xFF, and
the slot keeps pointing at it until it is reloaded. The weapon lookups (range,
attack, warhead) do not check for this. They read "ammo record −1", which in
Plus Dash is the last 12 bytes of the launcher table (the ammo table follows it
directly). In practice such a slot has range 0, so the pickers skip it. The
behaviour check found this, and the port's ammo table (`rules._AmmoTable`) now
reads negative ids the same way.

**The reaction shot** (0x4731F0(b, slot, t, flag), `rules.reaction_shot`): Emulated
1838 / 1838 with the real fire resolution.
1. **Mode:** fire mode 5, or 10 at an aircraft, + 0x80 for return fire.
2. **Shot:** `fire_resolution` at t's hex, and b is marked as having reacted
   (flag 0x40).
3. **Evasion AP:** after a reaction to a move, t pays 4 / 2 / 1 / 2 by its
   movement mode, doubled while carrying.
4. **Round:** b uses a round.
5. **Result:** 6 if t died, else 2.

The computer's reaction loop (`ai_reactions`, above) calls it. When player units
react to an AI mover, the game opens a menu of candidates (`reaction_menu_list`, 0x472ED0 /
`ui_reaction_menu` (0x4730E0)) and a weapon picker (`ui_reaction_weapon_picker`, 0x4E7EE0). That is player input; each choice
ends in this same shot.

**Fire‑support strikes**: the orders above are carried out by the strike executor
(`strike_executor`, 0x4E37A0), §5.13.

**Movement steps** (`rules.ai_walk` 0x475AE0, `rules.ai_path` 0x474510): Emulated
704 / 704 for a computer‑side mover, all result codes occurring. Inside whole
AI turns they are Emulated with the behaviours. Reactions (the player's
decision) and display are stubbed.
- **One step** (`ai_walk`, 0x475AE0, used for an adjacent hex):
  1. Pay the hex's AP and move (`move_unit`, 0x47ED20). Moving sets the facing and the
     movement mode and clears concealment.
  2. **Visibility** (`step_visibility`, 0x474E20): the mover is spotted while its hex is in the
     other side's view, and unspotted otherwise. An aircraft out of view is
     still spotted by any opposing unit whose own recon sees it. A spotted
     player unit 0–39 is written to the AI memory.
  3. **Mine** of the other side on the hex (F‑layer bit 7 for player movers,
     bit 6 for enemies; aircraft never set them off):
     - *Careful mode:* it is found and cleared for 4 AP (result 2).
     - *Otherwise it goes off* (`step_mine_blast`, 0x474230): unowned ammo‑12 damage, 4 AP lost
       at high speed or 2 at normal speed, and the hit applied. Result 4 if
       the blast kills, else 2. The mine bit is cleared with an XOR.
  4. **Look** (`step_search`, 0x47F950), unless the result is 4: a search with range and
     penetration 2 / 2 at high speed, the unit's own recon otherwise (mode 3
     searches as the search command). It marks the side's view and spots units
     (§5.6). Anything spotted sets result bit 0.
  5. **Reactions:** a spotted mover that has not reacted draws reaction fire.
     The loop's result bits are ORed in.
- **Path** (`ai_path`, 0x474510): the path comes from `move_path` (0x473CD0). That routine backtracks
  from the target to the neighbour with the lowest move‑map cost, ground
  units only across height steps below 2, taking the middle of equal ones
  with alternating rounding.
  - The walk **stops after the first step with a non‑zero result.**
  - **Blocked:** an occupied hex of the other side stops it (1).
  - **Friendly units passed through** are put back on their hexes.
  - **Mines:** only on hexes that were empty. In careful mode a mine is
    cleared only with 4 AP and the engineer skill (crew +8 bit 1); without
    them the unit passes over it harmlessly.
  - **Spotting and reactions:** only count on empty hexes.
- **Result codes** as `ai_move` reads them: 0 nothing, 1 spotted or blocked,
  2 mine found or survived, 4 mine kill, plus the reaction loop's bits.

**Per‑mission event scripts:** objectives, escapes, demolitions, scripted
destruction, map changes, dialogs and deployment rules. They do **not** move or
fire units: none of them calls the movement or fire engine, except that two
DASH missions apply damage directly. There are 16 tables of 23 entries (entry
0 = default). Their roles, from their callers:

| Table | Caller | Role |
|---|---|---|
| 0x51EAE8 / 0x51EB48 / 0x51EBA8 / 0x51EC08 | 0x443F60 | sortie / deployment rules |
| 0x51EC68 | the sortie screen 0x45ED60 (0x460D60) | deploy check: 1 passes, 0 refuses (after a dialog) |
| 0x51ECC8 | 0x4DD2F0 | mission init (camera, timers) |
| 0x51ED28 | 0x444730 | objective message (an id or −1) |
| 0x51EEB8 | 0x4403D0 | speech / message window hook |
| 0x51EF18 | 0x4DDF70 (the unit menu's entries) | menu hook: 1 adds entry 11 (its label: DS:0x517F1C points at the mission's string), 0 none |
| 0x51EF78 | `unit_command_menu` (0x4EE8D0) | the mission's own command (unit menu entry 11) |
| 0x51EFD8 | turn loop: stage 2 at start, 1 after the player's turn, 0 in the computer's turn | turn events |
| 0x51F038 | command 0x82 | the mission's scenario command (シナリオコマンド) |
| 0x51F098 | 0x428D80 (set explosives) | bomb rule: −1 an ordinary fused bomb, −2 refused, below 0x15 the hook byte (fuse asked), 0x15 + n no fuse, hook byte n + 1 |
| 0x51F158 | 0x480280 | timed bomb detonation |
| 0x51F0F8 | `mission_loop` after the occupancy rebuild (and 0x4847C0) | start script (puts back what a saved mission had changed, e.g. blown bridges) |
| 0x51F1B8 | `mission_loop`'s first call (and 0x4847C0) | load script: copies the mission's tables into place |

`rules.MISSION_SCRIPTS[script][role]` holds the ported routines (roles: load, init,
objective, deploy, turn, speech, menu, command, scenario, bomb_rule, start, bomb);
`verify_rules.verify_missions` runs every one against the game's on random worlds (the
windows stubbed and logged, answers random and replayed, a time limit per call) and
compares the result, units, crews, groups, the DS block, bombs, the H / T / F / O layers,
the stock, the turn counter, DS:0x506651, the RNG, the exe data and the log. The
deployment rules A-D belong to the operation plan screen, not ported.

**Set explosives** (0x428D80, the machine status window's pocket menu entry 7: a round of
warhead 13 with rounds left and a pocket not broken; AP = the round's +7 low 5 bits,
halved for an engineer, crew skills bit 1). Emulated 600 / 600 (`lay_explosive`):
- under that AP: 0x1E9;
- a round with warhead bit 5: 0x1BD, and on yes a mine of the unit's side on its hex;
- else the mission's bomb rule: −1 asks 0x1EA (yes / no) and the fuse list (0x1EB: 5, 10,
  ... minutes, one turn each), and the first entry of the bomb list off the map takes
  (x, y, fuse + 1, 0xFF); −2 nothing; below 0x15 the fuse list, the hook byte its value;
  0x15 and up no fuse (0xFF, so it never counts down) and the hook byte value − 0x14. The
  entry taken then is the first whose x is −1 or out of the row, or y out of 0–71.
- laid: the pocket loses a round (cleared at 0) and the caller charges the AP.

The scripts' windows: 0x43BA20 (a message, or a choice list whose label array the
script passes), `ui_message_box` 0x451FB0 (buttons DS:0x50CBC9[kind]: 了解 / 中止, 実行 /
中止; 1 for the first, 0 for the second or a cancel), 0x4521C0 (a line), 0x4DD390 (the
sortie's refusal), the explosion window 0x40F590 / 0x40F730 / 0x417410 / 0x410510 (0x417410
returns 0x80000 when the player skips; its end empties the hex of a unit at condition 0),
the radio's talk windows (0x488DE0 / 0x489140 / 0x489390; 0x489430 the portrait of a crew, 0 for crew −1), the
radar map's close (0x43F060) and redraws (0x466790, 0x4830E0, 0x4361C0, a hex 0x4F2150)
and the speech window 0x4403D0
(the approach: the speech hook in a loop until a transport lands; not ported, the
battle's own drop handling stands in). `occupant_at` 0x46EC80, as the scripts call it,
has no bounds check (x = −1 reads the row before's last hex).

0x51F218 is per‑mission data rather than code.

`tools/mission_scripts.py` inventories all of it: for each mission, every
routine and its subroutines, the shared helpers it calls, the messages it shows
(with their text from the mission's `WMES.PCK` chunk), and the group and unit
fields it reads.
- **Size:** 226 KB of mission‑specific code, from 2.5 KB (script 5) to 27 KB (script 21).
- **Shared calls:** 112 shared or engine functions in all. The most used are a
  group scan (0x4DE090, all 22 missions), message text, `random()`, "set
  destroyed", view scrolling, a dialog (0x4DD390, choice → −100 / −101 / −102),
  a speech window (0x4403D0), and "remove unit from map" (0x47FFA0, for
  escapes).

**Group records** (DS:0x50A35C, 23 × 35 B) carry much of the mission state:
+5 looks like the number of units still present, and +33's low nibble a group
status.

**When the tables run** (read in `mission_loop` and its callers): the load script
(0x51F1B8) first; the init (0x51ECC8) in the pre‑battle screen (0x416CF0 → 0x4DD2F0);
at a new mission the turn script with stage 2 (between `start_units` and the occupancy
rebuild) and then the start script (0x51F0F8); in each turn, stage 1 after the player's
support state, stage 0 in the computer's turn after the player's upkeep; the state
check after every player command; the mission's command as unit‑menu entry 11.

**Mission 1** (script 1, PD2 chunk 0: a diversion and a capture). Emulated 800 / 800 for
the objective, init, turn script and command (`verify_m01`), 200 / 200 for the state
check:
- **State** (0x499480): the mission goes on while group 0 or group 2 has units (+5 ≠ 0)
  and a clear status (+33 & 15 = 0); otherwise dialog 0x12B ends it.
- **Objective** (0x4995E0): −1 once group 0 or 2 has a clear status, else 0x10A.
- **Init** (0x499540): camera point (5, 13), drop points cleared, DS:0x50ADB1..0x50ADF0
  copied from DS:0x524130 / 0x524150 (nothing in the code was seen to write them), and
  DS:0x506651 = 0. **Load** (0x49A700): the 14 exit hexes at 0x519FE8 → 0x519FB0.
- **Turn script** (0x49A190):
  - stage 0: the mission turn counter DS:0x50663B + 1; while the alarm has not gone up
    (DS:0x50AD6E / 0x50AD74 bit 0): if a timed explosive is about to go off (an entry
    of DS:0x50AC1C with x ≠ −1 and fewer than 2 turns), both flags and the **alert**
    (DS:0x50ADF1) are set and every computer unit (status 3–5, with a machine and
    condition, order +3 = 1x) heads for a random one of those sites (+7/+8,
    `random(n)`). Otherwise the alert goes up (DS:0x50AD74 bit 0) if fewer than 3
    player units are at full condition, a player unit is spotted, any smoke is on the
    map, fewer than 32 computer units stand, a spotted player unit is damaged, or any
    crew's combat record shows a shot. Then the speech hook (§5.9: the group flight
    engine 0x43BDB0 and the arrival scenes);
  - stage 1, once the target is recovered (DS:0x50AD7A bit 0): each player unit on an
    exit hex is asked "%s %sを脱出させますか？" (0xAA, given and family names; 実行 / 中止)
    and leaves the map (0x47FFA0) on yes, unless it carries a unit (0xAB);
  - once (DS:0x50AD4E bit 0): the group scan (0x4DE090), groups 0 and 2 placed at the
    camera point, the speech window (0x4403D0);
  - finally, with no player unit left on the map and no group 0, 2 or 4 still waiting
    (members, +2 bits 4–5 clear) while the target is not recovered, the end code
    DS:0x50ADF2 = 0x80.
- **Command** (0x499F40, unit‑menu entry 11: **indoor search**): under 20 AP, 0xA9.
  Otherwise "indoor search: 20 AP. Search?" (0xA5, はい / いいえ). On yes, on hex (47, 24) or
  (46, 24) before the target is recovered: "target found, recovered" (0xA6), 20 AP, and
  DS:0x50AD7A's low byte records the crew (bits 1–5) and bit 0. Elsewhere it looks for a
  building (terrain type 7 or 8) in the ring around the unit: found, "nothing here"
  (0xA7) and 20 AP; else "no building here" (0xA8). **Quirk:** it walks `spiral`'s
  list (pairs of ints) 4 bytes at a time as (x, y) shorts, so it really tests the T
  layer at offsets y₀, x₁, y₁, x₂, … (hexes of row 0): in practice "no building".

**Mission 2** (script 2, PD2 chunk 1: two bridges to blow, then a rescue). Emulated
2,200 / 2,200 (`verify_missions`):
- **Charges:** six points per bridge (DS:0x517F3C, x/y shorts: bridge 0 at x 21–22, y
  16–21, bridge 1 at x 13, y 53–58), their states at DS:0x50AD51 + 12 b + 2 i (low nibble
  0 none, 1 set, 2 blown). The bomb rule (0x49C2F0) finds the unit's hex among 15 entries
  (the 12, then (−1, −1)); none: −1 (an ordinary bomb). On a bridge already down: 0xA7.
  Else 0xA1 (n set, 3 − n to go) or 0xA2; an empty point asks 0xA3 (設置 / 中止) and is
  set: 0xA4 (2 − n to go) or 0xA5, then 0x15 + the point (a charge with no fuse).
- **Turn script** (0x49B850): stage 0, with a player unit active: a bridge with more than
  two charges asks 0xA8 (爆破 / 待機) after scrolling to it; yes marks its six points blown,
  clears the first bomb-list entry on each point and blows it (0x49BE70: DS:0x50AD78 bit 6
  / 7, its 16 hexes at 0x51A1E8 + 0x40 b take the broken tiles of 0x51A2E8, T and H; the
  first eight are blasted and their occupant destroyed twice over). Then the speech hook
  (0x49B490: a type-6 group holding raises the alarm DS:0x50AD70 and the alert; the flight
  turn). Stage 1: each rescue group 12–19 (type 6, holding, sub-state 2) asks "take off?"
  by its counter +0x20 (0xAC at 2, 0xAD at 1, with its call sign; 実行 / 中止): 中止 puts
  it off (DS:0x50AD75's nibble + 1; at 2 groups 0x19 / 0x1A arrive at turn + 8 / + 7, at 4
  groups 0x1B / 0x1C), 実行 lets it go (sub-state 1). The mission ends when no rescue group
  is left to wait for and no player unit stands (the exact test in `m02_turn`): the units
  carried by themselves are destroyed, the others flagged with their crews; the end code
  is 0x80 for both bridges, 0x83 for one, 0x82 for none. The first call also picks the
  computer's layout: random(3), 0 / 1 move units 56–71 to 0x51A0A8 / 0x51A1A8's set, 2
  keeps the map's.
- **Command** (0x49B500, "機体放棄 0AP"): a pilot within 2 hexes of a unit with machine 0xC
  (the rescue aircraft), with a rescue group landed, abandons and blows up its machine
  (0xAB, 了解 / 中止) and boards it (+0x33 / +0x34). Carrying a unit: 0xAE.
- **Withdraw** (0x49C130): every player unit's fate is drawn (carried ones destroyed,
  random(100) marking the crew; the others marked and destroyed or flagged on
  random(100)), then the bridge end code.
- **Init** (0x49B170): camera (8, 7), drop points (14, 7–9) and (0, 3–5), the explosives
  (round 12) topped up to 10 in the stock. **Start** (0x49C570): a blown bridge is put
  back down. **Deploy** (0x49AFA0): a drop group formed (0x12C) and a rescue group with a
  machine (0x12D).

**Mission 3** (script 3, PD2 chunk 2: a capture and an escape, built as mission 1).
Emulated 1,100 / 1,100. As mission 1 with: the target on (0x33, 0x35) / (0x34, 0x35)
(0xA6), a second lead on (0x2F, 0x18) / (0x2E, 0x18) (0xAC, DS:0x50AD7A bit 7); the
exits (14) and landing hexes in tables the load script copies (0x51A418, 0x51A488,
0x51A4B8); the alarm under 5 fit player units (not 3), no machine check for the units
sent to a fused bomb, and a damaged computer unit raising it too; group 2's arrival lines
0xAE / 0xAD. At the end (no player unit on the map, nobody left waiting) every player
unit's fate is drawn (0x49E480) and the end code is 0x80 with the target found and its
finder alive, 0x83 with only the second lead, else 0x82 (the withdraw gives the code
without the draws). Init: camera (5, 13), every combat record's kills, shots and hits
cleared, DS:0x506651 = 0xA8.

**Mission 4** (script 4, PD2 chunk 3: hold the enemy while the division arrives; four
demolitions). Emulated 1,300 / 1,300:
- **Turn script** (0x49F300): stage 0 counts the computer units that get past the bottom
  edge (x > 1, y > 0x45: they leave their group, DS:0x50AD78 bits 1–5, to 20) and shows
  the count (0xA1: n, 21 − n); during the enemy's retreat (DS:0x50AD70 bit 0) units past
  x 0x23 at y < 3 leave their groups. Six turns into the retreat, with a player unit on
  the map, the operation succeeds (0x49FBA0: the radio, 0xA2 / 0xA3; 0x80 with fewer than
  10 through, else 0x83). Stage 1: under 120 computer units fit, the alert and their
  destinations cleared; under 50 left, the retreat: every computer unit on the map takes
  order 5, every computer group leaves for one of the computer's points (random(3)), the
  64 pairs at DS:0x50DC78 are filled (0x27–0x3D, 1). With no player unit on the map, or
  more than 20 through (0x49FDB0: 0xA4 / 0xA5), 0x82.
- **The end's fates** (0x49FFD0): on 0x82 every member of groups 0–19 is drawn on
  random(100) (flagged, destroyed, the crew marked); on 0x80 / 0x83 a destroyed member
  marks its crew when random(100) % 3 is 1. The withdraw is 0x82 with these fates.
- **Demolitions:** the bomb rule (0x49F710) gives the site 1–4 for a charge laid on its
  hexes (a fuse is asked; the hook byte is the site); the bomb hook (0x49F9C0) breaks the
  site's 8 or 9 hexes (tables 0x51A560 / 0x51A5B0 / 0x51A610 / 0x51A660 of 5 B: x, y and
  the T byte; H = 0x1E) and sets its flag (DS:0x50AD50 + 2 i). The start script puts the
  broken hexes back (and runs the bomb hook on entries 1–4 first, a quirk).
- **Command** (0x49F2B0, "状況確認 0AP"): the count (0xA1). Init (0x49F050): camera (7, 7),
  the player's drop points (14, 9), (14, 11), (11, 14). No deploy check.

**Mission 5** (script 5, PD2 chunk 4: clear the enemy out of rows 15–51). Emulated
900 / 900. Stage 0 runs the flight turn; stage 1 ends the mission with 0x80 when no
computer unit (on duty, with condition, not destroyed, on the map) stands in rows 15–51,
0x83 when none is left at all, 0x82 when no player unit is; the end first draws for each
destroyed player unit (random(100) odd marks its crew, +6 bit 1; 0x4A0FC0). The withdraw
(0x4A0F10) gives 0x80 with no computer unit left with condition, else 0x82 with one in the
rows and 0x83 without. The command ("状況確認 0AP") says whether one is still in the rows
(0x127 / 0x126). Init: camera (7, 7), the player's drop points (9, 0), (10, 0), (11, 0).

**Mission 6** (script 6, PD2 chunk 5: inspect the cargo of the trailers, units 42–49,
before they drive off). Emulated 900 / 900:
- **Command** (0x4A17A0, "積荷検分 20AP"): the trailers on the six hexes round the unit are
  marked (F bit 1, set_target_mark); the player clicks one (ui_map_click mode 2): one
  not inspected asks 0xA3 (実行 / 中止) and on 実行 is inspected (flag bit 1, 0xA4, 20 AP,
  DS:0x50AD6F's nibble + 1); one inspected says 0xA2; the marks are cleared
  (ui_map_hover_clear). Under 20 AP: 0xA1; no trailer next to it: 0xA5.
- **Turn script** (0x4A1BE0): stage 0, a trailer on column 1 or past 0x44 leaves the map,
  the flight turn, 0xA7 (the count). Stage 1: a player unit past column 0x44 is asked
  0xA6 (実行 / 中止) and leaves; the result (DS:0x50AD71's nibble) becomes 2 with all 8
  inspected, 1 with more than 3. With no player unit or no computer unit left, the result
  is set when the computer's side is gone, and the end code is 0x80 (result 2), 0x83 (1)
  or 0x82, after the fates (0x4A2080: a destroyed player unit marks its crew unless
  random(100) & 3 is 2). A first inspection raises the alert (DS:0x50AD76).
- **Withdraw** (0x4A2000): the same code, the player units still on the map destroyed
  first unless random(100) & 3 is 2. Init: camera (6, 6), drop points (4–6, 0) and
  (14, 5–7).

**Mission 7** (script 7, PD2 chunk 6: find the President's son among the buildings, then
fly him out). Emulated 1,300 / 1,300:
- **Search** (0x4A2E50 before the find, "人質捜索 15AP"): 0xA6 (実行 / 中止), 15 AP; ten points
  (DS:0x51A828) in two sets of five, each with a flag at DS:0x50AD4E + 2 × its byte at
  0x51A878; the set searched first is noted (DS:0x50AD6E bit 6 / 7) and the target is
  found (0xA1; bit 0, the finder's crew in bits 1–5) when the other set was noted first
  and all five of this one are searched; else 0xA2; a point searched before 0xA4; off
  the points 0xA3. **After the find** ("機体放棄 0AP") the pilot boards the rescue aircraft
  as in mission 2 (0xA7 / 0xA8 / 0xA9 / 0xB4), the finder aboard setting DS:0x50AD6F
  bit 0. The menu hook switches the label by DS:0x50AD6E bit 0.
- **Turn script** (0x4A3470): stage 1, before the alarm (DS:0x50AD80), a walk over the
  units counts the player's spotted, damaged and destroyed ones and the damaged computer
  units; at the first unit on duty after which one is set, the alarm: the alert, groups
  25–30 head for the camera point with +0x1C = 7, 0xE, 0x15, 0x1C and, for 29 and 30, two
  bytes of the caller's stack (mission_loop's saved EDI: not known statically; the battle
  leaves them). **Quirk:** the alarm sets the walk's counter back to 0x1F but not its
  pointer, so the walk runs on past unit 253 through the memory after the table,
  repeating the alarm. Then the rescue group 12, landed, asks "take off?" by its counter
  (0xB2 / 0xB3, はい / いいえ). The first call opens with a radio scene: a short one (0xAA)
  that puts groups 0, 2, 4's members on (4, 4) when the first formed group's type nibble
  is 0, else the submarine launch (0xAB–0xB1, a pause 0x453CD0) and DS:0x50AD4E bit 6.
- **End** (any stage): with no player unit on the map, the rescue gone (DS:0x50AD82) or
  group 12 empty: the fates (0x4A47B0: the VTOLs' passengers, every player unit drawn on
  random(100)) and 0x82 without the find, 0x80 with the finder intact and aboard before
  turn 20, else 0x83. The withdraw gives the same.
- **Demolitions:** eight sites (the bomb rule 0x4A3F50), the bomb hook (0x4A4520) sets
  their flags and tiles (H 0x1C on six bridge hexes, else 0x1E) and damages a unit on a
  bridge hex (+1 & 0xEB | 0x28); a hook byte outside 1–8 makes the game read low memory.
  The start script puts the tiles back. The load script copies the tables in 30 pieces.
- **Deploy** (0x4A29D0): the drop groups must share their task (0x12B) and the rescue
  group 12 be formed (0x12C).

**Mission 8** (script 8, PD2 chunk 7: destroy units 40–45, then leave by submarine).
Emulated 1,300 / 1,300:
- **Pickup call** (0x4A5A60, "回収依頼 8AP"; the menu hook writes the digit 0x51AED2 as '4'
  for a crew with skills bit 2, and drops the entry once the call is made): under the AP
  0xA1. Else 0xA2 (はい / いいえ); on はい DS:0x50AD6E bit 0, the AP spent, the radio (the
  unit's crew, 0xA3), the pickup point (0x51AEFC, three choices 0x51AD78: the west quay,
  the cape's quay, the east beach → DS:0x50AD6F's nibble 1–3) and the submarine's 0xC3.
  With the radar map open it is closed (0x43F060) and the unit panel (0x466790), the map
  (0x4830E0) and the date window (0x4361C0) are redrawn.
- **Turn script** (0x4A5DF0). Stage 0, after the call: the first time the submarine
  answers (0xAE, then 0xC4, or 0xAF after the alarm), surfaces (DS:0x50AD72 bit 0) and its
  pier appears (the start script 0x4A7240: 8, 8 or 6 hexes of 0x51ADE8 / 0x51AE38 /
  0x51AE88, H 0x1E); then its wait counter (bits 1–5) counts the turns to 6; at 2 the scene
  0xB0–0xB6, at 4 the scene 0xB7–0xC1 (the captain waits after all). Then the flight turn.
  Stage 1: before the alarm (DS:0x50AD70) any spotted, damaged or destroyed player unit,
  or a damaged one of units 40–45, raises it: the alert, groups 21–31 head for the camera
  point (+0x1C from a 10‑byte local table; group 31 reads the byte after it, never set),
  groups 32–35 one row above it with +0x1D = turn + 5, 8, 11, 14. Once the submarine is
  up, each player unit on the chosen point's area (x 0–12, y 28–35; x 26–36, y 55–62; x
  61–70, y 18–29) is asked 0xC2 (its crew's names) and leaves the map on はい.
- **The first call:** groups 0, 2, 4 land on the points their +0x1F picks (0x51AC58 /
  0x51ACB8 / 0x51AD18; another value reads the stack or low memory), the radar map, the
  landing scene 0xA4–0xAD, group 0 holds at the camera point, and units 40–45 go to six
  of the twelve points of 0x51AD88 (random(12), each point used once).
- **End:** with no player unit on the map (any stage) or at the withdraw: 0x80 with all
  six of units 40–45 destroyed, 0x83 with five, else 0x82; the fates (0x4A7410): each
  player unit on the map, unless random(100) & 3 is 2, marks its crew and is flagged (odd
  random(100)) or destroyed; a destroyed one, unless random(100) & 3 is 2, marks its crew
  bit 0 or 1. Init: camera (7, 7), the computer's points (0, 6), (4, 0), (11, 0),
  DS:0x506651 = 0xD3. The load script copies the seven tables.

**Mission 9** (script 9, PD2 chunk 8: find the dry test shaft; two bridges). Emulated
1,300 / 1,300. The command ("坑内確認 25AP", 0x4A8380) checks a shaft: on four decoy hexes
0xA2 then 0xA3 (seawater), on the four test shafts (DS:0x51AFD0) 0xA2 and the shaft's
flag (DS:0x50AD70 + 2 i); all four checked: 0xA4 and DS:0x50AD6E bit 0; under 25 AP
0xA1, elsewhere 0xA5. Stage 1 ends the mission when either side has no unit on the map
(the enemy gone: DS:0x50AD78 bit 0): 0x80 with the shafts done and the enemy gone, 0x83
with one of the two, else 0x82, after the fates (0x4A8A10: a destroyed player unit marks
its crew when random(100) & 3 is 2; at the withdraw each player unit on the map is first
destroyed on that draw). Two demolition sites: the bomb rule (charge points 0x51AFF0 /
0x51B010 → 1 / 2), the bomb hook breaks 9 hexes each (0x51B030 / 0x51B090, H 0x22; flags
DS:0x50AD50 / 0x50AD52), the start script restores them. Init: camera (7, 7).

**Mission 10** (script 10, PD2 chunk 9: the last mission; ten demolition sites, then the
control room). Emulated 1,300 / 1,300:
- **Init** (0x4A9240): camera (7, 7), every drop point cleared, DS:0x506651 = 0x101 (a
  word). On a new mission (DS:0x50AD94 = 0; else it returns that byte), every crew 0–63
  in service (+4 not after DS:0x50AD92, +2 = 0) has its unit unequipped (0x457130: the
  machine, launchers and rounds back to stock) and, in a group, leaves it
  (group_drop_player 0x4549B0; not listed: the note 0x1CE, whose negative answer is
  returned) and loses flag bit 2 (0x4EE800). Then the stock is set to a fixed issue (39
  stores over DS:0x506654–0x506733: launchers 0x0C / 0x18, rounds 0x3C, the rest 0;
  `rules.M10_STOCK`). It returns 0x3C3C3C3C, its last store.
- **Turn script** (0x4A99F0): stage 0 the turn counter and the flight turn; the first
  call holds group 0 at the camera point (+0x1C = +0x22 = 0), puts its members on the
  successive points of 0x51B1A0 and plays the radio (0x121, 0x122); with no member left
  in groups 0, 2 and 4, 0x82.
- **Command** (0x4A9700, "状態確認 30AP"): under 30 AP 0xA1; on the control room hex
  (0x24, 0x29) the radio 0xA2 with the time (0x453900: (turn + DS:0x506651) × 5 minutes,
  "HH:MM" written over DS:0x515170) and 0xA3, the radar map closed as in mission 8, and
  the end code 0x80 (result 1); elsewhere 0xA4.
- **Demolitions:** the bomb rule (0x4A9C10) gives site n (1–10) for a charge on one of
  its six points (0x51B200 + 0x30 (n − 1)); the bomb hook (0x4AA190) sets the site's
  flag (DS:0x50AD50 + 2 (n − 1)), turns the guards of sites 2–9 to their alert orders
  (+3 = +3 >> 4 | +3 & 0xF0 for each member slot of their groups; an empty slot, 0xFF,
  reaches unit 255, i.e. group 0's +3), site 10 raises the alert, and the site's 14 hexes
  take their T and H bytes (0x51B3E0 + 0xB0 (n − 1), 6 B entries), each redrawn. Another
  hook byte reads low memory. The start script breaks the blown sites again; the
  withdraw is 0x82.

**DASH mission 2** (script 12, DASH chunk 1: hold the airport's north gate while two
enemy sapper groups blow its walls). Emulated 1,300 / 1,300:
- **The sappers:** groups 21 and 26 carry rounds 12 to four sites (group 21: sites 1 then
  4, its stage in DS:0x50AD50 bits 1–5 and fuse in DS:0x50AD51's nibble; group 26: sites
  2 then 3, DS:0x50AD52 / 0x50AD53; DS:0x50AD8A / 0x50AD8C count the blasts for the start
  script). In stage 1 a unit with a round 12 standing on a site's two charge hexes lays it
  (the pocket cleared, the fuse 2, its group heading 4 rows up); a fuse at 0 blows the
  site (0x4B0670, live: the explosion window, each of its 15 hexes blasted and its occupant
  hit twice by a no‑shooter blast, `fire_damage` / `apply_hit` with slot 12 and mode 4,
  then the broken tiles, each hex redrawn), the alert goes up and the group moves on. A
  group with no round left takes a destination from a table on both stages (fixed points
  (0x41, 0x3C) / (0x46, 0x46) or one of two hexes by random(2) for x and y). **Quirk:**
  after site 2 the destinations are written for group 26's members by group 21's slots
  (an empty slot of group 26 reaches unit 255, i.e. the group table).
- **The enemy's retreat:** with more than 49 computer units destroyed (counted on top of
  group 21's rounds: the routine reuses the counter) every computer group runs for the
  nearer map edge (DS:0x50AD76 bit 0); stage 0 then takes its units on row or column 1 off
  the map, and after six turns of it with player units on the map the mission is won
  (0xAC, DS:0x50AD81 nibble 1, 0x80). Two player units past (0x20, 0x26) inside rows
  0x26–0x2F for three turns send both sapper groups home (stages 4).
- **Defeat:** more than four enemy units past (0x3D, 0x37) end it (0xA9 / 0xAA, or the
  lost scene 0x4B0A10 with group 0 gone; DS:0x50AD7F 2), as does losing every ground unit
  (0x4B0A10, DS:0x50AD7D 2; during the retreat 0xA1–0xA5 and nibble 1, a win). The end code
  (0x4B0960) is 0x80 with DS:0x50AD7D or 0x50AD81 at 1, else the fates (a destroyed unit
  with condition marks its crew bit 1 unless random(100) & 3 is 2) and 0x82; the withdraw
  gives 0x83 during the retreat.
- **Command** ("状況確認 0AP", 0x4AE930): the count of enemy units past (0x3D, 0x37)
  (0xAD). Objective (0x4AE730): 0x10A, 0x10B or −1 by the groups' status nibbles. Init:
  camera (0xB, 7), drop points (0xE, 7–9), the computer's (0, 3–5), stock byte
  DS:0x5066E0 = 0, DS:0x506651 = 0x36. The first call lands group 0 on 0x51C0A8's points;
  the start script blasts the counted sites again (not live).

**DASH mission 3** (script 14, DASH chunk 3: hold Bronax airport until the reserve comes).
Emulated 1,300 / 1,300:
- **The reserve** (stage 0, once, DS:0x50AD8C bit 0): with player units on the map and
  the turn counter at 15 (10 once a unit is lost), the crews waiting (+4 = 3, +2 = 0) are
  called up: three ground crews (+3 = 0) into group 2, two air crews into group 3, then
  three and two more into groups 4 and 5; each crew +4 = 2 (+6 bits 0–1, +7 cleared), its
  unit (the same number) made ready (condition from its machine's +2, launchers' bits
  4–5 cleared, pockets refilled to the round's +0 & 0x3F, +1 = 0, +2's low nibble). An air
  group short of half its ground group stops the turn with the debug line "Bad condition"
  (0x51C8AC / 0x51C8BC; 0x10000 or the window's code). With an air group formed: the radar,
  the called-up crews on duty take +4 = DS:0x50AD8E and their unit flag bit 2, and the
  radio (0xA6–0xAA, the arrival time turn + 4 by 0x453900).
- **Stage 1:** groups 20 / 21 are sent in (DS:0x50AD50 bit 0, the alert 2) when group 8 or
  10 has taken off, or once the reserve is in and more than 49 units are lost
  (0x4BAD80); under 25 computer units left, every computer unit retreats (orders 5, to
  the nearer of column 0x45 / row 0x46, columns 0x2A / 0x2D shifted left; DS:0x50AD76),
  and stage 0 takes those reaching it off the map. Groups 22–31 with no member left on
  the map are sent to their fallback points (8, 0xE) / (0xE, 8).
- **End:** with groups 0 and 2 empty, 0x82 (and a scene when the reserve's air groups
  still fly), or 0x80 during the retreat (0xB5–0xB7); six retreat turns with them alive:
  0x80 (0xB5, 0xB8, 0xB6). The fates (0x4BAB60) by the code: 0x82 two even random(100)
  destroy a member (a third marks its crew), 0x80 / 0x83 random(100) % 3 = 1 marks a
  destroyed member's crew. The withdraw is 0x82 and sends the called-up crews not on the
  map back to waiting. Init: camera (0xC, 8), DS:0x506651 = 0x5A. No unit command.
- `take_off_map` (0x47FEE0) and 0x47FFA0 read the status from the crew table by the unit's
  signed crew number: a number below 0 reads the stock before the table (found here).
  Every read of a unit's crew record does the same (`World.crew_of`, GDScript `ucrew`):
  a crew number below 0 or past 63 reads the memory around the table, not a wrapped crew.

**DASH mission 4** (script 15, DASH chunk 4: get four trailers, units 27–30, out by column 1
across two bridges with gates). Emulated 1,300 / 1,300:
- **The gates** (A on (0x34, 0x28), B on (0x13, 0x1C); DS:0x50AD68 bit 6 / 7 open): the unit
  command on a gate hex (20 AP; "ゲート 20AP", DS:0x51CB00) opens it (0xB6, its four hexes'
  tiles 199–0xCA, DS:0x50AD6E / 0x50AD70 bit 6) or closes it (0xB7; not with a unit in the
  way, 0xB9 with its machine's name), then 0xB8; a blown bridge gives 0xBA, a blown gate
  0xBB. Elsewhere, before the trailers are called (bit 0), "通信 10AP" (DS:0x51CAF0) and
  0xBC call them (units 27–30 +0x36 = 0; the AP spent first and given back on 中止).
  Under the AP 0x1E. In stage 0 an enemy on a gate hex opens again a gate opened before, and
  sends units heading for an open gate to a random one of its bridge's charge points.
- **The bridges:** three charges on a bridge's points (0x51CA50 / 0x51CA90, flags
  DS:0x50AD80 / 0x50AD72 + 2 i; 0xC0, 0xC1, 0xC2 and 0xC5, the bomb rule returning 0x15 /
  0x16 with no fuse) arm it (DS:0x50AD51 / 0x50AD53 nibble 1): stage 0 asks 0xBD and blows
  it (0x4BEA50: five hexes blasted, occupants hit twice by a no‑shooter blast, the twelve
  span hexes broken). It also goes by itself when a trailer comes within reach and two
  enemy units stand on its points. **Quirk:** the third charge on bridge A does not mark
  its point. The far banks' walls and the gates take charges too (bomb rule 3 / 4 / 5 / 6;
  the bomb hook breaks them by the entry's hex, 0x4BED30).
- **Stage 1:** the reinforcements (groups 23–26 arrived at their targets send groups 31,
  38, 39 / 32, 40, 41 to the camera point), the enemy called out to an open gate or a blown
  bridge (DS:0x50AD6F / 0x50AD71; for B their units' set mode + 4), and each trailer on
  column 1 leaves the map (0xCA, DS:0x50AD68 bits 1–5 + 1).
- **End:** with no trailer on the map, or no player unit or trailer carrying one, the end
  code (0x4BF2D0): four away 0x80, some 0x83, none 0x82, then the fates (0x4BF310, read in
  the disassembly: a destroyed unit marks its crew bit 1 on an odd random(100), else bit 0
  under 35; a damaged ground machine with 0x82 under 40 marks bit 0 and under 60 is
  destroyed). The withdraw gives the code without the fates. The first call sets the
  enemy's timetable by group 0's +0x1F, lands the trailers (0x51C920) and plays the
  launch scene. Init: DS:0x506651 = 0x54, the stock of rounds 12 topped to 14 with those
  loaded. **Quirk:** 0xCE and 0xD1 format two and four numbers from one argument.

**DASH mission 5** (script 16, DASH chunk 5: recover the research data from two buildings
and leave by air). Emulated 1,300 / 1,300:
- **Board** ("回収 0AP", DS:0x51D240, shown with a VTOL or transport, machine 0xC / 7, within
  two hexes): one in reach is taken, several are marked and clicked (0xAC confirms, 0xAB
  for a full transport); a transport with room takes the unit aboard (0xAD; +0x33 /
  +0x34, off the map, result −1), a VTOL or a full transport takes the crew only (0xA1:
  the machine blown in the explosion window, condition 0).
- **Survey** ("建物調査 20AP", DS:0x51D250) on (0xE, 7) / (0x1C, 0x24): five steps of 20 %
  (DS:0x50AD6E / 0x50AD70 bits 1–5, 0xAA / 0xA4, 0xA6 / 0xA5, 0xA7; bit 0 done); blown
  (DS:0x50AD62 / 0x50AD64) 0xA2, done 0xA3. **Quirk:** an abort of the confirmation box
  returns the answer of the message before it. From the third step on, each player turn
  advances the building's self-destruct (DS:0x50AD72 / 0x50AD74 bits 1–5, 0xA8, then 0xAE
  each computer turn) and at 6 it blows (sites 10 / 11).
- **Sites:** eleven (16‑B entries x, y, T, H as ints: sites 1–9 on row 0x40, two hexes per
  column pair); the bomb rule gives the site (fused, hook byte n) unless blown (0xA2) or
  already charged (0xA9); the bomb hook marks DS:0x50AD4E + 2 n (n unchecked) and blows it
  (occupants destroyed twice over). Sites 4–6 or the buildings call groups 27–29 in.
- **Stage 1:** the rescue groups 12–19 (type 6x) ask to take off (0xB2 / 0xB3, as mission
  7's); the mission ends when no rescue group waits and nobody is left (the exact test
  in `m16_turn`): 0x80 with both buildings done, 0x83 with only the second after three
  steps of the first, else 0x82, and the fates (0x4C1FE0, mission 7's for VTOLs and
  transports). Deploy (0x4C0900): 0x128 for a rescue group with the wrong machines, 0x127
  with none. Init: camera (3, 4), DS:0x506651 = 0x66.

**DASH mission 6** (script 17, DASH chunk 6: three demolitions on the tidal flats, then away
by air). Emulated 1,300 / 1,300:
- **The tide:** the level is (turn ÷ 6) mod 10, mapped 0–5 → 3–8 and 6–9 → 7–4; when it
  changes (DS:0x50AD7C bits 1–5), rows 0x24–0x46 of the T layer take MAP_CHG.PCK's entry
  for it (0x4C4B70: 72 × 35 tile bytes read from the file, each hex redrawn; the import
  exports the entries as `map_chg`), and site 3's tiles are put back if it is blown. A
  failed or short read gives 0x10000.
- **Sites:** the bomb rule gives 1 / 2 / 3 on (0x22, 0xD), (0x41, 0xB), (0x27, 0x41) (fused);
  the bomb hook breaks its twelve hexes (6‑B entries) and sets DS:0x50AD50 / 52 / 54. The
  end code (0x4C4830) is 0x80 with all three, else 0x82, and the fates (0x4C4870, one pass:
  VTOLs and transports and their passengers as mission 5's, other units as mission 7's).
- **Stage 1:** groups 25, 23 (with group 26's flags: a quirk), 26 (tide level 5 or 6) and
  27 (site 1 blown) are sent to the camera point; the rescue groups and the end test as
  mission 5's. The unit command only boards (mission 5's). The deploy check wants three
  rounds 12 in groups 0, 2, 4 (0x12E) and mission 5's rescue groups (0x130 / 0x12F).
  Init: camera (7, 0xB), DS:0x506651 = 0x30.

**DASH mission 7** (script 18, DASH chunk 7: hold the trenches until the 24th Combat Unit
lands). Emulated 1,300 / 1,300. Stage 0 takes every computer unit past row 0x45 off the map
and counts it (DS:0x50AD5A bits 1–5, 0xB9 while under 21). Every stage (after the first
call): more than 20 through with player units left ends it at 0x82 (the scene 0xB0–0xB8);
else group 19 landed with player units counts the six trench zones the enemy (status 3)
still holds (0x4C6E90: six dword counters at DS:0x5242F0, in the exe's zeroed data, which
the import now carries up to 0x526000): none 0x80, one or two 0x83, more 0x82 (0xA2–0xA6
or 0xA7–0xAF with the free count); no player unit left 0x82 (0xBA–0xBC). The speaker is
unit 1 or 16 on the map, else the lead crew of group 4, 0, 2 or 4 (0x4C7240: none, the
debug line "no members left"). The fates: every unit on duty destroyed or without
condition, on random(100) & 3 ≠ 2 with 0x82 or an odd one otherwise, marks its crew and
is flagged or destroyed. The withdraw is 0x82 with the fates. Init: camera (7, 7),
DS:0x506651 = 0x54. No unit command.

**DASH mission 8** (script 19, DASH chunk 8: survey the empty town, then take a helicopter).
Emulated 1,300 / 1,300:
- **Survey** (the unit command, 調査, label DS:0x51D838): 0xC9 asks how thoroughly (中断する /
  軽く 5 AP / 普通に 10 AP / 詳しく 15 AP); on one of sixteen points (0x51D7B8; points 0 and 1
  are building 1) building i's progress (DS:0x50AD4E + 2 i bits 1–5, full at 0x14) gains the
  choice (twice with the pilot's skill, crew +8 bit 0); a full one gives the AP back. Its
  line by building and progress (0xCD–0xE6; buildings 1, 4 and 6 with building 1 blown give
  the AP back and 0xE7, after the progress was added); a building's find when it reaches full
  (bit 6; buildings 1–6) moves the story step (DS:0x50AD6E bits 1–5) on; then 0xCC with the
  percentage. Off the points 0xE7 (the AP given back).
- **Capture** (once DS:0x50AD6E bit 6 is set, 奪取 10 AP, label DS:0x51D848; none on the
  captured helicopter, machine 0x1D): a computer helicopter (machine 0x1F) on or next to the
  unit, after ui_message_box 0xCB (0xC8 none, 0xCA while carrying): the two records swap
  (each keeps its crew), the unit becomes machine 0x1D (status 0, its AP), the other is blown
  up and destroyed; 10 AP. The start hook makes machine 0x1F machine 0x1D's record (+0 0x27,
  +4 / +5 8, +6 3, +0x1A 0x18, and its names) and redraws the blown buildings.
- **Charges:** the bomb rule gives 1 on (0xE, 0x35) / (0xE, 0x39) while building 1 stands
  (past half its survey after ui_message_box 0xA1), else the point's building 2–15 unless it
  is blown (4 and 6 also need building 1). The bomb hook sets the building's bit 0 and breaks
  it (0x4CB450: building 1 from MAP_CHG.PCK entry 9, its hexes' mines cleared and their
  occupants losing random(20) + 1; the others' fixed tiles); building 1 also blasts five hexes,
  waits a second (ui_wait) and destroys every unit on duty west of x 0x20, south of y 0x22.
- **Stage 0:** the flight turn; until the sequence ends (DS:0x50AD6E bit 0) a radio call by
  story step (the HQ "Beachside Café" and the squad's name, DS:0x51F218 by its group): step
  0 with three of buildings 7–14 found (0xA3–0xA5) or computer loaders seen (0xA6–0xAB);
  steps 1–5 the finds' calls (0xAC–0xBC); step 6 the end of the survey: two of group 20 in
  sight open the capture (0xBD), else 0xBE; then groups 6 and 8 leave. At steps 4–5 a
  counter (DS:0x50AD8D) calls the return (0xBF–0xC5) after three turns; the losses of groups
  21 / 22 (0xC6 / 0xC7). Groups 6 / 8 and 21 / 22 fight off the map (random(16) picks a
  target, random(10) + 1 damage).
- **Stage 1:** a player unit on column 1 or row 0x46 is asked 0xAA (了解 / 中止): yes takes it
  (and what it carries) off the map (the captured helicopter's pilot's +4 = DS:0x50AD92 + 2);
  none left: the end code. Groups 30 / 31 / 32 fly in at turns 10 / 7 / 4; groups 21 / 22 head
  for the camera when groups 6 / 8 are gone. The first call lays MAP_CHG.PCK entry 10's mines
  (the computer's side if unit 0x28's status is 3 or more), places groups 0 and 2 (0x51D6D8 /
  0x51D748) and plays the arrival (0xF2–0xF4).
- **End** (0x4CB350): the fates (each unit on duty intact on the map destroyed on random(100)
  & 3 = 2, a destroyed one's crew marked on another), then 0x80 at story step 6, 0x83 past
  step 3 or with building 3 or 5 fully surveyed, else 0x82. The deploy check always passes.
  Init: camera (4, 0xB), DS:0x506651 = 0xF0.

**DASH mission 9** (script 20, DASH chunk 9: bring the dome down on the tunnels). Emulated
1,300 / 1,300:
- **Bulkheads:** four, east (0x3A, 0x21), south (0x20, 0x3D), west (0x0A, 0x21), north
  (0x20, 0x0B); each one's state is DS:0x50AD72 / 74 / 76 / 78 bits 1–5 (0 open, 2 shut,
  4 blown while shut, 6 wrecked while open). The unit command (entry 11, 操作 10 AP, label
  DS:0x51E1E8; under 10 AP 0x1E, off the four hexes 0xA7, wrecked 0xA8) opens a shut one
  (tiles 12 + s, 0xAC) or shuts an open one when its 4–5 hexes are clear (else 0xA6):
  tiles 8 + s, then any charges laid in it (the bomb rule set its DS:0x50AD68 + 2 s bit 6,
  hook byte 0xD + s) go off, each blasted (until skipped) and freed, and the bulkhead is
  blown (tiles 4 + s, DS:0x50AD60 + 2 s |= 1, 0xAA); else 0xAB. Both cost 10 AP.
- **Pillars:** eight charge points (0x51DC28), two per section; the bomb rule (0x4D01B0)
  says 0xA1 / 0xA2 (neither / one of the pair set), 0xA5 and -2 when that point has its
  charge, else asks 0xA3 (設置 / 中止): yes sets DS:0x50AD4E + 2 n's state to 2, 0xA4,
  and fuses the charge with hook byte n (1–8). The bulkheads' charge hexes (6 each) give
  9–12. The bomb hook (0x4D0790): 9–12 blow a shut bulkhead; 1–8 bring their section
  down while it stands: its bulkhead open becomes 6, shut is blown; DS:0x50AD50 + 4 w and
  + 2 |= 1, the ruin, the section's counter (DS:0x50AD7C + 2 w bits 1–5) + 1.
- **Tiles** (0x4D0E70): sets 0–3 are a section's ruin, MAP_CHG.PCK's entry 0xC / 0xE /
  0xD / 0xB read as 4‑byte records (x, y, T, H), each hex's occupant destroyed with what
  it carries (0x4D1BB0); then the section's quarter is cleared to T 0, H 0x3E (section 0
  also (0x46, 0x1C) and (0x26, 0x1F) / (0x27, 0x1F) with T 0x8C / 0xA7). Sets 4–15 are
  6‑byte tables (x, y, T, H; 4–7 destroy the occupants). A missing entry gives 0x10000.
  The start hook puts back each bulkhead's tiles (shut 8 + s, blown 4 + s) and the fallen
  sections' ruins.
- **Stage 0:** the turn count and the flight turn; the alarm DS:0x50AD7A (bit 0 set when
  a computer unit is damaged or destroyed or a player unit is seen (flag 0x10); then its
  count goes up each turn, and at 5 groups 20–31 get +0x1D = the turn + 1); each shut
  bulkhead with a computer unit on its three outer hexes counts a turn in the low nibble
  of the byte after its state, and past 6 it is blown (scrolled to, blasted, tiles 4 + s).
- **Stage 1:** a player unit on an exit hex ((0x26, 0x27), (0x1F, 0x27), (0x1F, 0x1F),
  (0x26, 0x1F)) is asked 0xA9 with its pilot's name (脱出 / 中止): yes takes it (and what
  it carries) off the map. All four sections down: 0x80 and the fates. Then each
  bulkhead's guard groups (20/21, 22/23, 24/25, 26/27): shut with their members inside its
  box (0x4D1AE0), they head for its hex (+7 / +8); else their +4 low bits take the
  bulkhead's number and +7 / +8 are cleared.
- **End:** no player unit on the map, or the withdraw: the end code (0x4D0C10) first sets
  off each standing section's first charge (scrolled to, blasted, the ruin, the counter);
  four sections down 0x80, three 0x83, fewer 0x82; the fates (0x4D0DE0, the same for every
  code) mark the crew of every unit on duty except those intact, with condition and off
  the map. A window's abort code from it is lost: the turn and the withdraw store its low
  byte (0) as the end code. The first call places groups 0, 2, 4 at the camera with their
  members on the points of 0x51DAA8 / 0x51DB28 / 0x51DBA8 (one per member present).
  The deploy check counts rounds 12 of groups 0, 2 and 4's members whose "crew" (the table
  indexed by the unit's number, a quirk) has +3 clear: three or fewer, 0x132. Init:
  camera (5, 5), DS:0x506651 = 0x101.

**The group scan** (0x4DE090): groups 0–19 not yet placed (+3 bit 0 clear, +2 bits 4–5
clear, +0x16 = 0xFF, with members) get their drop point at +0x18/+0x19: player point
g mod 3 (DS:0x50AD99/9B + 4k), or for type 9 (+0x21 = 9x) the bytes at units[0] +
0x33BC + 0x46 g, which past unit 254 is the group table. Groups 20–63 take the
computer's points (DS:0x50ADA5/A7 + 4k). Groups 1, 3, …, 11 of type 0, 1 or 6 aim
(+0x1A/+0x1B) at the camera point.

### 5.9 The group flight engine: Emulated

Aircraft, transports, support batteries and set‑down teams move as **groups** on a
15 × 15 grid of the operation area (DS:0x50A35C, 64 records of 35 B; groups 0–19 are
the player's, 20–63 the computer's). Fields: +2 flags (bits 1–3: 3 = a radar, 4 =
engaging; bits 4–5 the state: 0 waiting, 1 flying, 2 holding, 3 leaving; bits 6–7 the
sub‑state), +5 the member count, +6.. 16 members, +0x16/+0x17 the position, +0x18/+0x19
the drop point, +0x1A/+0x1B the target (x = 0xFF: follow group +0x1B), +0x1C the step's
price still to pay, +0x1D the arrival turn (s16), +0x1F seen by radar, +0x20 a counter,
+0x21 the type (high nibble: 0 / 1 transports with an escort, 2 a transport of the
group before it, 3 ground attack, 4 fighters, 5 a set‑down team, 6 a carrier, 9 an
escort, 15 a ground site) and +0x22 the step along the line.

**The flight turn** (0x43BDB0, emulated 1000 / 1000 whole, `verify_flight_turn`), run by
the mission's speech hook in the computer's phase:
1. the grid is cleared; for every group: its counter counts down while holding (or
   flying with sub‑state 1); a type‑3 group with no ground‑attack round left becomes
   type 4 (0x440310); a group whose counter ran out turns back (state 3) to a random one
   of its side's three points, `random(3)` (0x440240; a player group of type 3 or 4 calls
   the radio, event 0x11); a leaving group at its target leaves the grid; a waiting group
   whose arrival time has come (0x43C3C0: the arrival turn, less the flight time
   ⌈distance / the slowest member's speed⌉) starts flying from its drop point, with its
   escort for odd groups below 12, and arrives at once if it starts on its target;
2. the radar sweep (0x43CC90, below), then every follower whose leader is off the grid or
   dead holds where it is (0x43CC30);
3. twice: the grid is cleared; fighters pick targets (0x43D3E0: the other side's type 9,
   then 4, 3, then below 3; the game tests the fighter's own target where it means the
   candidate's); groups en route move (0x43C5E0: the slowest member's speed / 2 pays the
   step price, 140 diagonal and 100 straight, leftover speed carried over), the others at
   their goal arrive (0x43FC90); every group in flight engages (0x43D9C0).

**Arriving** (0x43FC90) by type: transports call the radio and hold, their type‑9 escort
heading for the camera point; a type‑2 transport sets the group before it down at its
position (type 5, members flagged on map duty with x = y = −1) and leaves; type 3 holds,
with sub‑state 2 when on the camera point (DS:0x50AD95/97), else once no member waits
for a support destination; fighters following a fair target fight it (0x441130).

**The air fight** (0x441130, emulated `verify_air_fight`): after the animation, each
group fields its first two members; while both have someone alive the pairs a0–b0,
a1–b1, a0–b1, a1–b0 fight the melee of §3 (the copy 0x4235B0 of 0x424490, weapon prompt
0x1A7, alert DS:0x50ADF1). The losing player aircraft go down (0x441A80: crew marks by
`random(100)`, carried units destroyed, a transport's cargo group loses all but 2 or 6
of its units) and are destroyed; the computer's leave their group. The game's slips are
kept: pair 2's "both down" for a computer attacker crashes a1 twice; pair 4's "both
down" drops b1 (player attacker) or a0 (computer). With no pair left while both groups
live the game loops forever. A wiped‑out group is reported (radio event 9 with a copy
of its record) and leaves the grid.

**Missiles** (0x43DD70 / 0x43E0C0 / 0x43DF50 / 0x43E3C0): a member's missile slots
(launcher +8 kind 2, a loaded pocket, a non‑zero AA attack) fire at most twice per
volley, at the group followed (attack) or the first enemy group in range flying away or
engaging (defence; range = launcher +4 × 10 on the grid). Hit chance: launcher AA
accuracy (+5) − the target crew's DEFENSE² (signed), 15 to 98; ANTI AIRCRAFT grows by 4
per shot and 4 more per hit. Damage: AA attack × (100 − air armour − DEFENSE) / 100. A
set‑down team (0x441810) meets the other side's groups on its hex: a ground site (type
15) shoots it down on `random(200)` below their count; another team triggers radio event
0x0A and clears its members' support orders.

**The radar sweep** (0x43CC90, emulated 800 / 800, `verify_radar_sweep`): player groups
with a radar (+2 bits 1–3 = 3 or 4) flying or holding, or fighters leaving, watch for
computer groups not yet seen (+0x1F = 0) with bits 1–3 = 3. The watcher is the last one
holding with sub‑state 0, else flying, else holding with sub‑state 1, then 2 (0x43D350).
Each contact hex is shown once, every contact gets +0x1F = 1, and the watcher's radio
reports their living count (event 0xD by default, 0xE for type 3; fighters flying or
holding with sub‑state 0 report 0xC and turn on the nearest contact: state 2, sub‑state
2, type 9 → 4). Event 0x10 cannot be reached there (no leaving group is ever picked).

**The radar map** (0x43E510, emulated 300 / 300): opening it (DS:0x50DD44 = 1) clears the
grid the first time and marks every group on the map but even groups below 12 still
waiting; closed, the redraw (0x43F150) clears the grid. The grid is only read by the
radar's drawing.

**The radio** (0x4896C0, emulated 1500 / 1500, `verify_radio`): the chatter for event
kinds 0–0x11, for groups below 20 with someone alive (kind 9 takes a copy of the lost
group's record). It draws its lines and speakers with `random()`: each line is the first
of its list on `random(10)` < 5, else another (`random(n − 1)`); the speaker mode is
`random(n)` of the line's modes, each drawing `random(2)` for the window side; the face
and voice come from the group's first member (crew name id, machine class, `random(2)` /
`random(100)` for some). The lines are WMES messages 0x21–0x9A with the call signs
(DS:0x50C7E5, 39 per campaign, then 34 more read past them), the time ("HH:MM" of
(the mission turn + the group's +0x20 + DS:0x506651) × 5 minutes, 0x453900) or a count. With the radar closed, the first talk window
opens it.

**Mission 1's speech hook** (0x499830, emulated 1500 / 1500, `verify_m01_speech`): the
flight turn, then for group 0 and then group 2, once each (flags DS:0x50AD76 / 0x50AD78),
on its arrival turn with members: the speaker lookup (0x489510), its arrival scene
(0xA1 / 0xA2 when the other group has arrived, 0xA3 otherwise, 0xA4 for a group whose
type low nibble is not 0; group 0 ignores its second window's result there, group 2
checks it), then its members are set down on the hexes of a word table on its stack:
group 0 on (9, 30), (8, 29), (8, 30), (9, 34), (8, 33), (8, 34), group 2 on (9, 34),
(8, 33), (8, 34); a member past the table gets whatever the stack holds.

### 5.10 Starting a campaign and loading a mission: Emulated

**The save** (0x4987C0): a save file is "PD2DATA\0" and a memory image of DS:0x506638,
0x47BD bytes: the crew table, combat records, all 255 units, the 64 groups and the DS
block (then a check, 0x436130). A new game loads its campaign's SAVEDATA.ORG: the 27
player units carry their crews (+0xB = their number) but, in PD2, no machine (+0xC =
−1); DASH's are equipped. No group has members.

**A new campaign** (0x421B90, run by game_mode_loop 0x487D70 before the first mission;
emulated 786 / 786 from both saves, `verify_new_campaign`):
- the **pilot choice** (0x422050 with its list 0x422950): PD2 offers crews 2–15, DASH the
  crews from 2 with +2 = 0 and +3 = 0, each listed with +4 = −1. The player toggles
  pilots, each toggle confirmed, up to 5 (PD2) or 11 (DASH); "done" with the count
  reached is confirmed once more, below it the game offers to fill the rest at random
  (`rand() % 14` over the list until a free entry). The C runtime's `rand()` (0x4F5F90,
  state × 0x343FD + 0x269EC3, bits 16–30) is seeded from the clock (0x48F7A0), apart from
  the game's own generator (§1). Picked pilots get +4 = 0 (PD2: only crews up to 15),
  the others −1; PD2 then numbers its picks from the third on in pairs, +4 = (n + 2) /
  2 + 1: the turn of the campaign they become available;
- crew 1's +4 = 0, and the free‑pilot list (DS:0x50AD00 / 02) is rebuilt;
- **PD2**: unit 1 takes the unit template at DS:0x5138A0 with crew 1 and joins group 0;
  the first other crew already available (+4 ≤ DS:0x50AD92, +2 = 0, +5 = −1) takes
  0x5138D7 into group 0, the second 0x51390E into group 2 — mission 1's squad;
- **DASH**: the available crews keep their unit; those with +3 = 0 are drafted (+4 = 3)
  on an odd `rand() % 100` until 6 are, those with +3 = 1 take the template at
  0x513948; more are drafted from the free‑pilot list until 6; then the crews take the
  six templates at 0x513750 in order. No group is formed: DASH's sortie comes from the
  sortie screen (0x45ED60, §5.11).

**Joining a group** (0x454690, emulated 2000 / 2000, `verify_group_join`): the unit's
machine class (machines +0 low nibble) decides where it may go — class 0 into a group
with +2 bits 1–3 = 0, class 1 into one with bits = 2, classes 2–3 into groups 0, 2, …,
10 (+3 bit 0 set; class 3 only up to group 5), classes 4–5 into groups 12–19; no more
than two members whose crew +3 is 1, and of one class. A group holds 16 units (groups
12–19 two). The unit is appended, its crew's +5 = the group, it leaves the free‑pilot
list, and its flag bit 2 is set. Return codes: 0 joined, 1 full, 2 wrong group, 3 mixed
classes, 4 no machine, 5 not in the free‑pilot list (still joined), 6 two pilots
already, 7 the group's +3 bit 0 clear, 8 class 3 past group 5.

**Loading a mission** (0x416CF0 with load_init_npc 0x417030, read in the disassembly):
the mission's INIT entry is written over units 27–254 and the 64 groups (0x39BC
bytes), its NPC entry over crews 27–36. On the campaign's first chunk (DS:0x50663D = 1)
groups 0 and 2 keep their count and members across it; on later chunks the player's
groups with +2 bit 0 are emptied and every crew with +2 = 0 and +4 ≤ DS:0x50AD92 gets
+5 = −1. Then the operation plan (0x443F60) and the sortie screen (0x45ED60) run before
the battle (DS:0x50663A = 1, 0x436530); the sortie screen is §5.11.

### 5.11 The sortie screen: Emulated

The sortie screen (0x45ED60, "hensei_g.pac") runs before every battle, after the
briefing (0x4DD2F0, which loads the mission's SCN_MIS record, 0x1C6 bytes, to
DS:0x50DE41) and the operation plan. Emulated whole, 400 / 400 runs driven through its
buttons (`verify_sortie`).

- **Opening**: each transport group 1, 3, …, 11 with members (DASH: only with +2 bit 0)
  hands them to the ground group before it (appended, crew +5 = that group; the
  transport's count becomes 0). The free‑pilot list is rebuilt: crews with +4 ≤
  DS:0x50AD92, +2 < 3, +5 = −1 and +6 bits 0–1 clear.
- **Buttons** (0x437AC0 regions): the formable groups (+2 bit 0; the buttons reach groups
  0, 2, …, 10 and 12–19); a free pilot joins the selected group through 0x454690 (§5.10;
  its refusals show MES 0x1D8, 0x1D7, 0x1D6, 0x1D5, 0x1D4, 0x1D3, 0x1DB, 0x1DC for codes
  1–8); a member leaves through group_drop_player (flag bit 2 cleared; not listed: 0x1CE).
  Its member button 1 opens the armament screen (§5.12).
- **Scrolling**: the pool and the member list scroll (the screen's layout DS:0x50D741
  stays 1, four rows each): a join takes pool row scroll + p, a drop member scroll + p; a
  join that empties the rows below the scroll resets it, as does a drop; selecting a
  group resets the member scroll.
- **The roster** (region 0x31, 0x46A240): every crew with +4 ≤ DS:0x50AD92, +2 < 3 and +6
  bits 0–1 clear, in crew order; its twelve column headers sort it (§5.19). When it
  closes, **the free pool and the groups' member lists are rewritten in its order**: each
  row's crew goes to the next pool entry (+5 = −1) or the next member slot of its group,
  from slot 0, the counts untouched — so merely opening it orders members by crew number.
  An empty roster notes 0x1CE and ends the screen (−1). Picking a free pilot scrolls the
  pool to it (n < i + 4: n − 4, or 0 below 4 rows; else i); picking a member selects its
  group and scrolls its members the same way; the member scroll is reset either way.
- **The bulk menu** (regions 0x32 ground, 0x33 air; 0x462390): a scope — 全員 (crews with
  +4 ≤ DS:0x50AD92), 選択中部隊 (the selected group's), 未編成のみ (the free pool) —, an
  action — 装備除装 (slots and pockets 0–5 back to stock), 装備除装と編成解除 (and leave
  the group), 兵器降機と編成解除 (everything back, 0x457130, and leave); the pool's two:
  装備除装, 兵器降機 —, then MES 0x1CF, for crews with +2 = 0 and +3 = ground / air.
  Cancelling the action shows the scopes again. Leaving is group_drop_player (a refusal
  notes 0x1CE) and flag bit 2 is cleared either way. It returns 1 / 2 / 3 (what to redraw;
  1 and 2 reset the member scroll).
- **Start** — the checks, in order:
  1. PD2: crew 1 (Yao) must be in a group (else MES 0x21);
  2. each ground group 0, 2, …, 10 with +2 and +3 bit 0: its pilots' transport capacity
     (machine +9) against its ground units' load (+0xA) — too little: 0x22, a spare
     transport: 0x24 (with the group's name);
  3. groups 0, 2, 4 hold a machine of class 0 (else 0x23);
  4. the mission's deploy hook (table 0x51EC68) may refuse;
  5. DASH: no rescue group (12–19, type 6) may arrive before the drop groups (0x1E2);
  6. every group with members meets its type's three requirements from the mission
     record (+7 + type × 0x1C, 7 bytes each): 0 a machine‑10 member; 1 more than 2
     rounds of ammunition 12 (TX48); 2 and 8 only machines 7 and 12; 3 only machine 8;
     4 at least one TX48; 5 appear before the groups of type 0; 6 at most 5 members; 7
     at least 10 TX48; 9 / 10 the group's bytes at units[0] + 0x3384 / 0x3386 + 0x46 g.
     A failure shows MES (type × 3 + 0x11 + i) × 3 with the group's name.
  Then "start the operation?" (0x1C).
- **Yes**: each ground group 0, 2, …, 10 with +3 bit 0 gives its transport (the next
  group) its arrival turn, +0x1F and type (groups 6–10 also +0x1A/+0x1B), and its pilots
  (crew +3 = 1) move there. Escorts (12–17, type 9) aim at their bytes at units[0] +
  0x33BE + 0x46 g. Groups whose type's record entry +0x19 is 2 or 3 take positions from
  DS:0x50ADB1 / 0x50ADD1 (index +0x1F): types 1 and 8 place their class 0–1 members,
  type 6 heads for the camera point with its members' destination there. The mission
  flags DS:0x50AD4E–0x50AD8D are cleared and the timed‑explosive and sensor lists
  emptied.
- **Yes or no**: every member of groups 0–19 is refitted — crew = unit for the player's
  27, condition from the machine (+2), launcher slots unjammed, each pocket refilled to
  its round's capacity, parts repaired. Units 0–253 below status 3 lose flag bits 0, 1,
  3–6 and their support order, and take status 0 once their crew is available (+4 ≤
  DS:0x50AD92); the alert is reset. With no the screen goes on.

The combat records (DS:0x506B39) are read and written by index (crew +15): an index of
26 or more runs past the 26 records into the 8 bytes before the unit table and on into
unit 0, as the game does (the save holds such crews).

### 5.12 The armament screen: Emulated

Opened from the sortie screen for one player unit (0x454E60, "busou_g?.pac"; emulated
whole, 600 / 600 runs through its buttons and lists, `verify_equipment`). Everything
it fits comes from the base's **stock**, kept in the save: one count per machine
(DS:0x506654), launcher (DS:0x506674) and round (DS:0x5066D4). Fitting takes one, removing
gives it back:
- a pocket's round (0x457320); a slot's launcher with the pocket it loads from (0x457250);
  everything (0x457130): the six slots, pockets 0–5 and the machine (machine = −1).
- **Machine** (button 2): the list (0x457870) offers, for a ground crew (crew +3 = 0),
  machines of class 0–1 and, for an air crew, class 2 — with machine +0x1C = 0 and +0x1E ≤
  DS:0x50AD92 (available by now), each with its stock; one out of stock is refused (MES
  0x1B0). The pick first returns everything to stock, then takes the machine.
- **A slot** (buttons 6–11): (launcher, round) pairs (0x4582D0) — launchers whose mask
  (+0, 16 bits) meets the machine's slot mask (machine +0xB + 2 × slot), with +0xE = 0 and
  +0x10 ≤ DS:0x50AD92, and each of its rounds (+0xA..+0xC) available by now; "remove"
  first when the slot is filled. Out of stock: 0x1B3 (launcher), 0x1B4 (round). Slot s
  loads from pocket s + 6, filled to the round's capacity (+0, 6 bits).
- **A pocket** (0–5, up to the machine's +0x17): remove, a pocket item (rounds with +9 = 0,
  +8 bit 4, available, and +8 bit 5 or a kind 10–13) or a spare magazine for a fitted
  launcher with +9 bit 3 (its rounds). An empty list notes 0x1B6 / 0x1B9 — and then the
  pocket is emptied, the picker's −2 being read as "remove".
- **Remove all** (button 3, 0x1A3) and **undo** (button 5, after a machine change or a
  removal: 0x1A5) — undo frees everything, restores the unit as it was on opening, and
  takes its machine, launchers and pockets 0–5 from the stock again (not pockets 6–11:
  the game's slip).
- **Close** (button 4): in a group, a unit left without a machine (0x1DA) or whose machine
  no longer fits (class changed; or an air group with two pilots and a different machine
  unless both are 7 / 12; class 2–3 in a group above 10, class 4–5 below 12; 0x1A4) is
  asked to leave it (group_drop_player, flag bit 2 cleared).
The pickers' column headers sort their rows (§5.19); a click equal to the last one a
picker remembers does nothing (the machine list remembers values below 6, the slot list
below 0xC — so its column 12 sorts again each time —, the item list below 7).
- **Layout** (local_ac, busou_g<n>.pac): on opening, no machine: 0 for a ground crew, else
  2; with one: 2 for an air crew (+3 = 1), else 0 when the machine's class (+0 low nibble)
  is 0, else 1; a machine pick sets 0x4538A0's class of it.
- **The template menu** (the right button, 0x45A700): offered with no machine unless the
  layout is 2 (layout 1 becomes 0), or with a machine of 0–6. Three entries:
  - **登録** (register): "新規登録" (new; absent when all ten registers are used) and the
    used registers. New writes register *n* (n = the registers in use); a register picked
    twice in a row asks 上書きします and overwrites it. A register takes flags |= 7, the
    machine (sign‑extended to 16 bits), **slots 0–3 only** with their magazines (pockets
    6–9; a slot's state keeps the register's bits 6–7) and pockets 0–5; then reg_unit.dat is
    written (0x45CCE0, 0x186 bytes) and 登録完了 noted.
  - **呼出** (recall): the used registers (none: 登録されていません); picking one shows it
    and, **in the register itself**, launchers of slots 0–5 with +0x10 > DS:0x50AD92 and
    rounds of pockets 0–11 with +0xB > DS:0x50AD92 become −1. Then the list holds four copies
    before the registers: 0 machine + weapons + items, 1 machine + weapons, 2 weapons, 3
    items, applied from the register shown last.
  - **複写** (copy): the same four copies from another member — crews with +4 ≤
    DS:0x50AD92, +2 < 3, a machine 0–6, +6 bits 0–1 clear, not the unit's own crew (none:
    複写可能なメンバーはいません).
  The copies: 0 / 1 need the source's machine in stock (else a note): everything goes back
  to stock, the machine is taken, then each source slot whose launcher and loading pocket's
  round (state low nibble) are in stock is fitted with its magazine — a register's slots
  0–3 (state's low 6 bits), a unit's 0–5 (whole) —; 0 then each pocket 0–5 whose round is
  in stock. 2 needs a machine (0x1DE): slots 0–3 are freed, then the source slots that also
  meet the machine's slot mask are fitted (a unit's slots 4–5 too, over what they hold,
  which is not returned). 3 needs a machine: pockets 0–5 freed, then pockets 0 .. machine
  +0x17 − 1 copied where the round is in stock (no −1 test: a −1 round reads the stock byte
  before the rounds', the last launcher's). Stock indices are signed bytes (a register's
  machine a signed 16‑bit value).
- **reg_unit.dat** (0x186 bytes at DS:0x50CCEA, read from the campaign's folder each time
  the screen opens): ten 0x27‑byte registers — +0 flags (bit 0 machine, 1 slots, 2
  pockets; in use when any is set), +1 the machine (i16), +3 + 2s slot s (launcher, state),
  +0xF + 2p pocket p (round, count) for p 0–11. The shipped file is ten empty registers
  (each register's odd bytes 0xFF, the others 0). The menu treats registers 0 .. used − 1
  as the used ones.
Emulated with the stock, reg_unit.dat and other members' loadouts varied: 794 / 794 runs
(6 skipped: 5 where a −1 machine's stock is the save header's last byte, outside the
model; 1 where every scripted close was answered no and the screen stayed open).
Not ported: a Ctrl + Alt debug key (0x4595F0).

---

### 5.13 Fire‑support strikes: Emulated

The strike executor (`strike_executor`, 0x4E37A0(side); `rules.strike_executor`,
`Strike.executor`) carries out the support orders that `ai_fire_support` and the player's
support calls leave on group members: +6 the order, +7 / +8 the aim (+7 = 0xFF: unit +8),
+0x35 the slot. mission_loop runs it for the computer (side 3) before the AI memory is aged,
and for the player (side 0) at the turn start. Emulated whole: 1,500 / 1,500 random states
for either side (`verify_strike`), with interception, apply‑hit and the game's own unit removal;
the reaction loop, the radio, the questions and the pickers are scripted. Only members of the
side (status side .. side + 2) that are not destroyed, in positioned groups (+0x16 ≠ 0xFF),
act. A group is **held** when its +2 bits 4–5 are 2 and bits 6–7 are 2.

1. **Off‑map artillery (type 5 groups):**
   - *Order 1:* the slot fires at the aimed unit's hex, or over the aimed hex's strike area
     (on the map only). The round is used and the other side answers (counter‑battery,
     below). The order becomes 3.
   - *Order 2* (a counter‑battery order): the round is used. An aimed unit that is not
     destroyed, in a held group, takes the order‑2 damage. At 0, a player unit alone in its
     group gets radio line 8, and it is destroyed. The other side answers too; order 3.
2. **Support that flies in (type 3 / 4 groups):**
   - *Order 1 at a unit:* if it is not destroyed and is spotted, the slot fires at its hex
     ("ターゲットロックオン！", 0x206, on the player side) and a round is used; else "target
     lost" (0x205). Order 3.
   - *Order 1 at a hex on the map:* every reaction flag is cleared, and the striker flies in:
     - **Entry side** (0x47E380): the side the fire point lies on, seen from the group's
       +0x18 / +0x19.
     - **Entry hex** (0x4E2A60): random rolls along that edge.
     - **Flight** (0x4E4B00): it flies the line to the aim (0x480CD0), step by step
       (0x4E4560, `move_unit`). Each step puts back the unit it displaced on its last hex
       (DS:0x51F3B4, hex DS:0x5243B0 / 0x5243B4) and saves the new hex's occupant.
     - **Reaction fire:** it is spotted at every step and draws reaction fire (flag 10).
     - **End of the flight:** it stops within its slot's range of the aim.
     - **Shot down:** the same member index runs again.
     - A flight line point with x = −1 ends the game's list: a striker standing off the
       map does not move.
     - **Otherwise:** it leaves the map where it is, the displaced unit comes back, a round
       is used, "爆弾投下" (0x207, warhead 0) or "ロケット発射" (0x208, warhead 2) shows, and
       the slot fires over the strike area. Order 3, also when the aim is off the map.
   - *Order 2:* "%s 反撃砲撃実施中" (0x20B, the group's call sign) on the player side, a
     round, and the order‑2 damage to the aimed unit with no other check. At 0, radio 8 for a
     player unit alone in its group, then it is destroyed. Order 5.
3. **Group update**, decided by the last member alive seen (any side):
   - **Type 5 with bits 6–7 = 1:** a type‑5 group with a member of the side, +2 bits 4–5 = 2
     and bits 6–7 = 1 has bits 6–7 cleared.
   - **All struck:** a held group with a member that struck (order 3 or 5) and none still
     under orders (1 / 2) is reset, and every member alive gets order 0:
     - for the player side, unless one has order 5, a type‑5 group's +0x18 / +0x1A take
       +0x16 and +0x19 / +0x1B take +0x17, and the group is retargeted back
       (`group_retarget(-1, 0)`); the +2 high nibble becomes 6;
     - for the computer's side, bits 6–7 are cleared.
   - **Other side under orders:** a group with a member of the other side under orders, bits
     4–5 = 2 and 6–7 = 0, gets bits 6–7 = 2.

**The strike** (0x4E1A90) differs from the fire routine (§4):
- **Targets:** no reveal, no height, side or class filter. Whatever stands on a hex is hit,
  friend or foe, ground or air.
- **Experience:** the striker's ATTACK grows once before the hexes, and once per hit that
  does damage.
- **Hit roll** (0x4DF3D0), mode 9: (accuracy + fire control + skill − cover − defence) × 10
  / effectiveness, kept within 15–98, with no base, height, aim or range terms.
- **Damage:** the fire damage in mode 9 (`support_damage` 0x4DF4B0 is the same formula). A
  kill credits the striker; apply‑hit destroys at once.
- **Smoke** only lays smoke.
- **Mines** (DASH only): an empty hex takes a mine of the striker's side (warhead 13).
  Warheads below 3, or 13, set off a mine on the hex unless one was just laid. Its blast
  hits the ground unit read there before the shot, even one the shot destroyed.
- **AI memory** (DASH only too): every warhead but smoke wipes the AI memory entries on the
  hex. For an active unit not standing there it is a 50 % roll; an inactive unit's x and y
  are always wiped.
- **Strike area** (0x47E130): the aimed hex first, then the rest of the spiral of the
  launcher's radius (no arc test, unlike the fire area), shuffled.

**Order‑2 damage** (0x4E2300): the slot's ground attack (launcher +3 + round +1) × (100 − the
target machine's ground armour) / 100.

**Counter‑battery** (0x4E2CF0, after each type‑5 strike):
- **Candidates:** members of the other side's type 3 / 4 / 5 groups, positioned, with +2 bits
  4–5 = 2 and 6–7 = 0, no unit of the striking side in a group on their hex, and order 0.
- **Slot:** each offers its slot with the highest ground attack, among slots that:
  - reach the striker's group: 10 × range ≥ the grid distance;
  - are not broken, with rounds and a usable pocket;
  - have a missile launcher (types 3 / 4) or a kind‑1 one (type 5).
- **The player struck:** one candidate at random is ordered: order 2 on the striker.
- **The computer struck:** the player is asked (0x203, "敵の砲撃地点を探知しました…"). While the
  answer is yes:
  - a unit is picked (0x4E3230) and a slot (0x4E0450), and that unit is ordered;
  - "さらに、攻撃を加えますか？" (0x204) asks again until the candidate count is used up.

Edge cases kept from the game:
- an aimed unit already off the map is struck at (−1, −1); the port reads nothing there;
- an entry row of 72 clears a byte past the occupancy layer, which the port skips.

The counter-battery pickers (display, read in the decompilation): the unit list
(0x4E3230) refuses a unit whose group is not standing by (+2 bits 6–7 set, or a support
order 1 / 2); the weapon list (0x4E0450) refuses a slot that is empty, out of range of
the struck group (10 × range < grid_distance; type 5 groups and missiles only), of the
wrong launcher kind for the group's type (5: 1; 3 / 4: 2), without ground accuracy or
ground attack (unless warhead 8), without rounds, or broken (state 2).

### 5.14 Reinforcements: Emulated

At the turn start, after the player's strikes and their marks (0x483ED0(0), which leaves
the same state as `refresh_strikes`: 150 / 150), reinforcements arrive or leave (0x44F2E0;
`rules.reinforcements`, `Strike.reinforcements`). Emulated whole: 150 / 150 random states (`verify_reinforcements`),
with the game's unit removal and a scripted reaction loop. The routine reads some of its
locals before writing them; the check puts the same values on the emulator's stack.

It runs for **type‑6 groups** (+0x21 high nibble 6) among groups 0–19 that are:
- positioned on the called point (+0x16 / +0x17 = DS:0x50AD95 / 0x50AD97);
- in state 2 (+2 bits 4–5 = 2).

**Arriving** (+2 bits 6–7 = 0), member by member:
1. **Entry** (0x44F030): a random first hex and edge hex on the side the group comes from
   (+0x1F, 0–7). The member is set on the edge hex.
2. **Message:** "%s%d 進入開始!!" (0x1FF), with the group's call sign and the member slot
   counter (1–16). The member is deployed (flags | 0x0C).
3. **First step** (0x44F730, mode 2): the member steps onto the first hex, unspotted.
4. **Walk to its destination** (+7 / +8; 0x44FD50). An occupied destination is replaced by
   the first hex of the growing spirals around it (radius 1–71) that is passable for
   category 0, 30 or more high, and free. The walk follows the line (0x480CD0) step by
   step (0x44F730, mode 0).
5. **Each step:**
   - the unit the member displaced comes back (DS:0x514E04, hex DS:0x523E48 / 0x523E4C);
   - the member is spotted when an active computer‑side unit has it within its recon range
     (0x44FC70);
   - spotted and not yet reacted, it draws reaction fire (flag 10). Shot down, the
     displaced unit comes back and the walk ends.
6. **Result:** a member that is not destroyed and keeps condition gets status 1, and the
   next slot is taken. Otherwise the same slot runs again, since `destroy` took the member
   out of the group (a member left in place would loop forever).
7. **Group:** with any arrived, +0x20 = 4 and +2 bits 6–7 = 2.

**Leaving** (+2 bits 6–7 = 1), every member:
1. It walks out to an edge hex (the entry routine's, taken as its destination). The game's
   easy‑mode bit is forced on for its reaction fire (DS:0x551D29 bit 1).
2. It gets status 0, its hex is emptied unless it is destroyed, and it leaves the map
   (`remove_from_map`).
3. **Group:** with any gone, the group is retargeted back (`group_retarget(-1, 0)`) and
   +2 | 0x30.

**Quirks kept from the game:**
- The entry for side 3 reads the previous member's b before setting it (for the first
  member, a leftover stack value). A side outside 0–7 sets nothing and keeps the previous
  values; the port starts them at 0.
- A path point whose x is −1 ends the game's list, so a unit standing off the map does
  not move. The same holds for the strikers' flight (§5.13).
- An edge hex on row 72 makes the game read and write the byte past the occupancy layer.
  The port skips that byte.

### 5.15 Timed explosives: Emulated

At the turn start, after the reinforcements, the 15 timed explosives (DS:0x50AC1C: x, y,
fuse, hook flag) are run in order (0x480280; `rules.timed_explosives`,
`Turn.timed_explosives`). Emulated whole: 1,500 / 1,500 random states (`verify_bombs`).
The explosion animation is stubbed by its state effect, below.

**Countdown:**
- An entry on the map with a fuse of 1 or more counts down by one.
- Any other entry (none, off the map, or a fuse below 1) is cleared (x = 0xFF) when its x
  is 0 or above 71.

**Going off:** an entry on the map whose fuse is now 0 goes off over its hex and the six
around it, in direction order 0–5. On each hex that is on the map:
1. **Animation:** the explosion is animated (0x417410), unless the player has skipped the
   animations this turn. Its end empties the hex of a unit at condition 0 (`clear_hex`).
   Option bit 0x10 turns that animation, and so the emptying, off.
2. **Damage:** the unit there, read after that, takes the no‑shooter damage (round 12,
   mode 4). The hit is applied when it does damage.
3. **Mines** (DASH only): a mine on the hex goes off. It is animated, with the same
   emptying, then cleared. An active ground unit read before takes that damage again,
   applied even at 0.

**Afterwards:** unless the entry's fourth byte is 0xFF, the mission's bomb hook runs (table
0x51F158 by mission number, with the entry's index; mission 1's, 0x49A6F0, does nothing).
Then the entry is cleared.

### 5.16 Items and sensors: Emulated

**Using an item.** A pocket round with ammo +8 bit 5 set can be used from the machine status
window (0x4279F0, the pocket menu 0x427FF0). It costs the round's AP (ammo +7, low 5 bits).

**Refusals:**
- both manipulators broken (0x1B9);
- not enough AP;
- a broken pocket (0x1B8, checked in 0x4286D0).

**Target:** the hex must be on the target map, `fire_target_map(u, 0x80 + pocket)`: the
spiral of the round's range (ammo +3), hexes with a clear arc.

**The item command** (0x4ECC60; `rules.item_command`, `Item.command`) then runs. Emulated
whole after the click: 500 / 500 random states (`verify_items`).

**A sensor round** (warhead 9):
- It goes into the sensor list (DS:0x50AC58, 42 × 4 B: x, y, turns, round), with 4 turns,
  in the first free entry. Free means no x, or x / y outside the map's rows and columns.
- The game's loop then goes on from entry 22, so every free entry from 22 on is filled
  too: a quirk.
- The sensor searches at once, and each computer‑side unit it spots shows "敵ユニットを発見"
  (0x1C7).

**Any other round:**
- **Question:** 0x1CB ("投擲ユニットにも損害を与える恐れがあります") when it is warhead 1 and
  the target lies within its radius. Otherwise 0x1CC, with the AP needed, the AP left and
  the distance.
- **Area:** the radius is 0 for a mine round and 1 otherwise; the area is the strike area
  (§5.13).
- **The throw** (0x4ED380), per hex:
  - smoke (warhead 8) lays smoke;
  - an empty hex in DASH takes a mine of the thrower's side from a mine round, even on a
    mine;
  - a unit there takes the hit roll, random(100) < 98, which never hits an aircraft. A
    miss gives it DEFENCE +1;
  - a hit gives a kill credit if it kills, then the item damage (0x4EDA00) and the item
    hit (0x4EDEB0);
  - DASH mines go off as in the fire routine (§4), hitting a unit of class below 3.
- **No experience:** there is no ATTACK growth and no shot count.
- **Item damage:** the fire damage formula with these differences:
  - the damage class table differs at armour 1, warhead 13 (200);
  - the attack comes from the thrower's class (ATTACK and the round's ground attack, or
    ANTI AIRCRAFT / 2 and its air attack);
  - the cover divisor applies in every class, with the cover doubled when the target is
    *spotted*.
- **Item hit:** one part‑damage roll, random(12). Each part steps from intact to damaged to
  broken, with no 50 % rolls. A thrower destroyed by its own throw is removed after the
  hexes.

**After use:** the pocket loses a round. An empty pocket is cleared (`clear_pocket`).

**Sensors search as "unit −1"** (0x4806A0):
- **Search map:** the round's recon range (+4) and penetration (+5) around the sensor.
- **View:** the map is marked in the view of unit −1's side. Unit −1's record is the 55
  bytes before the unit table, in the combat records.
- **Spotting** (0x47F150, mode 8): units on hexes seen, not of that side, not armour 3, are
  spotted. So are aircraft that unit −1's own recon sees (its record's recon range, from
  its position; `sees_unit(o, −1)` has the viewer second). That position is 6 levels
  higher when unit −1's machine is airborne.

**Every recon pass** (0x483490, stage 0) ends with each sensor on the map with turns left
searching. **At the turn start** (0x480910) each such sensor counts down and searches. One
that is off the map or spent is dropped.

### 5.17 Airdrops: Emulated

First at the turn start (0x44AEA0; `rules.airdrop`, `Drop.airdrop`): the groups positioned
on the called point with +2 bits 4–5 = 2 and 6–7 = 0, by type (+0x21 >> 4). Emulated whole
with the player's clicks, menus and confirmations scripted: 23 / 23 random states
(`verify_airdrop`; melee and the reaction loop scripted).

**Type 0, transports** (+2 & 0x0E = 8). Each member in turn:
1. **Load:** it carries the previous group's members that are not destroyed or deployed
   (flags & 9). Each takes its machine's size (+0xA) of the transport machine's capacity
   (+9). Once a member does not fit, no later one does. With no passenger left, the
   transports stop.
2. **Entry** (0x44AC10): random hexes on its side (+0x1F) — the edge hex it is set on and
   the first hex. It shows "%s %s降下アプローチ開始！" (0x1F7: the carried group's name and
   call sign) and gets its full AP.
3. **The player flies it** (0x44BAC0):
   - every reaction flag is cleared; any reaction fire on the first step (mode 2,
     unspotted) ends its turn;
   - while it has AP, is not destroyed and the drop menu has not finished: a click on a
     neighbour steps there (0x44C1B0, 1 AP, spotted as reinforcements are, reaction fire
     with flag 10; shot down, its passengers drop where it was); a click elsewhere asks
     0x1DC and flies the line (0x44D0D0); a click on the transport opens the drop menu
     (ui_map_click mode 4 takes only marked hexes — the move command's and the
     transport's — and returns the hex's occupant, which is what is compared);
   - out of AP: "空域離脱!! 各機降下開始!!" (0x1F5) and everyone drops around it; otherwise
     "空域離脱!!" (0x1F6). It leaves from the last clicked hex: its hex emptied, the unit it
     displaced (DS:0x514D18) back, x = y = −1.
4. **Lost:** a transport destroyed or at condition 0 has its slot run again.
5. **Afterwards:** the carried group's +2 high nibble becomes 0xA and its position this
   group's; this group is retargeted back and +2 | 0x30.

**The drop menu** (0x44C7F0):
- **One by one:** a passenger, then a hex. Hexes within 2, passable, 30 or more high, free
  or holding a ground enemy, are marked; none: 0x1F0. The click is taken wherever it is,
  then confirmed (0x1F4). The menu ends when no passenger is left.
- **All:** in DASH confirmed first (0x213). Everyone drops around the transport.
- When done, the transport leaves.

**A drop** (0x44B300):
- **Hex check:** the hex is refused when it holds a unit of the dropper's side or an
  aircraft, the dropper's category cannot cross it, it is lower than 30, or (but for
  set‑downs, mode 2) on random(100) < 30. The first acceptable hex of growing spirals
  (radius 1–71) is taken instead. None: 0x1F1 (but for set‑downs) and the unit is
  destroyed.
- **On an enemy:** 0x1BB, then melee again while both stand. The defender falling lets it
  land; the attacker falling, or both, ends it.
- **Landing:** a random facing; a jump (mode 0) by a non‑ace damages a leg on
  random(100) > 89 (0x1F2). Then it searches (step_search, mode 0; enemies found are
  announced) and is deployed (flags | 0x0C).
- **Dropping everyone** (0x44B960): for each passenger, x and y come from two separate
  picks among the radius‑6 spiral (its centre excluded). So a unit can be set on
  (70, odd row), off the map, where the game's search reads past its window.

**Type 1** (+2 & 0x0E = 8): the previous group's members drop around the last of them on
the map (mode 1). Its +2 high nibble becomes 0xA and its position the called point; this
group is retargeted.

**Types 7 and 8:** their members on the map are set down where they are (mode 2); the group
takes the called point and +2 high nibble 0xA.

### 5.18 The end of a mission and the way back to the base: Emulated

**How a mission ends** (`mission_loop` 0x436690). It clears the end code DS:0x50ADF2
before it loads the mission. Then it leaves its turn loop:
- when DS:0x50ADF2 is set after the mission's start script (stage 2), after the turn
  script's stage 1 (the end of the player's phase) or after its stage 0 (the end of the
  computer's turn). The mission scripts set it: 0x80 success, 0x83 success in part, 0x82
  failure;
- when the player's command loop (0x4EF600) returns. A unit command that leaves the end
  code set ends the player's phase (code 0); the loop then runs on to the check after the
  turn script. The command menu also returns:
  - entry 0xB "withdraw" (WMES 0x1DE answered yes) gives **0x82, the scenario command**:
    the loop breaks and calls the mission's hook from table 0x51F038 (by DS:0x50CE72),
    and the end code is DS:0x50ADF2. Mission 1's hook (0x49A6C0) sets 0x80, so
    withdrawing from mission 1 clears it. Entry 0 (0x4DE070) only shows "bad story
    level". The other missions' hooks are ported with their scripts (§5.8; all of PD2 and
    DASH's scripts 12 and 14-18 so far);
  - entry 0xC (WMES 0x1DF) gives 0x81, which quits to the title;
  - 0x99 becomes 0x82, and 0xC0 returns at once.

On any code but 0xC0, the mission's end runs (§5.7: 0x4373B0, 0x4374C0). 0x4374C0
sign-extends the machine number, so a unit without one (−1) reads DS:0x50ADF2, the end
code itself, as its machine's +0x1C, and is marked destroyed. 0x436530 then writes
savedata.tmp, a memory image of DS:0x506638..0x50ADF4 (0x47BD bytes after "PD2DATA\0";
checksum 0x436130 at DS:0x50ADF3). Emulated: the hook 200 / 200 (`verify_scenario`), the
mission end widened to units without a machine 214 / 214 (`verify_mission_start`).

The table 0x51EC68 (mission 1's 0x499480, earlier taken for a state check after every
command) has one caller, the sortie screen (0x460D60): it is the mission's deploy check
(§5.11). Mission 1's passes when group 0 or 2 is formed and its status is clear, and
otherwise shows MES 0x12B and refuses.

**The title's new game** (0x46D780 with "0"; emulated 100 / 100, `verify_new_game`):
- the campaign flag is set and PD2's SAVEDATA.ORG is loaded;
- the mode word DS:0x506638 = 1, the step DS:0x50AD8E = DS:0x50AD92 = 1, DS:0x50AD94 = 0;
- the experience counters are converted (`convert_exp`): each crew's record (+15) holds 5
  counters at DS:0x506B34 + 13 r, and each becomes the ability's threshold less the
  counter (AP from DS:0x50CC11 by +9, the others from DS:0x50CC4C by +0xA..+0xD);
- crews 0–26 and units 0–26 are copied to DS:0x50CE73 / 0x50D023, outside the save;
- the chunk DS:0x50663D and the mission DS:0x50CE72 = 1;
- then the save and PD2's record set. game_mode_loop runs the new campaign (§5.10) next,
  then the mission start.

The title's other entries (continue, the mission list, DASH's own start) are not ported.

**The debrief** (0x48FA40; game_mode_loop calls it with DS:0x50663A = 2 for any result
from 0x80 up but 0x81). It clears DS:0x50663D, loads RMES.SLD (0x4719D0: its texts) and
reads savedata.tmp back, so random()'s word DS:0x50AD90 is the saved one. USERDISK.ID's
third word (0 on the CD) is the "disk flag" below.

It was emulated whole: 200 / 200 random saves of both campaigns, every mode and result,
with every branch reached (`verify_debrief`). The windows, pictures, fades, music and lists
were stubbed (the lists close at once). DASH's SAVEDATA.ORG was read for the hand-over.
The new campaign and the score screen 0x468490 were stubbed, and they write nothing to the
save.

The comparison covered the return code, the image it saves (or memory when it saves
nothing), DS:0x50CE72, the campaign flag, the kept crews and units, clearinf.bin, and the
two generators.

In a campaign (mode 1), PD2 (flag 1):
1. **The result.** At step 1 a failure (0x82) counts as 0x80.
   - **Cleared** (0x80, 0x83): the step's flag DS:0x50AD41 + step is set, the clear
     picture (M_CLR.pac) shows with its RMES texts, then the results screen. At step 1
     these are the story, RMES 0x20–0x25. Otherwise they are chunk × 6 + 0x20 and + 0x21,
     2 later for 0x83.
   - **The last step (10) cleared** ends the campaign: end0.pac, RMES 0x66–0x69, the score
     screen, the credits; 0x81, and nothing is saved.
   - **A failure** clears the step's flag and shows m_fail.pac and the results screen. At
     step 10 it is the game over: gameover.pac, RMES chunk × 6 + 0x24, 0x81.
2. **The results screen** (0x495B70) lists every crew 0–63 with +4 up to DS:0x50AD92 and
   +2 = 0 whose unit (by number) is in a group (+0 bit 2): the name, the unit's condition
   and machine, and its state. A hurt crew is sent to hospital: +6 bit 0 is badly hurt,
   bit 1 hurt. Its +7 = random(2) + 1 missions; it is 1 for crew 22, for crew 1 with bit 0
   and for crew 0 with bit 1 alone.
3. **The end checks.** The game is over (RMES 0x62–0x64, 0x81, no save) in two cases:
   - from step 3, fewer than 3 drop‑troop crews (+3 = 0) or fewer than 3 air crews (+3 ≠ 0)
     are alive. That is, units 0–63 with +0x36 = 0 whose crew has +2 = 0 and +4 up to the
     step;
   - from step 5, fewer than half the steps are cleared (the flags DS:0x50AD42..).
4. **The next step** (below step 10): step + 1, its mission from DS:0x50CC0D (from step 8
   DS:0x50CC17). That table gives PD2 missions 1, 3, 2, 5, 7, 8, 6, then DASH at step 8 (see
   below), then 4, 9, 10 at steps 8–10 after DASH. DS:0x50AD8E = DS:0x50AD92 = the step;
   DS:0x50CE72 = DS:0x50663D = the mission. Then:
   - **New stock:** every machine, launcher and round whose restock size (machine +0x1D,
     launcher +0xF, round +0xA, signed) is above the stock raises the stock to that size.
     Rounds 0xF, 0x10 and 0x29 do so only with the disk flag. The records that come with
     this step (+0x1C / +0xE / +9 = 0, and +0x1E / +0x10 / +0xB = the step) are listed;
   - **recruits:** each crew whose +4 is the step and +2 = 0 takes its unit (+0xB = the
     crew, +0x36 = 0);
   - **the groups are emptied:** groups 0–11 lose every member through group_drop_player,
     the unit's bit 2 cleared, until they are empty. Then every crew with +4 up to the step
     and +2 < 3 leaves its group (+5); a refusal of a crew with +2 = 0 shows a note. Its
     unit's bit 2 is cleared;
   - **the hospital:** the hurt crews (with +4 up to the step and +2 < 3) count +7 down by
     one. At 0, or always for crew 1, they are back: +6 bits 0–1 are cleared, and their
     unit loses its launchers and rounds.
5. **The units** 0–63 whose crew (by number) has +4 up to DS:0x50AD92 and +2 = 0 are
   restored:
   - each comes off the map (bit 3), is no longer spotted, concealed or reacted, and has its
     parts repaired (+1 = 0, +2 low nibble 0);
   - a destroyed one (+0 bit 0 or 1) loses its launchers, rounds and machine, and the two
     bits;
   - the others have their slots' states cleared. Each loaded pocket gets its round's full
     magazine (ammunition +0 low 6 bits), but the code writes it to the pocket numbered
     like the slot. Then each slot's pocket moves to pocket 6 + slot, the slot points there,
     and pockets 0–5 are emptied.
6. **The restock** of every machine, launcher and round of the steps so far (+0x1C / +0xE
   / +9 = 0 and +0x1E / +0x10 / +0xB up to DS:0x50AD92; launchers 6, 7 and 0x15 only with
   the disk flag):
   - the count held is the stock plus what units 0–63 carry whose crew has +2 ≤ 2 and +4 up
     to DS:0x50AD92 (launchers: below it), with 0xFF past 255 (0x495EA0 / 0x495F00 /
     0x495F70);
   - with x the restock size, a count below x adds x, and otherwise rand() % x + 1 (the C
     runtime's generator, §5.10), capped at 255;
   - then the count over 3x comes off the stock (to 0 at least). For rounds the register
     keeps the amount just added when the count is not over 3x, so that amount comes off
     again: rounds only fall.
7. **Experience** of 30 on 0x80, 10 on 0x83 and 0 otherwise (ATTACK, ANTI AIRCRAFT,
   CLOSE‑COMBAT, DEFENSE; AP 9 / 3 / 0; grow_* 0x4710C0..0x471430). It goes to the crews
   whose unit still has bit 2, which step 4 has just cleared, so after a normal step nobody
   gains any.
8. **The wrecks:** units 0–253 with a machine and +0 bit 0 lose their launchers, rounds
   and machine. DS:0x50AD94 = 0.
9. **PD2's step 8 goes on in DASH:**
   - the 27 crews and units are kept aside (DS:0x50CE73 / 0x50D023), the flag is cleared and
     DASH's SAVEDATA.ORG is loaded (random()'s word with it);
   - its counters are converted, the mode is 1 at step 1, and the new campaign's pilot
     choice runs (0x421B90);
   - then mission 12 (chunk 2) at step 1, with DASH's record set;
   - DASH's caps: machine 6 and launchers 6, 7 and 0x15 lose the count over 13; rounds 0xF,
     0x10 and 0x29 become 99 less what the units carry.
10. Then savedata.tmp is written and the debrief returns 0x80.

DASH (flag 0) follows the same steps with these differences:
- the clear also sets clearinf.bin's CLEAR_FLAG + 10 + chunk;
- before its end checks (RMES 0x6E–0x70), units 0–26 get +0x36 = 0;
- its last step is 11, its missions come from DS:0x50CC14, and a failure at steps 1, 4, 6
  and 8 (DS:0x519020) skips the next step;
- the new stock raises machine 6 only with the disk flag, and launchers only for 6, 7 and
  0x15 with it;
- the restore fills the magazines twice. The hospital also lets crews 0 and 18 back at
  once and skips counts of 0xFF. There is no experience;
- the restock applies the caps after every item;
- the mode becomes 1, and when mission 4 is next the campaign goes back to PD2 at step 8:
  crews and units 0–26 return from DS:0x50CE73 / 0x50D023 with the four abilities they have
  now (+0xA..+0xD), and PD2's record set is loaded;
- its step 10 cleared shows the credits (staff2_*.pac) and goes on.

Single missions (mode 2) and replays (mode 3) only show their pictures. DASH mode 2
cleared on chunk 3 sets CLEAR_FLAG + 14.

**The next mission** (game_mode_loop): after 0x80 it reads the saved mode word and
DS:0x50AD92 back. While the mode is 1 and DS:0x50AD92 is at most 20, it runs the mission
start 0x416CF0, which reads savedata.tmp and loads chunk DS:0x50663D from pd2\ or dash\ by
the flag (§5.10, then the sortie §5.11). Otherwise the game goes back to the title.
0x4783A0, the title's case 3, is the opening (op_*.pac) and changes no state.

`rules.debrief` / `Debrief.debrief` (with `results_screen`, `mission_exit`,
`scenario_command`, `new_game`, `next_mission`; fixtures 400 / 400 with the scenario and
new-game cases).

### 5.19 The lists' sort buttons: Emulated

A list window (0x452A10) returns its column headers as 0, 1, … before its rows; the
screen sorts its rows with **0x4172B0**, an exchange sort (for i, for j > i: rows i and j
swap when cmp(row i, row j) > 0, row i then compared on) — not stable. The comparators
(read in the disassembly; "largest first" is a swap when the first row's key is smaller):

| Table | List | Columns (largest first unless noted) |
|---|---|---|
| 0x5170F0 | the sortie's roster (crews) | 0 crew number, smallest first; 1 state (4 +6 bit 0, 3 bit 1, 2 in a group, 1 free), smallest first; 2–6 crew +9..+0xD (signed); 7–10 crew +8 bits 0–3; 11 the unit's machine (signed), smallest first, **equal rows swapped** |
| 0x513980 | the new campaign's pilots (crews) | 0–4 crew +9..+0xD (signed); 5–8 crew +8 bits 0–3 |
| 0x5152E8 | the armament machines | 0–4 machine +4, +5, +6, +7, +0x18; 5 its stock |
| 0x515300 | the armament slot pairs (launcher, round) | 0 range (launcher +4 + round +3, a byte); 1 launcher +2; 2 ground attack (round +1 + launcher +3); 3 launcher +5; 4 air attack (launcher +6 + round +2); 5 round +4; 6 sign‑extended launcher +7 low 5 bits + round +6 low 5 bits; 7 launcher +8 low 5 bits (as a signed byte shifted up 3); 8 launcher +9 low 3 bits, smallest first; 9 launcher stock; 10 launcher +9 bit 3; 11 round +0 (signed; 0xFF rows last, two 0xFF rows swapped); 12 rounds whose +0 is negative last, else round stock |
| 0x515338 | the armament items (rounds) | 0 round +0 as column 11 above; 1 +1; 2 +2; 3 +4; 4 +6 low 5 bits; 5 +7 low 5 bits; 6 stock |

The new campaign's pilot choice ignores its last sort header clicked again; its marks move
with their rows, so the random fill (rand() % 14 over the list) picks list positions in
the sorted order. The slot list sorts only its pairs ("remove" stays first). Emulated in
verify_new_campaign (779 / 779 with sorts), verify_sortie (800 / 800 with the roster and
the bulk menu) and verify_equipment. A DASH new campaign then draws random pool pilots
until six ground pilots are set (0x421B90); with too few eligible ones left — which the
sorted random fill can bring about — the game draws for ever: the port stops there.

## 6. Plus Dash vs Advanced (PC‑98): discrepancies found so far

| Area | Result |
|---|---|
| Melee damage, melee sequence, Yao 40 % rule, +4/+2 bonuses, per‑exchange +1/+1 | **Identical** (instruction by instruction) |
| Experience thresholds and level cap | **Identical** |
| Fire‑mode → experience mapping, defense +1 on a miss | Same structure. Plus Dash mode table not yet compared value by value |
| Record layouts | Launcher AP fields packed (PC‑98) vs unpacked; ammunition 11 vs 12 B (see `RE_NOTES.md`) |
| Mission records | Advanced adds start time and point tables (548 vs 454 B) |
| Hit chance (all 9 terms, aces, clamps, rolls) | **Identical**, except the move‑3 quirk: the evasion cost is the *target* unit index in Plus Dash and the *shooter* unit index on PC‑98. Both come from a leftover argument or register. Modelled with `hit_terms(..., pc98=True)` |
| Effectiveness table | **Identical** to the Plus Dash table with flag DS:0x554B10 = 0. Plus Dash adds a second table (warhead 13 → 2 for armours 0–2) |
| Fire damage (formula, cover divisor, low‑condition multipliers, easy mode) | **Identical**. PC‑98 computes the non‑200 product in 32‑bit longs, with the same result |
| Warheads 14–15 | Only PC‑98 has rounds with them: the L200E passive sensor (14) and the `.80W800` EMP round (15). PC‑98 damage classes are 0 / 100. Plus Dash dropped both rounds, and its tables give 1 / 10 through the effectiveness jump table |
| Missile interception (candidates, scoring, rolls, ace +30, decoys) | **Identical** (instruction by instruction). Only the ammo record layout differs |
| Applying a hit (spotting, criticals, part table, movement gear) | **Identical**, plus the **PC‑98‑only EMP effect** of warhead 15 (§4.5) |
| Max AP | **Same formula**. PC‑98 uses 16‑bit arithmetic, which differs only for impossible pocket counts |
| Movement step costs and blocking | **Identical** (instruction by instruction). The PC‑98 outer search loop has not been compared |
| Reaction fire: computer roll percentages, order, stop rule, position memory | **Identical** (PC‑98 ovseg 0 0x163D), except the start value used for a searching target |
| Reaction weapon choice | **Same structure and filters** (PC‑98 ovseg 0 0xDEA); not compared value by value |
| Line of sight, short‑range trace, reaction candidates | **Identical** (PC‑98 res DDF:A, ovseg 0 0xF77), including the x‑parity quirk |
| Recon: sight levels, ring, search map, unit search, unit‑to‑unit sight | **Same structure and constants** (PC‑98 res DDF:44D / 878 / 97B / C55 / 1334 / 15BD); not compared value by value |
| End‑of‑phase upkeep | PC‑98 (ovseg 2 0xACC) is **identical to the Plus Dash flag‑0 version** (the DASH campaign). Flag 1 (the PD2 campaign) refills AP, repairs only +1, and drops Hardy from the training aces |
| Campaign flag DS:0x554B10 | **Plus Dash only**: 1 = the PD2 campaign, 0 = DASH (which plays by the PC‑98 rules). It also selects the second effectiveness table (§4.2) |
| AI move (PC‑98 ovseg 11 0x3885) | **Identical** structure, weights, movement‑mode table, reserve, choice, fallback and return codes. Modes above 9 are undefined in both: PC‑98 leaves all five weights uninitialised, Plus Dash the kind‑0 weight |
| AI distance field (PC‑98 ovseg 11 0x29C7) | **Same structure** (search limits, blocking of other enemies, −1 / 0 post‑pass), with 16‑bit cells |
| AI engage (PC‑98 ovseg 11 0x1BE8, pickers 0x18DE / 0x165B / 0x145E) | **Same structure**: order, choice, tie roll, threshold, shot limit, reload, and the anti‑air quirk (u's own spotted flag). **Differs:** PC‑98 takes any unit with status < 3 as a target and in the blast sums, where Plus Dash requires status 0. PC‑98 scores are 16‑bit |
| AI conceal, search, reload (PC‑98 ovseg 11 0xC37 / 0xC8E / 0xA4A) | **Same structure and costs**; the reload also spends the reload AP |
| AI behaviours 1 and 2 (PC‑98 ovseg 11 0x4136 / 0x483B) | **Same** block sequence, engage parameters (all 31 calls) and condition tests (55 / 60) |
| AI behaviours 5, 6, 7 (PC‑98 ovseg 11 0x54F2 / 0x5690 / 0x5983) | **Same** case tables, blocks, move modes and the 30 % search |
| AI behaviours 3, 4, 11 (PC‑98 ovseg 11 0x4BA2 / 0x4E87 / 0x6000) | **Same**, including order 4's dead case‑4 engage |
| AI behaviours 8, 10 (PC‑98 ovseg 11 0x5227 / 0x5C4C) | **Same**. Order 10's done flag is uninitialised in both: Plus Dash reads the unit index, PC‑98 stack garbage |
| AI behaviour 9 (PC‑98 ovseg 11 0x5EF2) | **Differs:** PC‑98 fires once (engage (−1, 1, −1)) after digging in; Plus Dash only conceals, supports and searches |
| Fire resolution, AI fire (PC‑98 ovseg 5 0x1781) | **Same structure**: interception before an always‑made hit roll, smoke, the 30‑level cut, warhead‑13 mines. PC‑98 has no campaign flag, so the mine rules always apply. Not compared value by value |
| Movement steps | PC‑98 not compared yet |
| AI fire support (PC‑98 ovseg 11 0x641) | **Same rules and costs**, including the members paying the AP. **Differs:** PC‑98 takes groups **23**–63 as support groups and checks groups 0–22 for shadowing, where Plus Dash uses 20–63 and 1–19. The called point is at DS:0x4916 / 0x4918 |
| AI tactical field (PC‑98 ovseg 11 0x3001) | Same base, cover, flag, blocking, area pass and destination rule, with 16‑bit cells. **Exposure differs:** PC‑98 subtracts d × weight whenever d < R, with no R/2 fold. Its kind‑1 weapon finder (0x12F7) compares the best range with **itself**, so it never picks a weapon: on PC‑98 the kind‑1 term is always 0. Plus Dash fixed the finder and added the fold |

## 7. Next steps

1. Still to name:
   - slots 4–5 and flags 0x02 / 0x80;
   - unit status value 1 (always blocks movement);
   - tile 0xFE (the supply tile) on each map, and the turn‑length / time rules.
   Also find where the PC‑98 EMP counter (+2 bits 4–5) is counted down.
2. Check the conditions under which the fire routine calls interception (it also
   looks at sides and the spotted flag), and the Data Book's "missile intercept
   %" values against §4.4.
3. **The computer side** (§5.8):
   - The tactical rules are ported end to end (§4, §5): the computer's whole
     turn and every piece the player's commands use (fire, reaction shot, steps,
     search, conceal, reload). Left for the Godot engine, written from the
     decompiled C: the event scripts (the player's dialogs — reaction menu, mine
     clearing, "enemy discovered" — are ported);
   - the event scripts mission by mission (226 KB in all): all ten PD2 missions and
     DASH's missions 2-7 (scripts 12, 14-18) are ported and emulated; left: DASH's other 6 (scripts 11–22), and the
     approach loop 0x4403D0 and the operation plan's deployment rules (0x51EAE8..).
   Also the per‑step recon while moving (0x474090 / `step_visibility` (0x474E20) call `sees_unit` (0x412190)), and
   the search command for movement mode 3.
4. The remaining action costs: conceal, lay mines, throw, reload and item use.
5. Confirm that PC‑98 `random()` (0x118:6) is the same generator.
