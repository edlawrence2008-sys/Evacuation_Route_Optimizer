# Content generators

> **Status:** 2026-11-22. These are **editor-side asset tools**, not runtime
> systems. They rewrite files under `res://`, so they do not run during gameplay
> and were never part of the main-menu **Extras** tab.

## What exists

| Tool | Script | Input | Output |
|---|---|---|---|
| Blocks (autoblocks) | `scripts/block_generator.gd` | `textures/autoblocks/*.png` | `models/Blocks/blocks.tscn` and `resources/blocks/.tres` items: full block, top/bottom/side slabs, stairs, selected panels |
| Connected blocks | `scripts/connected_block_generator.gd` | `textures/auto_connecting_blocks/*.png` | `Auto_Connect_*` items in `blocks.tscn` and the block MeshLibrary |
| Foliage scenes | `scripts/foliage_generator.gd` | foliage textures | one placeable scene per texture under `scenes/placeables/foilage/` |
| Voxel item icons | `scripts/voxel_item_generator.gd` (core) + `scripts/voxel_item_generator_editor.gd` (tool) | every placeable in `scenes/placeables/{sim,device,foilage}/` | isometric `.tres` icons, optional `_item` meshes, `resources/voxel_items.json` |

**Every content generator is an editor tool.** `BlockGenerator`,
`ConnectedBlockGenerator`, `FoliageSceneGenerator` and the voxel-item editor
wrapper are all `@tool` `EditorScript`s, so each one works with **File → Run**
as well as from the plugin menu. They also expose a **static entry point**
(`generate_all()`, `generate_runtime()`) that the plugin calls directly, so the
menu never instantiates an `EditorScript` (Godot restricts that to editor
contexts). The scripts use `ResourceSaver` and `DirAccess`, which is why they
belong in the editor rather than in a game build.

**Why there are two voxel-item files.** `voxel_item_generator.gd` is the shared
implementation and the runtime lookup API (`icon_for_scene`,
`entry_for_scene`); gameplay code in `scenes/hand_item.gd` and `scenes/hud.gd`
preloads it, so it must stay a plain `RefCounted` and must not become an
`EditorScript`. `voxel_item_generator_editor.gd` is the thin `EditorScript`
adapter that supplies the in-tree host node the `SubViewport` renderer needs.
It contains no generation logic. Run the `_editor` file, never the core file.
World generators under `scripts/world/` are deliberately excluded: they are
runtime generators selected by **New Map → World Settings**, not asset tools.

Connected-texture inputs follow the same layout as the reference Python
generator: a 16x16 source holds q1-q4 (corner, edge, overflow, surrounded), and
a 32x16 source adds q5 in the right 16x16 block. q5 is a full background layer
composited **behind** q1-q4; it is not a fifth connection state.

## Why they are not in Extras

The short-lived **Extras → Generators** page only listed world generators from
`WorldGeneratorRegistry` (Flat Platform, Heightmap Terrain). It never called the
content tools above. Removing that page on 2026-11-21 did not touch these scripts;
they remain in the project and parse cleanly.

World generation is a separate feature:

- **New Map → World Settings** chooses Flat Platform or Heightmap Terrain;
- `WorldGeneratorRegistry` is the list used by that dropdown;
- saved worlds pin `generator`, `generator_version`, `seed`, `size` and
  `options` in `save.json`.

## How to run the content generators

The project now enables the **Content Generators** editor plugin
(`addons/content_generators/plugin.cfg`). Use:

- **Project → Tools → Content: Generate Blocks (autoblocks)**
- **Project → Tools → Content: Generate Connected Blocks**
- **Project → Tools → Content: Generate Foliage Scenes**
- **Project → Tools → Content: Generate Voxel Item Icons**

Alternatively, open the tool script in the Godot script editor and use
**File → Run** (the standard `EditorScript` workflow). Use these files:

- `scripts/block_generator.gd`
- `scripts/connected_block_generator.gd`
- `scripts/foliage_generator.gd`
- `scripts/voxel_item_generator_editor.gd`

Do **not** File → Run `scripts/voxel_item_generator.gd`; it is the shared
`RefCounted` core used at runtime and has no `_run()`.

The plugin prints `Content Generators: ready (Project > Tools).` in the Output
panel when it loads, so a missing line means the plugin did not start.

Verified 2026-11-22 from the plugin's static entry points: blocks processed 53
texture groups / 652 variant slots and synced 749 MeshLibrary items; connected
blocks added 36 `Auto_Connect_*` items (full block plus top/bottom/side slabs
and normal/upside-down stairs for each of six sources); foliage updated 9
scenes. All CTM shapes share one atlas per source at render time, so slabs and
stairs get dynamic per-face borders. Running the tools adds only the new
block/icon assets, so review `git status` afterwards.

If the menu is missing:

1. Check `project.godot` → `[editor_plugins]` contains
   `res://addons/content_generators/plugin.cfg`; if not, enable **Content
   Generators** under **Project → Project Settings → Plugins**.
2. Check **Project → Project Settings → Autoload** for a stale `McpBridge`
   entry pointing at a missing `.mcp` script. A broken autoload can stop editor
   plugins from loading; delete that entry.
3. **Project → Reload Current Project**, then open **Project → Tools** again.
4. Check the **Output** panel for the generator's error if it starts and fails.

## Safety notes

- Run them on a clean git working tree: they rewrite `blocks.tscn`, the block
  MeshLibrary, foliage scenes and voxel icon resources.
- Let the editor finish reimporting before launching the game.
- The voxel-icon scan includes every placeable scene under `sim/`, `device/`
  and `foilage/`, so new placeables get an icon automatically.
- Do not call these tools from an exported build; `res://` is read-only there.
