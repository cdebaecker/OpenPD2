extends SceneTree
## A mission whose groups fly in (PD2 mission 1): the approach (0x4403D0) opens the flight
## window; once the player's phase begins it must be closed (ui_refresh_panels' 0x43F060)
## so the map shows. Windowed: godot --path engine/godot -s tests/approach_view.gd

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.pick_window = false
	b.plan_window = false
	b.sortie_window = false
	root.add_child(b)
	for i in 300:
		await process_frame
	var shown: bool = b.radar_view != null and b.radar_view.visible
	var ok: bool = b.w != null and b.w.phase == 0 and not b.busy and not shown
	print("player phase %s, busy %s, flight window shown %s: %s" % [b.w.phase == 0 if b.w else false, b.busy, shown, "ok" if ok else "FAILED"])
	quit(0 if ok else 1)
