#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <marketing-version> [build-number]"
  echo "Example: $0 0.2.0 2"
  exit 1
fi

VERSION="$1"
BUILD="${2:-}"
PROJECT_FILE="$ROOT/project.yml"

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "✗ Version must look like 1.2 or 1.2.3"
  exit 1
fi

if [ -z "$BUILD" ]; then
  CURRENT_BUILD="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' "$PROJECT_FILE" | head -1)"
  if [ -z "$CURRENT_BUILD" ]; then
    echo "✗ Could not read CURRENT_PROJECT_VERSION from project.yml"
    exit 1
  fi
  BUILD="$((CURRENT_BUILD + 1))"
fi

if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "✗ Build number must be an integer"
  exit 1
fi

python3 - <<'PY' "$PROJECT_FILE" "$VERSION" "$BUILD"
from pathlib import Path
import re
import sys

project_file = Path(sys.argv[1])
version = sys.argv[2]
build = sys.argv[3]
text = project_file.read_text()

text, version_count = re.subn(
    r'(^\s*MARKETING_VERSION:\s*)".*?"(\s*$)|(^\s*MARKETING_VERSION:\s*)[^\n]+',
    lambda m: (m.group(1) or m.group(3)) + f'"{version}"',
    text,
    flags=re.MULTILINE,
)
text, build_count = re.subn(
    r'(^\s*CURRENT_PROJECT_VERSION:\s*)".*?"(\s*$)|(^\s*CURRENT_PROJECT_VERSION:\s*)[^\n]+',
    lambda m: (m.group(1) or m.group(3)) + f'"{build}"',
    text,
    flags=re.MULTILINE,
)

if version_count != 1 or build_count != 1:
    raise SystemExit("Failed to update version fields in project.yml")

project_file.write_text(text)
PY

echo "→ Updated project.yml"
echo "  MARKETING_VERSION=$VERSION"
echo "  CURRENT_PROJECT_VERSION=$BUILD"

echo "→ Regenerating Xcode project"
xcodegen generate >/dev/null

echo "✓ Version bump complete"
