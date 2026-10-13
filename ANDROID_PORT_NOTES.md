# Android arm64 port notes

Working log for the `android-arm64` branch. Every section is filled by the
phase that owns it. This file is the source for the upstream issue, so keep
entries factual and specific (file, line, error text, fix).

## Repo map (phase 00)

- **Upstream base commit:** `c9c5979f04cea8c38213004d4f04df0dcfb40d05` ("Release 1.0.0.", `VERSION` = `1.0.0`).
- **Host used for baseline:** WSL2 Ubuntu 22.04 (glibc 2.35, gcc 11.4), target `linux-x86_64`.

### Premake projects → source dirs

Workspace `usd-brep` (`premake5.lua:45`), configs `debug`/`release`, platforms `x86_64`/`aarch64`
(`premake5.lua:49`; macOS adds `universal` at `:145`). C++17, RTTI and exceptions on, and
`FatalCompileWarnings` on every platform (`premake5.lua:125`). The USD stack (marked † below) is
included only via `include_usd_dependent_stack()` (`premake5.lua:174-200`).

| Project | Kind | Source dir | Links (project / external) | Android |
|---|---|---|---|---|
| `SMLib` | SharedLib | `source/SMLib/{src,inc}` | tbb, tbbmalloc (`use_usd_tbb`) | **need** (kernel) |
| `SM_API` | SharedLib | `source/SM_API/{src,inc}` | SMLib | **need** (`SmApiTessellate*`) |
| `BREP_USD_DATA` † | SharedLib | `source/BREP_USD_DATA` | USD (`link_usd_common`), tbb, python | **need** (USD data layer) |
| `BREP_SM_USD` † | SharedLib | `source/BREP_SM_USD` | SMLib, BREP_USD_DATA, USD | **need** |
| `SM_API_USD` † | SharedLib | `source/SM_API_USD` | SMLib, SM_API, BREP_SM_USD, BREP_USD_DATA, USD | **need** (`SmApiUsdTessellateBrepArray`) |
| `USD_BREP_UTILS` † | SharedLib | `source/USD_BREP_UTILS` | BREP_USD_DATA, USD | optional (OCCT export dep) |
| `BREP_STAGING` † | StaticLib | `source/BREP_STAGING` | (USD headers) | optional (OCCT import dep) |
| `OCCT_BREP_IMPORT` † | StaticLib | `source/OCCT_BREP_IMPORT` | (USD headers) | optional, cheap: native `.brep` parser, **no OpenCASCADE dependency** |
| `OCCT_BREP_EXPORT` † | StaticLib | `source/OCCT_BREP_EXPORT` | (USD headers) | exclude unless needed |
| `HYDRA_USD_BREP` † | SharedLib | `source/HYDRA_USD_BREP` | SM_API_USD, usd_hd/hdGp/usdImaging/hf/pxOsd | **exclude** (imaging; gated by `usd_has_imaging()`) |
| `_omni_solid` † | SharedLib (py ext) | `source/SmPyLib/src` | SMLib, SM_API, SM_API_USD, python3.12, pybind11 | **exclude** (Python) |
| `_smlib_dev` | SharedLib (py ext) | `source/SmPyDevLib/src` | SMLib, SM_API, python, pybind11 | **exclude** |
| `_smlib_tests` | SharedLib (py ext) | `source/SmPyLib/tests_binding` | prog_test, SMLib, python | **exclude** |
| `prog_test`, `prog_test_app` | SharedLib / App | `tests/prog_test` | SMLib | optional (pure C++ kernel tests) |
| `SM_API_test`, `SM_API_test_app` | SharedLib / App | `tests/SM_API_test` (+ `Examples/SM_API`, `Examples/SMLib` sources) | SMLib, SM_API | optional (pure C++) |
| `SM_API_USD_test`, `SM_API_USD_test_app` † | SharedLib / App | `tests/SM_API_USD_test` | SMLib, SM_API, SM_API_USD, BREP_* | optional (pure C++) |
| `usd_test`, `usd_test_app` † | SharedLib / App | `tests/usd_test` | SMLib, BREP_SM_USD, BREP_USD_DATA | optional |
| `usd_brep_utils_test` † | App | `tests/usd_brep_utils_test` | USD_BREP_UTILS, BREP_USD_DATA | exclude |
| `HYDRA_USD_BREP_test_app` † | App | `tests/HYDRA_USD_BREP_test` | HYDRA_USD_BREP | **exclude** |
| `smtess_usd` † | App | `tools/smtess_usd/src` | SMLib, BREP_SM_USD, BREP_USD_DATA | optional (tessellation CLI) |
| `brep_geometry_validator` † | App | `tools/brep_geometry_validator/src` | BREP_SM_USD, SMLib, BREP_USD_DATA | exclude |
| `occt_to_usd`, `occt_dump` † | App | `tools/occt_to_usd` | OCCT_BREP_IMPORT, BREP_STAGING, BREP_USD_DATA | exclude |
| `usd_to_occt` † | App | `tools/usd_to_occt` | OCCT_BREP_EXPORT, USD_BREP_UTILS, BREP_USD_DATA | exclude |
| `sm_api_boolean_bounds_example` | App | `Examples/SM_API` | SM_API, SMLib | optional |
| `smlib_step_derivatives_example` | App | `Examples/SMLib` | SMLib | optional |

