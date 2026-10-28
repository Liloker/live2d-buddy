#!/bin/zsh
# build.sh — compile the app shell into build/Live2D Buddy.app (Xcode or Command Line Tools).
#
#   scripts/build.sh                      # native architecture
#   ARCHS="arm64 x86_64" scripts/build.sh # universal binary (used for releases)
#
# The bundle contains only this project's code. The Live2D runtime and the
# characters live in ~/Library/Application Support/Live2D Buddy and are fetched
# separately (scripts/fetch-assets.sh, or the app menu "Get demo characters…").
set -euo pipefail
root=${0:A:h:h}
version=$(<"$root/VERSION")
build=${BUILD_NUMBER:-$(git -C "$root" rev-list --count HEAD 2>/dev/null || print 1)}
app="$root/build/Live2D Buddy.app"
archs=(${=ARCHS:-$(uname -m)})
cache="${TMPDIR:-/tmp}/live2d-buddy-module-cache"

command -v xcrun >/dev/null || { print -u2 "build: xcrun not found — install Xcode Command Line Tools: xcode-select --install"; exit 1; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Web"

binaries=()
for arch in $archs; do
  out="$root/build/Live2DBuddy-$arch"
  xcrun swiftc "$root/app/main.swift" -O -target "$arch-apple-macos13.0" \
    -framework AppKit -framework WebKit -module-cache-path "$cache" -o "$out"
  binaries+=("$out")
done
lipo -create $binaries -output "$app/Contents/MacOS/Live2DBuddy"
rm -f $binaries

sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" "$root/app/Info.plist" > "$app/Contents/Info.plist"
cp "$root/app/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp -R "$root/web/." "$app/Contents/Resources/Web/"
cp "$root/scripts/fetch-assets.sh" "$root/assets/manifest.tsv" "$root/bin/buddy" "$app/Contents/Resources/"
codesign --force --sign - "$app" >/dev/null 2>&1 || print -u2 "build: ad-hoc codesign failed (the app still runs locally)"

print "Built $app ($version, ${(j:+:)archs})"
