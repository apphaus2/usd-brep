#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the android-aarch64 target: kernel, C API, USD data layer, SmApiUsd* (tessellation) and the
# OCCT .brep libraries, as shared libraries for Android arm64-v8a.
#
#   tools/android/build.sh [release|debug]      (default: release)
#
# Steps: fetch the Android packages (tools/android/fetch-packages.sh) -> ./prebuild.sh -p
# android-aarch64 (Packman, premake gmake2 generation via premake5-android.lua, omniSolid schema
# staging) -> make with the NDK's clang -> collect runtime resources + MANIFEST.txt -> check the
# binaries. `./repo.sh build` is not used for compiling: repo_build only drives make for
# linux-*/macos-* targets (see ANDROID_PORT_NOTES.md, phase 03).
#
# Needs ANDROID_NDK_HOME (r27+), or an NDK under ~/android/android-ndk-*.

set -euo pipefail

CONFIG="${1:-release}"
case "$CONFIG" in release|debug) ;; *) echo "usage: $0 [release|debug]" >&2; exit 2 ;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLATFORM=android-aarch64
OUT="$ROOT/_build/$PLATFORM/$CONFIG"
cd "$ROOT"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$(ls -d "$HOME"/android/android-ndk-* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -f "${ANDROID_NDK_HOME:-}/build/cmake/android.toolchain.cmake" ] \
    || { echo "error: set ANDROID_NDK_HOME to an Android NDK (r27+)" >&2; exit 1; }
export ANDROID_NDK_HOME
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_SYSROOT_LIB="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
JOBS="${JOBS:-$(nproc)}"

echo "== packages"
tools/android/fetch-packages.sh

echo "== prebuild (Packman + file staging + schema)"
./prebuild.sh -p "$PLATFORM"
if [ "$CONFIG" = debug ]; then
    ./repo.sh build -g -d -p "$PLATFORM"
fi

echo "== premake (premake5-android.lua -> _compiler/gmake2-android)"
# Same invocation repo_build uses, plus --platform-target, which repo_build does not pass.
"$ROOT/_build/host-deps/premake/premake5" --file="$ROOT/premake5.lua" gmake2 \
    --platform-host=linux-x86_64 --platform-target="$PLATFORM" \
    --scripts="$(readlink -f "$ROOT/_repo/deps/repo_build")/lua" --os=linux

echo "== make $CONFIG ($JOBS jobs, NDK $(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties"))"
make --directory="$ROOT/_compiler/gmake2-android" --no-print-directory --output-sync "config=${CONFIG}_aarch64" \
    -j"$JOBS" CC="$NDK_BIN/clang" CXX="$NDK_BIN/clang++" AR="$NDK_BIN/llvm-ar"

echo "== resources"
# The device needs these next to the libraries: the omniSolid codeless schema (located through
# OMNISOLID_PLUGIN_PATH) and OpenUSD's plugin tree (found at <dir of libusd_plug.so>/usd, or via
# PXR_PLUGINPATH_NAME).
RES="$OUT/resources"
rm -rf "$RES"
mkdir -p "$RES/omniSolid" "$RES/usd"
cp -a "$ROOT/_build/schema/omniSolid/resources" "$RES/omniSolid/"
cp -aL "$ROOT/_build/target-deps/usd/$CONFIG/lib/usd/." "$RES/usd/"
# Runtime libraries the usd-brep libraries need: OpenUSD + oneTBB (staged into extraLibs/ by
# source/SM_API_USD/premake5.lua at prebuild time) and the NDK's C++ runtime.
mkdir -p "$OUT/extraLibs"
cp -aL "$ROOT/_build/target-deps/usd/$CONFIG/lib/"*.so "$OUT/extraLibs/"
cp "$NDK_SYSROOT_LIB/libc++_shared.so" "$OUT/extraLibs/"

{
    echo "# usd-brep android-aarch64 ($CONFIG): files that must ship to the device."
    echo "# Paths are relative to _build/$PLATFORM/$CONFIG/. Put every .so in one library folder"
    echo "# (an APK's lib/arm64-v8a/, or a dir on LD_LIBRARY_PATH)."
    echo "# Set OMNISOLID_PLUGIN_PATH=<resources>/omniSolid/resources before reading BrepArray prims."
    echo "# Ship resources/usd/ as <library folder>/usd/ (where libusd_plug.so looks), or point"
    echo "# PXR_PLUGINPATH_NAME at it."
    echo
    echo "[usd-brep libraries]"
    (cd "$OUT" && ls -1 lib*.so)
    echo
    echo "[runtime libraries: OpenUSD, oneTBB, NDK libc++_shared]"
    (cd "$OUT" && ls -1 extraLibs/*.so)
    echo
    echo "[resources]"
    (cd "$OUT" && find resources -type f | LC_ALL=C sort)
} > "$OUT/MANIFEST.txt"

echo "== check"
status=0
ALLOWED_SYSTEM="libc.so libm.so libdl.so liblog.so libc++_shared.so"
in_tree() { [ -f "$OUT/$1" ] || [ -f "$OUT/extraLibs/$1" ]; }
for so in "$OUT"/lib*.so; do
    name="$(basename "$so")"
    desc="$(file -b "$so" | cut -d, -f1-2)"
    echo "$name: $desc"
    case "$desc" in *"ARM aarch64"*) ;; *) echo "  error: not an ARM aarch64 shared object" >&2; status=1 ;; esac
    for needed in $("$NDK_BIN/llvm-readelf" -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        if [[ " $ALLOWED_SYSTEM " == *" $needed "* ]] || in_tree "$needed"; then
            continue
        fi
        echo "  error: NEEDED $needed is neither an NDK system library nor in-tree" >&2
        status=1
    done
    # premake adds $ORIGIN for sibling libraries; anything else would be a build-machine path.
    runpath="$("$NDK_BIN/llvm-readelf" -d "$so" | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p')"
    for entry in ${runpath//:/ }; do
        case "$entry" in '$ORIGIN'|'$ORIGIN/'*) ;; *) echo "  error: run path entry $entry" >&2; status=1 ;; esac
    done
done
echo "static libraries: $(cd "$OUT" && ls -1 lib*.a | tr '\n' ' ')"
echo "manifest: $OUT/MANIFEST.txt"
exit $status
