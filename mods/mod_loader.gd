extends Node
## Minimal mod loader for Explosiovania.
## Loaded through override.cfg (no changes to Explosiovania.pck).
## Every folder in <game>/mods/ that contains a mod_main.gd is instantiated as a child node.
## Delete override.cfg (or the mods folder) to go back to the vanilla game.

const VERSION := "1.0.0"


func _init() -> void:
	var mods_dir := OS.get_executable_path().get_base_dir().path_join("mods")
	var dirs := DirAccess.get_directories_at(mods_dir)
	dirs.sort()
	for dir_name in dirs:
		if dir_name.begins_with(".") or dir_name.begins_with("_"):
			continue  # "_disabled_mod" style folders are skipped
		if not FileAccess.file_exists(mods_dir.path_join(dir_name).path_join("mod_main.gd")):
			continue
		var script: Script = load("res://mods/%s/mod_main.gd" % dir_name)
		if script == null:
			push_error("[ModLoader] failed to load mod: " + dir_name)
			continue
		var mod: Node = script.new()
		mod.name = dir_name
		add_child(mod)
		print("[ModLoader] loaded mod: ", dir_name)
