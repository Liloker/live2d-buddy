#!/bin/zsh
# fetch-assets.sh — download the third-party Live2D runtime and demo characters.
#
# These files are NOT part of this repository and are not covered by its
# licence. Every file is pinned to an exact upstream revision and verified
# against the SHA-256 in assets/manifest.tsv before it is installed.
#
#   scripts/fetch-assets.sh                 # interactive, installs to the app's data folder
#   scripts/fetch-assets.sh --yes --quiet   # non-interactive
#   scripts/fetch-assets.sh --from "/path/to/old/Contents/Resources/Web"   # offline import
#   scripts/fetch-assets.sh --check         # verify only, no network
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fetch-assets.sh [--dest DIR] [--from DIR] [--only runtime|models] [--check] [--yes] [--quiet]

  --dest DIR   where to install (default: ~/Library/Application Support/Live2D Buddy)
  --from DIR   copy files from a local folder with the same layout instead of downloading
               (e.g. an older app bundle's Contents/Resources/Web); checksums still apply
  --only KIND  only "runtime" (live2d.min.js) or only "models"
  --check      verify what is installed; never downloads (exit 1 if anything is missing)
  --yes, -y    do not ask for confirmation
  --quiet, -q  only print errors

Mirrors are tried in order; override with LIVE2D_BUDDY_MIRRORS="jsdelivr fastly github gcore".
EOF
}

here=${0:A:h}
manifest="$here/manifest.tsv"
[[ -f $manifest ]] || manifest="$here/../assets/manifest.tsv"
[[ -f $manifest ]] || { print -u2 "fetch-assets: manifest.tsv not found next to the script or in ../assets"; exit 66; }

if [[ $OSTYPE == darwin* ]]; then
  dest="$HOME/Library/Application Support/Live2D Buddy"
else
  dest="${XDG_DATA_HOME:-$HOME/.local/share}/live2d-buddy"
fi
from="" only="" check=0 yes=0 quiet=0
while (( $# )); do
  case $1 in
    --dest) dest=$2; shift 2 ;;
    --from) from=${2:A}; shift 2 ;;
    --only) only=$2; shift 2 ;;
    --check) check=1; shift ;;
    -y|--yes) yes=1; shift ;;
    -q|--quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "fetch-assets: unknown option $1"; usage >&2; exit 64 ;;
  esac
done
[[ -z $only || $only == runtime || $only == models ]] || { print -u2 "fetch-assets: --only must be runtime or models"; exit 64; }

say() { (( quiet )) || print -r -- "$@"; }

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | cut -d' ' -f1
  else sha256sum -- "$1" | cut -d' ' -f1; fi
}

# gh:owner/repo@ref:path  ->  candidate URLs, in mirror order
mirror_urls() {
  local spec=${1#gh:}
  local repo=${spec%%@*} rest=${spec#*@}
  local ref=${rest%%:*} p=${rest#*:}
  p=${p// /%20}
  local m
  for m in ${=LIVE2D_BUDDY_MIRRORS:-jsdelivr fastly github gcore}; do
    case $m in
      jsdelivr) print -r -- "https://cdn.jsdelivr.net/gh/$repo@$ref/$p" ;;
      fastly)   print -r -- "https://fastly.jsdelivr.net/gh/$repo@$ref/$p" ;;
      gcore)    print -r -- "https://gcore.jsdelivr.net/gh/$repo@$ref/$p" ;;
      github)   print -r -- "https://raw.githubusercontent.com/$repo/$ref/$p" ;;
    esac
  done
}

