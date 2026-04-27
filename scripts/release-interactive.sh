#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Murmur"
RELEASE_PATHS=(
  "project.yml"
  "Murmur"
  "MurmurTests"
  "Murmur.xcodeproj"
  "scripts"
)

remote_url="$(git remote get-url origin 2>/dev/null || true)"
if [[ "$remote_url" =~ github.com[:/]([^/]+/[^/.]+)(\.git)?/?$ ]]; then
  REPO_SLUG="${BASH_REMATCH[1]}"
else
  REPO_SLUG="Cryptic0011/murmur"
fi

DEFAULT_BRANCH="$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' | head -1)"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
START_BRANCH="$(git branch --show-current)"
CURRENT_VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION: "?([^"]+)"?/\1/p' project.yml | head -1)"
CURRENT_BUILD="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([^"]+)"?/\1/p' project.yml | head -1)"
TEMP_STASH_MESSAGE=""
TEMP_STASH_CREATED=false
TEMP_STASH_RESTORED=false

if [ -z "$START_BRANCH" ]; then
  echo "✗ You are in a detached HEAD state. Switch to a branch before releasing."
  exit 1
fi

if [ -z "$CURRENT_VERSION" ] || [ -z "$CURRENT_BUILD" ]; then
  echo "✗ Could not read version info from project.yml"
  exit 1
fi

prompt() {
  local message="$1"
  local default="${2:-}"
  local answer
  if [ -n "$default" ]; then
    read -r -p "$message [$default]: " answer
    printf '%s\n' "${answer:-$default}"
  else
    read -r -p "$message: " answer
    printf '%s\n' "$answer"
  fi
}

confirm() {
  local message="$1"
  local default="${2:-Y}"
  local suffix="y/N"
  local answer

  if [ "$default" = "Y" ]; then
    suffix="Y/n"
  fi

  read -r -p "$message [$suffix]: " answer
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || {
    echo "✗ Required tool not found: $tool"
    exit 1
  }
}

tracked_release_status() {
  git status --short -- "${RELEASE_PATHS[@]}"
}

print_status_warning() {
  local full_status release_status
  full_status="$(git status --short)"
  release_status="$(tracked_release_status)"

  if [ -n "$full_status" ]; then
    echo ""
    echo "Current git status:"
    printf '%s\n' "$full_status"
  fi

  if [ -n "$full_status" ] && [ "$full_status" != "$release_status" ]; then
    echo ""
    echo "Note: this script only stages release app paths:"
    printf '  %s\n' "${RELEASE_PATHS[@]}"
    echo "Unrelated files, generated assets, .DS_Store files, and sibling worktree files are left alone."
  fi
}

stage_release_paths() {
  git add -- "${RELEASE_PATHS[@]}"
}

ensure_no_release_changes_before_switch() {
  local status
  status="$(tracked_release_status)"
  if [ -n "$status" ]; then
    echo "✗ Release-path changes are still uncommitted:"
    printf '%s\n' "$status"
    echo "Commit or stash them before switching branches."
    exit 1
  fi
}

restore_temp_stash() {
  if [ "$TEMP_STASH_CREATED" != true ] || [ "$TEMP_STASH_RESTORED" = true ]; then
    return
  fi

  echo "→ Restoring temporarily stashed unrelated changes"
  if [ "$(git branch --show-current)" != "$START_BRANCH" ]; then
    git switch "$START_BRANCH"
  fi
  git stash pop
  TEMP_STASH_RESTORED=true
}

on_exit() {
  local code=$?
  trap - EXIT
  if [ "$code" -ne 0 ]; then
    restore_temp_stash || true
  fi
  exit "$code"
}

trap on_exit EXIT

stash_remaining_changes_for_branch_ops() {
  local status
  status="$(git status --short)"
  if [ -z "$status" ]; then
    return
  fi

  echo ""
  echo "Uncommitted changes remain after the release commit:"
  printf '%s\n' "$status"
  echo ""
  echo "These are not being added to the release commit, but git pull/switch may refuse to run while they are present."

  if confirm "Temporarily stash remaining changes until the release finishes?" "Y"; then
    TEMP_STASH_MESSAGE="release-interactive temporary stash before $TAG_NAME"
    git stash push --include-untracked -m "$TEMP_STASH_MESSAGE"
    if git stash list | head -1 | grep -Fq "$TEMP_STASH_MESSAGE"; then
      TEMP_STASH_CREATED=true
    fi
  else
    echo "✗ Cannot safely update $DEFAULT_BRANCH with unrelated dirty files present."
    exit 1
  fi
}

