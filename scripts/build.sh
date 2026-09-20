#!/bin/zsh
# Build, run, install, archive or test FindMySyncPlus from the command line.
#
#   scripts/build.sh debug     Build Debug and launch it
#   scripts/build.sh harness   Build Release and install it to /Applications, for tools/harness
#   scripts/build.sh release   Archive Release, export, and write the DMG under Archive/<timestamp>/
#   scripts/build.sh test      Run the test suite
#
# It builds whichever checkout you are standing in. Run from a worktree and the worktree's
# commits are what get built; run from anywhere else and it builds the checkout this script
# lives in. It prints source, branch, version and commit before doing anything, so a build of
# the wrong tree is visible before it is a problem.
#
# Signing comes from Configs/Local.xcconfig (see Configs/Signing.xcconfig). Without that
# file, pass DEVELOPMENT_TEAM=<team id> in the environment.

set -e

SCHEME=FindMySyncPlus
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --- Which source --------------------------------------------------------------------------

SCRIPT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
CWD_REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$CWD_REPO" && -f "$CWD_REPO/FindMySyncPlus.xcodeproj/project.pbxproj" ]]; then
  SRC_DIR="$CWD_REPO"
else
  SRC_DIR="$SCRIPT_REPO"
fi
PROJECT="$SRC_DIR/FindMySyncPlus.xcodeproj"

# --- Where output goes ---------------------------------------------------------------------
#
# One workspace whichever checkout built it. DerivedData stays on a single path because macOS
# keys Local Network grants by app path, and a per-worktree product would add a permanent
# entry each time. The workspace is the directory above the main checkout, which a worktree
# finds through its common git directory. Set FMS_WORKSPACE to put it somewhere else.

COMMON_DIR="$(cd "$SRC_DIR" && git rev-parse --path-format=absolute --git-common-dir)"
MAIN_CHECKOUT="$(dirname "$COMMON_DIR")"
FMS_WORKSPACE="${FMS_WORKSPACE:-$(dirname "$MAIN_CHECKOUT")}"
DERIVED_DATA="$FMS_WORKSPACE/.build/DerivedData"
ARCHIVE="$FMS_WORKSPACE/.build/FindMySyncPlus.xcarchive"
EXPORT_DIR="$FMS_WORKSPACE/Archive/$(date +"%Y-%m-%d_%H-%M-%S")"
EXPORT_OPTIONS="$FMS_WORKSPACE/ExportOptions.plist"
INSTALLED_APP=/Applications/FindMySyncPlus.app

# --- Signing -------------------------------------------------------------------------------
#
# The team lives in Configs/Local.xcconfig, which version control ignores — so a worktree
# has no copy. It is read from the environment, then from the checkout being built, then
# from the main checkout, and passed on the command line so a worktree signs like the main
# checkout does.

team_from() {
  sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$1" 2>/dev/null | head -1
}
TEAM="${DEVELOPMENT_TEAM:-$(team_from "$SRC_DIR/Configs/Local.xcconfig")}"
TEAM="${TEAM:-$(team_from "$MAIN_CHECKOUT/Configs/Local.xcconfig")}"
TEAM_ARGS=()
if [[ -n "$TEAM" ]]; then
  TEAM_ARGS=(DEVELOPMENT_TEAM="$TEAM")
fi

# Codesigning needs the login keychain unlocked, which it is not in an SSH or tmux session.
if ! security show-keychain-info login.keychain-db 2>/dev/null; then
  echo "==> Keychain locked — unlocking for codesign..."
  security unlock-keychain login.keychain-db
fi

# --- What is being built -------------------------------------------------------------------
#
# The commit goes into the About window through the GIT_COMMIT build setting, which
# Info.plist substitutes. It is passed in rather than read by a build phase: user script
# sandboxing is on, and in a worktree the real git directory sits outside SRCROOT, so a
# script phase could not reach git anyway. A trailing + means the tree was dirty.

GIT_COMMIT="$(cd "$SRC_DIR" && git rev-parse --short HEAD 2>/dev/null || true)"
if [[ -n "$GIT_COMMIT" ]] && ! (cd "$SRC_DIR" && git diff --quiet HEAD 2>/dev/null); then
  GIT_COMMIT="${GIT_COMMIT}+"
