// Records the README demo deterministically: a fake clock drives the pet's
// animations, so every frame is identical run to run regardless of CPU speed.
//
//   node docs/demo/record.mjs http://127.0.0.1:8765 en /tmp/frames-en
//   ffmpeg -framerate 25 -i /tmp/frames-en/f%04d.jpg ... (see docs/demo/README.md)
//
// The server must serve web/ + the fetched assets at its root, plus
// docs/demo/stage.html as /stage.html and docs/ as /docs (see docs/demo/README.md).
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';

const [base = 'http://127.0.0.1:8765', lang = 'en', out = 'frames'] = process.argv.slice(2);
const FPS = 25;
const STEP = 1000 / FPS;
const DURATION = Number(process.env.DURATION) || 20600;
const SWITCH_AT = 10900; // swap Nepgear → Tia
mkdirSync(out, { recursive: true });

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
// Context-level fake clock covers the pet iframe too; paused = time only moves on runFor().
await context.clock.install({ time: new Date('2026-10-28T16:20:00Z') });
await context.clock.pauseAt(new Date('2026-10-28T16:20:01Z')); // freeze before anything schedules timers
const page = await context.newPage();
page.on('pageerror', (e) => console.error('pageerror', e.message));
await page.goto(`${base}/stage.html`);
await page.evaluate((l) => window.stage.setup(l), lang); // loading uses fetch/decode only, no timers
await context.clock.runFor(200);

let switched = false;
for (let f = 0, ms = 0; ms <= DURATION; f++, ms += STEP) {
  await page.evaluate((t) => window.stage.at(t), ms);
  // cross-fade around the character swap
  const dt = ms - SWITCH_AT;
  if (dt > -320 && dt < 0) await page.evaluate((v) => window.stage.fade(v), -dt / 320);
  if (dt >= 0 && !switched) {
    switched = true;
    await page.evaluate(() => window.stage.switchTo('tia', 1.05));
  }
  if (dt >= 0 && dt < 320) await page.evaluate((v) => window.stage.fade(v), dt / 320);
  await context.clock.runFor(STEP);
  await page.screenshot({ path: `${out}/f${String(f).padStart(4, '0')}.jpg`, type: 'jpeg', quality: 94 });
  if (f % 50 === 0) console.log(`frame ${f} (${Math.round(ms)} ms)`);
}
await browser.close();
console.log('done');