require_tool git
require_tool xcodegen
require_tool xcodebuild
require_tool hdiutil

echo "Murmur GitHub release"
echo "Repository: $REPO_SLUG"
echo "Starting branch: $START_BRANCH"
echo "Default branch: $DEFAULT_BRANCH"
echo "Current version: v$CURRENT_VERSION ($CURRENT_BUILD)"
echo ""

TARGET_VERSION="$(prompt "Release version" "$CURRENT_VERSION")"
if ! [[ "$TARGET_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "✗ Version must look like 1.2 or 1.2.3"
  exit 1
fi

SUGGESTED_BUILD="$CURRENT_BUILD"
if [ "$TARGET_VERSION" != "$CURRENT_VERSION" ]; then
  SUGGESTED_BUILD="$((CURRENT_BUILD + 1))"
fi
TARGET_BUILD="$(prompt "Build number" "$SUGGESTED_BUILD")"
if ! [[ "$TARGET_BUILD" =~ ^[0-9]+$ ]]; then
  echo "✗ Build number must be an integer"
  exit 1
fi

TAG_NAME="v$TARGET_VERSION"
RELEASE_TITLE="$(prompt "Release title" "Murmur $TARGET_VERSION")"
COMMIT_MESSAGE="$(prompt "Commit message" "release: $TAG_NAME")"
RUN_TESTS=$(confirm "Run tests before building?" "Y" && echo true || echo false)
BUILD_DMG=$(confirm "Build a fresh DMG?" "Y" && echo true || echo false)
COMMIT_CHANGES=$(confirm "Commit release app changes on $START_BRANCH?" "Y" && echo true || echo false)
PUSH_BRANCH=$(confirm "Push $START_BRANCH to origin?" "Y" && echo true || echo false)
RELEASE_FROM_MAIN=$(confirm "Switch to $DEFAULT_BRANCH, pull latest, and tag from there?" "Y" && echo true || echo false)
UPLOAD_RELEASE=$(confirm "Create/update GitHub release and upload DMG?" "Y" && echo true || echo false)

RELEASE_DRAFT=false
if [ "$UPLOAD_RELEASE" = true ]; then
  require_tool gh
  RELEASE_DRAFT=$(confirm "Create GitHub release as draft?" "N" && echo true || echo false)
fi

echo ""
echo "Plan"
echo "  Version: $TAG_NAME ($TARGET_BUILD)"
echo "  Start branch: $START_BRANCH"
echo "  Release branch: $([ "$RELEASE_FROM_MAIN" = true ] && echo "$DEFAULT_BRANCH" || echo "$START_BRANCH")"
echo "  Run tests: $RUN_TESTS"
echo "  Build DMG: $BUILD_DMG"
echo "  Commit release paths: $COMMIT_CHANGES"
echo "  Push branch: $PUSH_BRANCH"
echo "  Upload release: $UPLOAD_RELEASE"
if [ "$UPLOAD_RELEASE" = true ]; then
  echo "  Draft release: $RELEASE_DRAFT"
fi
echo ""

print_status_warning
echo ""
confirm "Proceed with this release?" "Y" || exit 0

if [ "$TARGET_VERSION" != "$CURRENT_VERSION" ] || [ "$TARGET_BUILD" != "$CURRENT_BUILD" ]; then
  echo "→ Bumping version to $TARGET_VERSION ($TARGET_BUILD)"
  ./scripts/bump-version.sh "$TARGET_VERSION" "$TARGET_BUILD"
else
  echo "→ Version unchanged"
fi

if [ "$RUN_TESTS" = true ]; then
  echo "→ Running tests"
  xcodebuild test -scheme "$SCHEME" -destination 'platform=macOS'
fi

DMG_PATH="$ROOT/dist/Murmur.dmg"
VERSIONED_DMG_PATH="$ROOT/dist/Murmur-v$TARGET_VERSION.dmg"

if [ "$COMMIT_CHANGES" = true ]; then
  echo "→ Staging release app paths"
  stage_release_paths

  if git diff --cached --quiet; then
    echo "→ No staged release-path changes to commit"
  else
    echo "→ Creating commit: $COMMIT_MESSAGE"
    git commit -m "$COMMIT_MESSAGE"
  fi
fi

if [ "$PUSH_BRANCH" = true ]; then
  echo "→ Pushing $START_BRANCH"
  git push -u origin "$START_BRANCH"
fi

RELEASE_REF="$START_BRANCH"
if [ "$RELEASE_FROM_MAIN" = true ]; then
  ensure_no_release_changes_before_switch
  stash_remaining_changes_for_branch_ops

  if [ "$START_BRANCH" != "$DEFAULT_BRANCH" ]; then
    echo "→ Switching to $DEFAULT_BRANCH"
    git switch "$DEFAULT_BRANCH"
    echo "→ Pulling latest $DEFAULT_BRANCH"
    git pull --ff-only origin "$DEFAULT_BRANCH"
    echo "→ Merging $START_BRANCH into $DEFAULT_BRANCH"
    git merge --no-ff "$START_BRANCH" -m "merge $START_BRANCH for $TAG_NAME"
    echo "→ Pushing $DEFAULT_BRANCH"
    git push origin "$DEFAULT_BRANCH"
  else
    echo "→ Pulling latest $DEFAULT_BRANCH with rebase"
    git pull --rebase origin "$DEFAULT_BRANCH"
    echo "→ Pushing $DEFAULT_BRANCH"
    git push origin "$DEFAULT_BRANCH"
  fi

  RELEASE_REF="$DEFAULT_BRANCH"
fi

if [ "$BUILD_DMG" = true ]; then
  echo "→ Building release DMG"
  ./scripts/build-release-dmg.sh
fi

if [ -n "$(tracked_release_status)" ]; then
  echo "✗ Release-path changes appeared after the release commit:"
  tracked_release_status
  echo "Commit these changes before creating the tag."
  exit 1
fi

if [ "$UPLOAD_RELEASE" = true ] && [ ! -f "$DMG_PATH" ]; then
  echo "✗ Cannot upload release because $DMG_PATH does not exist."
  echo "  Re-run with DMG build enabled, or build it with ./scripts/build-release-dmg.sh."
  exit 1
fi

if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  echo "✗ Local tag $TAG_NAME already exists."
  echo "  Delete it manually if you really need to retag: git tag -d $TAG_NAME"
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
  echo "✗ Remote tag $TAG_NAME already exists on origin."
  exit 1
fi

echo "→ Creating annotated tag $TAG_NAME on $(git branch --show-current)"
git tag -a "$TAG_NAME" -m "$RELEASE_TITLE"

echo "→ Pushing tag $TAG_NAME"
git push origin "$TAG_NAME"

if [ "$UPLOAD_RELEASE" = true ]; then
  mkdir -p "$ROOT/dist"
  RELEASE_NOTES_PATH="$ROOT/dist/release-notes-$TAG_NAME.md"

  if [ ! -f "$RELEASE_NOTES_PATH" ]; then
    cat > "$RELEASE_NOTES_PATH" <<EOF
## $RELEASE_TITLE

- Murmur release $TAG_NAME
- Includes a DMG build for macOS installation.

Download:
https://github.com/$REPO_SLUG/releases/latest/download/Murmur.dmg
EOF
  fi

  if gh release view "$TAG_NAME" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "→ GitHub release already exists; updating notes and assets"
    gh release edit "$TAG_NAME" \
      --repo "$REPO_SLUG" \
      --title "$RELEASE_TITLE" \
      --notes-file "$RELEASE_NOTES_PATH"
    gh release upload "$TAG_NAME" \
      --repo "$REPO_SLUG" \
      "$DMG_PATH" \
      "$VERSIONED_DMG_PATH" \
      --clobber
  else
    echo "→ Creating GitHub release $TAG_NAME"
    GH_ARGS=(
      release create "$TAG_NAME"
      "$DMG_PATH"
      "$VERSIONED_DMG_PATH"
      --repo "$REPO_SLUG"
      --title "$RELEASE_TITLE"
      --notes-file "$RELEASE_NOTES_PATH"
      --target "$RELEASE_REF"
    )
    if [ "$RELEASE_DRAFT" = true ]; then
      GH_ARGS+=(--draft)
    fi
    gh "${GH_ARGS[@]}"
  fi
fi

restore_temp_stash

echo ""
echo "✓ Release workflow complete"
echo "  Version: $TAG_NAME ($TARGET_BUILD)"
echo "  Release branch: $RELEASE_REF"
echo "  Tag: $TAG_NAME"
if [ -f "$DMG_PATH" ]; then
  echo "  DMG: $DMG_PATH"
fi
echo "  GitHub release: https://github.com/$REPO_SLUG/releases/tag/$TAG_NAME"
echo "  Latest DMG URL: https://github.com/$REPO_SLUG/releases/latest/download/Murmur.dmg"
