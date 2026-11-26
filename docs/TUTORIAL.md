# Tutorial — draft and implementation requirements

> **Status:** 2026-11-25 — **draft**. No tutorial controller is implemented yet.
> This page specifies the tutorial we need, the exact flow, the data it must
> persist, and the pieces that must exist in code. It is deliberately written
> before the UI so the tutorial does not become a hard-coded sequence of labels.

---

## 1. Why a tutorial is needed now

The project now has four separate mental models a new user must discover:

1. **Build mode / inventory** — blocks, placeables, Useables, hotbar, property
   exports.
2. **Simulation** — spawners vs. Random Populate, Start/Reset, quotas, seeds,
   recording.
3. **Optimizer** — cohorts, methods, objective, first solve, re-solve,
   hysteresis, plans.
4. **Analysis** — saved plans, route paint, Demo Player, Demo Comparer, exports,
   experiments.

The optimizer panel is only useful if the user knows that a *plan* is a saved
decision, not the live run; the Route Paint tool is only useful if the user knows
it changes navigation cost without placing blocks; exports are only useful if the
user can find `user://exports`. A tutorial must teach those distinctions.

---

## 2. Proposed first-run flow (12 steps, 8–12 minutes)

Each step has a **goal**, a **highlight target**, a **gate** (what must be true to
continue), and **copy** (short, actionable). The tutorial pauses simulation and
inventory where needed.

| # | Goal | Highlight | Gate | Copy |
|---|---|---|---|---|
| 1 | Look around | player view | mouse moved | "Look around. The floor is a voxel grid." |
| 2 | Open inventory | `R` / inventory | inventory visible | "Press R. Everything you can place is here." |
| 3 | Place a floor | Build tab, floor tool | ≥ 10 new cells | "Left click places; right click removes. Build a short corridor." |
| 4 | Place exits | Placeables → Evac Point | ≥ 2 EvacPoints | "Place two exits at the ends of the corridor." |
| 5 | Place a spawner | Placeables → Spawner | ≥ 1 spawner | "A spawner creates agents. Set its quota in the Property tab." |
| 6 | Start a run | Simulation → Start | run started | "Start the crowd. Watch the statistics (F3)." |
| 7 | Read the result | F4 / results | results visible | "F4 reports total, average and P95 evacuation time. The seed and parameters are saved with the run." |
| 8 | Enable the optimizer | Optimizer button | optimizer panel open | "Enable the optimizer. A method decides which cohort walks to which exit." |
| 9 | Run a solve | Run once | solve applied | "This is the plan: cohort colours and cohort → exit lines. Run once does not re-solve every frame." |
| 10 | Save the plan | Saved plans → Save plan | plan file exists | "Name it and save. A green status line and the file path confirm it." |
| 11 | Reuse the plan | Arm at Start | plan armed | "Arm it, Reset, then Start. The saved assignment is applied at the next run." |
| 12 | Paint a corridor | Useables → Route Paint | ≥ 1 painted cell | "Hold the Route Paint tool. Left click a start block, left click the destination; right click erases. Painted cells cost less to path through." |
| 13 | Show and export | Show / Export Last Run | export exists | "Show draws the saved plan. Export writes runs.csv and friends to the exports folder; Open Exports opens it." |

The last steps can be split into an "advanced" tutorial:

- batch experiment (`experiment_dry_run`, `experiment_start`);
- Demo Player timeline and plan overlay;
- Demo Comparer metrics/verdict;
- authored route persistence and layout signature warning.

---

## 3. What the tutorial system needs

### 3.1 Controller

A lightweight `TutorialController` autoload or HUD-owned node:

```gdscript
class_name TutorialController
extends Node

signal step_changed(index: int, step: Dictionary)
signal tutorial_finished(completed: bool)

var steps: Array[Dictionary] = []
var index: int = -1
var active: bool = false
var completed: bool = false
var skipped: bool = false

func start(tutorial_id: String) -> void
func next() -> void
func previous() -> void
func skip() -> void
func complete() -> void
func save_progress() -> void
func load_progress() -> void
```

Each step dictionary:

```gdscript
{
  "id": "place_exit",
  "title": "Place an exit",
  "body": "...",
  "target": "Inventory/ItemCategoryScroll/ItemCategoryHbox/Placeables",
  "target_kind": "control",           # control | world | console | menu
  "highlight": Rect2 or Vector3,
  "gate": Callable,                  # polled at low Hz
  "on_enter": Callable,
  "on_exit": Callable,
  "pause": true,                     # freeze simulation while reading
  "allow_skip": true,
  "requires": ["inventory", "build_mode"],
}
```

### 3.2 Existing hooks the tutorial can use

- `HUDManager.blocks_button`, `placeables_button`, `useables_button`,
  `simulation_button`, `agents_button` — category anchors.
- `GlobalData.spawning_started`, `spawning_stopped`, `spawning_reset`,
  `npc_spawned`, `npc_evacuated` — run gates.
