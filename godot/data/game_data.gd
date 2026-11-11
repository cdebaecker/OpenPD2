extends Node
## Reads what engine/importer/pd2_import.py wrote to user://import from the player's own
## copy of the game. Nothing of the game is in the project itself.

const ROOT := "user://import"

var manifest: Dictionary = {}
var palette: Array = []
var _tables := {}
var _messages := {}
var _translations := {}
## "ja" shows the game's own text; "en" / "fr" use the translation tables when they have
## the message (translations/*.csv: res://translations, user://translations, the folder
## named by the PD2_TRANSLATIONS environment variable, or a PowerDolls2-content checkout
## next to this one), else the Japanese text.
var language := OS.get_locale_language()


func _ready() -> void:
	reload()


func available() -> bool:
	return not manifest.is_empty()


func reload() -> void:
	manifest = _json(ROOT + "/manifest.json")
	var pal: Dictionary = _json(ROOT + "/palette.json")
	palette = pal.get("tactical", [])
	_tables.clear()
	_messages.clear()
	_translations.clear()


func mission_count(campaign: String) -> int:
	return int(manifest.get("missions", {}).get(campaign, 0))


## Record tables of a campaign: machines (32 x 31 B), launchers (96 x 17 B), ammo (72 x 12 B),
## and the names.
func tables(campaign: String) -> Dictionary:
	if not _tables.has(campaign):
		var doc: Dictionary = _json("%s/tables/%s.json" % [ROOT, campaign])
		var t := {
			"machines": _join(doc.get("machines", [])),
			"launchers": _join(doc.get("launchers", [])),
			"ammo": _join(doc.get("ammo", [])),
			"machine_names": doc.get("machine_names", []),
			"launcher_names": doc.get("launcher_names", {}),
			"ammo_names": doc.get("ammo_names", {}),
			"crew_names": doc.get("crew_names", []),
			"crew": Marshalls.base64_to_raw(doc.get("crew", "")),
			"call_signs": doc.get("call_signs", []),
			"exe_text": doc.get("exe_text", {}),
			"script_choices": doc.get("script_choices", {}),
			"map_chg": doc.get("map_chg", []).map(func(e): return Marshalls.base64_to_raw(e)),
			"data_image": [int(doc.data_image[0]), Marshalls.base64_to_raw(doc.data_image[1])] if doc.has("data_image") else [],
		}
		_tables[campaign] = t
	return _tables[campaign]


## A campaign's new-game state (SAVEDATA.ORG's memory image, from <campaign>/save.json):
## [base address, bytes], or [] with an older import.
func save_image(campaign: String) -> Array:
	var doc: Dictionary = _json("%s/%s/save.json" % [ROOT, campaign])
	if not doc.has("image"):
		return []
	return [int(doc.base), Marshalls.base64_to_raw(doc.image)]


## The campaign's REG_UNIT.DAT as shipped (the armament screen's ten registers), or [].
func reg_unit_shipped(campaign: String) -> PackedByteArray:
	var doc: Dictionary = _json("%s/%s/save.json" % [ROOT, campaign])
	return Marshalls.base64_to_raw(doc.get("reg_unit", ""))


## A text of Pd2.exe's own (the import's exe_text, by address), translated (exe.csv: the
## address in hex) and formatted.
func exe_text(campaign: String, va: int, args := []) -> String:
	return format_text(exe_raw(campaign, va), args)


## The same text unformatted (for the texts the game formats with wsprintfA).
func exe_raw(campaign: String, va: int) -> String:
	var t := _translated("exe", "%X" % va)
	if t == "":
		t = str(tables(campaign).get("exe_text", {}).get("%X" % va, ""))
	return t


## A mission's data, with the base64 blobs decoded to PackedByteArrays.
func mission(campaign: String, index: int) -> Dictionary:
	var doc: Dictionary = _json("%s/%s/missions/m%02d.json" % [ROOT, campaign, index])
	for k in ["record", "init", "roster", "npc", "S", "M", "H"]:
		doc[k] = Marshalls.base64_to_raw(doc.get(k, ""))
	return doc


func map_texture(campaign: String, index: int) -> Texture2D:
	var path := "%s/%s/maps/m%02d.png" % [ROOT, campaign, index]
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	return ImageTexture.create_from_image(img) if img else null


## A battle message (WMES.PCK, as message_text 0x471A00 reads it), translated, with its
## arguments filled in by format_text (0x435B10). `entry` is the WMES entry (DS:0x50663D - 1,
## the mission's chunk); ids 0x1A3 and up hold the same text in every entry of both campaigns.
func battle_text(campaign: String, id: int, args := [], entry := 0) -> String:
	return format_text(battle_raw(campaign, id, entry), args)


