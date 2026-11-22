const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const elements = new Map(), calls = [];
function element() {
  return {value:'', children:[], append(v) { this.children.push(v); }, replaceChildren() { this.children=[]; }, addEventListener(){}, removeAttribute(){}, selectedIndex:0};
}
const get = id => { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); };
let sdk;
class Player {
  constructor() { sdk=this; this.events={}; }
  addListener(name, fn) { this.events[name]=fn; }
  async connect() { this.events.ready({device_id:'wink-device'}); return true; }
  activateElement() {}
  disconnect() {}
}
const context = vm.createContext({
  document:{getElementById:get, createElement:element, querySelectorAll:()=>[], addEventListener(){}},
  blink:{host:{info:async()=>({capabilities:['spotify']})}, spotify:{
    status:async()=>({connected:true}),
    request:async(...args)=>{ calls.push(args); return args[1].endsWith('/devices') ? {devices:[{id:'other',name:'Other app',is_active:true}]} : null; }
  }},
  Spotify:{Player}, window:{Spotify:{Player},addEventListener(){}}, setInterval(){}, setTimeout, clearTimeout
});
vm.runInContext(fs.readFileSync('Resources/Plugins/org.blink.spotify/app.js','utf8'),context);
(async()=>{
  for(let i=0;i<10;i++) await new Promise(resolve=>setImmediate(resolve));
  assert(sdk,'automatically connects SDK');
  assert.equal(get('devices').value,'wink-device','Wink selected instead of active external device');
  assert(calls.some(c=>c[0]==='PUT' && c[3]?.device_ids?.[0]==='wink-device' && c[3].play===false),'automatically transfers without unsolicited playback');
  await vm.runInContext('devices()',context);
  assert.equal(get('devices').value,'wink-device','refresh retains Wink');
  get('devices').value='other'; await get('devices').onchange();
  await vm.runInContext('devices()',context);
  assert.equal(get('devices').value,'other','explicit external selection respected');
  get('stream').onclick();
  for(let i=0;i<10;i++) await new Promise(resolve=>setImmediate(resolve));
  assert.equal(get('devices').value,'wink-device','Play in Wink restores Wink');
  assert(calls.some(c=>c[3]?.device_ids?.[0]==='wink-device' && c[3].play===true),'explicit play resumes audio');
  console.log('PASS: automatic connection, Wink default, silent transfer, refresh, explicit override, Play in Wink');
})().catch(e=>{console.error(e);process.exitCode=1;});
