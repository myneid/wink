'use strict';

const items = [
  { label: 'Draw the screen with ANSI', checked: true },
  { label: 'Handle arrows and Enter', checked: false },
  { label: 'Try the touch controls', checked: false }
];
const keys = { up: '\x1b[A', down: '\x1b[B', enter: '\r' };
let selected = 0;
let terminal;

function render(size = terminal.size()) {
  const lines = [
    '\x1b[1;36mTUI Starter\x1b[0m',
    '',
    ...items.map(({ label, checked }, index) => {
      const line = (index === selected ? '> ' : '  ') + (checked ? '[x] ' : '[ ] ') + label;
      const clipped = line.slice(0, size.cols);
      return index === selected ? '\x1b[7m' + clipped + '\x1b[0m' : clipped;
    })
  ];
  terminal.write('\x1b[?25l\x1b[2J\x1b[H' + lines.slice(0, size.rows).join('\r\n'));
}

function input(key) {
  if (!terminal) return;
  switch (key) {
    case keys.up: selected = (selected + items.length - 1) % items.length; break;
    case keys.down: selected = (selected + 1) % items.length; break;
    case keys.enter:
    case ' ': items[selected].checked = !items[selected].checked; break;
    default: return;
  }
  render();
}

for (const button of document.querySelectorAll('[data-key]')) {
  button.addEventListener('click', () => input(keys[button.dataset.key]));
}

mountTerminal(document.querySelector('#terminal'), {
  onInput: input,
  onResize: size => { if (terminal) render(size); },
  onReady: instance => {
    terminal = instance;
    render();
  }
});
