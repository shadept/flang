#!/usr/bin/env bash
# Builds all FLang test scripts using the final compiler binary.
# Usage:
#   ./build-all-tests.sh [--show-progress] [RID]
# Defaults:
#   RID = osx-x64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
cd "$REPO_ROOT"

SHOW_PROGRESS=0
RID="osx-x64"

for arg in "$@"; do
  case "$arg" in
    --show-progress)
      SHOW_PROGRESS=1
      ;;
    *)
      RID="$arg"
      ;;
  esac
done

BUILD_SCRIPT="$REPO_ROOT/build.sh"
if [[ ! -f "$BUILD_SCRIPT" ]]; then
  echo "Build script not found at $BUILD_SCRIPT" >&2
  exit 1
fi

echo "== Building compiler ($RID) =="
"$BUILD_SCRIPT" "$RID"

# Locate flang binary
DIST_DIR="$REPO_ROOT/dist/$RID"
if [[ "$RID" == win* ]]; then
  FLANG="$DIST_DIR/flang.exe"
else
  FLANG="$DIST_DIR/flang"
fi

if [[ ! -f "$FLANG" ]]; then
  echo "Could not find compiler at $FLANG. Please build the final binary first." >&2
  exit 1
fi

# Discover test sources (*.f) under tests/FLang.Tests/Harness
HARNESS_DIR="$REPO_ROOT/tests/FLang.Tests/Harness"
if [[ ! -d "$HARNESS_DIR" ]]; then
  echo "Harness directory not found: $HARNESS_DIR" >&2
  exit 1
fi

# macOS ships an older Bash (3.2) that doesn't provide 'mapfile'.
# Use a portable while-read loop to populate TEST_FILES while preserving sorting.
TEST_FILES=()
while IFS= read -r file; do
  TEST_FILES+=("$file")
done < <(find "$HARNESS_DIR" -type f -name '*.f' | sort)

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo "No .f test files found under $HARNESS_DIR"
  exit 0
fi

echo "Using compiler: $FLANG"
echo "Discovered ${#TEST_FILES[@]} test script(s). Starting build..."

TOTAL=0
PASSED=0
FAILED=0
FAILED_LIST=()

for file in "${TEST_FILES[@]}"; do
  TOTAL=$((TOTAL+1))
  rel="${file#$REPO_ROOT/}"
  if [[ $SHOW_PROGRESS -eq 1 ]]; then
    echo "[BUILD] $rel"
  fi

  firPath="${file%.*}.fir"
  if "$FLANG" "$file" --release --emit-fir "$firPath" > >(cat) 2> >(tee /dev/stderr); then
    PASSED=$((PASSED+1))
    if [[ $SHOW_PROGRESS -eq 1 ]]; then
      echo "[OK]    $rel"
    fi
  else
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$rel")
    echo "[FAIL]  $rel" >&2
  fi
done

echo "Build summary: $PASSED passed, $FAILED failed, $TOTAL total"
exit 0
