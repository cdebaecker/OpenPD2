# OpenPD2

Play **POWER DoLLS 2 plus DASH** (Kogado Studio, Windows, 1998) with a new engine built on
Godot 4. The engine reproduces the original game's rules exactly, including the
random-number generator, the combat formulas and the computer's 11 AI behaviours.

OpenPD2 contains **nothing from the original game**. It reads the data from your own
copy of the game. You need the POWER DoLLS 2 plus DASH CD: the CD image (`.img` /
`.cue` / `.ccd` / `.iso`), a copy of the CD's files, or an installed game folder.

> POWER DoLLS © Kogado Studio. OpenPD2 is a fan project, not affiliated with or endorsed
> by Kogado Studio.

## Status

Early. The tactical battle runs as a **sandbox**:
- each mission's map and enemy force;
- a stand-in squad of four DoLLS;
- moving, normal and aimed fire, search, conceal and melee;
- the computer's whole turn.

Still missing:
- the briefing and equipment screens;
- the player's own fire and reaction menus;
- the mission event scripts and the victory checks;
- the strategy layer, music and saves.

## 1. Import your game

Needs Python 3.10 or later:

```
python -X utf8 importer/pd2_import.py "path/to/Power Dolls 2+dash.cue"
```

The importer checks `Pd2.exe` against `importer/versions.json`. It accepts only the
original Windows CD release. It writes the record tables, missions, maps and palette
to Godot's user folder for OpenPD2:
- Windows: `%APPDATA%\Godot\app_userdata\OpenPD2\import`
- Linux: `~/.local/share/godot/app_userdata/OpenPD2/import`

## 2. Run

Open `godot/` in Godot 4.7 and press Play. The start screen lists the missions of both
campaigns.

Controls:
- left click selects or acts; right or middle drag pans; the wheel zooms;
- M move, F fire, A aimed fire, 1–4 weapon slot;
- S search, C conceal;
- Tab next unit, E end turn.

Headless check, which loads every mission and plays two turns:

```
godot --headless --path godot -s tests/smoke_battle.gd
```

## How it is built

- `importer/`: `pd2_import.py` and the format readers in `formats/`. They read the CD's
  ISO 9660 track, the InstallShield `data.z`, the `.PCK` / `.SLD` archives, the map
  layers, and the record tables in `Pd2.exe`.
- `godot/core/`: the rules, pure GDScript with no UI. The game state is laid out like the
  original's memory, so each rule reads the same bytes the game reads. The core is a
  line-for-line port of the project's Python reference implementation. That
  implementation was checked against the original code under emulation, and the port is
  checked against it case by case. The reference and its checks are not part of OpenPD2.
- `godot/ui/`: the start screen and the battle.
- `docs/RULES.md`: the rules, written out.

## Licence

GPL-3.0 (see `LICENSE`).