fi

echo "==> source:  $PROJECT"
echo "==> branch:  $(cd "$SRC_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo "==> version: $(grep -m1 MARKETING_VERSION "$PROJECT/project.pbxproj" | tr -d ' \t;' | cut -d= -f2)"
echo "==> commit:  ${GIT_COMMIT:-unknown}"
echo "==> output:  $FMS_WORKSPACE/.build"
echo "==> team:    ${TEAM:-(none — Xcode's automatic signing will ask)}"

build() {
  local configuration="$1"; shift
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${TEAM_ARGS[@]}" \
    GIT_COMMIT="$GIT_COMMIT" \
    "$@"
}

stamped_commit() {
  /usr/libexec/PlistBuddy -c "Print :GitCommit" "$1/Contents/Info.plist" 2>/dev/null || echo "(none)"
}

case "${1:-debug}" in
  debug)
    echo "==> Building Debug..."
    build Debug build
    APP="$DERIVED_DATA/Build/Products/Debug/FindMySyncPlus.app"
    echo "==> Done: $APP (About will say $(stamped_commit "$APP"))"
    echo "==> Launching..."
    pkill -x FindMySyncPlus 2>/dev/null || true
    sleep 1
    open "$APP"
    ;;

  harness)
    # The harness runs whatever is installed at /Applications, and it has to be a Release
    # build: the suite guards the artifact users get. The rm -rf is not optional — copying
    # over an existing bundle leaves macOS running the cached old binary.
    echo "==> Building Release..."
    build Release build
    APP="$DERIVED_DATA/Build/Products/Release/FindMySyncPlus.app"
    echo "==> Installing to $INSTALLED_APP..."
    pkill -x FindMySyncPlus 2>/dev/null || true
    rm -rf "$INSTALLED_APP"
    cp -R "$APP" "$INSTALLED_APP"
    echo "==> Installed: $INSTALLED_APP (About will say $(stamped_commit "$INSTALLED_APP"))"
    ;;

  release)
    echo "==> Archiving Release..."
    build Release -archivePath "$ARCHIVE" archive

    if [[ ! -f "$EXPORT_OPTIONS" ]]; then
      if [[ -z "$TEAM" ]]; then
        echo "error: no $EXPORT_OPTIONS and no team id to write one from" >&2
        exit 1
      fi
      EXPORT_OPTIONS="$FMS_WORKSPACE/.build/ExportOptions.plist"
      mkdir -p "$FMS_WORKSPACE/.build"
      cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>debugging</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST
      echo "==> Wrote $EXPORT_OPTIONS for team $TEAM"
    fi

    echo "==> Exporting to $EXPORT_DIR..."
    xcodebuild \
      -exportArchive \
      -archivePath "$ARCHIVE" \
      -exportPath "$EXPORT_DIR" \
      -exportOptionsPlist "$EXPORT_OPTIONS"
    APP="$EXPORT_DIR/FindMySyncPlus.app"
    echo "==> Exported: $APP (About will say $(stamped_commit "$APP"))"

    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
    DMG_NAME="FindMySyncPlus-${VERSION}.dmg"
    DMG_PATH="$EXPORT_DIR/$DMG_NAME"
    DMG_TEMP="$FMS_WORKSPACE/.build/dmg-staging"

    echo "==> Creating DMG: $DMG_NAME..."
    rm -rf "$DMG_TEMP"
    mkdir -p "$DMG_TEMP"
    cp -R "$APP" "$DMG_TEMP/"
    ln -s /Applications "$DMG_TEMP/Applications"

    hdiutil create \
      -volname "FindMySyncPlus" \
      -srcfolder "$DMG_TEMP" \
      -ov \
      -format UDZO \
      "$DMG_PATH"

    rm -rf "$DMG_TEMP"
    echo "==> Done: $DMG_PATH"
    ;;

  test)
    # Not -quiet: it suppresses the TEST SUCCEEDED banner while still printing TEST FAILED,
    # so a green run reads as having produced no verdict.
    echo "==> Testing..."
    build Debug test
    ;;

  *)
    echo "Usage: $0 [debug|harness|release|test]" >&2
    exit 1
    ;;
esac
