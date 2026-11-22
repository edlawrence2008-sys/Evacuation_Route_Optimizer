# Main menu, saves, music and credits

> **Status:** 2026-11-21 · **Applies to:** `scenes/menu/main_menu.*`,
> `scenes/menu/menu_backdrop.gd`, `scenes/menu/credits.*`,
> `scenes/ui/bgm_popup.*`, `scripts/music_manager.gd`,
> `resources/credits/credits.json` · **Companions:**
> [`CODEBASE_ANALYSIS.md`](CODEBASE_ANALYSIS.md) §3.2, §4.7, §4.13,
> [`PROCGEN.md`](PROCGEN.md).

## Boot flow

`project.godot` boots into `scenes/menu/main_menu.tscn`, a standalone 3D main
menu. The old 2D logo scene at that path was replaced.

| Action | Destination |
|---|---|
| **Saves** | Opens the pause menu's own Saves page as an overlay. |
| **Load Selected** | Loads the selected save's map (normally `res://Maps/test.tscn`). |
| **New Map...** | Opens the name dialog, then creates the selected world: Blank Platform or Heightmap Terrain. **World Type** opens the shared World Settings dialog (type, size, seed). |
| **Extras → Credits** | `res://scenes/menu/credits.tscn` |
| **Credits → Back / Esc** | `res://scenes/menu/main_menu.tscn` |
| **Quit** | `SceneTree.quit()` |

The main menu and the pause menu share the same visual language: an angled 3D
panel, Pixelta/dogicapixel labels, `pause_button_3d` rows, gold hover bars,
staggered intros, UI blips and a drifting voxel backdrop. Both menus also tilt
slightly toward the cursor. The title letters stay pinned to the panel (so they
travel with the buttons) and add a small cursor-driven tilt on top.

## Main menu

Scene: `scenes/menu/main_menu.tscn`  
Script: `scenes/menu/main_menu.gd`  
Backdrop: `scenes/menu/menu_backdrop.gd`

- **Main panel:** Saves, Extras, Settings, Quit.
- **Saves:** the main menu instances `scenes/menu/pause_menu.tscn` under its
  camera with `saves_only = true`. That overlay uses the pause menu's existing
  save list, thumbnail, details and dialogs. The Saves page uses compact scaled
  buttons, six save rows, a top header row (New Map / World Type / Sort /
  Rename), and two bottom action columns; long names are shortened in the list.
  **Save** and **Save As** are hidden because no live world is loaded. **World Type** stays available so New Map can
  choose Blank Platform or Heightmap Terrain; it opens a **World Settings**
  dialog with type, size and seed. Load, New Map, Rename, **Sort**, Duplicate,
  Delete and Back remain. Both menus therefore share one implementation of the
  save and world-creation UI. **Sort** cycles **Last Played** (default),
  **Date Created**, **Alphabetically** and **Date Modified**; the choice is
  persisted, and loading a save stamps its `last_played` timestamp.

### New Map and world settings

- **World Type** shows `World: Blank Platform` or `World: Heightmap 128/256/384`.
  Clicking it opens a dialog with:
  - type: Blank Platform / Heightmap Terrain,
  - size: Small (128), Medium (256), Large (384),
  - seed: numeric, `0` means random.
- **Blank** keeps the existing small starter platform.
- **Heightmap** creates a bounded procedural terrain through
  `HeightmapTerrainGenerator`, pins `generator`, `generator_version`, `seed`,
  `size` and `options` in `save.json`, and regenerates missing chunks when the
  save is loaded. The player is placed above the generated surface at the world
  origin.
- The save details panel adds `Heightmap terrain · seed <n> · <size>` for
  procgen slots.
- **Extras panel:** Credits, Back. (A short-lived **Generators** tab was removed
  on 2026-11-21; world generators remain selectable through **New Map → World
  Settings**, which lists every entry in `WorldGeneratorRegistry`.)
- **Settings:** Graphics, Gameplay, Audio, Back. These reuse
  `scenes/menu/settings/*.tscn` and `PerformanceSettings`, so changes persist in
  `user://settings.cfg` and apply to the game. Gameplay includes **Simulation
  Defaults** (`user://export_defaults.json`), where **Use Current Session**
  captures global, agent, Random Populate and optimizer exports for new saves.
  **Audio** holds **Music** (BGM level, applied live by `MusicManager`) and
  **Volume** (master).
- **Not included:** the Controls keybind editor and Water tuning pages. Those
  remain available in the in-game pause menu.

### Adding another Extras entry

1. Duplicate an existing button under `Panel/ExtrasPanel` in
   `main_menu.tscn`.
