#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Make sure the Android dependency packages that deps/android-deps.packman.xml asks for are in the
# local Packman file remote (../usd-android-packages/dist by default). Missing zips are downloaded
# from the GitHub release pinned in tools/android/packages.env; every zip is checked against the
# sha256 recorded in the deps file. A fresh clone of this fork can therefore build without a local
# usd-android-packages build.
#
# Usage: tools/android/fetch-packages.sh [--force]   (--force re-downloads even if present)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=packages.env
source "$ROOT/tools/android/packages.env"
DEPS="$ROOT/deps/android-deps.packman.xml"
DIST="$(cd "$ROOT" && mkdir -p "$ANDROID_PACKAGES_DIST" && cd "$ANDROID_PACKAGES_DIST" && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# "<name>@<version>.zip <sha256>" for every package in the deps file.
mapfile -t PACKAGES < <(python3 -I - "$DEPS" <<'EOF'
import sys
import xml.etree.ElementTree as ET
for pkg in ET.parse(sys.argv[1]).getroot().iter("package"):
    print(f'{pkg.get("name")}@{pkg.get("version")}.zip {pkg.get("checksum", "")}')
EOF
)
[ "${#PACKAGES[@]}" -gt 0 ] || { echo "error: no packages found in $DEPS" >&2; exit 1; }

download() {
    local asset="$1" out="$2"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh release download "$ANDROID_PACKAGES_TAG" --repo "$ANDROID_PACKAGES_REPO" \
            --pattern "$asset" --output "$out" --clobber
    else
        # Public release: plain HTTPS works without gh. '+' in the tag must be URL-encoded.
        local tag="${ANDROID_PACKAGES_TAG//+/%2B}" name="${asset//+/%2B}"
        curl -fL --retry 3 --silent --show-error -o "$out" \
            "https://github.com/$ANDROID_PACKAGES_REPO/releases/download/$tag/$name"
    fi
}

status=0
for entry in "${PACKAGES[@]}"; do
    asset="${entry%% *}"
    want="${entry#* }"
    file="$DIST/$asset"
    if [ "$FORCE" = 1 ] || [ ! -f "$file" ]; then
        echo "fetching $asset ($ANDROID_PACKAGES_REPO@$ANDROID_PACKAGES_TAG)"
        download "$asset" "$file.part"
        mv "$file.part" "$file"
    fi
    have="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ -n "$want" ] && [ "$have" != "$want" ]; then
        echo "error: $asset sha256 $have does not match $want in deps/android-deps.packman.xml" >&2
        status=1
    else
        echo "ok      $asset  $have"
    fi
done
echo "Packman file remote: $DIST"
exit $status
