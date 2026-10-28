# Regenerating the demo recordings

`docs/media/demo-*.gif|mp4` are rendered from the real renderer (`web/`) in
headless Chromium, inside a fake desktop (`stage.html`). A paused fake clock
drives every animation, so the output is identical run to run.

```sh
# 1. assets + a static server whose root mixes web/, the assets and the stage
scripts/fetch-assets.sh --yes --dest /tmp/l2d-assets
mkdir -p /tmp/l2d-serve && cd /tmp/l2d-serve
for f in "$OLDPWD"/web/*; do ln -sfn "$f" .; done
ln -sfn /tmp/l2d-assets/live2d.min.js . && ln -sfn /tmp/l2d-assets/models .
ln -sfn "$OLDPWD/docs" docs && ln -sfn "$OLDPWD/docs/demo/stage.html" stage.html
python3 -m http.server 8765 --bind 127.0.0.1 &
cd "$OLDPWD"

# 2. frames (needs `npm i playwright` and a Chromium)
node docs/demo/record.mjs http://127.0.0.1:8765 en /tmp/frames-en
node docs/demo/record.mjs http://127.0.0.1:8765 zh-CN /tmp/frames-zh

# 3. encode
ffmpeg -framerate 25 -i /tmp/frames-en/f%04d.jpg -c:v libx264 -preset veryfast -crf 21 \
  -pix_fmt yuv420p -movflags +faststart docs/media/demo-en.mp4
ffmpeg -framerate 25 -i /tmp/frames-en/f%04d.jpg -vf "fps=12.5,scale=880:-1:flags=lanczos,split[a][b];\
[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  docs/media/demo-en.gif
```

The characters shown are the third-party demo models (© their owners); the
recordings are for illustration only.
