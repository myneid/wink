'use strict';
const $ = id => document.getElementById(id), api = blink.spotify;
let player = null, localDevice = null, sdkLoading = null, selectedDevice = null;
let playback = null, view = 'search', offset = 0, artwork = '', busy = false, connected = false;
const request = (verb, path, query = {}, body) => api.request(verb, path, query, body);
const report = error => { $('status').textContent = error?.message || String(error); };
async function run(action) { try { $('status').textContent = ''; await action(); } catch (error) { report(error); } }
function session(value) { connected = value; $('setup').hidden = value; $('app').hidden = !value; $('disconnect').hidden = !value; $('connection').textContent = value ? 'Connected' : 'Disconnected'; }
const time = ms => `${Math.floor((ms || 0) / 60000)}:${String(Math.floor((ms || 0) / 1000) % 60).padStart(2, '0')}`;
function deviceQuery() { const id = $('devices').value; if (!id) throw new Error('Wink player is connecting. If audio is blocked, click Play in Wink.'); return {device_id: id}; }
async function command(path, verb = 'PUT', query = {}, body) { await request(verb, '/me/player' + path, {...deviceQuery(), ...query}, body); await refresh(); }
async function refresh() {
  if (!connected || busy) return;
  busy = true;
  try {
    const state = await request('GET', '/me/player'); playback = state;
    const track = state?.item;
    $('title').textContent = track?.name || 'No active playback';
    $('artist').textContent = track ? `${(track.artists || []).map(a => a.name).join(', ')} — ${track.album?.name || ''}` : 'Choose Play in Wink, then select a song.';
    $('tracklink').hidden = !track?.external_urls?.spotify;
    if (track?.external_urls?.spotify) $('tracklink').href = track.external_urls.spotify;
    $('toggle').textContent = state?.is_playing ? 'Pause' : 'Play';
    $('progress').textContent = `${time(state?.progress_ms)} / ${time(track?.duration_ms)}`;
    $('seek').max = track?.duration_ms || 1; $('seek').value = state?.progress_ms || 0;
    $('volume').value = state?.device?.volume_percent ?? 50;
    $('shuffle').textContent = `Shuffle ${state?.shuffle_state ? 'on' : 'off'}`;
    $('repeat').textContent = `Repeat ${state?.repeat_state || 'off'}`;
    const image = track?.album?.images?.[0]?.url || '';
    if (image !== artwork) { artwork = image; $('art').hidden = true; if (image) { const data = await api.artwork(image); if (artwork === image) { $('art').src = data; $('art').hidden = false; } } }
  } finally { busy = false; }
}
async function devices() {
  const data = await request('GET', '/me/player/devices');
  const available = data?.devices || [];
  $('devices').replaceChildren();
  const target = selectedDevice || localDevice;
  const wink = document.createElement('option');
  wink.value = localDevice || ''; wink.textContent = localDevice ? 'Wink (in-app)' : 'Wink (connecting…)';
  $('devices').append(wink);
  for (const device of available) {
    if (device.id === localDevice) continue;
    const option = document.createElement('option'); option.value = device.id || '';
    option.textContent = `${device.name}${device.is_active ? ' • active' : ''}`; $('devices').append(option);
  }
  $('devices').value = target || '';
  if ($('devices').selectedIndex < 0) { selectedDevice = null; $('devices').value = localDevice || ''; }
}
function button(text, action) { const b = document.createElement('button'); b.textContent = text; b.onclick = () => run(action); return b; }
function row(item, kind) {
  const track = item.track || item.item || item;
  if (!track) return;
  const div = document.createElement('div'); div.className = 'row';
  const description = document.createElement('div'); description.className = 'description'; description.textContent = track.name || 'Unavailable';
  const sub = document.createElement('small'); sub.textContent = (track.artists || []).map(a => a.name).join(', ') || track.owner?.display_name || '';
  description.append(sub); div.append(description);
  if (kind === 'playlist') div.append(button('Open', () => { view = track.id; offset = 0; $('heading').textContent = track.name; return load(); }));
  if (track.uri) {
    div.append(button('Play', () => command('/play', 'PUT', {}, kind === 'playlist' ? {context_uri: track.uri} : {uris: [track.uri]})));
    if (kind !== 'playlist') div.append(button('+ Queue', () => command('/queue', 'POST', {uri: track.uri})));
  }
  const href = track.external_urls?.spotify;
  if (href && href.startsWith('https://open.spotify.com/')) { const a = document.createElement('a'); a.href = href; a.textContent = 'Spotify ↗'; a.target = '_blank'; a.rel = 'noopener'; div.append(a); }
  $('results').append(div);
}
async function load(append = false) {
  if (!append) $('results').replaceChildren();
  let data, items, kind = 'track'; const query = {limit: '10', offset: String(offset)};
  if (view === 'search') {
    const q = $('query').value.trim(); if (!q) return;
    data = (await request('GET', '/search', {...query, q, type: 'track'}))?.tracks;
  } else if (view === 'library') data = await request('GET', '/me/tracks', query);
  else if (view === 'playlists') { data = await request('GET', '/me/playlists', query); kind = 'playlist'; }
  else if (view === 'queue') { const queue = await request('GET', '/me/player/queue'); items = queue?.queue || []; }
  else data = await request('GET', `/playlists/${view}/items`, query);
  items = items || data?.items || []; items.forEach(item => row(item, kind));
  if (!items.length && !append) $('results').textContent = 'No items available.';
  $('more').hidden = !data?.next;
}
$('login').onclick = () => run(async () => { $('login').disabled = true; try { await api.login($('client').value.trim()); session(true); await devices(); await startLocalPlayer(); await refresh(); } finally { $('login').disabled = false; } });
$('disconnect').onclick = () => run(async () => { if (player) player.disconnect(); player = null; localDevice = null; selectedDevice = null; $('stream-status').textContent = 'Disconnected'; await api.logout(); session(false); $('art').removeAttribute('src'); $('results').replaceChildren(); artwork = ''; playback = null; });
$('toggle').onclick = () => run(() => command(playback?.is_playing ? '/pause' : '/play'));
$('next').onclick = () => run(() => command('/next', 'POST'));
$('previous').onclick = () => run(() => command('/previous', 'POST'));
$('shuffle').onclick = () => run(() => command('/shuffle', 'PUT', {state: String(!playback?.shuffle_state)}));
$('repeat').onclick = () => run(() => command('/repeat', 'PUT', {state: ({off:'context',context:'track',track:'off'})[playback?.repeat_state || 'off']}));
$('volume').onchange = () => run(() => command('/volume', 'PUT', {volume_percent: $('volume').value}));
$('seek').onchange = () => run(() => command('/seek', 'PUT', {position_ms: $('seek').value}));
$('devices').onchange = () => run(async () => { if ($('devices').value) { selectedDevice = $('devices').value; await request('PUT', '/me/player', {}, {device_ids:[$('devices').value], play:false}); await refresh(); } });
$('refresh').onclick = () => run(async () => { await devices(); await refresh(); });
$('searchform').onsubmit = event => { event.preventDefault(); view = 'search'; offset = 0; $('heading').textContent = 'Search results'; run(() => load()); };
document.querySelectorAll('[data-view]').forEach(b => { b.onclick = () => { view = b.dataset.view; offset = 0; $('heading').textContent = b.textContent; run(() => load()); }; });
$('more').onclick = () => { offset += 10; run(() => load(true)); };
document.addEventListener('keydown', event => {
  if (!connected || event.metaKey || event.ctrlKey || event.altKey || ['INPUT','TEXTAREA','SELECT','BUTTON'].includes(event.target.tagName)) return;
  const actions = {' ': 'toggle', n:'next', p:'previous'};
  if (actions[event.key]) { event.preventDefault(); $(actions[event.key]).click(); }
  if (event.key === '/') { event.preventDefault(); $('query').focus(); }
});
setInterval(() => { if (connected && !document.hidden) run(refresh); }, 10000);
run(async () => { const info = await blink.host.info(); if (!info.capabilities.includes('spotify')) throw new Error('This host does not provide the Spotify capability. Use the bundled Wink plugin.'); session((await api.status()).connected); if (connected) { await devices(); await startLocalPlayer(); await refresh(); } });

