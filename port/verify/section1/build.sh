#!/bin/sh
cd /Users/deborahmangan/Projects/Platoon/port
for i in 1 2 3 4 5 6; do
  out=$(swift build -c release --scratch-path /tmp/pbuild-section1 2>&1)
  if echo "$out" | grep -q "Build complete"; then echo "BUILD OK"; exit 0; fi
  if echo "$out" | grep -q "modified during the build"; then sleep 5; continue; fi
  echo "$out" | grep -E "error" | head -20; exit 1
done
echo "BUILD RETRIES EXHAUSTED"; exit 1
