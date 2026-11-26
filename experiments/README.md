# Experiments and exports

This folder holds manifest files for the batch runner and saved evacuation plans
are written to the user directory, not here.

## Run a batch

The checked-in manifest uses **self-contained fixture presets**, so it needs no
save:

1. Load any 3D map (for example `Maps/test.tscn`). The runner builds the fixture
   floor/exits/spawners in the current scene.
2. Validate without running:

   ```text
   experiment_dry_run res://experiments/assignment_comparison_v1.json
   ```

3. Run:

   ```text
   experiment_start res://experiments/assignment_comparison_v1.json
   ```

A fixture scenario is declared with `fixture_preset` (`s1`/`s2`/`s3`/`s4`) or a
custom `fixture` dictionary. To use a hand-made save instead, set `save_slug`
(and `load_save: true` to switch to it) plus the expected exits/rates.

The runner skips cells already listed in
`user://experiments/<experiment>/completed.json` when `resume` is true. Use
`only` to run a substring of cell ids and `repeat` for same-seed repeats.

## Output

Each cell writes:

```
user://experiments/<experiment>/cells/<cell_id>/
    runs.csv
    agents.csv
    exits.csv
    solves.csv
    convergence.csv
    data_dictionary.md
    export.json
    raw/<demo_id>/{recording.jsonl,manifest.json,summary.json}
    plans/<demo_id>.json
```

At the end the runner also writes a combined table set to
`user://experiments/<experiment>/` plus `summary.json` and `completed.json`.
`ExperimentExporter` shows the absolute user-directory path in the console and
in the Simulation panel's export status.

`experiments/analyze_export.py` reads that folder's `runs.csv` and writes
`analysis_summary.md` (descriptive per condition + predicted-vs-measured error;
Friedman/Wilcoxon when pandas/scipy are available).

## Saved plans

The Optimizer panel's **Saved plans** section captures the current assignment
and the routes the agents are walking. **Arm at Start** applies it to the next
run. Plans live at:

```
user://saves/<save_slug>/plans/<plan_id>.json
```

They are plain JSON and are suitable for figures, appendices, or loading into
another run of the same layout. A plan made on a different exit set/layout is
refused by default; the console `plan_apply` reports the mismatch.

## Tidy tables

See the generated `data_dictionary.md` in each export. The tables join on
`run_id`; `demo_id` identifies the source recording. The raw files are copied
beside the tables so an export is self-contained.