- `OptimizerBridge.state_changed`, `result_ready`, `solve_count` — solve gates.
- `PlanStore.list_plans()` / `plan_path()` — save gate.
- `RoutePainter.get_committed_cells()` — paint gate.
- `SimRecorder.get_demo_id()` / `SimRecorder.get_last_summary()` — result gate.
- `ExperimentExporter.output_root()` — export location.
- `DemoPlayer.is_active()`, `DemoComparer` signals — playback gates.

### 3.3 Missing hooks to add

| Need | Owner | Notes |
|---|---|---|
| A stable highlighted-rect query for any Control | `HUDManager` | `get_control_rect(path) -> Rect2`, works with scrolling inventory. |
| A world-space marker for "place here" | tutorial overlay | A ring/arrow at a target block; hidden when the gate is met. |
| "Tutorial is open" input suppression | `BuildController`, `player` | Do not place/break while a tutorial step with `pause` is open. |
| Completion persistence | `GlobalData` or a new `TutorialStore` | `user://tutorial_progress.json`, keyed by tutorial id. |
| First-run detection | main menu / HUD | "Start tutorial" vs "Skip"; never auto-open on an existing save without asking. |
| Reset tutorial | Saves/Settings | A "Replay tutorial" button. |

### 3.4 UI pattern

- A small **top-left tutorial card** (not a modal): title, body, `Back`, `Next`,
  `Skip`, step counter.
- The rest of the UI stays usable; the card's anchor can be highlighted with a
  pulsing outline.
- For "do this" steps, the card sits bottom-left and a world marker points at
  the target.
- No voice-over; text is localisable later.
- `Esc` opens the pause menu, not "cancel tutorial"; `Skip` is explicit.

### 3.5 Safety

- The tutorial must never run during a batch experiment.
- The tutorial must not start with agents already spawned unless the step is a
  "continue from current state" step.
- The route paint step needs a small, safe map or a pre-built fixture; do not
  ask the user to paint on a map with no walkable floor.
- The tutorial must not overwrite the user's active save. Use a temporary
  tutorial save or build in the current map and offer "Undo tutorial changes"
  (clear placed placeables/blocks) when finished.

---

## 4. Tutorial fixtures

The tutorial needs a deterministic, small map. Recommended:

- 24 × 12 floor, one corridor, two exits, one spawner, 30 agents.
- No water/hazard distractions.
- `ExperimentFixture` already knows how to build a floor and exits; add a
  `tutorial` preset with one spawner and a fixed population.
- Alternatively use `Maps/test.tscn` and let the tutorial build the corridor;
  this teaches building but is slower and harder to recover from a mistake.

Recommended: **build-on-empty-floor** for steps 3–5, with a "fix my steps"
reset that clears only tutorial-placed cells. It teaches the actual tools.

---

## 5. Copy draft

Use short, imperative sentences. Avoid the word "simply".

1. "Look around. This is the voxel floor the crowd will use."
2. "Press R to open the inventory. Build, Placeables, Useables, Simulation."
3. "Left click to place a floor block, right click to remove. Build a short corridor."
4. "Open Placeables and place two Evac Points at the ends."
5. "Place a Spawner and set its quota in the Property tab."
6. "Open Simulation and press Start."
7. "Press F4. Total time is the primary result; P95 and max show the tail."
8. "Open Optimizer. Enable it and choose a method."
9. "Press Run once. Colours are exits; lines are cohort assignments."
10. "Name the plan and press Save plan. The green line shows the saved file path."
11. "Arm at Start, Reset, then Start to reuse the plan."
12. "Hold Route Paint from Useables. Left click start, left click destination; right click erases."
13. "Press Show to see the plan. Export Last Run writes the analysis tables; Open Exports opens the folder."

---

## 6. Implementation order

1. `TutorialStore` progress persistence + `TutorialController` skeleton.
2. Tutorial card UI + highlight rectangle helper.
3. Steps 1–7 (build/simulate/results).
4. Steps 8–11 (optimizer plan/save/reuse) after the plan UI feedback is stable.
5. Step 12 (Route Paint) after the tool is usable.
6. Step 13 (show/export).
7. Tutorial fixture and reset/undo.
8. Playtest with a user who has never opened the project; record every stall.

## 7. Acceptance checklist

- A new user can complete the tutorial without opening the console.
- Every step's gate is observable, not just "click Next".
- Skip leaves the project in a clean state.
- Replaying the tutorial does not duplicate placed objects or overwrite a save.
- The tutorial explains the difference between:
  - **assignment** (exit choice),
  - **plan** (saved assignment + routes),
  - **painted route** (navigation cost preference),
  - **recorded demo** (measured outcome).
- A screenshot of each step is captured for the appendix.

---

## 8. Current gaps (honest)

- No tutorial controller, card, highlight ring or progress file yet.
- `HUDManager.get_control_rect()` does not exist.
- The Route Paint tool exists at the code level; its tutorial copy must be
  validated in the editor after the Useables card is visible.
- The tutorial fixture preset still needs to be added to `ExperimentFixture`.
