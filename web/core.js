/*
 * Live2D Buddy — pure helpers shared by the renderer (pet.js) and the unit
 * tests (tests/core.test.cjs). No DOM, no WebGL, no globals besides the export.
 */
(function (root) {
  'use strict';

  /** Parse a Cubism 2 `.mtn` motion file into per-parameter keyframe tracks. */
  function parseMotion(text) {
    const tracks = {};
    let fps = 30;
    for (const line of text.split(/[\r\n]+/)) {
      const f = line.match(/^\$fps=([\d.]+)/);
      if (f) fps = +f[1] || 30;
      const m = line.match(/^(PARAM_[^=]+)=(.*)$/);
      if (m) {
        const values = m[2].split(',').map(Number);
        if (values.length && values.every(Number.isFinite)) tracks[m[1]] = values;
      }
    }
    const length = Math.max(1, ...Object.values(tracks).map((v) => v.length));
    return { fps, tracks, length };
  }

  /** Linear interpolation inside a keyframe track at fractional frame `p`. */
  function sample(values, p) {
    p = Math.max(0, Math.min(values.length - 1, p));
    const i = Math.floor(p);
    const a = p - i;
    return values[i] * (1 - a) + values[Math.min(i + 1, values.length - 1)] * a;
  }

  /** Frame-rate independent exponential smoothing toward `target`. */
  function follow(value, target, dt) {
    return value + (target - value) * (1 - Math.exp(-10 * dt));
  }

  /** Scale a w×h box to fit inside cw×ch with padding, keeping the ratio. */
  function fit(w, h, cw, ch, pad = 16) {
    const s = Math.min((cw - 2 * pad) / w, (ch - 2 * pad) / h);
    return { width: w * s, height: h * s };
  }

  /**
   * Map a point inside the visible artwork to 'head' | 'upper' | 'other'
   * (or null when outside). `regions` holds proportional thresholds measured
   * from the top of the artwork, e.g. { head: 0.34, upper: 0.62 }.
   */
  function hitRegion(regions, x, y, rect) {
    if (x < rect.x || x > rect.x + rect.width || y < rect.y || y > rect.y + rect.height) return null;
    const v = (y - rect.y) / rect.height;
    const head = regions && Number.isFinite(regions.head) ? regions.head : 0.34;
    const upper = regions && Number.isFinite(regions.upper) ? regions.upper : 0.62;
    return v < head ? 'head' : v < upper ? 'upper' : 'other';
  }

  /** Pick a random entry from a pool ('' when the pool is empty). */
  function pick(pool, random = Math.random) {
    if (!Array.isArray(pool) || pool.length === 0) return '';
    return pool[Math.min(pool.length - 1, Math.floor(random() * pool.length))];
  }

  /** True only on the frame the pointer enters the artwork. */
  function hoverEntry(previous, current) {
    return !previous && current;
  }

  /**
   * Select motion entries from a model's index.json `motions` table.
   * spec: { group: 'tap_body', match: '/Touch[1-6]\\.mtn$', limit: 3 }
   */
  function selectMotions(motions, spec) {
    if (!motions || !spec || !spec.group) return [];
    let list = Array.isArray(motions[spec.group]) ? motions[spec.group] : [];
    if (spec.match) {
      const re = new RegExp(spec.match);
      list = list.filter((m) => m && re.test(m.file));
    }
    if (Number.isFinite(spec.limit)) list = list.slice(0, spec.limit);
    return list;
  }

  /** Bounding box of pixels whose alpha exceeds `threshold` (null if none). */
  function alphaBounds(pixels, width, height, threshold = 12) {
    let x0 = width, y0 = height, x1 = 0, y1 = 0;
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        if (pixels[(y * width + x) * 4 + 3] > threshold) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
    }
    return x1 > x0 ? { x0, y0, x1, y1 } : null;
  }

  /**
   * Turn a measured bounding box into a stable zoom/centre so the artwork
   * fills ~84% of the width or ~88% of the height of the canvas.
   */
  function frameBounds(box, width, height) {
    return {
      rw: (box.x1 - box.x0) / width,
      rh: (box.y1 - box.y0) / height,
      cx: (box.x0 + box.x1) / width - 1,
      cy: (box.y0 + box.y1) / height - 1,
      s: Math.min((width * 0.84) / (box.x1 - box.x0), (height * 0.88) / (box.y1 - box.y0)),
    };
  }

  /** Resolve a { zh, en, ... } object (or plain string) for a language tag. */
  function localized(value, lang) {
    if (value == null) return '';
    if (typeof value === 'string') return value;
    const base = String(lang || 'en').toLowerCase().startsWith('zh') ? 'zh' : String(lang || 'en').slice(0, 2).toLowerCase();
    return value[lang] || value[base] || value.en || Object.values(value)[0] || '';
  }

  /** Candidate line-pack files for a language tag, most specific first. */
  function lineCandidates(lang) {
    const tag = String(lang || 'en');
    const base = tag.slice(0, 2).toLowerCase();
    const list = [tag];
    if (base === 'zh') list.push('zh-CN');
    list.push(base, 'en');
    return [...new Set(list)];
  }

  /** Map an agent event to the reaction the character plays. */
  function reactionFor(event) {
    return { done: 'success', error: 'fail', attention: 'attention', thinking: 'thinking' }[event] || 'head';
  }

  const api = {
    parseMotion, sample, follow, fit, hitRegion, pick, hoverEntry, selectMotions,
    alphaBounds, frameBounds, localized, lineCandidates, reactionFor,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PetCore = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
