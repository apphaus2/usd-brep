<!-- SPDX-License-Identifier: Apache-2.0 -->

# SM_API_USD Examples

Native C++ examples using the `SmApiUsd*` USD entry points and the `SmApi*` wrappers they build
on. Fork addition (Android port); see `ANDROID_PORT_NOTES.md`.

## `brepinfo`: report, tessellate and time the BReps in a USD file

[`brepinfo.cpp`](brepinfo.cpp) is one source that builds for the host platform and for
`android-aarch64`. It proves the pipeline a viewer uses, from opening a stage to getting
triangles.

```
brepinfo <file.usd[c|a]> [--tol <chordHeight>] [--angle <deg>] [--edges] [--json]
```

| Option | Meaning |
|---|---|
| `--tol <h>` | Chord height tolerance, in world units. The default is `SmTessellationDefaults::kChordHeightTol` (0, which turns it off). |
| `--angle <d>` | Curve and surface angle tolerance, in degrees. The default is `kCurveAngleTolDeg` / `kSurfaceAngleTolDeg` (25). |
| `--edges` | Also samples each BRep's trimmed edges into boundary polylines with `SmApiTessellateBoundaries`, at `--angle`. |
| `--json` | Prints one JSON object on stdout instead of text. Diagnostics still go to stderr. |

Steps:

1. **Schema.** `SmApiUsdEnsurePluginRegistered()` registers the omniSolid schema before any stage
   is opened. It uses the folder in `OMNISOLID_PLUGIN_PATH`. If `PXR_PLUGINPATH_NAME` already
   lists an `omniSolid/resources` folder, OpenUSD has registered it and the variable isn't needed.
2. **Open.** `UsdStage::Open`, timed as `open`. Every `BrepArray`-typed prim is found the same
   way `SmApiUsdImportBreps` finds them.
3. **Import.** `SmApiUsdImportBreps` in partial mode, with the healer on (the library default),
   timed as `import`. It converts every packed BRep to an `SmBrep`. This is where the
   face/edge/vertex counts per BRep come from (`SmApiGetFaces`, `SmApiGetEdges`,
   `SmBrep::GetVertices`; `SM_API` has no vertex query). The call reads the file again, but the
   layer is already loaded, so the time is mostly composition, conversion and healing.
4. **Tessellate.** `SmApiUsdTessellateBrepArray` on each prim, timed as `tessellate`. This is
   what a viewer calls. It imports and heals again in a private context, so its time includes
   that. It reports triangles (`faceVertexCounts`, fanned) and mesh points per BRep.
5. **Edges** (`--edges` only). `SmApiTessellateBoundaries` on the imported BReps, timed as
   `edges`. It reports polyline and point counts.

Timings are wall-clock milliseconds (`steady_clock`) from a single run. They're a diagnostic, not
a benchmark.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Every BRep imported and tessellated fully. |
| 1 | At least one BRep failed to import or tessellate, or kept failed faces. The report is still printed. |
| 2 | Usage error. |
| 3 | Setup failure: the schema plugin, the stage, or a file with no `BrepArray` prims. |

A malformed file can also crash inside the library: `TestFiles/brep_validator/DefectiveCube.usda`
segfaults in `SmApiUsdImportBreps` (see `ANDROID_PORT_NOTES.md`, Known issues).

### Host (Linux)

```bash
./repo.sh build -r --target brepinfo
OMNISOLID_PLUGIN_PATH="$PWD/_build/schema/omniSolid/resources" \
    ./_build/linux-x86_64/release/brepinfo TestFiles/usd_TestFiles/sphere_nurbs.usda --edges
```

The build sets run paths, so no `LD_LIBRARY_PATH` is needed. They point into
`_build/target-deps`, which Android and host prebuilds share: after `tools/android/build.sh`,
run `./prebuild.sh` again before running host binaries.

### Android (Quest 3)

```bash
tools/android/build.sh release
tools/android/run-on-device.sh TestFiles/usd_TestFiles/sphere_nurbs.usda --edges
```

`run-on-device.sh` mirrors the build into `/data/local/tmp/brepinfo/`:
- `lib/` holds the libraries, stripped of debug info, with OpenUSD's plugin tree in `lib/usd/`.
- `resources/omniSolid/resources` holds the omniSolid schema, which the script passes through
  `PXR_PLUGINPATH_NAME`.
- `files/` holds the input file.

Then it runs `brepinfo` with `LD_LIBRARY_PATH`, prints the output and the exit code, and exits
with that code. It pulls nothing back. Only files that changed are pushed again. Set `CONFIG=debug`
for a debug build and `DEVICE_DIR` to use another folder. It works with a Linux `adb`, or the
Windows `adb.exe` from WSL.

### Inputs

The `BrepArray` files in `TestFiles/` are all small. For medium and large baselines,
[`make_samples.sh`](make_samples.sh) converts two SMLib test models with the repo's own
`tools/scripts/smb_to_usd.py`. It runs on the host and needs the host build's Python bindings:

```bash
Examples/SM_API_USD/make_samples.sh   # -> _build/brepinfo-samples/{BoltMBox1,Platte}.usdc
```

The baselines are in `ANDROID_PORT_NOTES.md`: "Baseline (host)" and "Baseline (Quest 3)".
