# Seamless Transitions for Explosiovania

Walk between regions without a loading screen.

In the base game, touching a region gate fades to white and loads the next region for about 3 seconds. With this mod, the next region is built in the background while you walk towards the gate. You walk straight through, keeping your speed, height and camera angle.

- Works for region gates and for the floor holes / ceiling openings between regions.
- Region gates take the colour of the region behind them (can be turned off).
- No changes to the game files: two loose files next to the game, delete them to uninstall.
- Your save is used as normal: the mod writes only what the base game writes on a transition.

## Install

1. Download `SeamlessTransitions-vX.Y.Z.zip` from the [Releases](../../releases) page.
2. Open the game folder: in Steam, right-click Explosiovania > Manage > Browse local files.
3. Copy `override.cfg` and the `mods` folder from the zip into that folder, next to `Explosiovania.exe`.
4. Start the game. The log (`%APPDATA%\Godot\app_userdata\Explosiovania\logs`) shows `[SeamlessTransitions] v… installed` if it loaded.

When updating, copy the `mods` folder again and overwrite the old files.

### Uninstall

Delete `override.cfg` and the `mods` folder from the game folder. Steam's "Verify integrity of game files" does not remove them.

## Settings

`mods/seamless_transitions/settings.cfg`, any text editor; restart the game to apply. Every setting is explained in the file. The useful ones:

| Setting | Default | |
|---|---|---|
| `mode` | `stream` | `stream` = built in the background, no stutter. `swap` = simpler: loaded early, swapped in at the gate behind a short flash. |
| `stream_budget_ms` | `3.0` | Time per frame spent building the next region. Lower = smoother, higher = ready sooner. |
| `gate_style` | `tinted` | `vanilla` keeps the original white gates. |
| `keep_momentum` | `true` | Keep speed, height and camera angle through the gate. |
| `exit_depth` | `3.0` | How deep inside the exit doorway you appear (vanilla: 9.4 m, then it walks you out). |

## Renderer (Vulkan)

`override.cfg` switches the game from Direct3D 12 to Vulkan. With two regions loaded at the same time, the Direct3D 12 renderer of Godot 4.5 runs out of descriptor heaps and fails; Vulkan doesn't, and uses about half the video memory. If Vulkan isn't available, the game falls back to Direct3D 12 and the mod uses `swap` mode.

The first start after installing compiles shaders for Vulkan, so the first minutes can stutter a bit.

If you want to keep Direct3D 12, delete the two `rendering_device/...` lines in `override.cfg`. The mod then uses `swap` mode.

## Known issues

- Quitting the game while a region is still being built can crash on exit.
- Some frames can take longer while a region is being built; these spikes come from the engine (uploading the region to the GPU), not from the mod's own work.
- A slide or ground pound is not carried through a gate; you arrive running.
- The transition into the Saint Passways boss fight uses the normal loading screen on purpose.
- Walking back into a gate right after arriving: the region you came from has to be built again first, so you get a short white fade, like in the base game.

## Mod loader (for other mods)

The mod ships with a small general mod loader (`mods/mod_loader.gd`), started by `override.cfg`. Other Explosiovania mods can use it too:

- Put your mod in `mods/<your_mod>/mod_main.gd`, a script that `extends Node`. Each one is added as a child node of the loader at startup, in alphabetical folder order, before the first scene loads.
- Folders starting with `_` or `.` are skipped: rename a folder to `_my_mod` to disable it.
- Loose `.gd` files work: `res://mods/...` falls back to the files next to the game, so nothing has to be packed.
- To change a game script without touching `Explosiovania.pck`, write an extension (`extends "res://path/original.gd"`), load it in your mod's `_init` and call `take_over_path("res://path/original.gd")` on it before scenes using it load. Seamless Transitions does this for stage gates, levers and a few others; see `mods/seamless_transitions/mod_main.gd`. Scripts that other scripts extend by `class_name` can't be replaced this way.
- Two mods that replace the same game script will conflict.

If another mod ships its own `override.cfg`, the two files need to be merged by hand: keep one `[autoload]` section with both entries.

## How it works (short)

- When you get close to a gate, the next region's scene is loaded on a background thread and rebuilt node by node, a few milliseconds per frame.
- It is added to the game "dormant": hidden, paused, its collisions on separate physics layers and its sounds muted. It can't touch you or the region you're in, but its own scripts still set themselves up from your save like in a normal load.
- When you cross the gate, the player, environment and current scene are swapped in one frame. The region around you is switched on first, the rest over the next frames, and the region you left is freed in the background.

Built for Explosiovania on Godot 4.5. Game updates may break it; check the Releases page for a new version.

## Changelog

- **0.3.3**: Red key doors and soul doors you had already opened could appear shut or wrongly opened after streaming. The Perdition Passways intro overlay no longer comes back.
- **0.3.2**: Linked puzzles (torches, levers, logic gates) load together like in the base game; castle torch-puzzle door fixed. No more stray switch sounds near gates. Walking back into a gate before the region is ready freezes you behind a white fade instead of letting you walk into the void. Sloped doorways can't be walked under.
- **0.3.1**: Collisions of a dormant region work on their own layers (lasers, arenas and toggle platforms set up correctly). Exit gate fixes.
- **0.3.0**: Floor holes / ceiling openings streamed too. Race fixes. Faster preparation.
- **0.2.1**: Fixes from the first play-test (moving-platform crash, puzzle logic, arena enemies, placeholder text, pause map).
- **0.2.0**: Stream mode.
- **0.1.0**: First version (swap mode).

## License

MIT, see `LICENSE`. Explosiovania belongs to its developers; this mod contains none of the game's files.
