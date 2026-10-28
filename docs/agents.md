# Let your agents drive the pet

Live2D Buddy does not embed an AI. It exposes three tiny, dependency-free
control surfaces so that *any* agent — Claude Code, Codex, Cursor, a cron job,
a CI script — can make the pet react. Pick the lowest layer that does the job.

```
anything that can open a URL ──► live2dbuddy://say?text=…  ──► running pet
anything that can run a shell ──► buddy say "…"           ──┘   (no network, no ports)
agent lifecycle hooks         ──► buddy hook claude|codex ──┘
```

## 1. The `buddy` CLI

Installed to `~/.local/bin/buddy` by `make install` / `install.sh` (it is just a
wrapper around the app binary's `--cli` mode).

| Command | Effect |
| --- | --- |
| `buddy say <text…> [--duration SEC]` | Speech bubble (shown even when random bubbles are off) |
| `buddy react [tap\|success\|fail\|attention\|thinking]` | Motion only, no text |
| `buddy event <done\|attention\|error\|thinking> [message…]` | Motion + a line from the active line pack (or your message) |
| `buddy character <id>` | Switch character (`nepgear`, `tia`, or your own) |
| `buddy show` / `buddy hide` / `buddy start` / `buddy status` | Visibility / launch / is it running? |
| `buddy hook claude [--preview]` | Read a Claude Code hook payload from stdin |
| `buddy hook codex <json> [--preview]` | Handle a Codex `notify` payload |

Flags: `--launch` starts the pet if it is not running (otherwise commands are
silently ignored, exit 0 — hooks never fail your agent); `--dry-run` prints the
URL instead of sending it.

**Privacy by default.** Hook events show generic lines ("All done! Come take a
look ✨"), never your prompt, code or the agent's reply — handy when screen
sharing. `--preview` opts in to showing the first ~120 characters of the
agent's last message.

## 2. Claude Code

Add to `~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "$HOME/.local/bin/buddy hook claude", "async": true }] }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [{ "type": "command", "command": "$HOME/.local/bin/buddy hook claude", "async": true }]
      }
    ]
  }
}
```

| Hook event | Pet event |
| --- | --- |
| `Stop` | `done` — success motion + "All done!" |
| `Notification`, `PermissionRequest` | `attention` — alert motion + "Waiting for your approval~" |
| `StopFailure` | `error` |
| `UserPromptSubmit` (optional, chatty) | `thinking` |

Hook reference: <https://code.claude.com/docs/en/hooks>

## 3. Codex CLI

In `~/.codex/config.toml` (Codex passes the event JSON as the last argument;
use an absolute path because `notify` is not run through a shell):

```toml
notify = ["/Users/YOU/.local/bin/buddy", "hook", "codex"]
```

`agent-turn-complete` → `done`. Codex also supports lifecycle hooks
(`~/.codex/hooks.json`); any hook can simply call `buddy event attention`, etc.
Config reference: <https://developers.openai.com/codex/config-advanced>

## 4. Everything else

```sh
npm test && buddy event done || buddy event error      # any long task
buddy say "Deploy finished 🚀" --duration 10
open -g "live2dbuddy://event?name=attention"           # Raycast, Shortcuts, Alfred, Keyboard Maestro…
```

### URL scheme reference

| URL | Parameters |
| --- | --- |
| `live2dbuddy://say` | `text` (≤280 chars), `duration` (1–60 s, default 6.5) |
| `live2dbuddy://react` | `kind` = `tap` \| `success` \| `fail` \| `attention` \| `thinking` |
| `live2dbuddy://event` | `name` = `done` \| `attention` \| `error` \| `thinking`, optional `message` |
| `live2dbuddy://character` | `id` |
| `live2dbuddy://show`, `live2dbuddy://hide` | — |

Commands that arrive while a character is still loading are queued (up to 20).

## Why hooks + CLI before MCP

*Status* is something the agent harness already knows deterministically:
hooks fire every time, cost zero tokens and cannot be "forgotten" by the
model. An MCP tool, by contrast, adds its schema to every request and only runs
when the model decides to call it — great for *expressive* moments ("celebrate
when the flaky test finally passes", "say the summary out loud"), wasteful for
"I'm done". So the order is:

1. ✅ CLI + URL scheme + hook recipes (this release)
2. ⏳ `buddy-mcp`: a ~60-line stdio MCP server exposing `pet_say`, `pet_react`,
   `pet_event`, `pet_set_character`, implemented on top of the `buddy` CLI — the
   app itself stays dumb, offline and dependency-free
3. ⏳ Optional local socket (`~/Library/Application Support/Live2D Buddy/buddy.sock`)
   if two-way state (e.g. "is the pet visible?", click-to-approve) is ever needed

If you build one of these, please open a PR.