Library helpers live in `premake5-libraries.lua`:
- `use_usd()` (`:236`) adds `usd/<config>/include` and `lib`, **and calls `use_python()`**.
  On Linux it also adds `usd/<config>/include/python` (`:252-256`).
- `use_python()` (`:320`) links `python3.12` on Linux and macOS.
- `link_usd_common()` (`:294`) links 20 `usd_*` libs: ar arch gf js kind pcp plug **python** sdf sdr
  tf trace usd usdGeom usdLux usdShade usdUtils usdVol vt work.
- `use_usd_tbb()` (`:274`) links `tbb` / `tbb_debug` from **`usd/<config>/lib`**.
- **Android impact (phase 03):** every USD-stack project links libpython and `usd_python` today.
  The Android target must drop `use_python()` and `usd_python` (and `usd_sdr` if the core build
  lacks it) without touching the upstream helpers, for example through a wrapper in
  `premake5-android.lua`.

### Platform strings and where they're defined

- `platform = "%{cfg.system}-%{cfg.platform}"` in `premake5-public.lua:57`. That gives
  `linux-x86_64`, `linux-aarch64`, `windows-x86_64` and `macos-universal`, the last overridden in
  `premake5.lua:149-156`.
- Premake platforms are `x86_64` and `aarch64` (`premake5.lua:49`), plus `universal` on macOS (`:145`).
- ABI token `platform_target_abi` comes from `repo.toml:13-16` (`[repo.tokens]`): linux-x86_64 and
  linux-aarch64 → abi `2.35`, windows-x86_64 → `v142`. Packman resolves it to e.g.
  `manylinux_2_35_x86_64`, as seen in the resolved package names below.
- Per-platform staging sections in `prebuild.toml:33,39,49`: `[linux-x86_64]`, `[linux-aarch64]`,
  `[macos-universal]`.
- Packman `platforms=` attribute in `deps/host-deps.packman.xml:3-4`: `windows-x86_64 linux-x86_64
  linux-aarch64`, plus `macos-aarch64` as the *host* platform for the macOS premake.
- Per-platform fetch list in `repo.toml:55` (`fetch."platform:macos-universal"`).
- Platform naming convention: `<os>-<arch>` with arch spelled `x86_64`/`aarch64`. **The Android tag
  `android-aarch64` follows it.**

### Packman packages pulled

Fetch order (`repo.toml:39-57`) is host files, then target files. Repo tools come from
`deps/repo-deps.packman.xml`: `repo_man@2.9.3`, `repo_build@1.34.6`, `repo_format@3.2.1`,
`repo_package@6.5.2`, `repo_test@2.50.3` and `repo_ci@0.10.1`, linked to `_repo/deps/<name>`.

| Manifest | Package (as resolved on linux-x86_64) | linkPath | Consumers |
|---|---|---|---|
| `deps/host-deps.packman.xml` | `premake@5.0.0-beta2+nv1-linux-x86_64` | `_build/host-deps/premake` | build generator |
| `deps/target-deps-python.packman.xml` | `python@3.12.15+nv1-manylinux_2_35_x86_64` (**not on public CDN**, see Known issues) → overridden locally to `3.12.13+nv5` | `_build/target-deps/python` | every `use_usd()` project via `use_python()`, plus `_omni_solid`, `_smlib_dev`, `_smlib_tests` |
| `deps/target-deps-python.packman.xml` | `pybind11@2.11.1-0` | `_build/target-deps/pybind11` | `_omni_solid`, `_smlib_dev`, `_smlib_tests` |
| `deps/target-deps.packman.xml` | `usd.py312.manylinux_2_35_x86_64.stock.<config>@0.25.11-gl.18041+v25.11.363a7c8d` | `_build/target-deps/usd/<config>` | every † project via `use_usd()` and `link_usd_common()`; **also TBB for SMLib** and all others via `use_usd_tbb()` |
| `deps/target-deps-python-macos.packman.xml` | `pybind11@2.11.1-0` | (macOS only) | |

