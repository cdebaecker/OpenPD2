class_name SaveFiles
extends RefCounted
## The game's save files in user://saves (the game folder's PD2RECnn.BIN, MEMBERnn.DAT,
## KEMURInn.DAT and savedata.tmp) and the lines its slot lists show (0x498070).

const DIR := "user://saves"


static func read(name: String) -> Variant:
	var p := DIR.path_join(name)
	return FileAccess.get_file_as_bytes(p) if FileAccess.file_exists(p) else null


static func write(name: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(DIR.path_join(name), FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	return true


## The world the title runs on (0x46D780): the exe's data and the memory as DASH's
## SAVEDATA.ORG leaves it (what the title does not load stays as it is).
static func title_world() -> Pd2World:
	var tables := GameData.tables("dash")
	var w := Pd2World.new(tables.machines, tables.launchers, tables.ammo, PackedByteArray(), 255)
	w.n_units = 254
	var img: Array = tables.get("data_image", [])
	if img.size() == 2:
		w.static_mem[img[0]] = img[1]
	var sv: Array = GameData.save_image("dash")
	if sv.size() == 2:
		Debrief.load_image(w, sv[1])
	w.title_list = Title.saved_list
	return w


static func exe(va: int, args := []) -> String:
	return GameData.exe_text("dash", va, args)


## An exe pointer array's strings (the import's script_choices).
static func choice_texts(arr: int) -> Array:
	var out := []
	for p in GameData.tables("dash").get("script_choices", {}).get("%X" % arr, []):
		out.append(GameData.exe_text("dash", ("0x" + str(p)).hex_to_int()))
	return out


static func mission_name(m: int) -> String:
	var names := choice_texts(Title.MISSION_NAMES)
	return names[m] if m >= 0 and m < names.size() else "#%d" % m


## 0x498070's line for slot s: the save's mode (Campaign / One Shot / Rescue), its name
## (DS:0x50663E) and the verb (0x519ED8 overwrite, 0x519EE8 load), format 0x519EF0. The
## date the game prints for a save made in a battle (0x453900) is not ported: left blank.
static func slot_line(s: int, verb: int) -> String:
	var d: Variant = read("PD2REC%02d.BIN" % s)
	var data: PackedByteArray = d if d != null else PackedByteArray()
	if data.size() < 8 + 0x1C or data.slice(0, 8) != Title.magic():
		return "%02d  %s" % [s + 1, GameData.ui_text("UI_SLOT_EMPTY")]
	var mode := data[8] | data[9] << 8
	var kind := exe(0x50CBF2 if mode == 1 else (0x50CBFB if mode == 2 else 0x50CC04))
	var name := data.slice(8 + 6, 8 + 0x1C)
	var z := name.find(0)
	if z != -1:
		name = name.slice(0, z)
	# wsprintfA's format (%8s right-aligned, %-18s left-aligned)
	return "%02d  %s" % [s + 1, GameData.exe_raw("dash", 0x519EF0) % [kind, saved_name(name), "", exe(verb)]]


## The save's name (Shift-JIS): the mission name it was copied from, found in the exe's
## data (the import's text for that address), else the bytes as ASCII.
static func saved_name(b: PackedByteArray) -> String:
	var img: Array = GameData.tables("dash").get("data_image", [])
	for p in GameData.tables("dash").get("script_choices", {}).get("%X" % Title.MISSION_NAMES, []):
		var addr := ("0x" + str(p)).hex_to_int()
		if img.size() == 2 and not b.is_empty():
			var data: PackedByteArray = img[1]
			var o := addr - int(img[0])
			if o >= 0 and o + b.size() < data.size() and data.slice(o, o + b.size()) == b and data[o + b.size()] == 0:
				return GameData.exe_text("dash", addr)
	return b.get_string_from_ascii()


## The sortie's save with its slot and answer chosen (rules.SaveHooks): files to user://saves.
class Writer extends Title.SaveHooks:
	var pick := 0x29
	var answer := 1
	var notes := []

	func slot() -> int:
		return pick

	func confirm(s: int) -> int:
		return answer

	func note(text: int) -> int:
		notes.append(text)
		return 0

	func write(name: String, data: PackedByteArray) -> bool:
		return SaveFiles.write(name, data)
