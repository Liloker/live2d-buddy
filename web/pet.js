/*
 * Live2D Buddy renderer.
 *
 * Draws a Cubism 2 model with WebGL (runtime: live2d.min.js) and talks to the
 * native macOS shell through window.webkit.messageHandlers.pet. The page also
 * runs standalone in a normal browser, which is how the README demo is
 * recorded and the quickest way to iterate on the look and feel.
 *
 * Public API (window.pet) — called by the native shell or by a host page:
 *   init(opts)         load line packs + characters.json, report the list
 *   load(id)           load a character
 *   pointer(x, y)      cursor position in window coordinates (gaze + hit test)
 *   tap(x?, y?)        click reaction (head / upper body / other)
 *   say(text, ms, priority, force)
 *   sayIdle()          one of the idle lines ("Say something" menu)
 *   react(kind)        'tap' | 'success' | 'fail' | 'attention' | 'thinking'
 *   event(name, msg)   agent event: 'done' | 'attention' | 'error' | 'thinking'
 *   bubbles(on)        enable / disable spontaneous and reactive bubbles
 *   visible(on)        pause rendering while hidden
 *   inspect()          diagnostics used by the smoke test
 */
(function () {
  'use strict';

  const C = window.PetCore;
  const canvas = document.querySelector('#pet');
  const bubble = document.querySelector('#bubble');
  const gl = canvas.getContext('webgl', {
    alpha: true, antialias: true, premultipliedAlpha: true, preserveDrawingBuffer: true,
  });
  const TOP = 70; // px reserved above the model for the speech bubble
  const params = new URLSearchParams(location.search);
  const hasNative = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pet);
  const native = (type, data = {}) => {
    if (hasNative) window.webkit.messageHandlers.pet.postMessage({ type, ...data });
  };

  // ---------------------------------------------------------------- state
  let lang = 'en';
  let lines = {};
  let characters = [];
  let defaultId = null;
  let character = null;

  let model = null;
  let textures = [];
  let idleMotions = [];
  let headMotions = [];
  let upperMotions = [];
  let reactionMotions = {};
  let currentMotion = null;
  let motionStart = 0;
  let transitionAt = 0;
  let previousPose = {};
  let lastPose = {};

  let ready = false;
  let loading = false;
  let loadToken = 0;
  let visible = true;
  let bounds = null;
  let gazeX = 0, gazeY = 0, targetX = 0, targetY = 0, lastFrame = 0;

  let bubblesOn = true;
  let bubbleTimer = 0;
  let randomTimer = 0;
  let messagePriority = 0;
  let messageUntil = 0;
  let hovered = false;
  let lastHover = -Infinity;
  let reactUntil = 0;
  let reactKind = 'head';
  let lastRegion = null;

  const UI = {
    'zh': {
      loadFailed: '加载失败：',
      missingAssets: '还没有角色模型。右键我 →「下载示例角色…」，或在终端运行 make assets。',
    },
    'en': {
      loadFailed: 'Failed to load: ',
      missingAssets: 'No character yet. Right-click me → “Get demo characters…”, or run `make assets`.',
    },
  };
  const ui = (key) => (lines.ui && lines.ui[key]) || (UI[lang.startsWith('zh') ? 'zh' : 'en'][key]);
  const text = (value) => C.localized(value, lang);

  // ---------------------------------------------------------------- bubbles
  function say(message, timeout = 6500, priority = 1, force = false) {
    if (!message || (!bubblesOn && !force) || !visible) return;
    const now = performance.now();
    if (now < messageUntil && messagePriority > priority) return;
    messagePriority = priority;
    messageUntil = now + timeout;
    bubble.textContent = message;
    bubble.classList.add('show');
    clearTimeout(bubbleTimer);
    bubbleTimer = setTimeout(() => {
      bubble.classList.remove('show');
      messagePriority = 0;
      messageUntil = 0;
    }, timeout);
  }

  function showSticky(message) {
    clearTimeout(bubbleTimer);
    bubble.textContent = message;
    bubble.classList.add('show');
  }

  /** A gentle companion line every 3–7 minutes while bubbles are enabled. */
  function schedule() {
    clearTimeout(randomTimer);
    if (!bubblesOn) return;
    randomTimer = setTimeout(() => {
      say(C.pick(lines.idle));
      schedule();
    }, 180000 + Math.random() * 240000);
  }

  // ---------------------------------------------------------------- loading
  const renderScale = Number(params.get('scale')) || 0; // ?scale=1 for fast offline recording
  function resize() {
    // Render at ≥2× the window size for crisp edges on any display.
    const d = renderScale > 0 ? renderScale : Math.max(2, Math.min(window.devicePixelRatio || 1, 2.5));
    canvas.width = Math.round(canvas.clientWidth * d);
    canvas.height = Math.round(canvas.clientHeight * d);
  }
  new ResizeObserver(resize).observe(canvas);

  function missing(kind) {
    return Object.assign(new Error('missing ' + kind), { code: 'missing-' + kind });
  }

  async function fetchOK(url, kind = 'model') {
    let r;
    try {
      r = await fetch(url);
    } catch (e) {
      throw missing(kind);
    }
    if (r.status === 404) throw missing(kind);
    if (!r.ok && r.status !== 0) throw new Error('HTTP ' + r.status + ' ' + url);
    return r;
  }

  async function loadLines(tag) {
    for (const candidate of C.lineCandidates(tag)) {
      try {
        return await (await fetchOK('lines/' + candidate + '.json', 'lines')).json();
      } catch (e) { /* try the next candidate */ }
    }
    return {};
  }

  async function init(opts = {}) {
    lang = opts.lang || navigator.language || 'en';
    document.documentElement.lang = lang;
    bubblesOn = opts.bubbles !== false;
    lines = await loadLines(lang);
    try {
      const cfg = await (await fetchOK('characters.json', 'characters')).json();
      characters = Array.isArray(cfg.characters) ? cfg.characters : [];
      defaultId = cfg.default || (characters[0] && characters[0].id) || null;
    } catch (e) {
      characters = [];
      defaultId = null;
    }
    native('characters', {
      list: characters.map((c) => ({ id: c.id, name: text(c.name) || c.id, aspect: c.windowAspect || 0.82 })),
      default: defaultId,
    });
    if (!characters.length) showSticky(ui('missingAssets'));
    return characters.length;
  }

  function chooseMotion(motion, now) {
    previousPose = { ...lastPose };
    currentMotion = motion;
    motionStart = now;
    transitionAt = now;
  }

  async function load(id) {
    const next = characters.find((c) => c.id === id) || characters.find((c) => c.id === defaultId) || characters[0];
    if (!next || loading) return;
    loading = true;
    ready = false;
    character = next;
    const token = ++loadToken;
    // A new speaker: drop whatever the previous character was saying.
    clearTimeout(bubbleTimer);
    bubble.classList.remove('show');
    messagePriority = 0;
    messageUntil = 0;
    native('status', { message: 'loading', character: next.id });
    try {
      if (typeof Live2D === 'undefined' || typeof Live2DModelWebGL === 'undefined') throw missing('runtime');
      Live2D.init();
      Live2D.setGL(gl);
      for (const t of textures) gl.deleteTexture(t);
      textures = [];

      const base = next.model.endsWith('/') ? next.model : next.model + '/';
      const cfg = await (await fetchOK(base + (next.config || 'index.json'))).json();
      model = Live2DModelWebGL.loadModel(await (await fetchOK(base + cfg.model)).arrayBuffer());

      for (let i = 0; i < cfg.textures.length; i++) {
        const img = new Image();
        img.src = base + cfg.textures[i];
        try {
          await img.decode();
        } catch (e) {
          throw missing('model');
        }
        const t = gl.createTexture();
        textures.push(t);
        gl.bindTexture(gl.TEXTURE_2D, t);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 1);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, 1);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
        for (const p of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_2D, p, gl.LINEAR);
        for (const p of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T]) gl.texParameteri(gl.TEXTURE_2D, p, gl.CLAMP_TO_EDGE);
        model.setTexture(i, t);
      }

      if (cfg.pose) {
        // Cubism 2 pose groups: show the first part of each group, hide the rest.
        const pose = await (await fetchOK(base + cfg.pose)).json();
        for (const entry of pose.parts_visible || []) {
          for (const [i, part] of entry.group.entries()) {
            for (const partId of [part.id, ...(part.link || [])]) {
              const j = model.getPartsDataIndex(partId);
              if (j >= 0) model.setPartsOpacity(j, i === 0 ? 1 : 0);
            }
          }
        }
      }

      const read = async (m) => C.parseMotion(await (await fetchOK(base + m.file)).text());
      const motions = cfg.motions || {};
      idleMotions = await Promise.all((motions.idle || []).map(read));
      headMotions = await Promise.all(C.selectMotions(motions, (next.motions || {}).head).map(read));
      upperMotions = await Promise.all(C.selectMotions(motions, (next.motions || {}).upper).map(read));
      reactionMotions = {};
      for (const [kind, file] of Object.entries(next.reactions || {})) {
        try {
          reactionMotions[kind] = await read({ file });
        } catch (e) { /* optional */ }
      }
      if (token !== loadToken) return;

      model.saveParam();
      bounds = null;
      resize();
      previousPose = {};
      lastPose = {};
      chooseMotion(idleMotions[0], performance.now());
      render(motionStart, 0, true);

      // Measure the actual artwork once, then keep a stable framing while it animates.
      const pixels = new Uint8Array(canvas.width * canvas.height * 4);
      gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      const box = C.alphaBounds(pixels, canvas.width, canvas.height);
      if (!box) throw new Error('model rendered no visible pixels');
      bounds = C.frameBounds(box, canvas.width, canvas.height);

      ready = true;
      native('ready', { character: next.id, width: canvas.width, height: canvas.height });
      say(text(next.greeting));
      schedule();
    } catch (e) {
      const code = e && e.code ? e.code : 'render';
      native('error', { code, message: String((e && e.message) || e) });
      showSticky(code.startsWith('missing') ? ui('missingAssets') : ui('loadFailed') + ((e && e.message) || e));
    } finally {
      loading = false;
    }
  }

  // ---------------------------------------------------------------- rendering
  function artworkRect() {
    const w = canvas.clientWidth * bounds.rw * bounds.s;
    const h = canvas.clientHeight * bounds.rh * bounds.s;
    return { x: (canvas.clientWidth - w) / 2, y: TOP + (canvas.clientHeight - h) / 2, width: w, height: h };
  }

  function applyReaction(now) {
    if (now >= reactUntil) return;
    const k = reactKind;
    if (k === 'head' || k === 'upper') {
      model.addToParamFloat('PARAM_ANGLE_Z', Math.sin(now / 170) * (k === 'head' ? 5 : -3), 1);
      if (k === 'head') {
        model.setParamFloat('PARAM_EYE_L_SMILE', 0.7);
        model.setParamFloat('PARAM_EYE_R_SMILE', 0.7);
      } else {
        model.addToParamFloat('PARAM_ANGLE_X', -12, 1);
      }
    } else if (k === 'success') {
      model.addToParamFloat('PARAM_ANGLE_Y', Math.sin(now / 140) * 8, 1);
      model.setParamFloat('PARAM_EYE_L_SMILE', 0.9);
      model.setParamFloat('PARAM_EYE_R_SMILE', 0.9);
      model.setParamFloat('PARAM_MOUTH_FORM', 1);
    } else if (k === 'fail') {
      model.addToParamFloat('PARAM_ANGLE_Y', -10, 1);
      model.addToParamFloat('PARAM_ANGLE_X', Math.sin(now / 90) * 6, 1);
      model.setParamFloat('PARAM_MOUTH_FORM', -1);
    } else if (k === 'attention') {
      model.addToParamFloat('PARAM_ANGLE_Z', Math.sin(now / 80) * 7, 1);
      model.addToParamFloat('PARAM_BODY_ANGLE_X', Math.sin(now / 80) * 3, 1);
    } else if (k === 'thinking') {
      model.addToParamFloat('PARAM_ANGLE_Z', 9, 1);
      model.setParamFloat('PARAM_EYE_BALL_Y', 0.6);
      model.setParamFloat('PARAM_EYE_BALL_X', -0.4);
    }
  }

  function render(now, dt, initial = false) {
    if (!model) return;
    model.loadParam();
    if (currentMotion) {
      let frame = ((now - motionStart) / 1000) * currentMotion.fps;
      if (frame >= currentMotion.length - 1 && !initial) {
        chooseMotion(C.pick(idleMotions) || null, now);
        frame = 0;
      }
      if (currentMotion) {
        const blend = Math.min(1, (now - transitionAt) / 350);
        for (const [k, v] of Object.entries(currentMotion.tracks)) {
          let value = C.sample(v, frame);
          if (previousPose[k] !== undefined) value = previousPose[k] * (1 - blend) + value * blend;
          model.setParamFloat(k, value);
          lastPose[k] = value;
        }
      }
    }

    // Gaze: eyes first, head and body follow with smoothing.
    gazeX = C.follow(gazeX, targetX, dt);
    gazeY = C.follow(gazeY, targetY, dt);
    model.addToParamFloat('PARAM_ANGLE_X', gazeX * 22, 0.8);
    model.addToParamFloat('PARAM_ANGLE_Y', gazeY * 16, 0.8);
    model.setParamFloat('PARAM_EYE_BALL_X', gazeX);
    model.setParamFloat('PARAM_EYE_BALL_Y', gazeY);
    model.addToParamFloat('PARAM_BODY_ANGLE_X', gazeX * 5, 0.8);

    const blink = now % 4900;
    if (blink < 180) {
      const eye = Math.abs(blink - 90) / 90;
      model.setParamFloat('PARAM_EYE_L_OPEN', eye);
      model.setParamFloat('PARAM_EYE_R_OPEN', eye);
    }
    applyReaction(now);

    const w = model.getCanvasWidth();
    const h = model.getCanvasHeight();
    const s = Math.min(2 / w, 2 / h) * 0.92;
    const sy = (s * canvas.width) / canvas.height;
    const z = bounds ? bounds.s : 1;
    const cx = bounds ? bounds.cx : 0;
    const cy = bounds ? bounds.cy : 0;
    model.setMatrix(new Float32Array([
      s * z, 0, 0, 0,
      0, -sy * z, 0, 0,
      0, 0, 1, 0,
      (-w * s / 2 - cx) * z, (h * sy / 2 - cy) * z, 0, 1,
    ]));
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    model.update();
    model.draw();
  }

  // Cubism 2 motions are authored at 30 fps; drawing faster only burns battery.
  const FRAME_MS = 1000 / 30;
  function loop(now) {
    requestAnimationFrame(loop);
    if (now - lastFrame < FRAME_MS - 2) return;
    const dt = Math.min((now - lastFrame) / 1000, 0.05);
    lastFrame = now;
    if (ready && visible) render(now, dt);
  }
  requestAnimationFrame(loop);

  // ---------------------------------------------------------------- interaction
  function pointer(px, py) {
    targetX = Math.max(-1, Math.min(1, (px / canvas.clientWidth - 0.5) * 2));
    targetY = Math.max(-1, Math.min(1, (0.55 - (py - TOP) / canvas.clientHeight) * 2));
    if (!ready) return;
    let hit = false;
    const ix = Math.floor((px * canvas.width) / canvas.clientWidth);
    const iy = canvas.height - 1 - Math.floor(((py - TOP) * canvas.height) / canvas.clientHeight);
    if (ix >= 0 && iy >= 0 && ix < canvas.width && iy < canvas.height) {
      const p = new Uint8Array(4);
      gl.readPixels(ix, iy, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p);
      hit = p[3] > 25;
    }
    if (C.hoverEntry(hovered, hit) && performance.now() - lastHover > 4000) {
      say(C.pick(lines.hover), 4000, 8);
      lastHover = performance.now();
    }
    hovered = hit;
    native('hit', { hit });
  }

  function startReaction(kind, duration) {
    reactKind = kind;
    reactUntil = performance.now() + duration;
  }

  function tap(px, py) {
    if (!ready) return;
    const region = Number.isFinite(px) && Number.isFinite(py)
      ? C.hitRegion(character.regions, px, py, artworkRect())
      : 'head';
    if (!region) return;
    lastRegion = region;
    startReaction(region, 1400);
    const bank = region === 'head' ? headMotions : region === 'upper' ? upperMotions : [];
    if (bank.length) chooseMotion(C.pick(bank), performance.now());
    say(C.pick(lines.click), 4000, 8);
    native('interaction', { region });
  }

  function react(kind = 'tap') {
    if (!ready) return;
    if (kind === 'tap') kind = 'head';
    const motion = reactionMotions[kind] || (kind === 'head' ? C.pick(headMotions) : null);
    if (motion) chooseMotion(motion, performance.now());
    startReaction(kind, kind === 'head' || kind === 'upper' ? 1400 : 2600);
  }

  function event(name, message) {
    react(C.reactionFor(name));
    const line = message || C.pick(lines.agent && lines.agent[name]);
    say(line, name === 'attention' ? 9000 : 6500, 9, true);
  }

  function setBubbles(on) {
    bubblesOn = !!on;
    if (!bubblesOn) {
      bubble.classList.remove('show');
      messagePriority = 0;
      messageUntil = 0;
    }
    schedule();
  }

  function inspect() {
    return {
      ready,
      character: character && character.id,
      characters: characters.map((c) => c.id),
      width: canvas.width,
      height: canvas.height,
      bounds,
      artwork: bounds ? artworkRect() : null,
      lastRegion,
      message: bubble.textContent,
      messagePriority,
      gaze: { x: gazeX, y: gazeY },
      bubbleVisible: bubble.classList.contains('show'),
      antialias: gl.getContextAttributes().antialias,
    };
  }

  window.pet = {
    init,
    load,
    pointer,
    tap,
    say,
    sayIdle: () => say(lines.menuSay || C.pick(lines.idle), 6500, 2, true),
    react,
    event,
    bubbles: setBubbles,
    visible(on) { visible = !!on; },
    inspect,
  };

  window.addEventListener('error', (e) => native('error', { code: 'script', message: e.message }));

  if (hasNative) {
    native('boot');
  } else if (!params.has('manual')) {
    // Standalone browser mode: follow the real mouse and load the default character.
    window.addEventListener('mousemove', (e) => pointer(e.clientX, e.clientY));
    window.addEventListener('click', (e) => tap(e.clientX, e.clientY));
    init({ lang: params.get('lang') || navigator.language }).then((n) => n && load(params.get('character') || defaultId));
  }
})();