**TBB:** there is no separate TBB package. oneTBB 2021.13 (`TBB_INTERFACE_VERSION 12130`) is
bundled in the USD package: headers in `usd/<config>/include/{tbb,oneapi}`, libs
`libtbb.so.12`, `libtbbmalloc.so.2`, `libtbbmalloc_proxy`, `libtbbbind_2_5` in
`usd/<config>/lib`. SMLib links `tbb` + `tbbmalloc` (`source/SMLib/premake5.lua`). An Android
package must provide both, and either sit in the same `usd/<config>/lib` location or have
the Android premake add a separate tbb libdir.

**Resolved USD package layout** (`_build/target-deps/usd/release/`), the reference for phase 01:
`bin/`, `cmake/{pxrTargets.cmake,pxrTargets-release.cmake}`, `include/{pxr,tbb,oneapi,Imath,
MaterialX*,Alembic,opensubdiv}`, `lib/` (72 `libusd_*.so` + third-party .so + `lib/usd/<plugin>/
resources/plugInfo.json` tree + top-level `lib/usd/plugInfo.json` + `lib/python/pxr`),
`plugin/usd/` (hdStorm, hioAvif, hioOpenEXR, sdrGlslfx, usdAbc, each `.so` + resource dir +
`plugInfo.json`), `pxrConfig.cmake`, `PACKAGE-LICENSES/`, `libraries/` (MaterialX), `resources/`,
`share/`, `scripts/`, `python/`. Library naming is `libusd_<name>.so` (prefix `usd_`, matching
`link_usd_common()`).

### `prebuild` schema staging

`prebuild.sh` runs `./repo.sh build -g -r -p=linux-<uname -m>`: it generates projects (`-g`) and
pulls release deps (`-r`) without compiling. It then stages the **omniSolid** codeless schema:

- Source: `source/schema/omniSolid/resources/{schema.usda,generatedSchema.usda,plugInfo.json}`
  (compiled schema is committed).
- If `schema.usda` differs from `HEAD`, the script regenerates it with
  `_build/target-deps/usd/release/bin/usdGenSchema`, which needs jinja2. Otherwise nothing is
  regenerated (`prebuild.sh:609-631`).
- It always copies `generatedSchema.usda` and `plugInfo.json` to
  **`_build/schema/omniSolid/resources/`** (`prebuild.sh:633-636`).
- At runtime it's found via `OMNISOLID_PLUGIN_PATH` (`repo.toml` `[repo_test] env_vars`; test
  `debugenvs`). The release package ships it from `_build/schema/` (`repo.toml` package files).
- `prebuild.toml` copy rules stage USD `bin/`, `lib/usd/**` and `plugin/usd/**` into
  `_build/$platform/$config/usd/`. `source/SM_API_USD/premake5.lua` also `prebuild_copy`s `lib/usd`
  into `extraLibs/usd` and `plugin/usd` into `plugin/usd`. Both are relevant to which resources
  the viewer must ship.

### OpenUSD version in use

**OpenUSD 25.11**: package version `0.25.11-gl.18041+v25.11.363a7c8d` (`deps/target-deps.packman.xml:3`),
the "stock" NVIDIA build for Python 3.12, with imaging included. The comment at
`premake5-libraries.lua:229` says "OpenUSD 26.08 packages are built without imaging", but that
doesn't match the pinned 25.11 package, which ships `pxr/imaging/hd`. So `HYDRA_USD_BREP` *is*
built on linux-x86_64.

### Tessellation entry points

