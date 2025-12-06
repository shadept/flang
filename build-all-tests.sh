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
FILTER=""

IS_WINDOWS=0
UNAME_OUTPUT=$(uname -s 2>/dev/null || printf 'Unknown')
case "$UNAME_OUTPUT" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT*)
    IS_WINDOWS=1
    ;;
  *)
    IS_WINDOWS=0
    ;;
 esac

usage() {
  cat <<'EOF'
Usage: ./build-all-tests.sh [options]
  --show-progress           Print per-test build lines in addition to the progress bar
  --filter <path>.f         Build only the specified test (relative to tests/FLang.Tests/Harness)
  --rid <RID>               Override the target runtime identifier (default: osx-x64)
  --help                    Show this help text

For backward compatibility, specifying a bare RID (without --rid) is still supported.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show-progress)
      SHOW_PROGRESS=1
      shift
      ;;
    --filter=*)
      FILTER="${1#--filter=}"
      shift
      ;;
    --filter)
      if [[ $# -lt 2 ]]; then
        echo "Missing argument for --filter" >&2
        exit 1
      fi
      FILTER="$2"
      shift 2
      ;;
    --rid=*)
      RID="${1#--rid=}"
      shift
      ;;
    --rid)
      if [[ $# -lt 2 ]]; then
        echo "Missing argument for --rid" >&2
        exit 1
      fi
      RID="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      RID="$1"
      shift
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

abspath() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
}

resolve_filter_path() {
  local candidate="$1"
  if [[ -z "$candidate" ]]; then
    return 1
  fi

  local attempts=("$candidate" "$HARNESS_DIR/$candidate" "$REPO_ROOT/$candidate")
  for path in "${attempts[@]}"; do
    if [[ -f "$path" ]]; then
      abspath "$path"
      return 0
    fi
  done

  return 1
}

trim_all() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

normalize_output_file() {
  local src="$1"
  local dest
  dest=$(mktemp -t flang-out.XXXXXX)
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line" >>"$dest"
    fi
  done < "$src"
  echo "$dest"
}

resolve_executable_path() {
  local sourceFile="$1"
  local base="${sourceFile%.*}"

  if [[ $IS_WINDOWS -eq 1 ]]; then
    if [[ -f "${base}.exe" ]]; then
      echo "${base}.exe"
      return 0
    fi
    if [[ -f "$base" ]]; then
      echo "$base"
      return 0
    fi
  else
    if [[ -f "$base" ]]; then
      echo "$base"
      return 0
    fi
    if [[ -f "${base}.exe" ]]; then
      echo "${base}.exe"
      return 0
    fi
  fi

  return 1
}

# macOS ships an older Bash (3.2) that doesn't provide 'mapfile'.
# Use a portable while-read loop to populate TEST_FILES while preserving sorting.
TEST_FILES=()
while IFS= read -r file; do
  TEST_FILES+=("$file")
done < <(find "$HARNESS_DIR" -type f -name '*.f' | sort)

if [[ -n "$FILTER" ]]; then
  if ! FILTER_PATH=$(resolve_filter_path "$FILTER"); then
    echo "Could not locate test matching filter: $FILTER" >&2
    exit 1
  fi

  if [[ "$FILTER_PATH" != "$HARNESS_DIR"* ]]; then
    echo "Filter path must reside under $HARNESS_DIR" >&2
    exit 1
  fi

  TEST_FILES=("$FILTER_PATH")
fi

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
declare -a EXPECTED_COMPILE_ERRORS EXPECTED_STDOUT EXPECTED_STDERR
EXPECTED_COMPILE_ERRORS=()
EXPECTED_STDOUT=()
EXPECTED_STDERR=()
EXPECTED_EXIT_CODE=""
EXPECTED_TEST_NAME=""

parse_metadata() {
  local file="$1"
  EXPECTED_COMPILE_ERRORS=()
  EXPECTED_STDOUT=()
  EXPECTED_STDERR=()
  EXPECTED_EXIT_CODE=""
  EXPECTED_TEST_NAME=""
  while IFS= read -r line; do
    local trimmed="${line#${line%%[![:space:]]*}}"
    [[ $trimmed == //!* ]] || continue
    local content=$(trim_all "${trimmed#//!}")

    case "$content" in
      TEST:*)
        EXPECTED_TEST_NAME=$(trim_all "${content#TEST:}")
        ;;
      EXIT:*)
        EXPECTED_EXIT_CODE=$(trim_all "${content#EXIT:}")
        ;;
      STDOUT:*)
        EXPECTED_STDOUT+=("$(trim_all "${content#STDOUT:}")")
        ;;
      STDERR:*)
        EXPECTED_STDERR+=("$(trim_all "${content#STDERR:}")")
        ;;
      COMPILE-ERROR:*)
        EXPECTED_COMPILE_ERRORS+=("$(trim_all "${content#COMPILE-ERROR:}")")
        ;;
    esac
  done < "$file"
}

render_progress 0 "$TOTAL_TESTS"

for file in "${TEST_FILES[@]}"; do
  rel="${file#$REPO_ROOT/}"
  tmp_output=$(mktemp -t flang-tests.XXXXXX)
  parse_metadata "$file"
  expect_compile_fail=0
  if [[ ${#EXPECTED_COMPILE_ERRORS[@]} -gt 0 ]]; then
    expect_compile_fail=1
  fi

  if [[ $SHOW_PROGRESS -eq 1 ]]; then
    clear_progress_line
    if [[ -n "$EXPECTED_TEST_NAME" ]]; then
      echo "[BUILD] $rel :: $EXPECTED_TEST_NAME"
    else
      echo "[BUILD] $rel"
    fi
  fi

  firPath="${file%.*}.fir"
  compile_succeeded=0
  if "$FLANG" "$file" --release --emit-fir "$firPath" >"$tmp_output" 2>&1; then
    compile_succeeded=1
  fi

  failure_msgs=()
  expected_failure_satisfied=0
  run_stdout=""
  run_stderr=""
  stdout_norm=""
  stderr_norm=""

  if [[ $compile_succeeded -eq 1 ]]; then
    if [[ $expect_compile_fail -eq 1 ]]; then
      failure_msgs+=("Expected compile failure with codes: ${EXPECTED_COMPILE_ERRORS[*]}, but compilation succeeded")
    else
      if [[ -s $tmp_output ]]; then
        clear_progress_line
        cat "$tmp_output"
      fi

      if ! exe_path=$(resolve_executable_path "$file"); then
        failure_msgs+=("FLang.CLI did not produce an executable for $rel")
      else
        run_stdout=$(mktemp -t flang-run-out.XXXXXX)
        run_stderr=$(mktemp -t flang-run-err.XXXXXX)
        set +e
        "$exe_path" >"$run_stdout" 2>"$run_stderr"
        run_exit=$?
        set -e
        stdout_norm=$(normalize_output_file "$run_stdout")
        stderr_norm=$(normalize_output_file "$run_stderr")

        if [[ -n "$EXPECTED_EXIT_CODE" ]]; then
          if [[ "$run_exit" -ne "$EXPECTED_EXIT_CODE" ]]; then
            failure_msgs+=("Expected exit code $EXPECTED_EXIT_CODE but got $run_exit")
          fi
        fi

        if [[ ${#EXPECTED_STDOUT[@]} -gt 0 ]]; then
          for expected_line in "${EXPECTED_STDOUT[@]}"; do
            if ! grep -F -x -q -- "$expected_line" "$stdout_norm" 2>/dev/null; then
              failure_msgs+=("Missing expected STDOUT line: $expected_line")
            fi
          done
        fi

        if [[ ${#EXPECTED_STDERR[@]} -gt 0 ]]; then
          for expected_line in "${EXPECTED_STDERR[@]}"; do
            if ! grep -F -x -q -- "$expected_line" "$stderr_norm" 2>/dev/null; then
              failure_msgs+=("Missing expected STDERR line: $expected_line")
            fi
          done
        fi
      fi
    fi
  else
    if [[ $expect_compile_fail -eq 1 ]]; then
      missing_codes=()
      for code in "${EXPECTED_COMPILE_ERRORS[@]}"; do
        if ! grep -F -q "$code" "$tmp_output"; then
          missing_codes+=("$code")
        fi
      done
      if [[ ${#missing_codes[@]} -eq 0 ]]; then
        expected_failure_satisfied=1
      else
        failure_msgs+=("Missing expected error codes: ${missing_codes[*]}")
      fi
    else
      failure_msgs+=("Compilation failed for $rel")
    fi
  fi

  if [[ ${#failure_msgs[@]} -eq 0 ]]; then
    PASSED=$((PASSED+1))
    if [[ $SHOW_PROGRESS -eq 1 ]]; then
      clear_progress_line
      if [[ $expected_failure_satisfied -eq 1 ]]; then
        echo "[OK]    $rel (expected compile error)"
      else
        echo "[OK]    $rel"
      fi
    fi
  else
    FAILED=$((FAILED+1))
    FAILED_LIST+=("$rel")
    clear_progress_line
    for msg in "${failure_msgs[@]}"; do
      echo "$msg" >&2
    done
    if [[ -s $tmp_output ]]; then
      echo "--- Compiler Output: $rel ---" >&2
      cat "$tmp_output" >&2
    fi
    if [[ -n "$run_stdout" && -s $run_stdout ]]; then
      echo "--- Program STDOUT: $rel ---" >&2
      cat "$run_stdout" >&2
    fi
    if [[ -n "$run_stderr" && -s $run_stderr ]]; then
      echo "--- Program STDERR: $rel ---" >&2
      cat "$run_stderr" >&2
    fi
    echo "[FAIL]  $rel" >&2
  fi

  rm -f "$tmp_output"
  [[ -n "$run_stdout" ]] && rm -f "$run_stdout"
  [[ -n "$run_stderr" ]] && rm -f "$run_stderr"
  [[ -n "$stdout_norm" ]] && rm -f "$stdout_norm"
  [[ -n "$stderr_norm" ]] && rm -f "$stderr_norm"

  TOTAL=$((TOTAL+1))
  render_progress "$TOTAL" "$TOTAL_TESTS"
done

printf '\n'

echo "Build summary: $PASSED passed, $FAILED failed, $TOTAL total"
if [[ $FAILED -gt 0 ]]; then
  if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
    echo "Failed scripts:"
    for f in "${FAILED_LIST[@]}"; do
      echo " - $f"
    done
  fi
  exit 1
fi
exit 0
