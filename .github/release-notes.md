### Install

```sh
curl -fsSL https://raw.githubusercontent.com/Liloker/live2d-buddy/main/install.sh | zsh
```

…or download **Live2D-Buddy-macOS.zip** below, move *Live2D Buddy.app* to Applications, open it, then right-click the pet → **Get demo characters…**.

The app is ad-hoc signed, not notarized: if macOS says it cannot be opened, go to **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine "/Applications/Live2D Buddy.app"`. The curl installer avoids this.

### What's inside

- Native AppKit + WKWebView shell (~260 KB binary, universal arm64/x86_64, macOS 13+). No Electron, no background network traffic.
- Cubism 2 renderer: gaze follows the cursor (no Accessibility permission), hover/click reactions, drag to move, resize, click-through on transparent pixels.
- `buddy` CLI + `live2dbuddy://` URL scheme, with ready-made Claude Code and Codex hook recipes (see `docs/agents.md`).
- Characters and the Live2D runtime are **not included** (third-party, personal use only); they are downloaded on demand and verified against pinned SHA-256 checksums.