| Function | Declaration | Definition |
|---|---|---|
| `SmApiUsdTessellateBrepArray(const UsdPrim&, const SmTessellationParams&, SmBoolean bHealer, double boundaryAngleTolDeg, std::vector<SmApiUsdTessellatedBrep>&)` | `source/SM_API_USD/inc/SmApiUsdTessellate.h:57` | `source/SM_API_USD/src/SmApiUsdTessellate.cpp:47` |
| `SmApiTessellate(SmBrep*, SmPolyBrep*&, const SmTessellationParams&, SmBoolean bAllowPartial, ...)` | `source/SM_API/inc/SmApiBrep.h:125` | `source/SM_API/src/SmApiBrep.cpp:679` |
| `SmApiTessellateBoundaries(SmBrep*, double, SmTArray<SmPoint3d>&, SmTArray<ULONG>&, SmTArray<SmEdge*>&)` | `source/SM_API/inc/SmApiBrep.h:138` | `source/SM_API/src/SmApiBrep.cpp:654` |
| `SmTessellationParams` (quality controls) | `source/SM_API/inc/SmApiTessellationParams.h:29` | — |
| Stage-level parallel driver (calls `SmApiUsdTessellateBrepArray` per prim) | `source/SM_API_USD/inc/SmApiUsd.h:321` | `source/SM_API_USD/src/SmApiUsdTessellate.cpp:290` |

`SmApiUsdTessellatedBrep` (result struct, `SmApiUsdTessellate.h:30`) carries `VtArray<GfVec3f>`
points and normals, face-vertex counts and indices, and subset indices and material paths, all
ready for a `UsdGeom.Mesh`.

### Host baseline build (phase 00 gate)

2026-10-12, WSL2 Ubuntu 22.04, from `~/usd-brep-workspace/usd-brep` with the Python `.user`
override in place:

```
./prebuild.sh                 # exit 0, 6 s (generate + release deps + schema staging)
./repo.sh build               # exit 0, "BUILD (RELEASE) SUCCEEDED (Took 232.83 seconds)"; release config only
./tests.sh linux-x86_64       # exit 0, 76 s
```

The test suites all passed: usd_test, usd_brep_utils_test, prog_test, SM_API_test,
SM_API_USD_test, HYDRA_USD_BREP_test, brep_geometry_validator (5), heal_file (26),
SmPyLib (412, 2 skipped), SmPyDevLib (22, 1 skipped), brep_validator (34), occt_to_usd (12,
1 skipped; 29/29 samples) and usd_to_occt (5, 1 skipped; 29/29 round-trips). The skips are for
fixtures that aren't present: numpy, the native part fixture, the GFX build, and external .brep
samples.

`_build/target-deps/` after the build:
- `python` → `~/.cache/packman/chk/python/3.12.13+nv5-manylinux_2_35_x86_64`
- `pybind11` → `~/.cache/packman/chk/pybind11/2.11.1-0`
- `usd/release` → `~/.cache/packman/chk/usd.py312.manylinux_2_35_x86_64.stock.release/0.25.11-gl.18041+v25.11.363a7c8d`

`usd/debug` isn't resolved because `./repo.sh build` defaults to release.

Each `target-deps` entry is a symlink into the Packman cache (`PM_PACKAGES_ROOT`, default
`~/.cache/packman`), and the `<name>/<version>` folder is the extracted package root. An Android
package must extract to the same shape.

## Android dependency packages (phase 01)

Built by `apphaus2/usd-android-packages` (`scripts/build-all.sh`). Its README has the details.

- `onetbb@2021.13.0-r1-android-aarch64` and `usd.core.release@25.11-r1-android-aarch64` are zips
  in `usd-android-packages/dist/`, built for arm64-v8a, android-32, `c++_shared`, NDK r28c.
- **oneTBB is 2021.13.0, not the latest (2023.1.0).** That's the version upstream's USD 25.11
  package bundles. OpenUSD 25.11 doesn't compile with oneTBB 2023: `work/workTBB/dispatcher_impl.h`
  tests `TBB_INTERFACE_VERSION_MAJOR` before any header defines it and takes the removed
  `tbb::task` path.
- The USD package mirrors upstream's layout, with TBB headers, libs and CMake config merged into
  the USD tree, so `use_usd_tbb()` works unchanged. Library names are unversioned (`libtbb.so`,
  `libusd_*.so`), since Android doesn't use `.so.N` symlinks.
- **USD libraries present:** all 19 of `link_usd_common()` except `usd_python`, which isn't
  built without Python. Imaging libraries (`usd_hd`, `usdImaging`, ...) aren't built either.
