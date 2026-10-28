# Third-party notices

Live2D Buddy's own code and artwork are MIT-licensed (see `LICENSE`). The items
below are **not** covered by that licence.

## Not included — downloaded on your machine by `scripts/fetch-assets.sh`

Nothing in this section is stored in this repository or in release archives.
The script pins each file to an exact upstream revision and verifies its
SHA-256 (`assets/manifest.tsv`) before installing it into
`~/Library/Application Support/Live2D Buddy/`.

| File(s) | Source | Rights |
| --- | --- | --- |
| `live2d.min.js` | [stevenjoezhang/live2d-widget](https://github.com/stevenjoezhang/live2d-widget) tag `v0.9.1` | Contains the **Live2D Cubism 2.1 Core** © Live2D Inc., under the [Live2D SDK License Agreement (Public)](https://docs.google.com/document/d/10tz1WrycskzGGBOhrAfGiTSsgmyFy8D9yHx9r_PsN8I/); the surrounding widget code is GPL-3.0. |
| `models/HyperdimensionNeptunia/…` (Nepgear) | [fghrsh/live2d_api](https://github.com/fghrsh/live2d_api) @ `02dc5b3` | Hyperdimension Neptunia © IDEA FACTORY / COMPILE HEART. |
| `models/Potion-Maker/Tia/…` (Tia) | [fghrsh/live2d_api](https://github.com/fghrsh/live2d_api) @ `02dc5b3` | © Potion Maker. |

fghrsh/live2d_api's MIT licence covers its API code only. Its README states:
*"API 内所有模型 版权均属于原作者，仅供研究学习，不得用于商业用途"* — all models
are copyright of their original authors, for study only, no commercial use.
Respect that when you use or share anything built with these characters.

If you are a rights holder and want the demo download removed, please open an
issue — it is one line in `assets/manifest.tsv`.

## Included in this repository

| File | Origin | Licence |
| --- | --- | --- |
| `web/lines/zh-CN.json` (`click`, `hover` lines) | Adapted from `waifu-tips.json` in [live2d-widget](https://github.com/stevenjoezhang/live2d-widget) (stevenjoezhang, fghrsh) | GPL-3.0 — this data file is therefore distributed under GPL-3.0; all other lines in it are original. |
| `app/AppIcon.icns`, `docs/media/*` | Original to this project | MIT. Screenshots and demo recordings show the third-party demo characters for illustration only; they remain © their owners. |
