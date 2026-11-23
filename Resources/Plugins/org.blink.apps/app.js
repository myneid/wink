 'use strict';
const $ = id => document.getElementById(id), api = blink.apps;
let apps = [], selected = 0, busy = false;
const button = (label, action) => { const b = document.createElement('button'); b.textContent = label; b.disabled = busy; b.onclick = () => run(action); return b; };
function draw() {
  $('apps').replaceChildren(); selected = Math.max(0, Math.min(selected, apps.length - 1));
  apps.forEach((app, index) => {
    const row = document.createElement('div'); row.className = 'app' + (selected === index ? ' selected' : ''); row.setAttribute('role','listitem');
    row.onclick = () => { selected = index; document.querySelectorAll('.app').forEach((r,i) => r.classList.toggle('selected',i === index)); };
    const info = document.createElement('div'); info.className = 'info'; info.textContent = `${app.name}  v${app.version}`;
    const source = document.createElement('small'); source.textContent = app.source; info.append(source); row.append(info);
    row.append(button('Open ↵', () => api.open(app.id)));
    if (app.repositoryURL) {
      const link = document.createElement('a'); link.href = app.repositoryURL;
      link.textContent = 'Open GitHub ↗'; link.rel = 'noopener noreferrer';
      link.setAttribute('aria-label', `Open ${app.name} project on GitHub`); row.append(link);
    }
    if (app.updateVersion) row.append(button(`Update → ${app.updateVersion}`, async () => { await api.update(app.id); await refresh(); }));
    else { const status = document.createElement('small'); status.textContent = app.updatable ? 'GitHub app' : 'Updates with Wink'; row.append(status); }
    $('apps').append(row);
  });
  ['install','check','refresh'].forEach(id => $(id).disabled = busy);
}
async function refresh() { apps = await api.list(); draw(); }
async function run(action) { if (busy) return; busy = true; draw(); $('status').textContent = ''; try { await action(); } catch(e) { $('status').textContent = e.message || String(e); } finally { busy = false; draw(); } }
$('refresh').onclick = () => run(refresh);
$('install').onclick = () => run(async () => { await api.install(); await refresh(); });
$('check').onclick = () => run(async () => {
  const messages = [];
  for (const app of apps.filter(a => a.updatable)) { try { const changed = await api.check(app.id); messages.push(`${app.name}: ${changed ? 'update available' : 'up to date'}`); } catch(e) { messages.push(`${app.name}: ${e.message || e}`); } }
  await refresh(); $('status').textContent = messages.join('\n') || 'Bundled apps update with Wink. No GitHub-installed apps to check.';
});
document.addEventListener('keydown', event => {
  if (busy || event.metaKey || event.ctrlKey || event.altKey || ['INPUT','TEXTAREA'].includes(event.target.tagName)) return;
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); selected += event.key === 'ArrowDown' ? 1 : -1; draw(); }
  if (event.key === 'Enter' && !['BUTTON','A'].includes(event.target.tagName) && apps[selected]) { event.preventDefault(); run(() => api.open(apps[selected].id)); }
  if (event.key.toLowerCase() === 'c') $('check').click();
  if (event.key.toLowerCase() === 'i') $('install').click();
  if (event.key.toLowerCase() === 'u' && apps[selected]?.updateVersion) run(async () => { await api.update(apps[selected].id); await refresh(); });
});
run(refresh);
