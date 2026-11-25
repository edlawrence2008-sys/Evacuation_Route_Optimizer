# Legacy water (archived)

This addon is the previous water implementation, preserved for parts. It is
**not wired into the game**. The core project no longer creates a water system,
places water items, or exposes water settings.

## What moved here

| File | Original |
|---|---|
| `legacy_water_system.gd` | `scripts/world/water_system.gd` |
| `shaders/legacy_water.gdshader` | `scripts/world/water.gdshader` |
| `shaders/legacy_water_edge.gdshader` | `scripts/world/water_edge.gdshader` |
| `scenes/legacy_water_menu.tscn` | `scenes/menu/settings/water_menu.tscn` |
| `textures/sea_foam*.png`, `textures/splash_small.png` | `textures/particles/` |
| `textures/water_flow.png`, `textures/water_still.png` | `textures/specialblocks/` |
| `legacy_water_settings.gd` | Water half of `scripts/performance_settings.gd` |
| `legacy_water_bootstrap.gd`, `legacy_water.tscn` | New optional scene hook |

The class is now `LegacyWaterSystem`. The four reserved MeshLibrary items were
renamed to `Legacy_Water_Surface`, `Legacy_Water_Full`, `Legacy_Water_Slab` and
`Legacy_Water_Panel`; their IDs (275–278) are unchanged so old chunk/save data
still resolves. Core inventory hides every `Legacy_Water_*` item.

## What was removed from the core

- `NavGridMap` no longer creates a sibling `WaterSystem`.
- `BuildController` no longer places water or picks it with the eyedropper.
- The pause-menu Water tab, the Graphics `Water FX` toggle and the Settings
  `Water Tuning` entry are gone.
- `PerformanceSettings` no longer stores water tuning.
- `WorldRecipe` no longer carries an unused `water_level` field.
- Water textures and shaders no longer live under the core `textures/` or
  `scripts/world/` trees.

Old demo recordings can still contain `water_placed` events; `demo_player.gd`
keeps the text label for those files.

## Running it again

1. Add `addons/legacy_water/legacy_water.tscn` as a sibling of the scene's
   `GridMap`, or add a `LegacyWaterBootstrap` node and set `grid_path`.
2. Optionally add `legacy_water_settings.gd` as an autoload and assign it to
   the bootstrap's `settings` property. Without it the system uses its own
   exported defaults.
3. To place water again, re-add the removed `BuildController` hooks. The public
   API is `LegacyWaterSystem.place(cells: Array[Vector3i], kind: String)` and
   `get_pick_item(cell)`. The kind strings are the four `Legacy_Water_*` names.
4. The archived `legacy_water_menu.tscn` still uses the old `water_*` action
   names. It needs its own button dispatch if you re-enable that page.

## Known limitations (why it was replaced)

- One `Dictionary` entry per wet voxel plus an active queue, a local spread
  pass, an incremental whole-body hydrostatic BFS and a separate 2D wave field.
  Cost scales with wet cells, not with the visible/active area.
- No water state persistence: water depth is runtime-only, so saving and
  loading loses it.
- No NPC coupling: agents cannot sample depth, flow or buoyancy.
- Height-field depth cannot represent overhangs, waterfalls or separated
  vertical bodies cleanly; the workarounds (falling columns, stranded-layer
  wakeups, same-Y leveling) add most of the complexity.
- Multiple ordered transfers plus a global leveling pass makes settling slow
  and order-sensitive; integer-depth shortcuts (“one unit films”, 0.9 surface)
  leak into the simulation.

## Removed material entry

`resources/block_materials.json` used to contain this entry for the old water
items. It was removed from the core registry with the rest of the water system:

```json
{
  "id": "water",
  "label": "Water",
  "prefixes": ["water"],
  "properties": {
    "base_stability": 0.05,
    "base_durability": 0.05,
    "base_weight": 1.0,
    "buoyancy": 1.0,
    "base_path_cost": 2.0,
    "flammability": 0.0
  }
}
```

The replacement investigation is in
[`docs/WATER_SYSTEM_INVESTIGATION.md`](../../docs/WATER_SYSTEM_INVESTIGATION.md).