## A battle message's text before format_text (its format codes kept), translated.
func battle_raw(campaign: String, id: int, entry := 0) -> String:
	if not _messages.has(campaign):
		_messages[campaign] = _json("%s/%s/messages.json" % [ROOT, campaign])
	var tables: Array = _messages[campaign].get("wmes", [])
	var ja := ""
	if entry < tables.size() and id < tables[entry].size():
		ja = tables[entry][id]
	if ja == "" and not tables.is_empty():
		return ""                           # a line the entry leaves empty stays empty
	# a mission's own messages differ between entries: "<campaign>.<entry>.<id>" first,
	# then "<campaign>.<id>" (the radio lines differ between campaigns), then "<id>"
	var t := _translated("wmes", "%s.%d.%X" % [campaign, entry, id])
	if t == "":
		t = _translated("wmes", "%s.%X" % [campaign, id])
	if t == "":
		t = _translated("wmes", "%X" % id)
	if t == "":
		t = ja
	return t


## The radio's call sign n (DS:0x50C7E5, the campaign's set), translated (callsigns.csv,
## key "<campaign>.<n>", else "<n>"; the English names are the game's own and need none).
func call_sign(campaign: String, n: int) -> String:
	var t := _translated("callsigns", "%s.%d" % [campaign, n])
	if t == "":
		t = _translated("callsigns", "%d" % n)
	if t != "":
		return t
	var signs: Array = tables(campaign).call_signs
	return signs[n] if n >= 0 and n < signs.size() else ""


## A debrief text (RMES.SLD, which 0x4719D0 loads for the debrief 0x48FA40), translated
## (rmes.csv: "<campaign>.<id>") or the game's own; an empty line stays empty.
func debrief_text(campaign: String, id: int) -> String:
	if not _messages.has(campaign):
		_messages[campaign] = _json("%s/%s/messages.json" % [ROOT, campaign])
	var lines: Array = _messages[campaign].get("rmes", [])
	var ja: String = lines[id] if id >= 0 and id < lines.size() else ""
	if ja.strip_edges() == "":
		return ""
	var t := _translated("rmes", "%s.%X" % [campaign, id])
	# the game's page breaks (0x0C), line breaks (CR) and waits for a click (@)
	var out := format_text(t if t != "" else ja, [])
	return out.replace(char(12), "").replace(char(13), char(10)).replace("@", char(10)).strip_edges()


## A title note (MES0.SLD, which 0x471990 loads for the title; message_text there reads
## it), translated (mes.csv: "mes0.<id>") or the game's own.
func title_note(id: int) -> String:
	if not _messages.has("dash"):
		_messages["dash"] = _json("%s/%s/messages.json" % [ROOT, "dash"])
	var lines: Array = _messages["dash"].get("mes0", [])
	var t := _translated("mes", "mes0.%X" % id)
	if t == "":
		t = lines[id] if id >= 0 and id < lines.size() else ""
	return format_text(t, [])


## A base-screen message (MES.PCK, which message_text reads while DS:0x50663A = 0: the
## sortie screen, the briefing), translated (mes.csv: "<campaign>.<entry>.<id>", then
## "<campaign>.<id>", then "<id>") and formatted; a line the entry leaves empty stays empty.
func base_text(campaign: String, id: int, args := [], entry := 0) -> String:
	if not _messages.has(campaign):
		_messages[campaign] = _json("%s/%s/messages.json" % [ROOT, campaign])
	var tables: Array = _messages[campaign].get("mes", [])
	var ja := ""
	if entry < tables.size() and id < tables[entry].size():
		ja = tables[entry][id]
	if ja == "":
		return format_text("", args)
	var t := _translated("mes", "%s.%d.%X" % [campaign, entry, id])
	if t == "":
		t = _translated("mes", "%s.%X" % [campaign, id])
	if t == "":
		t = _translated("mes", "%X" % id)
	if t == "":
		t = ja
	return format_text(t, args)


## An engine UI string (translations/ui.csv): the language's column, else English, else the key.
func ui_text(key: String) -> String:
	if not _translations.has("ui"):
		_translations["ui"] = _load_csv("ui")
	var row: Dictionary = _translations["ui"].get(key, {})
	return row.get(language, row.get("en", key))


func _translated(table: String, key: String) -> String:
	if language == "ja":
		return ""
	if not _translations.has(table):
		_translations[table] = _load_csv(table)
	var row: Dictionary = _translations[table].get(key, {})
	return row.get(language, "")


