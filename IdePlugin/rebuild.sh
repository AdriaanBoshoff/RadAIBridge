#!/usr/bin/env bash
#
# Rebuild RadAiBridge, deploy the .bpl and restart RAD Studio.
#
# Two things this exists to get right:
#
#  1. A .bpl cannot hot-reload, so every plugin change needs a full IDE restart.
#  2. The deploy must never write over a .bpl that a running IDE has mapped.
#     The copy appears to succeed but leaves an image the next IDE start
#     silently fails to load - no error dialog, the package just never appears
#     in the process. That looks exactly like "the plugin stopped working" and
#     is miserable to diagnose. So the IDE is always shut down first.
#
# Usage:  ./rebuild.sh            (from anywhere)
#         BDS_VER=37.0 ./rebuild.sh
set -euo pipefail

BDS_VER="${BDS_VER:-37.0}"
BDS_ROOT="/c/Program Files (x86)/Embarcadero/Studio/$BDS_VER"
BDS_BIN="$BDS_ROOT/bin"
BDS_LIB_WIN="C:\\Program Files (x86)\\Embarcadero\\Studio\\$BDS_VER\\lib\\Win32\\release"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$HERE/dcu/Win32/Debug"
DEPLOY="$DEPLOY_DIR/RadAiBridge.bpl"
DISCOVERY="$APPDATA/RadAiBridge/bridge.json"

[ -x "$BDS_BIN/dcc32.exe" ] || { echo "dcc32 not found under $BDS_BIN" >&2; exit 1; }

cd "$HERE"
mkdir -p "$DEPLOY_DIR"

echo "==> compiling"
"$BDS_BIN/dcc32.exe" -B RadAiBridge.dpk \
  -U"$BDS_LIB_WIN" -I"$BDS_LIB_WIN" \
  -N0"dcu\\Win32\\Debug" -LE"." -LN"."

echo "==> closing any running IDE"
powershell -NoProfile -Command "Get-Process bds -ErrorAction SilentlyContinue | Stop-Process -Force" || true
for _ in $(seq 1 20); do
  powershell -NoProfile -Command "if (Get-Process bds -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }" && break
  sleep 1
done

echo "==> deploying to $DEPLOY"
cp -f RadAiBridge.bpl "$DEPLOY"
cmp -s RadAiBridge.bpl "$DEPLOY" || { echo "deploy mismatch" >&2; exit 1; }

rm -f "$DISCOVERY"

echo "==> starting IDE"
powershell -NoProfile -Command "Start-Process '$(cygpath -w "$BDS_BIN/bds.exe")' -ArgumentList '-pDelphi'"

echo "==> waiting for the bridge"
for _ in $(seq 1 24); do
  if [ -f "$DISCOVERY" ]; then
    echo "bridge up: $(cat "$DISCOVERY")"
    exit 0
  fi
  sleep 5
done
echo "bridge did not come up within 120s" >&2
exit 1
