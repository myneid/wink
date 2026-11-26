'use strict';

// This adapter only uses Web APIs and hterm; there is no native bridge.
function mountTerminal(container, { onInput, onResize, onReady }) {
  lib.init(() => {
    hterm.defaultStorage = new lib.Storage.Memory();
    const terminal = new hterm.Terminal();
    terminal.onTerminalReady = () => {
      terminal.prefs_.set('background-color', '#14201f');
      terminal.prefs_.set('foreground-color', '#e6f3ed');
      terminal.prefs_.set('enable-clipboard-notice', false);
      const io = terminal.io.push();
      io.onVTKeystroke = io.sendString = onInput;
      io.onTerminalResize = (cols, rows) => onResize({ cols, rows });
      terminal.installKeyboard();
      onReady({
        write: text => io.print(text),
        size: () => ({ cols: terminal.screenSize.width, rows: terminal.screenSize.height })
      });
    };
    terminal.decorate(container);
  });
}
