-- SPDX-License-Identifier: Apache-2.0
--
-- Android arm64 target (platform android-aarch64). Fork addition, see ANDROID_PORT_NOTES.md.
--
-- premake5.lua includes this file instead of defining the host workspace when premake runs with
-- --platform-target=android-aarch64. tools/android/build.sh runs premake that way (repo_build
-- never passes --platform-target to premake). It reuses the upstream project files unchanged; only
-- the workspace, the toolchain and three library helpers differ. Projects are generated as gmake2
-- makefiles in _compiler/gmake2-android with --os=linux (bionic is a Linux userland, so the
-- projects' "system:linux" settings apply) and compiled with the NDK's clang by build.sh.
-- Outputs land in _build/android-aarch64/{debug,release}.

------------------------------------------------------------------------------------------------------------------------
------------------                              Globals and helpers                                   ------------------
------------------------------------------------------------------------------------------------------------------------

platform = "android-aarch64"
-- Keep the Android makefiles apart from the host's _compiler/gmake2.
workspace_dir = "%{root}/_compiler/".._ACTION.."-android"
include("premake5-public.lua")

target_dir = target_dir or bin_dir

include("premake5-utils.lua")
include("premake5-libraries.lua")

-- No Python on Android: use_usd() calls use_python(), which links libpython3.12.
function use_python()
end

-- OpenUSD for Android is built without Python, so there is no usd_python library.
local upstream_link_usd_common = link_usd_common
function link_usd_common()
    upstream_link_usd_common()
    removelinks { "usd_python" }
end

-- use_usd() adds the build tree's USD lib folder as a run path on Linux. On a device the libraries
-- sit next to each other (or in the APK's lib/ folder), so no run path is wanted.
local upstream_use_usd = use_usd
function use_usd()
    upstream_use_usd()
    removerunpathdirs { target_deps.."/usd/"..config.."/lib" }
end

------------------------------------------------------------------------------------------------------------------------
------------------                                 NDK toolchain                                      ------------------
------------------------------------------------------------------------------------------------------------------------

local ndk = os.getenv("ANDROID_NDK_HOME")
if is_string_empty(ndk) then
    error("ANDROID_NDK_HOME must point at an Android NDK (r27 or newer)")
end
local android_api = os.getenv("ANDROID_API") or "32"
local ndk_host = (os.host() == "macosx") and "darwin-x86_64" or "linux-x86_64"
local ndk_llvm = ndk.."/toolchains/llvm/prebuilt/"..ndk_host
local android_target_flags = {
    "--target=aarch64-linux-android"..android_api,
    "--sysroot="..ndk_llvm.."/sysroot",
}

------------------------------------------------------------------------------------------------------------------------
------------------                                   Workspace                                        ------------------
------------------------------------------------------------------------------------------------------------------------

repo_build.setup_options()

workspace "usd-brep"
    location (workspace_dir)
    targetdir (target_dir)
    objdir (build_dir.."/intermediate/"..platform.."/%{prj.name}")
    configurations { "debug", "release" }
    platforms { "aarch64" }
    architecture "ARM64"
    toolset "clang"

    repo_build.set_prebuild_file("_build/generated/prebuild.toml")

    symbols "On"
    exceptionhandling "On"
    rtti "On"
    staticruntime "Off"
    cppdialect "C++17"
    pic "On"
    -- Same policy as upstream: warnings are errors.
    flags { "FatalCompileWarnings" }

    -- The NDK's own CMake toolchain flags. __ANDROID__ and __ANDROID_API__ come from --target.
    defines { "ANDROID" }
    buildoptions (concat_arrays(android_target_flags, {
        "-fdata-sections", "-ffunction-sections", "-funwind-tables", "-fstack-protector-strong",
        "-no-canonical-prefixes",
        -- No a*b+c -> FMA contraction (clang's default on arm64; the host's gcc/x86-64 build has
        -- none). Contraction changes rounding, which flips the tessellator's ties, so meshes
        -- differ from the host's (BoltMBox1: 888 vs 884 triangles). Off: bit-identical to the
        -- host, at no measurable speed cost on the Quest 3. See ANDROID_PORT_NOTES.md, phase 04.
        "-ffp-contract=off",
        -- Upstream's Linux warning set, minus gcc-only -Wshadow=local, then the clang suppressions
        -- upstream already uses for macOS (must follow -Wall), including -Wno-missing-braces from
        -- macos_common_buildoptions().
        "-Wall", "-Wunused-parameter", "-Wno-missing-braces",
        -- Not reported by the host gcc, benign (see ANDROID_PORT_NOTES.md): clang's
        -- misleading-indentation heuristic (SmTopologySweep.cpp, a commented-out if), and bionic
        -- marks fgetc() warn_unused_result (NL_Util.cpp skips bytes on purpose).
        "-Wno-misleading-indentation", "-Wno-unused-result",
    }))
    buildoptions (macos_warning_suppressions())
    -- c++_shared: one C++ runtime shared by every .so (usd-brep, OpenUSD, oneTBB, the app).
    linkoptions (concat_arrays(android_target_flags, {
        "-nostdlib++", "-Wl,--build-id=sha1", "-Wl,--no-undefined", "-Wl,-z,relro,-z,now",
        "-Wl,--gc-sections",
    }))
    links { "c++_shared", "log" }

    filter { "configurations:debug" }
        defines { "_DEBUG", "NOMINMAX", "SM_DEBUG_CODE=1", "SM_GFX_CODE=1", "SM_GRAPHICS_CALLBACKS=1" }
        optimize "Off"
        runtime "Debug"
        -- The Android packages are release-only: link the release oneTBB in debug builds too.
        removedefines { "TBB_USE_DEBUG=1" }
        defines { "TBB_USE_DEBUG=0" }
        removelinks { "tbb_debug", "tbbmalloc_debug" }
        links { "tbb", "tbbmalloc" }
    filter { "configurations:release" }
        -- SM_GRAPHICS_CALLBACKS=1: see the host workspace in premake5.lua.
        defines { "NDEBUG", "NOMINMAX", "SM_GRAPHICS_CALLBACKS=1" }
        optimize "On"
        runtime "Release"
    filter {}

------------------------------------------------------------------------------------------------------------------------
------------------                                    Projects                                        ------------------
------------------------------------------------------------------------------------------------------------------------

-- Kernel, C API (incl. SmApiTessellate*), the USD data layer and SmApiUsd* (incl.
-- SmApiUsdTessellateBrepArray), plus the OCCT .brep import/export libraries (native parsers, no
-- OpenCASCADE). Not built: Python modules, Hydra/imaging, tests and command-line tools, except the
-- brepinfo sample (a PIE executable; clang links PIE by default for Android targets).
include("source/SMLib/premake5.lua")
include("source/SM_API/premake5.lua")
include("source/BREP_USD_DATA/premake5.lua")
include("source/USD_BREP_UTILS/premake5.lua")
include("source/BREP_STAGING/premake5.lua")
include("source/OCCT_BREP_IMPORT/premake5.lua")
include("source/OCCT_BREP_EXPORT/premake5.lua")
include("source/BREP_SM_USD/premake5.lua")
include("source/SM_API_USD/premake5.lua")
include("Examples/SM_API_USD/premake5.lua")
