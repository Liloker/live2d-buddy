#!/bin/zsh
# One-line installer for Live2D Buddy (macOS 13+, Apple Silicon or Intel):
#
#   curl -fsSL https://raw.githubusercontent.com/Liloker/live2d-buddy/main/install.sh | zsh
#
# Installs the latest release to ~/Applications (or, if there is no release yet,
# builds from source with the Command Line Tools), the `buddy` CLI to
# ~/.local/bin, then downloads the third-party Live2D runtime + demo characters
# (~4 MB, checksum-verified) into ~/Library/Application Support/Live2D Buddy.
# Downloading with curl means no Gatekeeper quarantine prompt for the unsigned app.
set -euo pipefail

repo=${LIVE2D_BUDDY_REPO:-Liloker/live2d-buddy}
prefix=${PREFIX:-$HOME/Applications}
bindir=${BINDIR:-$HOME/.local/bin}
url="https://github.com/$repo/releases/latest/download/Live2D-Buddy-macOS.zip"

[[ $OSTYPE == darwin* ]] || { print -u2 "Live2D Buddy runs on macOS only."; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/live2d-buddy-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

print "→ Downloading $url"
if curl -fsL --retry 2 --connect-timeout 10 -o "$tmp/app.zip" "$url" && ditto -x -k "$tmp/app.zip" "$tmp/release" 2>/dev/null \
   && [[ -d "$tmp/release/Live2D Buddy.app" ]]; then
  built="$tmp/release/Live2D Buddy.app"
else
  print "→ No prebuilt release available — building from source instead"
  xcrun --find swiftc >/dev/null 2>&1 || { print -u2 "Needs the Xcode Command Line Tools first:  xcode-select --install"; exit 1; }
  mkdir -p "$tmp/src"
  curl -fsSL --retry 2 "https://codeload.github.com/$repo/tar.gz/refs/heads/${LIVE2D_BUDDY_REF:-main}" | tar -xz -C "$tmp/src" --strip-components 1
  zsh "$tmp/src/scripts/build.sh"
  built="$tmp/src/build/Live2D Buddy.app"
fi

osascript -e 'tell application id "io.github.liloker.live2dbuddy" to quit' >/dev/null 2>&1 || true
mkdir -p "$prefix" "$bindir"
rm -rf "$prefix/Live2D Buddy.app"
ditto "$built" "$prefix/Live2D Buddy.app"
xattr -dr com.apple.quarantine "$prefix/Live2D Buddy.app" 2>/dev/null || true
install -m 755 "$prefix/Live2D Buddy.app/Contents/Resources/buddy" "$bindir/buddy"

print "→ Fetching the Live2D runtime and demo characters (third-party, not part of this project)"
zsh "$prefix/Live2D Buddy.app/Contents/Resources/fetch-assets.sh" ${LIVE2D_BUDDY_YES:+--yes} || \
  print -u2 "Asset download failed — the app will offer “Get demo characters…” in its menu."

open "$prefix/Live2D Buddy.app"
print "✓ Installed $prefix/Live2D Buddy.app"
print "  Try:  $bindir/buddy say 'hello'"
case ":$PATH:" in *":$bindir:"*) ;; *) print "  (add $bindir to your PATH to type just 'buddy')" ;; esac
