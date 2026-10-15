#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Run the brepinfo sample on a connected Android device (Quest 3) over adb.
#
#   tools/android/run-on-device.sh <file.usd[c|a]> [brepinfo options]     (CONFIG=debug for debug)
#
# Pushes the android-aarch64 build (tools/android/build.sh) and the input file to
# /data/local/tmp/brepinfo/ (DEVICE_DIR), runs brepinfo there, prints its output and exit code,
# and exits with brepinfo's exit code. Pulls nothing. Idempotent: the payload is mirrored, and
# adb push --sync only sends files that changed. Device layout, as an app would ship it:
#   brepinfo
#   lib/*.so                       usd-brep, OpenUSD, oneTBB, libc++_shared (LD_LIBRARY_PATH)
#   lib/usd/                       OpenUSD plugin tree (found next to libusd_plug.so)
#   resources/omniSolid/resources  omniSolid schema (found through PXR_PLUGINPATH_NAME)
#   files/<input>
# Works with a Linux adb or, under WSL, the Windows adb.exe (paths converted with wslpath).

set -euo pipefail

die() { echo "run-on-device: $*" >&2; exit 2; }

[ $# -ge 1 ] || die "usage: $0 <file.usd[c|a]> [brepinfo options]"
INPUT="$(realpath "$1")" || die "no such file: $1"
[ -f "$INPUT" ] || die "no such file: $1"
shift

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/_build/android-aarch64/$CONFIG"
DEVICE_DIR="${DEVICE_DIR:-/data/local/tmp/brepinfo}"
[ -x "$OUT/brepinfo" ] || die "build first: tools/android/build.sh $CONFIG"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$(ls -d "$HOME"/android/android-ndk-* 2>/dev/null | sort -V | tail -1 || true)"
fi
STRIP="${ANDROID_NDK_HOME:-}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
[ -x "$STRIP" ] || die "set ANDROID_NDK_HOME to an Android NDK (for llvm-strip)"

if command -v adb >/dev/null 2>&1; then
    ADB=adb; hostpath() { echo "$1"; }
elif command -v adb.exe >/dev/null 2>&1; then
    ADB=adb.exe; hostpath() { wslpath -w "$1"; }
else
    die "adb not found (install platform-tools, or use the Windows adb.exe from WSL)"
fi
[ "$($ADB get-state 2>/dev/null | tr -d '\r')" = device ] || die "no device in 'adb devices'"

# Payload: the build keeps debug info (~160 MB), so binaries are copied with it stripped. Files are
# refreshed only when the build is newer, keeping their timestamps so adb push --sync skips them.
PAYLOAD="$OUT/device-payload"
mkdir -p "$PAYLOAD/lib" "$PAYLOAD/resources" "$PAYLOAD/files"
put_binary() {
    if [ ! -f "$2" ] || [ "$1" -nt "$2" ]; then
        "$STRIP" --strip-debug -o "$2" "$1"
        touch -r "$1" "$2"
    fi
}
put_binary "$OUT/brepinfo" "$PAYLOAD/brepinfo"
for so in "$OUT"/lib*.so "$OUT"/extraLibs/*.so; do
    put_binary "$so" "$PAYLOAD/lib/$(basename "$so")"
done
cp -a -u "$OUT/resources/usd" "$PAYLOAD/lib/"
cp -a -u "$OUT/resources/omniSolid" "$PAYLOAD/resources/"
NAME="$(basename "$INPUT")"
cp -a -u "$INPUT" "$PAYLOAD/files/$NAME"

echo "device: $($ADB get-serialno | tr -d '\r'), $DEVICE_DIR" >&2
$ADB shell "mkdir -p $DEVICE_DIR"
$ADB push --sync "$(hostpath "$PAYLOAD")/." "$DEVICE_DIR/" >/dev/null
$ADB shell "chmod 755 $DEVICE_DIR/brepinfo"

# stderr goes to a file on the device so stdout stays clean (e.g. for --json); it's printed after.
set +e
$ADB shell "cd $DEVICE_DIR && LD_LIBRARY_PATH=$DEVICE_DIR/lib \
PXR_PLUGINPATH_NAME=$DEVICE_DIR/resources/omniSolid/resources \
./brepinfo files/$NAME $* 2>stderr.txt; echo exit=\$?" | tr -d '\r' > "$PAYLOAD/stdout.txt"
set -e
$ADB shell "cat $DEVICE_DIR/stderr.txt" | tr -d '\r' >&2
code="$(sed -n 's/^exit=//p' "$PAYLOAD/stdout.txt" | tail -1)"
grep -v '^exit=' "$PAYLOAD/stdout.txt" || true
echo "exit=${code:-?}" >&2
exit "${code:-2}"