- Runtime needs `libc++_shared.so` from the NDK, which isn't packaged.
- Patches (OpenUSD-side, not usd-brep): `patches/OpenUSD-25.11/0001` fixes bionic `NOFILE` and
  `__environ` in `pxr/base/arch`. `0002` adds `register` to the aarch64 `execve` asm-register
  variables in `arch/stackTrace.cpp`, which clang otherwise ignores.

## Packman (phase 02)

**How the in-tree client works** (Packman 8.6.1, bootstrapped by `tools/packman/packman`; the
client code lives in `~/.cache/packman/packman-common/8.6.1/`):
- **Config files:** a user-level `~/config.packman.xml`, plus `$PM_INSTALL_PATH/config.packman.xml`
  (`tools/packman/config.packman.xml`, which defines the public `cloudfront` https remote). Both are
  merged, and `PM_REMOTE_<NAME>_<ATTR>` env vars override attributes. The package cache is
  `$PM_PACKAGES_ROOT`, default `~/.cache/packman`. `target-deps` links point into `chk/<name>/<version>`.
- **Remotes:** `<remote2 name>` with `<transport actions protocol packageLocation>`. Protocols
  are `file`, `http(s)`, `s3`, `gtl` and `nstorage`. A `file` transport reads
  `<packageLocation>/<name>@<version>.{7z,zip}`; a relative `packageLocation` resolves against the
  current directory. **Project files can define `<remote2>` themselves** (toolsVersion ≥ 5.6) and
  select them with `remotes="..."`, but may only reference remotes defined in the same file.
- **Per-platform selection in deps XML:** `platforms="..."` on `<package>`, as used by
  `deps/host-deps.packman.xml` for premake, plus `${platform}` in names and versions. Upstream
  selects target deps per platform by *file list* in `repo.toml`, not by attributes.
- **Tokens:** attributes accept `$token` / `${token}` (from repo_build) and `$env{VAR}`.
  `repo_build` passes `fetch.packman_extra_tokens`, which can contain `${root}`, into every pull.
- **Integrity:** `<package checksum="sha256">` makes Packman verify the archive (toolsVersion ≥ 7.6).
- **Config filters (the main pitfall):** `repo_man` applies `"platform:<p>"` keys in `repo.toml`
  against the **host** platform when it loads the config, which is why upstream's
  `"platform:macos-universal"` works on a Mac. A cross target needs `repo_build`'s own
  **`"platform_target:<p>"`** filter (`repo_build/main.py:1229`), applied to `[repo_build]` once the
  `-p` target is known.

**Remote configuration mechanism used:** a **project-level file remote** inside the Android deps
file. Its `packageLocation` is the token `${android_packages_dist}`, which `repo.toml` defines for
the Android target only as `${root}/../usd-android-packages/dist`, so it resolves to an absolute
path at run time. No user-level config, env var or generated file is needed, and the public
`cloudfront` remote is untouched.

**Deps file / entries added:** a new `deps/android-deps.packman.xml`. Upstream selects target deps
per platform by file list, so the fork follows that rather than adding `platforms=` attributes to
upstream files. It's pulled *instead of* `target-deps-python.packman.xml` and
`target-deps.packman.xml`, so Python and pybind11 are excluded for Android.
- `usd-${config}` → `usd.core.release@25.11-r1-android-aarch64`, linked at
  `_build/target-deps/usd/${config}`. The path matches upstream, so `use_usd()` and `use_usd_tbb()`
  resolve unchanged. Only a release build exists, so a debug pull links the same package.
- `tbb` → `onetbb@2021.13.0-r1-android-aarch64`, linked at `_build/target-deps/tbb`.
- Both carry `checksum=` with the release's sha256. Host and repo tooling (`host-deps`,
  `repo-deps`: premake, `repo_*`) are untouched; they run on the host.
- `tools/android/fetch-packages.sh` reads names, versions and checksums from that file, and the
  release tag and dist folder from `tools/android/packages.env`. It downloads any missing zip from
  the GitHub release (with `gh`, or `curl` without it) and checks it. So a fresh clone of the fork
  builds without a local `usd-android-packages` build.