function loadStreamingSDK() {
  if (window.Spotify) return Promise.resolve();
  if (sdkLoading) return sdkLoading;
  sdkLoading = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Spotify streaming SDK timed out. Check your connection and try reopening the tab.')), 20000);
    window.onSpotifyWebPlaybackSDKReady = () => { clearTimeout(timer); resolve(); };
    const script = document.createElement('script'); script.src = 'https://sdk.scdn.co/spotify-player.js';
    script.onerror = () => { clearTimeout(timer); reject(new Error('Cannot load Spotify streaming SDK.')); };
    document.head.append(script);
  });
  return sdkLoading;
}
async function useLocalPlayer(play = false) {
  if (!localDevice) return;
  await request('PUT', '/me/player', {}, {device_ids:[localDevice], play});
  await devices();
  selectedDevice = localDevice; $('devices').value = localDevice;
  await refresh();
}
async function startLocalPlayer() {
  // Connect on login or tab open; audio activation stays in the click handler.
  if (player) return;
  $('stream-status').textContent = 'Connecting built-in player…';
  await loadStreamingSDK();
  player = new Spotify.Player({name:'Wink', volume:0.5, enableMediaSession:true,
    getOAuthToken: callback => api.streamingToken().then(callback).catch(error => {
      $('stream-status').textContent = 'Reconnect Spotify to authorize streaming'; report(error);
    })});
  const thisPlayer = player;
  for (const event of ['initialization_error','authentication_error','account_error','playback_error']) {
    player.addListener(event, error => {
      $('stream-status').textContent = event === 'authentication_error' ? 'Disconnect and reconnect Spotify to grant streaming access' : `In-app playback: ${error.message}`;
      report(error);
      thisPlayer.disconnect(); if (player === thisPlayer) { player = null; localDevice = null; }
    });
  }
  player.addListener('ready', ({device_id}) => {
    if (player !== thisPlayer) return;
    localDevice = device_id; $('stream-status').textContent = 'Wink player ready'; if (!selectedDevice) run(() => useLocalPlayer(false)); else run(devices);
  });
  player.addListener('not_ready', () => { localDevice = null; $('stream-status').textContent = 'Wink player offline — reopen this tab to reconnect'; });
  player.addListener('autoplay_failed', () => { $('stream-status').textContent = 'Click Play in Wink again to enable audio'; });
  player.addListener('player_state_changed', () => { if (connected) run(refresh); });
  const ok = await player.connect();
  if (!ok && player === thisPlayer) { player.disconnect(); player = null; throw new Error('Spotify could not connect the built-in player. Reconnect Spotify and check Premium eligibility.'); }
}
$('stream').onclick = () => {
  // Activate synchronously in the user gesture when the SDK is already ready.
  if (player) player.activateElement();
  run(async () => {
    await startLocalPlayer();
    if (player) player.activateElement();
    if (localDevice) await useLocalPlayer(true);
  });
};
window.addEventListener('pagehide', () => { if (player) player.disconnect(); });
