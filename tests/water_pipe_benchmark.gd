extends SceneTree

## Microbenchmark for the proposed 2.5D pipe-model water update.
##
## Run headless:
##   godot --headless --path . --script res://tests/water_pipe_benchmark.gd
##
## It measures the update shape only: two-axis edge flux plus two apply passes
## over packed arrays. Terrain queries, mesh rebuilds, agents and rendering are
## deliberately excluded. Use it to compare simulation cell sizes, not as a
## frame-time guarantee for the finished system.

const CASES := [
	{"label": "1m 128x128", "width": 128, "height": 128, "steps": 120},
	{"label": "2m 64x64", "width": 64, "height": 64, "steps": 400},
	{"label": "4m 32x32", "width": 32, "height": 32, "steps": 1000},
	{"label": "1m 256x256", "width": 256, "height": 256, "steps": 40},
]


func _initialize() -> void:
	print("water pipe benchmark")
	for entry: Dictionary in CASES:
		var result := _bench(
			int(entry["width"]),
			int(entry["height"]),
			int(entry["steps"])
		)
		print(
			"%s: %d cells, %.3f ms/step, %.3f ms/frame avg at 10 Hz"
			% [
				entry["label"],
				result["cells"],
				result["ms_per_step"],
				result["ms_per_step"] / 6.0,
			]
		)
	quit()


func _bench(width: int, height: int, steps: int) -> Dictionary:
	var count := width * height
	var depth := PackedFloat32Array()
	depth.resize(count)
	var floor_y := PackedFloat32Array()
	floor_y.resize(count)
	for index in count:
		floor_y[index] = float((index * 37) % 5) * 0.03125
		depth[index] = 1.0

	var flux := PackedFloat32Array()
	flux.resize(count)
	var flux_z := PackedFloat32Array()
	flux_z.resize(count)

	var start := Time.get_ticks_usec()
	for _step in steps:
		for z in height:
			var row := z * width
			for x in width - 1:
				var index := row + x
				var diff := (
					floor_y[index] + depth[index]
					- floor_y[index + 1] - depth[index + 1]
				)
				flux[index] = clampf(diff * 0.25, -0.25, 0.25)
		for z in height:
			var row := z * width
			for x in width - 1:
				var index := row + x
				var flow := flux[index]
				depth[index] -= flow
				depth[index + 1] += flow

		for z in height - 1:
			var row := z * width
			for x in width:
				var index := row + x
				var diff := (
					floor_y[index] + depth[index]
					- floor_y[index + width] - depth[index + width]
				)
				flux_z[index] = clampf(diff * 0.25, -0.25, 0.25)
		for z in height - 1:
			var row := z * width
			for x in width:
				var index := row + x
				var flow := flux_z[index]
				depth[index] -= flow
				depth[index + width] += flow

	var elapsed := Time.get_ticks_usec() - start
	return {
		"cells": count,
		"ms_per_step": float(elapsed) / float(steps) / 1000.0,
	}
