'use strict';

// Glue between hterm and the native side. Native -> JS calls go through
// `wink.*`; JS -> native goes through the `wink` script message handler.

hterm.defaultStorage = new lib.Storage.Memory();

// hterm does not support DEC mode 1003 (any-event mouse tracking); treat it as
// 1002, same as Blink does.
hterm.VT.prototype.setDECMode_original = hterm.VT.prototype.setDECMode;
hterm.VT.prototype.setDECMode = function(code, state) {
  if (code === '1003') code = '1002';
  hterm.VT.prototype.setDECMode_original.call(this, code, state);
};

// Native draws its own resize feedback (none), so hide hterm's overlay.
hterm.Terminal.prototype.overlaySize = function() {};

let t = null;
let _ready = false;
let _prefs = null; // the terminal's own PreferenceManager, set in init()
const _decoder = new TextDecoder('utf-8');
const _pending = [];

function _post(op, data) {
  const handler = window.webkit && window.webkit.messageHandlers.wink;
  if (handler) handler.postMessage(Object.assign({op}, data || {}));
}

// Blink theme files call these two globals, so they work unmodified.
function term_set(key, value) { _prefs.set(key, value); }
function term_applySexyTheme(theme) {
  term_set('color-palette-overrides', theme.color);
  term_set('foreground-color', theme.foreground);
  term_set('background-color', theme.background);
}

function _syncBackground() {
  const bg = _prefs.get('background-color');
  document.documentElement.style.backgroundColor = bg;
  document.body.style.backgroundColor = bg;
  _post('background', {color: bg});
}

function _b64ToBytes(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

window.wink = {
  init(opts) {
    t = new hterm.Terminal('wink');
    _prefs = t.getPrefs();
    term_set('font-family', opts.fontFamily);
    term_set('font-size', opts.fontSize);
    term_set('receive-encoding', 'raw'); // native side hands us decoded text
    term_set('scrollbar-visible', false);
    term_set('enable-clipboard-notice', false);
    term_set('audible-bell-sound', '');
    term_set('copy-on-select', false);
    term_set('pass-meta-v', true);
    term_set('pass-meta-number', true); // let Cmd+1..9 switch tabs
    term_set('alt-is-meta', !!opts.optionIsMeta);
    term_set('scroll-on-output', false);
    term_set('scroll-on-keystroke', true);
    term_set('cursor-blink', false);
    if (opts.theme) {
      try { (0, eval)(opts.theme); } catch (e) { console.error(e); }
    }

    t.onTerminalReady = function() {
      // Native side sends/receives real strings; don't UTF-8 (de|en)code again.
      t.vt.characterEncoding = 'raw';
      t.keyboard.characterEncoding = 'raw';
      const io = t.io.push();
      io.onVTKeystroke = io.sendString = (data) => _post('input', {data});
      io.onTerminalResize = (cols, rows) => _post('resize', {cols, rows});
      t.installKeyboard();
      // ⌘ belongs to macOS: keep hterm from treating it as Meta so WebKit hands
      // the event back to the app's menu bar (⌘T, ⌘W, ⌘C, ⌘V, ...).
      for (const type of ['keydown', 'keypress', 'keyup']) {
        t.document_.addEventListener(type, (e) => {
          if (e.metaKey) e.stopImmediatePropagation();
        }, true);
      }
      t.setCursorVisible(true);
      _syncBackground();
      for (const chunk of _pending) t.io.writeUTF8(chunk);
      _pending.length = 0;
      _ready = true;
      _post('ready', {cols: t.screenSize.width, rows: t.screenSize.height});
      t.focus();
    };
    t.decorate(document.getElementById('terminal'));
  },

  // With the VT in raw mode, writeUTF8 interprets the (already decoded) string
  // as-is; io.print would UTF-8 encode it first.
  write(b64) {
    const text = _decoder.decode(_b64ToBytes(b64), {stream: true});
    if (!text) return;
    if (_ready) t.io.writeUTF8(text);
    else _pending.push(text);
  },

  setFontSize(size) { term_set('font-size', size); },
  setOptionIsMeta(on) { term_set('alt-is-meta', !!on); },

  applyTheme(source) {
    (0, eval)(source);
    _syncBackground();
  },

  focus() { if (t) t.focus(); },
  blur() { if (t) t.onFocusChange_(false); },

  clear() { if (t) { t.clearHome(); t.clearScrollback(); } },
};
