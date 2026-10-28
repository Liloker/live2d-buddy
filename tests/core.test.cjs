// Unit tests for web/core.js — run with `make test` (Node.js ≥ 18, no dependencies).
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const C = require('../web/core.js');

const root = path.join(__dirname, '..');
const readJSON = (p) => JSON.parse(fs.readFileSync(path.join(root, p), 'utf8'));

// Motion parsing and interpolation
const m = C.parseMotion('$fps=30\nPARAM_ANGLE_X=0,10,20\n#comment\nPARAM_BAD=x');
assert.equal(m.fps, 30);
assert.equal(C.sample(m.tracks.PARAM_ANGLE_X, 0.5), 5);
assert.equal(C.sample(m.tracks.PARAM_ANGLE_X, 100), 20);
assert.equal(m.tracks.PARAM_BAD, undefined);
assert.equal(m.length, 3);
console.log('PASS motion parsing / interpolation');

// Frame-rate independent smoothing and proportional fit
assert.ok(C.follow(0, 1, 1 / 60) > 0 && C.follow(0, 1, 1 / 60) < 1);
assert.ok(Math.abs(C.follow(C.follow(0, 1, 1 / 60), 1, 1 / 60) - C.follow(0, 1, 1 / 30)) < 1e-9);
const r = C.fit(1000, 2000, 500, 600, 20);
assert.ok(r.width <= 460 && r.height <= 560);
assert.equal(r.height / r.width, 2);
console.log('PASS frame-rate independent smoothing, proportional fit');

// Hit regions come from characters.json and are size independent
const chars = readJSON('web/characters.json');
const byId = Object.fromEntries(chars.characters.map((c) => [c.id, c]));
const rect = { x: 100, y: 100, width: 100, height: 400 };
assert.equal(C.hitRegion(byId.nepgear.regions, 150, 130, rect), 'head');
assert.equal(C.hitRegion(byId.nepgear.regions, 150, 280, rect), 'upper');
assert.equal(C.hitRegion(byId.nepgear.regions, 150, 450, rect), 'other');
assert.equal(C.hitRegion(byId.nepgear.regions, 90, 120, rect), null);
assert.equal(C.hitRegion(byId.nepgear.regions, 300, 260, { x: 200, y: 200, width: 200, height: 800 }), 'head');
assert.equal(C.hitRegion(byId.tia.regions, 150, 280, rect), 'head'); // Tia's head band is taller (50%)
assert.equal(C.hitRegion(byId.tia.regions, 150, 380, rect), 'upper');
assert.equal(C.hitRegion(undefined, 150, 130, rect), 'head'); // defaults
// The smoke test taps at 15% and 58% of the artwork: must be head / upper for every character.
for (const c of chars.characters) {
  assert.equal(C.hitRegion(c.regions, 150, 100 + 400 * 0.15, rect), 'head', c.id);
  assert.equal(C.hitRegion(c.regions, 150, 100 + 400 * 0.58, rect), 'upper', c.id);
}
console.log('PASS hit regions per character, size independent');

// Motion selection mirrors the original Tia behaviour: Touch1–3 only for the upper body
const tiaMotions = {
  tap_body: ['Sukebei1', 'Sukebei2', 'Touch1', 'Touch2', 'Touch3', 'Touch4', 'Touch Dere1'].map((n) => ({ file: `motions/${n}.mtn` })),
  flick_head: [{ file: 'motions/Touch Dere1.mtn' }, { file: 'motions/Touch Dere2.mtn' }],
};
assert.deepEqual(C.selectMotions(tiaMotions, byId.tia.motions.upper).map((x) => x.file),
  ['motions/Touch1.mtn', 'motions/Touch2.mtn', 'motions/Touch3.mtn']);
