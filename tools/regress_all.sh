#!/bin/bash
# Default-settings lockstep regression gate (every agent runs this before handing off a change).
#
#   tools/regress_all.sh [--bin PATH/platoon-headless] [--only REGEX] [--skip REGEX] [--jobs N] [--out DIR]
#                        [--no-emu] [--no-cache] [--list]
#
# Runs ~60 scenarios (kernel/boot/title/hiscores, section 0, section 1, section 2 - the verification harness
# scripts of port/verify/*) with all enhancement options at their defaults and checks that the port under test
# is BYTE-IDENTICAL to the pre-enhancement port (commit $BASE, built once into /tmp/regress-cache): every
# tick dump at the original main-loop heads (RAM + frame numbers), the full-RAM hash of every frame, every
# screenshot and dumped file. Prints PASS/FAIL per scenario, then ALL PASS / FAILED: ... ; exit code 0/1.
# Also prints each scenario's lockstep status against tools/amiga/emu (information; emulator runs are cached).
#
# Run it in the background (it takes ~3-5 min warm, ~10 min the first time):
#   tools/regress_all.sh --bin /tmp/pbuild-<agent>/release/platoon-headless > /tmp/enh-<agent>/regress.log 2>&1
# Without --bin the current tree is built into /tmp/pbuild-regress (serialised by a lock directory).
# Details: port/PORTING.md "Regression gate".
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=716172f
CACHE=/tmp/regress-cache
BIN=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) BIN="$2"; shift 2;;
    --list) python3 "$ROOT/tools/regress/regress.py" --list; exit 0;;
    *) ARGS+=("$1"); shift;;
  esac
done

lock() {   # mkdir-based lock (macOS has no flock(1)); stale after 20 min
  local d="$1" n=0
  while ! mkdir "$d" 2>/dev/null; do
    if [ -n "$(find "$d" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then rm -rf "$d"; continue; fi
    sleep 3; n=$((n + 1)); [ $n -gt 400 ] && { echo "regress: lock $d timeout"; exit 2; }
  done
}

# 1. baseline binary: the pinned pre-enhancement commit, built once
BASEDIR="$CACHE/baseline-$BASE"
BASEBIN="$BASEDIR/build/release/platoon-headless"
if [ ! -x "$BASEBIN" ]; then
  mkdir -p "$CACHE"; lock "$CACHE/.baseline.lock"
  if [ ! -x "$BASEBIN" ]; then
    echo "regress: building baseline $BASE (once) ..."
    rm -rf "$BASEDIR/src"; mkdir -p "$BASEDIR/src"
    git -C "$ROOT" archive --format=tar "$BASE" port/Package.swift port/Sources | tar -x -C "$BASEDIR/src" || { rmdir "$CACHE/.baseline.lock"; exit 2; }
    mkdir -p "$BASEDIR/src/port/Tests/PlatoonCoreTests"
    echo 'import XCTest' > "$BASEDIR/src/port/Tests/PlatoonCoreTests/Empty.swift"
    ( cd "$BASEDIR/src/port" && swift build -c release --product platoon-headless --scratch-path "$BASEDIR/build" ) > "$BASEDIR/build.log" 2>&1
    [ -x "$BASEBIN" ] || { echo "regress: baseline build failed, see $BASEDIR/build.log"; rmdir "$CACHE/.baseline.lock"; exit 2; }
  fi
  rmdir "$CACHE/.baseline.lock" 2>/dev/null
fi

# 2. binary under test
if [ -z "$BIN" ]; then
  lock /tmp/pbuild-regress.lock
  echo "regress: building the current tree into /tmp/pbuild-regress ..."
  for i in 1 2 3 4 5 6; do
    out=$(cd "$ROOT/port" && swift build -c release --product platoon-headless --scratch-path /tmp/pbuild-regress 2>&1)
    echo "$out" | grep -q "modified during the build" && { sleep 5; continue; }
    break
  done
  rmdir /tmp/pbuild-regress.lock 2>/dev/null
  echo "$out" | grep -E "error:" | head -20
  BIN=/tmp/pbuild-regress/release/platoon-headless
  echo "$out" | grep -q "error:" && { echo "regress: build of the current tree FAILED"; exit 2; }
fi
[ -x "$BIN" ] || { echo "regress: no binary $BIN"; exit 2; }

exec python3 "$ROOT/tools/regress/regress.py" --bin "$BIN" --base-bin "$BASEBIN" "${ARGS[@]+"${ARGS[@]}"}"