**Platform tag chosen and why:** `android-aarch64`. It follows the tree's `<os>-<arch>`
convention (`linux-x86_64`, `linux-aarch64`, `windows-x86_64`), using the arch spelling the
premake platforms use (`aarch64`, not `arm64`).
- The deps file spells the tag out instead of using `${platform}`. `repo.toml` sets
  `abi = "2.35"` for the Linux host (a host-filtered token). `repo_build` then tries
  `get_abi_platform_translation("android-aarch64", "2.35")`, gets `None` for a non-Linux/Windows
  platform, and Packman falls back to the host platform for `${platform}`. The first attempt failed
  with `Package not found ... (name: usd.core.release, version: 25.11-r1-linux-x86_64)`.
- `repo_man`'s platform table has no `android-aarch64`, so `repo_build`'s VS Code Python-env
  generation fails with `KeyError: 'shell_ext'`. It's disabled for the Android target; there's no
  Python on Android anyway.
- `prebuild.toml` and `premake5*.lua` needed no changes for resolution: premake `gmake2`
  generation runs and the schema staging works. Whether the generated projects target Android
  properly is phase 03.

**Gate (2026-10-12):**
```
tools/android/fetch-packages.sh          # dist/ emptied first: downloads both zips, sha256 ok, rc=0
rm -rf _build _compiler ~/.cache/packman/chk/{usd.core.release,onetbb}
./prebuild.sh -p android-aarch64         # rc=0; Packman: "missing from local storage" -> Extracting
                                         #   usd.core.release@25.11-r1-android-aarch64.zip, onetbb@...zip
ls _build/target-deps                    # tbb -> .../onetbb/2021.13.0-r1-android-aarch64
                                         # usd/release -> .../usd.core.release/25.11-r1-android-aarch64
find -L _build/target-deps/usd/release/lib/usd -name plugInfo.json | wc -l   # 19 (incl. lib/usd/plugInfo.json)
./prebuild.sh                            # host: rc=0, python/pybind11/usd.py312.manylinux_2_35_x86_64 as before
```
`_build/target-deps` is shared across platforms, as upstream designed it. Switching `-p` relinks
`usd/<config>`, while links only one platform pulls stay behind (e.g. `tbb` after a host
prebuild); nothing on the other platform references them.

## Build target decisions (phase 03)

**Approach A (premake) outcome: works. No source changes.** The command is
`tools/android/build.sh [release|debug]`, which runs:
1. `tools/android/fetch-packages.sh`.
2. `./prebuild.sh -p android-aarch64`, for Packman, the `prebuild.toml`/`prebuild_copy` staging
   into `_build/android-aarch64/<cfg>` and the omniSolid schema.
3. premake `gmake2` with `--platform-target=android-aarch64`, generating `_compiler/gmake2-android`.
4. `make config=<cfg>_aarch64` with the NDK's `clang`/`clang++`/`llvm-ar`.
5. Resource collection and `MANIFEST.txt`, then a check of every `.so`.

A clean release build takes about 42 s with 10 jobs, with zero compiler warnings.

- **Why `build.sh` drives premake and make instead of `./repo.sh build -p android-aarch64`:**
  `repo_build` (1.34.6) never passes `--platform-target` to premake
  (`build.py:generate_projects`). It always adds `--os=<host>`, and its make step builds
  `config=<cfg>_<arch>` with the arch taken from a `linux-`/`macos-` prefix, so it's empty for
  `android-aarch64`. Teaching it a non-host toolchain would mean patching `repo_build`, so for
  Android the build script makes the two calls `repo_build` would have made. `repo.sh build` is
  untouched and still used for Packman and staging (via `prebuild.sh`).
- **`premake5-android.lua`** (new) defines its own `usd-brep` workspace, which
  `premake5.lua` includes and returns from when `--platform-target=android-aarch64` (see the
  upstream files table). It sets `platform = "android-aarch64"`, so outputs go to
  `_build/android-aarch64/{debug,release}` and objects to `_build/intermediate/android-aarch64`.
  Configurations are `debug`/`release`, the platform is `aarch64`, and the toolset is `clang`. The
  upstream project files are included **unchanged**, and only three helpers are overridden in Lua:
  - `use_python()` does nothing, since `use_usd()` called it and it linked libpython3.12.
  - `link_usd_common()` drops `usd_python`.
  - `use_usd()` drops the build-tree USD runpath.