static func _load_csv(table: String) -> Dictionary:
	var dirs := ["res://translations", "user://translations"]
	if OS.has_environment("PD2_TRANSLATIONS"):
		dirs.append(OS.get_environment("PD2_TRANSLATIONS"))
	# a development checkout next to the content repository (D:/Dev/PowerDolls2-content)
	dirs.append(ProjectSettings.globalize_path("res://").path_join("../../../PowerDolls2-content/translations").simplify_path())
	var out := {}
	for d in dirs:
		var f := FileAccess.open("%s/%s.csv" % [d, table], FileAccess.READ)
		if f == null:
			continue
		var head := f.get_csv_line()
		while not f.eof_reached():
			var row := f.get_csv_line()
			if row.size() < 2 or row[0] == "":
				continue
			var cells := {}
			for i in range(1, mini(row.size(), head.size())):
				if row[i] != "":
					cells[head[i]] = row[i]
			out[row[0]] = cells
	return out


## format_text (0x435B10): %% is a percent sign; %[width] then d / l (decimal, padded with
## spaces on the left to the width), x (upper-case hex; decimal when negative), s (padded
## on the right and cut to the width), c (one character). %aHH and %b (which takes an
## argument) set the colour and print nothing here. A backslash then n or r is a line break.
## '@' is left in: the game's window printer (0x438FE0) waits for a click there.
static func format_text(t: String, args: Array) -> String:
	var out := ""
	var ai := 0
	var i := 0
	while i < t.length():
		var c := t[i]
		if c == "\\" and i + 1 < t.length() and (t[i + 1] == "n" or t[i + 1] == "r"):
			out += "
"
			i += 2
			continue
		if c != "%":
			out += c
			i += 1
			continue
		i += 1
		if i >= t.length():
			break
		if t[i] == "%":
			out += "%"
			i += 1
			continue
		var wd := ""
		while i < t.length() and t[i] >= "0" and t[i] <= "9":
			wd += t[i]
			i += 1
		var width := mini(int(wd), 80) if wd != "" else 0
		if i >= t.length():
			break
		var k := t[i]
		i += 1
		var a: Variant = args[ai] if ai < args.size() else 0
		match k:
			"d", "l", "x":
				ai += 1
				var n := int(a)
				if k == "d":
					n = ((n & 0xFFFF) ^ 0x8000) - 0x8000      # a short
				var v := ("%X" % n) if k == "x" and n >= 0 else str(n)
				out += " ".repeat(maxi(0, width - v.length())) + v
			"s":
				# the width counts Shift-JIS bytes (0x435B10): a double-byte character counts
				# 2 and is copied while the count is below the width
				ai += 1
				var v := str(a)
				var n := 0
				for ch in v:
					var u := ch.unicode_at(0)
					if width == 0 or n < width:
						out += ch
					n += 1 if _single_byte(u) else 2
				if n < width:
					out += " ".repeat(width - n)
			"c":
				ai += 1
				out += char(int(a)) if a is int else str(a)
			"a":
				i += 2
			"b":
				ai += 1
	return out


## A character's width in the game's Shift-JIS text: ASCII and the half-width kana are one
## byte; the translations' Latin letters with accents (no Shift-JIS form) count one too.
static func _single_byte(u: int) -> bool:
	return u < 0x80 or (u >= 0xFF61 and u <= 0xFF9F) or (u >= 0xC0 and u <= 0x24F and u != 0xD7 and u != 0xF7)


## A prompt's text and its choices: the choices start after the full-width space before the
## first choice and are split by
## '・' ("移動　・　中止"), as the texts are written (the popup builder 0x40C090 is not
## read yet); answer 0 is the first choice (the prompt's 0, checked in the emulated
## commands). Returns [text, [choices]].
static func prompt_parts(t: String) -> Array:
	var f := t.find("・")
	if f == -1:
		return [t, []]
	var cut := f
	while cut > 0 and t[cut - 1] == "　":
		cut -= 1
	while cut > 0 and t[cut - 1] != "　":
		cut -= 1
	var parts := []
	for p in t.substr(cut).split("・"):
		parts.append(p.replace("　", "").strip_edges())
	var head := t.substr(0, cut)
	while head.ends_with("　") or head.ends_with(" "):
		head = head.left(head.length() - 1)
	return [head, parts]


static func _join(parts: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for p in parts:
		out.append_array(Marshalls.base64_to_raw(p))
	return out


static func _json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return {}
	var v = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v != null else {}
