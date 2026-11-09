#!/bin/bash
# usage: scripts/mill_retry.sh <mill args...>      (env MILL_LOG=<file>: full output also goes there)
# Runs `mill -i <args>` in the repository root and retries (up to 8 times, sleep i*10 s) only when the dependency
# download fails: Maven Central answers HTTP 429 now and then. Any other failure ends at once. Exit code = mill's.
# Dependencies come from the Google mirror of Maven Central unless COURSIER_REPOSITORIES is already set.
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$ROOT" || exit 255
export COURSIER_REPOSITORIES="${COURSIER_REPOSITORIES:-ivy2Local|https://maven-central.storage-download.googleapis.com/maven2|central}"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
for i in 1 2 3 4 5 6 7 8; do
  mill -i "$@" 2>&1 | tee "$TMP"
  rc=${PIPESTATUS[0]}
  [ -n "$MILL_LOG" ] && cat "$TMP" >> "$MILL_LOG"
  if [ $rc -eq 0 ]; then echo "MILL_OK attempt $i"; exit 0; fi
  if grep -q "response code: 429\|download error" "$TMP"; then
    echo "MILL_RETRY $i: download error, sleeping $((i*10)) s"; sleep $((i*10)); continue
  fi
  echo "MILL_FAIL rc=$rc attempt $i"; exit $rc
done
echo "MILL_FAIL after 8 retries (download errors)"; exit 1