- **Toolchain flags** are the NDK's own CMake-toolchain set:
  - `--target=aarch64-linux-android32` and `--sysroot=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/<host>/sysroot`.
  - `-fPIC` (`pic "On"`), `-DANDROID`, `-ffunction-sections -fdata-sections -funwind-tables
    -fstack-protector-strong`.
  - Link: `-nostdlib++` + `c++_shared`, `log`, `-Wl,--no-undefined,-z,relro,-z,now,--gc-sections,--build-id=sha1`.
  - `-D__ANDROID_API__=32` is **not** passed: clang defines it from `--target`, and redefining it
    would be a `-Wmacro-redefined` error under `FatalCompileWarnings`. The NDK sysroot has no
    plain `libc++.so`, hence `-nostdlib++` with an explicit `c++_shared`.
  - `--os=linux`: bionic is a Linux userland, so the projects' `filter "system:linux"` settings
    apply as on the host (`-fvisibility=hidden` + export macros, `links { "dl" }`, SMLib's
    `tbb`/`tbbmalloc`).
- **Warnings.** Upstream's `FatalCompileWarnings` is kept, along with its Linux set
  (`-Wall -Wunused-parameter`). Gcc's `-Wshadow=local` is dropped because clang 19 rejects it
  (`unknown warning option '-Wshadow=local'`). On top of that come the clang suppressions upstream
  already uses for macOS (`macos_warning_suppressions()` and `-Wno-missing-braces` from
  `macos_common_buildoptions()`; first hit: `SmTransform.h:135 suggest braces around
  initialization of subobject`). Two more, both benign and reported by clang/bionic but not by the
  host gcc/glibc:
  - `-Wno-misleading-indentation`: `SmTopologySweep.cpp:1773`, a statement left after its `if`
    was commented out.
  - `-Wno-unused-result`: `NL_Util.cpp:4419`, where `fgetc()` skips bytes on purpose and bionic
    declares it `warn_unused_result`.
  - No `TCHAR`/`_T`/`ULONG` issues came up; the Linux paths already cover bionic.
- **Debug builds:** the Android packages are release-only, so the debug config links `tbb`/`tbbmalloc`
  with `TBB_USE_DEBUG=0`, and the dependency `usd-debug` points at the release USD package.

**Approach B (CMake) used? why:** no. Approach A worked on the first real attempt, once
`--platform-target` was passed.

