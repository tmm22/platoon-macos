#!/bin/bash
cd /Users/deborahmangan/Projects/Platoon/port
for i in 1 2 3 4 5 6; do
  out=$(swift build -c release --scratch-path /tmp/pbuild-section0 2>&1)
  if echo "$out" | grep -q "modified during the build"; then sleep 5; continue; fi
  echo "$out" | grep -E "error:" | head -20
  echo "$out" | tail -1
  exit 0
done
echo "build retries exhausted"
