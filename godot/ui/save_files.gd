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


## 0x498070's line for slot s (Title.slot_line): the save's mode (Campaign / One Shot /
## Rescue), its name (DS:0x50663E), the time (0x453900: the mission turn from DS:0x506651,
## for a save made in a battle; else 0x50CBD1's 編成) and the verb (0x519ED8 overwrite,
## 0x519EE8 load), format 0x519EF0.
static func slot_line(s: int, verb: int) -> String:
	var line: Variant = Title.slot_line(read("PD2REC%02d.BIN" % s), 0xFF, false)
	if not line is Array:
		return "%02d  %s" % [s + 1, GameData.ui_text("UI_SLOT_EMPTY")]
	var when: String = line[2] if line[2] != null else exe(Title.SLOT_SORTIE_TIME)
	# wsprintfA's format (%8s right-aligned, %-18s left-aligned, %-5s)
	return "%02d  %s" % [s + 1, GameData.exe_raw("dash", 0x519EF0) % [exe(line[0]), saved_name(line[1]), when, exe(verb)]]


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


## A save file's modified time as the local date (FindFirstFile's ftLastWriteTime through
## FileTimeToLocalFileTime): {} without the file.
static func modified_time(name: String) -> Dictionary:
	var p := "user://saves/" + name
	if not FileAccess.file_exists(p):
		return {}
	var t := FileAccess.get_modified_time(p)
	var bias: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_dict_from_unix_time(t + bias)