2. Give it a unique `action`, a `caption`, and a position inside the panel.
3. Add a branch for that action in `main_menu.gd` → `_click_at()`.
4. Either open a new `Node3D` view with `_show_view("...")`, or change scene
   with `get_tree().change_scene_to_file("res://...tscn")`.

The Credits button is a scene-change example; the Back button is a view-change
example.

## Music manager

Autoload: `scripts/music_manager.gd`

All menu/credits music goes through `MusicManager`, which owns one
`AudioStreamPlayer`. Scenes call:

- `MusicManager.play_menu_playlist()` — starts or continues the menu themes.
- `MusicManager.play_track(source)` — plays one file.
- `MusicManager.stop()`.

The manager reads the `music` array in `resources/credits/credits.json`, so it
knows which file is playing and its title, artist, source and licence. It emits
`track_changed(track)` when playback changes and `playback_stopped()` when it
ends. Re-requesting the file that is already playing is a no-op, so it does not
restart the song or re-announce it. If a file is not in the JSON, it derives a
title from the filename and uses "Unknown" for the artist.

The menu playlist covers the menus and credits. Loading a save (or starting a
new map) from the main menu stops it, so no menu theme plays over the game.
`PerformanceSettings.music_volume` (the **Music** row on the Audio page) is
stored in `user://settings.cfg` and applied to the player as a gain on top of
the manager's base level; `settings_changed` updates it live.

## BGM information pop-up

Scene: `scenes/ui/bgm_popup.tscn`  
Script: `scenes/ui/bgm_popup.gd`

A top-left `PixelPanel` (the same frame used by the palettes and unified block
shape pop-ups) with:

- the particle `sound_visual.png` icon,
- a horizontally scrolling track title,
- the artist underneath as "by ...".

It is 268 × 66 px, anchored exactly at `(0, 0)` so its frame touches the
screen's top-left corner, and its fill is slightly translucent (alpha 0.78) so
it stays unobtrusive. Both text lines use 16 px dogicapixel, the minimum size
the pop-up uses. The 38 × 38 icon sits centred with breathing room above and
below, the title and artist each get a clipped 203 px column, and the artist
line ellipsises instead of spilling over the frame.

It listens to `MusicManager`; each new track slides/fades in from the left,
stays for about eight seconds, then slides/fades back out to the left. The
title marquee is time-driven (`_process`), so it restarts and scrolls for every
new track; titles that already fit do not scroll. A repeated `track_changed`
for the same source is ignored, so a song is only announced once. It is
instanced in:

- `scenes/menu/main_menu.tscn` (CanvasLayer),
- `scenes/menu/credits.tscn` (CanvasLayer),
- `scenes/hud.tscn` (in-game, top-left above the hotbar).

## Credits

Scene: `scenes/menu/credits.tscn` (3D)  
Script: `scenes/menu/credits.gd`  
Data: `resources/credits/credits.json`

The credits screen is fully 3D: the shared voxel backdrop, angled 3D panel,
`Label3D` credits/music lists, 3D Back button and 3D search prompt. Music is
supplied by `MusicManager`, and the BGM pop-up is instanced over the scene.

Controls:

- **Type** to filter music credits by title, artist, source path or licence.
- **Backspace** edits the query.
- **Mouse wheel** scrolls long credit lists.
- **Back / Esc** returns to the main menu.
- The current menu theme is marked with `>` in the music list.

### Adding people or sections

Edit `resources/credits/credits.json`:

```json
{
  "sections": [
    {
      "title": "LEAD DEVELOPER & RESEARCHER",
      "entries": [
        {
          "name": "Ed Lawrence Zenarosa",
          "roles": ["Lead Developer", "Researcher"]
        }
      ]
    },
    {
      "title": "3D ART",
      "entries": [
        {
          "name": "Another Person",
          "roles": ["Environment Artist"]
        }
      ]
    }
  ]
}
```

- Sections render in file order and long lists scroll with the mouse wheel.
- Empty sections are skipped, so an empty placeholder section is safe.
- `roles` can be a list or a single string. Two roles render as
  "Role A and Role B"; three or more render as "A, B and C".
- Long names/roles are shortened on the 3D panel; the full music title remains
  in the BGM pop-up.

### Adding music credits

Append to the `music` array:

```json
{
  "title": "Track Name",
  "artist": "Artist or Composer",
  "source": "res://sounds/songs/menu_themes/track.mp3",
  "license": "Menu theme"
}
```

`MusicManager` picks up menu-theme entries automatically. New search entries
appear without touching the script. The current track is marked with `>`.

### Fallback

If `credits.json` is missing or malformed, `credits.gd` falls back to the lead
credit, and `MusicManager` falls back to the three known menu themes, so neither
screen opens blank.