assert.equal(C.selectMotions(tiaMotions, byId.tia.motions.head).length, 2);
assert.deepEqual(C.selectMotions({ idle: [] }, byId.nepgear.motions.head), []); // Nepgear has no tap groups
assert.deepEqual(C.selectMotions(undefined, { group: 'x' }), []);
console.log('PASS motion group selection');

// Lines: every click / hover line reachable, all packs well-formed
const zh = readJSON('web/lines/zh-CN.json');
const en = readJSON('web/lines/en.json');
assert.equal(C.pick(zh.click, () => 0), '是…是不小心碰到了吧…');
assert.equal(new Set(Array.from({ length: zh.click.length }, (_, i) => C.pick(zh.click, () => i / zh.click.length))).size, 7);
assert.equal(new Set(Array.from({ length: zh.hover.length }, (_, i) => C.pick(zh.hover, () => i / zh.hover.length))).size, 10);
assert.equal(C.pick([], Math.random), '');
for (const pack of [zh, en]) {
  for (const key of ['click', 'hover', 'idle']) assert.ok(pack[key].length > 0, key);
  for (const key of ['done', 'attention', 'error', 'thinking']) assert.ok(pack.agent[key].length > 0, key);
  assert.ok(pack.menuSay);
}
assert.equal(C.hoverEntry(false, true), true);
assert.equal(C.hoverEntry(true, true), false);
assert.equal(C.hoverEntry(true, false), false);
console.log('PASS line packs: all 7 click and 10 hover lines reachable');

// Language fallback and localisation
assert.deepEqual(C.lineCandidates('zh-Hans-CN'), ['zh-Hans-CN', 'zh-CN', 'zh', 'en']);
assert.deepEqual(C.lineCandidates('en-US'), ['en-US', 'en']);
assert.equal(C.localized({ zh: '你好', en: 'Hi' }, 'zh-CN'), '你好');
assert.equal(C.localized({ zh: '你好', en: 'Hi' }, 'fr-FR'), 'Hi');
assert.equal(C.localized('plain', 'en'), 'plain');
assert.equal(C.localized(undefined, 'en'), '');
console.log('PASS language fallback');

// Agent events map to reactions
assert.equal(C.reactionFor('done'), 'success');
assert.equal(C.reactionFor('error'), 'fail');
assert.equal(C.reactionFor('attention'), 'attention');
assert.equal(C.reactionFor('nope'), 'head');
console.log('PASS agent event mapping');

// Artwork bounds from an alpha mask
const w = 10, h = 8, px = new Uint8Array(w * h * 4);
for (let y = 2; y <= 5; y++) for (let x = 3; x <= 7; x++) px[(y * w + x) * 4 + 3] = 255;
assert.deepEqual(C.alphaBounds(px, w, h), { x0: 3, y0: 2, x1: 7, y1: 5 });
assert.equal(C.alphaBounds(new Uint8Array(w * h * 4), w, h), null);
const b = C.frameBounds({ x0: 3, y0: 2, x1: 7, y1: 5 }, w, h);
assert.ok(Math.abs(b.rw - 0.4) < 1e-9 && Math.abs(b.cx - 0) < 1e-9);
console.log('PASS artwork bounds');

// Manifest: every model path referenced by characters.json is fetched, checksums well-formed
const manifest = fs.readFileSync(path.join(root, 'assets/manifest.tsv'), 'utf8')
  .split('\n').filter((l) => l && !l.startsWith('#')).map((l) => l.split('\t'));
assert.ok(manifest.every((cols) => cols.length === 3 && /^[0-9a-f]{64}$/.test(cols[1]) && cols[2].startsWith('gh:')));
const fetched = new Set(manifest.map((cols) => cols[0]));
assert.ok(fetched.has('live2d.min.js'));
for (const c of chars.characters) {
  assert.ok(fetched.has(c.model + 'index.json'), c.id + ' index.json in manifest');
  for (const file of Object.values(c.reactions)) assert.ok(fetched.has(c.model + file), file);
}
console.log('PASS asset manifest covers every configured character');
