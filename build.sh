#!/usr/bin/env bash
# Simple build script for FLang — produces Release artifacts and fills ./dist as configured
# Usage:
#   ./build.sh [RID]
# Examples:
#   ./build.sh                # builds for default RID (osx-x64)
#   ./build.sh osx-x64        # builds macOS x64
#   ./build.sh linux-x64      # builds Linux x64 (on a machine/CI that can cross-publish)

set -euo pipefail

# Determine repository root (directory containing this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
cd "$REPO_ROOT"

RID="${1:-osx-x64}"

echo "=== Building FLang.CLI (Release) for RID=$RID ==="
echo

fail() { echo; echo "ERROR: $1" >&2; exit "${2:-1}"; }

# Restore solution packages (explicit)
dotnet restore "flang.sln" -nologo -v minimal || fail "Build failed during 'dotnet restore'. See errors above." $?

# Publish FLang.CLI; the .csproj is configured to produce a single-file, self-contained binary
dotnet publish "src/FLang.CLI/FLang.CLI.csproj" -c Release -r "$RID" -nologo -v minimal || \
  fail "Build failed during 'dotnet publish'. See errors above." $?

DIST_DIR="${REPO_ROOT}/dist/${RID}"

# Compute expected binary name by RID (Windows uses .exe)
if [[ "$RID" == win* ]]; then
  FINAL_EXE="${DIST_DIR}/flang.exe"
else
  FINAL_EXE="${DIST_DIR}/flang"
fi

echo
if [[ -f "$FINAL_EXE" ]]; then
  size=$(stat -f%z "$FINAL_EXE" 2>/dev/null || stat -c%s "$FINAL_EXE")
  echo "Success: ${FINAL_EXE} (${size} bytes)"
  STD_LIB_DIR="${DIST_DIR}/stdlib"
  if [[ -d "$STD_LIB_DIR" ]]; then
    echo "Stdlib copied to: $STD_LIB_DIR"
  else
    echo "Note: stdlib folder not found at $STD_LIB_DIR"
  fi
  echo
  echo "Done."
  exit 0
else
  echo "WARNING: Expected final artifact was not found at $FINAL_EXE" >&2
  echo "The publish may have succeeded, but the post-publish copy step might have been skipped." >&2
  echo "Check the publish logs and the MSBuild target in src/FLang.CLI/FLang.CLI.csproj." >&2
  exit 1
fi
