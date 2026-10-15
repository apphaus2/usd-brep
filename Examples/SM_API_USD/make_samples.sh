#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The BrepArray USD files in TestFiles/ are all small (<= 236 triangles at default quality). For
# medium and large brepinfo baselines, convert two SMLib test models from TestFiles/pt_TestFiles
# with the repo's own converter (tools/scripts/smb_to_usd.py, which needs the host build's Python
# bindings):
#
#   Examples/SM_API_USD/make_samples.sh      -> _build/brepinfo-samples/{BoltMBox1,Platte}.usdc
#
# Run on the host after ./repo.sh build. The outputs are regenerated, not committed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/_build/brepinfo-samples"
cd "$ROOT"
set +u
# shellcheck disable=SC1091
source tools/scripts/run_view_env.sh
set -u
mkdir -p "$OUT"
for model in Boolean/BoltMBox1 Defeature/Platte; do
    _build/target-deps/python/bin/python3 tools/scripts/smb_to_usd.py \
        "TestFiles/pt_TestFiles/$model.smb" "$OUT/$(basename "$model").usdc"
done