# Read the manifest (skip comments / blank lines, honour --only).
typeset -a paths shas srcs
while IFS=$'\t' read -r p s src; do
  [[ -z $p || $p == \#* ]] && continue
  if [[ $only == runtime && $p == models/* ]] || [[ $only == models && $p != models/* ]]; then continue; fi
  paths+=("$p"); shas+=("$s"); srcs+=("$src")
done < "$manifest"
total=${#paths}
(( total > 0 )) || { print -u2 "fetch-assets: nothing to do (empty manifest selection)"; exit 65; }

# Already complete?
missing=0
for i in {1..$total}; do
  f="$dest/${paths[i]}"
  [[ -f $f && $(sha256 "$f") == "${shas[i]}" ]] || (( missing += 1 ))
done
if (( check )); then
  if (( missing )); then say "fetch-assets: $missing of $total files missing or modified in $dest"; exit 1; fi
  say "fetch-assets: all $total files present and verified in $dest"; exit 0
fi
if (( missing == 0 )); then say "fetch-assets: all $total files already installed and verified ($dest)"; exit 0; fi

if (( ! yes )); then
  cat <<'EOF'
This downloads third-party files that are NOT part of Live2D Buddy and are not covered by its licence:

  • live2d.min.js — Live2D Cubism 2 runtime (© Live2D Inc., proprietary), as bundled by
    stevenjoezhang/live2d-widget v0.9.1
  • Two demo characters from github.com/fghrsh/live2d_api — Nepgear (Hyperdimension Neptunia
    © IDEA FACTORY / COMPILE HEART) and Tia (© Potion Maker). Upstream notice: all models are
    copyright of their original authors, for study and personal use only, no commercial use.

About 4 MB. Every file is checked against a pinned SHA-256.
EOF
  if [[ -t 0 ]]; then
    read -r "reply?Continue? [Y/n] "
    [[ -z $reply || $reply == [Yy]* ]] || { print "Cancelled."; exit 2; }
  elif [[ -r /dev/tty ]] && { true </dev/tty; } 2>/dev/null; then
    read -r "reply?Continue? [Y/n] " </dev/tty
    [[ -z $reply || $reply == [Yy]* ]] || { print "Cancelled."; exit 2; }
  fi
fi

# curl does not read the macOS system proxy; borrow it when no proxy env is set.
typeset -a curl_proxy
if [[ $OSTYPE == darwin* && -z ${https_proxy:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-} ]] && command -v scutil >/dev/null; then
  proxy_info=$(scutil --proxy 2>/dev/null || true)
  if [[ $proxy_info == *"HTTPSEnable : 1"* ]]; then
    host=${${proxy_info#*HTTPSProxy : }%%$'\n'*}
    port=${${proxy_info#*HTTPSPort : }%%$'\n'*}
    [[ -n $host && -n $port ]] && curl_proxy=(--proxy "http://$host:$port")
  fi
fi

mkdir -p "$dest"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/live2d-buddy-assets.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

install_file() { # index, verified temp file, origin label
  local target="$dest/${paths[$1]}"
  mkdir -p "${target:h}"
  mv -f "$2" "$target"
  say "[$1/$total] ${paths[$1]} · ok ($3)"
}

# 1. Already installed, or available in --from: no network needed.
typeset -a todo
for i in {1..$total}; do
  p=${paths[i]} want=${shas[i]}
  if [[ -f "$dest/$p" && $(sha256 "$dest/$p") == "$want" ]]; then
    say "[$i/$total] $p · already ok"; continue
  fi
  if [[ -n $from && -f "$from/$p" ]]; then
    cp "$from/$p" "$tmpdir/$i"
    if [[ $(sha256 "$tmpdir/$i") == "$want" ]]; then install_file $i "$tmpdir/$i" "local copy"; continue; fi
  fi
  todo+=($i)
done

# 2. Everything else: one parallel pass over the first mirror …
if (( ${#todo} )); then
  config="$tmpdir/curl.cfg"
  : > "$config"
  for i in $todo; do
    url=${${(f)"$(mirror_urls "${srcs[i]}")"}[1]}
    print -r -- "url = \"$url\"" >> "$config"
    print -r -- "output = \"$tmpdir/$i\"" >> "$config"
  done
  curl -fsSL --parallel --parallel-max 8 --retry 1 --connect-timeout 8 --max-time 120 $curl_proxy -K "$config" 2>/dev/null || true
fi

# 3. … then verify, falling back to the other mirrors one file at a time.
failed=0
for i in $todo; do
  want=${shas[i]} tmp="$tmpdir/$i"
  if [[ -f $tmp && $(sha256 "$tmp") == "$want" ]]; then
    url=${${(f)"$(mirror_urls "${srcs[i]}")"}[1]}
    install_file $i "$tmp" "${${url#https://}%%/*}"; continue
  fi
  got=""
  for url in ${${(f)"$(mirror_urls "${srcs[i]}")"}[2,-1]}; do
    rm -f "$tmp"
    if curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 $curl_proxy -o "$tmp" "$url" 2>/dev/null \
       && [[ $(sha256 "$tmp") == "$want" ]]; then
      got=${${url#https://}%%/*}; break
    fi
  done
  if [[ -n $got ]]; then
    install_file $i "$tmp" "$got"
  else
    print -u2 "[$i/$total] ${paths[i]} · FAILED (no mirror returned a file with the expected checksum)"
    (( failed += 1 ))
  fi
done

cat > "$dest/THIRD-PARTY-ASSETS.txt" <<'EOF'
Files in this folder were downloaded by Live2D Buddy's fetch-assets.sh. They are NOT part of
Live2D Buddy and are not covered by its licence.

live2d.min.js  Live2D Cubism 2 runtime © Live2D Inc. (proprietary), as bundled by
               https://github.com/stevenjoezhang/live2d-widget (v0.9.1, GPL-3.0 for its own code).
models/        Demo characters from https://github.com/fghrsh/live2d_api
               Nepgear — Hyperdimension Neptunia © IDEA FACTORY / COMPILE HEART
               Tia     — © Potion Maker
               Upstream notice: all models are copyright of their original authors, for study and
               personal use only; commercial use is not permitted.

Delete this folder to remove them. Your own models and line packs can live here too.
EOF

if (( failed )); then
  print -u2 "fetch-assets: $failed file(s) failed. Check your network/proxy, or use --from with a local copy."
  exit 1
fi
say "fetch-assets: installed $total files into $dest"
