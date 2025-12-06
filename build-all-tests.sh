#!/usr/bin/env bash
# Builds all FLang test scripts using the final compiler binary.
# Usage:
#   ./build-all-tests.sh [--show-progress] [RID]
#   Shows an inline progress bar by default. Pass --show-progress for per-test logs.
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

TOTAL_TESTS=${#TEST_FILES[@]}

echo "Using compiler: $FLANG"
echo "Discovered ${TOTAL_TESTS} test script(s). Starting build..."

render_progress() {
  local current=$1
  local total=$2
  if [[ $total -le 0 ]]; then
    return
  fi

  local width=40
  local percent=$(( current * 100 / total ))
  if (( percent > 100 )); then
    percent=100
  fi

  local filled=$(( current * width / total ))
  if (( filled > width )); then
    filled=$width
  fi
  local empty=$(( width - filled ))

  local filled_bar empty_bar
  printf -v filled_bar '%*s' "$filled" ''
  filled_bar=${filled_bar// /#}
  printf -v empty_bar '%*s' "$empty" ''
  empty_bar=${empty_bar// /-}

  printf "\r[%s%s] %d/%d (%3d%%)" "$filled_bar" "$empty_bar" "$current" "$total" "$percent"
}

clear_progress_line() {
  printf '\r\033[K'
}

TOTAL=0
PASSED=0
FAILED=0
FAILED_LIST=()

render_progress 0 "$TOTAL_TESTS"

for file in "${TEST_FILES[@]}"; do
  rel="${file#$REPO_ROOT/}"
  tmp_output=$(mktemp -t flang-tests.XXXXXX)

  if [[ $SHOW_PROGRESS -eq 1 ]]; then
    clear_progress_line
    echo "[BUILD] $rel"
  fi

  firPath="${file%.*}.fir"
  if "$FLANG" "$file" --release --emit-fir "$firPath" >"$tmp_output" 2>&1; then
    PASSED=$((PASSED+1))
    if [[ -s $tmp_output ]]; then
      clear_progress_line
      cat "$tmp_output"
    fi
    if [[ $SHOW_PROGRESS -eq 1 ]]; then
      clear_progress_line
      echo "[OK]    $rel"
    fi
  else
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$rel")
    clear_progress_line
    cat "$tmp_output"
    echo "[FAIL]  $rel" >&2
  fi

  rm -f "$tmp_output"

  TOTAL=$((TOTAL+1))
  render_progress "$TOTAL" "$TOTAL_TESTS"
done

printf '\n'

echo "Build summary: $PASSED passed, $FAILED failed, $TOTAL total"
exit 0
