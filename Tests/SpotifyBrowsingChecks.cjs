const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const elements = new Map(), calls = [];
function element() { return {value:'', children:[], append(v){this.children.push(v);}, replaceChildren(){this.children=[];}, removeAttribute(){}, selectedIndex:0}; }
const get = id => { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); };
get('searchtype').value = 'artist'; get('query').value = 'An artist'; get('release-group').value = 'album';
let respond = async (verb, path, query) => {
  if (path === '/search') return {artists:{items:[{id:'artist1',name:'An artist',uri:'spotify:artist:artist1'}]}};
  if (path === '/artists/artist1/albums') return {items:[{id:'album1',name:'An album',uri:'spotify:album:album1',release_date:'2024-01-01',total_tracks:12}],next:null};
  if (path === '/albums/album1/tracks') return {items:[{id:'track1',name:'A song',uri:'spotify:track:track1',disc_number:2,track_number:1,duration_ms:180000}],next:query.offset==='0'?'more':null};
  return null;
};
const context = vm.createContext({document:{getElementById:get,createElement:element,querySelectorAll:()=>[],addEventListener(){}},
  blink:{host:{info:async()=>({capabilities:['spotify']})},spotify:{status:async()=>({connected:false}),request:async(...args)=>{calls.push(args);return respond(...args);}}},
  window:{addEventListener(){}},setInterval(){},setTimeout,clearTimeout});
vm.runInContext(fs.readFileSync('Resources/Plugins/org.blink.spotify/app.js','utf8'),context);
const evaluate = code => vm.runInContext(code,context);
const click = async text => {
  const b = get('results').children[0].children.find(c=>c.textContent===text);
  assert(b,`Missing ${text}`); await b.onclick();
};
(async()=>{
  await evaluate('load()');
  assert.equal(calls.at(-1)[2].type,'artist');
  await click('Albums →');
  assert.equal(calls.at(-1)[1],'/artists/artist1/albums');
  assert.equal(calls.at(-1)[2].include_groups,'album');
  const before = calls.length; await click('Play album');
  assert.equal(calls.length,before,'no playback request without a device');
  get('devices').value='wink-device';
  await click('Play album');
  assert.equal(calls.at(-1)[3].context_uri,'spotify:album:album1');
  await click('Tracks →');
  assert.equal(calls.at(-1)[1],'/albums/album1/tracks');
  await click('Play');
  assert.equal(calls.at(-1)[3].context_uri,'spotify:album:album1');
  assert.equal(calls.at(-1)[3].offset.position,0);
  await get('more').onclick(); await click('Play');
  const secondRow = get('results').children[1]; await secondRow.children.find(c=>c.textContent==='Play').onclick();
  assert.equal(calls.at(-1)[3].offset.position,10,'paged track starts at correct album position');
  await get('back').onclick(); assert.equal(calls.at(-1)[1],'/artists/artist1/albums');
  get('release-group').value='single'; get('release-group').onchange();
  await new Promise(r=>setImmediate(r)); assert.equal(calls.at(-1)[2].include_groups,'single');
  await get('back').onclick(); assert.equal(calls.at(-1)[2].type,'artist');
  get('searchtype').value='album'; await evaluate('load()'); assert.equal(calls.at(-1)[2].type,'album');
  let finish; respond = () => new Promise(resolve=>{finish=resolve;});
  const pending = evaluate('load()');
  respond = async()=>({albums:{items:[{name:'New result'}]}});
  await evaluate('load()'); finish({albums:{items:[{name:'Stale result'}]}}); await pending;
  assert.equal(get('results').children[0].children[0].textContent,'New result','stale navigation response ignored');
  console.log('PASS: artist search, albums, release filter, album context playback, paged track offsets, back, album search, stale response guard');
})().catch(error=>{console.error(error);process.exitCode=1;});
