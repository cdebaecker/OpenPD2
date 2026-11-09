extends Node
## Reads what engine/importer/pd2_import.py wrote to user://import from the player's own
## copy of the game. Nothing of the game is in the project itself.

const ROOT := "user://import"

var manifest: Dictionary = {}
var palette: Array = []
var _tables := {}


func _ready() -> void:
	reload()


func available() -> bool:
	return not manifest.is_empty()


func reload() -> void:
	manifest = _json(ROOT + "/manifest.json")
	var pal: Dictionary = _json(ROOT + "/palette.json")
	palette = pal.get("tactical", [])
	_tables.clear()


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
		}
		_tables[campaign] = t
	return _tables[campaign]


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
