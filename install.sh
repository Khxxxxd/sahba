#!/bin/bash
# Sahba installer: installs or updates Sahba on Apple silicon Macs (M1 or later) with macOS 14 or newer.
#
#   curl -fsSL https://raw.githubusercontent.com/Khxxxxd/sahba/main/install.sh | bash
#
# What it does:
#   1. checks the Mac (Apple silicon, macOS 14+)
#   2. downloads FFmpeg (for video and audio) from its official builds, checks fingerprint and signature
#   3. downloads Sahba itself, checks its fingerprint, and puts it in ~/Applications
#   4. opens it (an icon appears in the menu bar)
# Running it again updates Sahba. Nothing needs Homebrew or Xcode.
#
# This file is kept plain ASCII on purpose.
set -euo pipefail

VERSION="1.0.0"
ZIP_SHA="bbf0d3b772e9ec4abf59348ebfe6bdbe6ae2fba7cfecd696d48bfd447682de94"
REPO="${SAHBA_REPO:-Khxxxxd/sahba}"
ZIP_URL="${SAHBA_ZIP_URL:-https://github.com/$REPO/releases/download/v$VERSION/Sahba-$VERSION.zip}"

FF_URL="${SAHBA_FF_URL:-https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2}"
FF_SHA="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
FP_SHA="fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"
FF_TEAM="KU3N25YGLU"
MIN_MACOS=14

# Testing hooks: SAHBA_HOME installs under another folder instead of $HOME (and leaves the running
# app alone); SAHBA_NO_OPEN=1 skips opening the app at the end.
BASE="${SAHBA_HOME:-$HOME}"
APPS="$BASE/Applications"
BIN="$BASE/Library/Application Support/Sahba/bin"

# Colours only when printing to a terminal.
if [[ -t 1 ]]; then GREEN=$'\033[32m'; RED=$'\033[31m'; PLAIN=$'\033[0m'; else GREEN=""; RED=""; PLAIN=""; fi
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  %s[ok]%s %s\n' "$GREEN" "$PLAIN" "$*"; }
fail() { printf '\n  %sSahba could not be installed:%s %s\n\n' "$RED" "$PLAIN" "$*" >&2; exit 1; }

echo
echo "  Sahba $VERSION"
echo

# 1. The Mac -----------------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || fail "Sahba is for macOS only."
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]] \
  || fail "Sahba needs a Mac with Apple silicon (M1 or later). Intel Macs are not supported."
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
(( OS_MAJOR >= MIN_MACOS )) || fail "Sahba needs macOS $MIN_MACOS or later. This Mac has macOS $OS_VERSION."
for tool in curl ditto shasum codesign; do
  command -v "$tool" >/dev/null 2>&1 || fail "the system tool '$tool' is missing."
done
ok "Apple silicon, macOS $OS_VERSION"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # source destination; source may be a URL or (for tests) a local path
  if [[ "$1" == /* ]]; then
    cp "$1" "$2"
  else
    curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" || fail "could not download $1"
  fi
}
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# 2. FFmpeg (kept between updates; downloaded again only if the pinned version changes) ------------
install_tool() { # name sha256
  local name="$1" sha="$2" mark="$BIN/.$1.sha256" team
  if [[ -x "$BIN/$name" && -f "$mark" && "$(cat "$mark")" == "$sha" ]]; then
    ok "$name already installed"
    return 0
  fi
  say "downloading $name ..."
  fetch "$FF_URL/$name.zip" "$TMP/$name.zip"
  [[ "$(sha_of "$TMP/$name.zip")" == "$sha" ]] || fail "$name did not match its expected fingerprint."
  mkdir -p "$TMP/$name"
  ditto -x -k "$TMP/$name.zip" "$TMP/$name"
  [[ -f "$TMP/$name/$name" ]] || fail "$name archive did not contain $name."
  team="$(codesign -dv "$TMP/$name/$name" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if ! codesign --verify --strict "$TMP/$name/$name" 2>/dev/null || [[ "$team" != "$FF_TEAM" ]]; then
    fail "$name signature check failed."
  fi
  mkdir -p "$BIN"
  mv -f "$TMP/$name/$name" "$BIN/$name"
  chmod 755 "$BIN/$name"
  printf '%s\n' "$sha" > "$mark"
  ok "$name installed"
}
install_tool ffmpeg "$FF_SHA"
install_tool ffprobe "$FP_SHA"
"$BIN/ffmpeg" -hide_banner -version </dev/null >/dev/null 2>&1 || fail "FFmpeg did not run on this Mac."

# 3. Sahba ---------------------------------------------------------------------------------------
say "downloading Sahba $VERSION ..."
fetch "$ZIP_URL" "$TMP/Sahba.zip"
[[ "$(sha_of "$TMP/Sahba.zip")" == "$ZIP_SHA" ]] || fail "the Sahba download did not match its expected fingerprint."
mkdir -p "$TMP/app"
ditto -x -k "$TMP/Sahba.zip" "$TMP/app"
[[ -d "$TMP/app/Sahba.app" ]] || fail "the download did not contain Sahba.app."
codesign --verify --deep --strict "$TMP/app/Sahba.app" 2>/dev/null || fail "Sahba.app is damaged (signature check failed)."

if [[ -z "${SAHBA_HOME:-}" ]]; then
  # Quit a running copy so it can be replaced.
  pkill -x Sahba 2>/dev/null || true
  for _ in $(seq 50); do pgrep -x Sahba >/dev/null 2>&1 || break; sleep 0.1; done
fi
mkdir -p "$APPS"
rm -rf "$APPS/Sahba.app"
ditto "$TMP/app/Sahba.app" "$APPS/Sahba.app"
xattr -dr com.apple.quarantine "$APPS/Sahba.app" 2>/dev/null || true
INSTALLED="$("$APPS/Sahba.app/Contents/MacOS/Sahba" --version </dev/null 2>/dev/null || true)"
[[ "$INSTALLED" == "$VERSION" ]] || fail "Sahba was copied but does not start (got '$INSTALLED')."
ok "Sahba installed in $APPS"

# 4. Open it -------------------------------------------------------------------------------------
if [[ -z "${SAHBA_NO_OPEN:-}" ]]; then
  open "$APPS/Sahba.app"
  ok "Sahba is running: look for its icon in the menu bar"
fi

echo
echo "  How to use: drag any file, and while dragging press Shift."
echo "  A wheel opens: drop the file on the format you want."
echo "  While the wheel is open, Command shows tools and Control shows actions."
echo
