# Bring your own model

Live2D Buddy renders **Cubism 2** models (`.moc` + `.mtn` + a JSON model
definition). Cubism 3/4/5 (`.moc3`) support is on the roadmap.

Everything user-provided lives in the data folder — right-click the pet →
**Open assets folder**, or:

```sh
open ~/Library/Application\ Support/Live2D\ Buddy
```

## 1. Copy the model

```
~/Library/Application Support/Live2D Buddy/
├── characters.json        ← your copy (overrides the built-in one)
├── lines/en.json          ← optional: your own lines
└── models/
    └── my-character/
        ├── my-character.model.json
        ├── my-character.moc
        ├── textures/…
        └── motions/…
```

## 2. Register it in `characters.json`

Start from the built-in file:

```sh
cp "/Applications/Live2D Buddy.app/Contents/Resources/Web/characters.json" \
   ~/Library/Application\ Support/Live2D\ Buddy/      # or ~/Applications/…
```

and append an entry:

```json
{
  "id": "mine",
  "name": { "en": "My character", "zh": "我的角色" },
  "model": "models/my-character/",
  "config": "my-character.model.json",
  "windowAspect": 0.9,
  "regions": { "head": 0.35, "upper": 0.65 },
  "motions": { "head": { "group": "flick_head" }, "upper": { "group": "tap_body" } },
  "reactions": { "success": "motions/happy.mtn", "fail": "motions/sad.mtn" },
  "greeting": { "en": "Hello!", "zh": "你好！" }
}
```

| Field | Meaning |
| --- | --- |
| `id` | Used by the menu, `buddy character <id>` and preferences |
| `name` | Menu label; a string or `{ "en": …, "zh": … }` |
| `model` | Folder relative to the data folder (ends with `/`) |
| `config` | Model definition file inside that folder (default `index.json`) |
| `windowAspect` | Window width ÷ (height − 70). ~0.8 for full-body, ~1.05 for wide characters |
| `regions` | Proportional click bands from the top of the visible artwork |
| `motions.head` / `motions.upper` | Motion groups from the model definition played on click; optional `match` (regex) and `limit` |
| `reactions` | Optional motions for agent events: `success`, `fail`, `attention`, `thinking` |
| `greeting` | Said when the character appears |

Quit and reopen the pet (or pick the character from the menu). If something is
off, run the app from Terminal to see errors:

```sh
"$HOME/Applications/Live2D Buddy.app/Contents/MacOS/Live2DBuddy" --smoke-test
```

## Lines

Copy `Resources/Web/lines/en.json` (or `zh-CN.json`) into
`~/Library/Application Support/Live2D Buddy/lines/` and edit `click`, `hover`,
`idle` and the `agent` pools. The language follows macOS's preferred language.

## Licensing

Only use models you have the right to use — most Live2D models are licensed
for personal use only, and redistribution is usually forbidden. Keep your
models in the data folder; never commit them to a public fork of this
repository.