**Projects excluded on Android** (not included by `premake5-android.lua`): `_omni_solid`,
`_smlib_dev` and `_smlib_tests` (Python); `HYDRA_USD_BREP` and its test (imaging); every test
project (`prog_test*`, `SM_API_test*`, `SM_API_USD_test*`, `usd_test*`, `usd_brep_utils_test`);
the tools (`smtess_usd`, `brep_geometry_validator`, `occt_to_usd`, `occt_dump`, `usd_to_occt`);
and the examples. **Built:** `SMLib`, `SM_API`, `BREP_USD_DATA`, `USD_BREP_UTILS`, `BREP_SM_USD`,
`SM_API_USD` (shared), and `BREP_STAGING`, `OCCT_BREP_IMPORT`, `OCCT_BREP_EXPORT` (static; they
built cleanly, so they're in).

**Resource collection:** `build.sh` fills `_build/android-aarch64/<cfg>/`:
- `resources/omniSolid/resources/{generatedSchema.usda,plugInfo.json}`, from
  `_build/schema/omniSolid/resources`. It's found at runtime through `OMNISOLID_PLUGIN_PATH`
  (`UsdBrepUtilities.cpp:110`).
- `resources/usd/`, OpenUSD's `lib/usd` plugin tree (19 `plugInfo.json` files). OpenUSD looks for it
  at `<dir of libusd_plug.so>/usd`, or wherever `PXR_PLUGINPATH_NAME` points.
- `extraLibs/`: `libusd_*.so`, `libtbb.so` and `libtbbmalloc.so` from the package, plus the NDK's
  `libc++_shared.so`.
- `MANIFEST.txt` lists the usd-brep `.so` files, the runtime `.so` files and all 66 resource
  files, with how each is found.

The `.so` files keep their debug info (158 MB tree); an APK build strips them.

**Gate (2026-10-12):**
```
tools/android/build.sh release     # rc=0, 42 s from clean, 0 warnings
file lib*.so                       # all six: ELF 64-bit LSB shared object, ARM aarch64
llvm-nm -D -C libSM_API_USD.so     # T SmApiUsdTessellateBrepArray(UsdPrim const&, SmTessellationParams const&, int, double, vector<SmApiUsdTessellatedBrep>&)
llvm-nm -D -C libSM_API.so         # T SmApiTessellate(...), T SmApiTessellateBoundaries(...)
llvm-readelf -d lib*.so            # NEEDED: in-tree (usd-brep, libusd_*, libtbb*) or NDK (libc, libm,
                                   #   libdl, liblog, libc++_shared); RUNPATH only $ORIGIN; no libpython
./prebuild.sh && ./repo.sh build && ./tests.sh linux-x86_64
                                   # host unchanged: rc=0/0/0, BUILD (RELEASE) SUCCEEDED (233.72 s), suite
                                   #   counts identical to the phase 00 baseline
```

## Upstream files edited
| File | Lines | Change | Reason / error |
|------|-------|--------|----------------|
| `.gitignore` (new file) | — | Ignore `_build/`, `_compiler/`, `_repo/`, `_builtpackages/` | Upstream has no `.gitignore`. Keeps build output out of commits. |
| `deps/target-deps-python.packman.xml.user` (new file) | — | Packman `.user` override pinning `python@3.12.13+nv5-${platform_target_abi}` | Upstream pin `3.12.15+nv1` is missing from the public CDN. Without this, `./prebuild.sh` fails on a fresh clone (see Known issues). Remove once upstream publishes or re-pins. |
| `repo.toml` | 58-66 (added, nothing changed) | `[repo_build]` keys under `"platform_target:android-aarch64"`: `fetch.packman_target_files_to_pull = [deps/android-deps.packman.xml]`, `fetch.packman_extra_tokens.android_packages_dist`, and `vscode.generate_python_env_file/generate_python_setup_shell_script = false` | Pull Android deps instead of the Python + host-USD files; give the file remote an absolute path; avoid `KeyError: 'shell_ext'` (repo_man has no android platform mapping). `"platform:"` filters match the host, not the target, so they can't be used. |
| `premake5.lua` | 12-16 (added, nothing changed) | `if _OPTIONS["platform-target"] == "android-aarch64" then include("premake5-android.lua") return end`, before the host workspace | The Android target needs its own workspace (toolchain, project subset, no Python). Without `--platform-target=android-aarch64` the file behaves exactly as upstream. |

## Source edits (verbatim diff hunks)
```diff
```

## Baseline (host) — phase 04
| File | faces/edges/verts | tris | open ms | import ms | tess ms |
|------|-------------------|------|---------|-----------|---------|

## Baseline (Quest 3) — phase 04
| File | faces/edges/verts | tris | open ms | import ms | tess ms |
|------|-------------------|------|---------|-----------|---------|

## Known issues / follow-ups
- **Upstream 1.0.0 pins a Python that is not publicly fetchable.**
  `deps/target-deps-python.packman.xml` asks for `python@3.12.15+nv1-${platform_target_abi}`,
  and the public Packman CDN (`d4i3qtqj3r0z5.cloudfront.net`) doesn't have it for
  `manylinux_2_35_x86_64`. `./prebuild.sh` fails with:
  `Package not found on specified remote servers! (name: python, version: 3.12.15+nv1-manylinux_2_35_x86_64)`.
  The workaround needs no edit to upstream files: a committed
  `deps/target-deps-python.packman.xml.user` (Packman merges `<project>.user` over the project
  file) pins `3.12.13+nv5`, the version upstream 0.2.0 used, which is on the CDN. Report upstream.
- README says test fixtures are Git LFS, but the public repo has no `.gitattributes` and no LFS
  pointer files. `git lfs pull` is a no-op. Fixtures (`TestFiles/`, 28 MB) are plain git.
- **OpenUSD on Android logs `ArchWarn: ARCH_CACHE_LINE_SIZE != Arch_ObtainCacheLineSize()`** once
  per process (`pxr/base/arch/assumptions.cpp:140`). Bionic's `sysconf(_SC_LEVEL1_DCACHE_LINESIZE)`
  returns 0. On the Quest 3 (Android 14, API 34) the real L1D line is 64 bytes (`CTR_EL0`), which
  equals `ARCH_CACHE_LINE_SIZE`, so this is cosmetic. A possible OpenUSD fix: read `CTR_EL0` on
  Android/aarch64. Not patched; flagged for an OpenUSD upstream issue.
- Stale comment at `premake5-libraries.lua:229` (says 26.08, no imaging; the pin is 25.11 with imaging).

## Upstream issue
- URL:
