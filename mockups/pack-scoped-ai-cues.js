/* 本地交互原型：数据、音频与凭据均为模拟值。 */
const EVENTS = [
  {key:'task_start',zh:'任务开始',hex:'#0A72D0',glyph:'✈',freq:880},
  {key:'stop',zh:'本轮结束',hex:'#288B43',glyph:'✓',freq:520},
  {key:'stop_failure',zh:'执行中断',hex:'#AC6900',glyph:'❚❚',freq:330},
  {key:'notification',zh:'待响应',hex:'#C4633C',glyph:'🔔',freq:700},
  {key:'subagent_stop',zh:'子任务结束',hex:'#5B59D6',glyph:'✓',freq:600},
];
const EV = Object.fromEntries(EVENTS.map(e=>[e.key,e]));
const HOSTS = {
  claude:{name:'Claude Code',status:'5/5 · 已激活',bindings:{
    task_start:['UserPromptSubmit','已实现'],stop:['Stop','已实现'],
    stop_failure:['StopFailure','已实现'],notification:['Notification','已实现'],
    subagent_stop:['SubagentStop','已实现']}},
  codex:{name:'Codex',status:'4/5 · 已激活',bindings:{
    task_start:['UserPromptSubmit','已实现'],stop:['Stop','已实现'],
    stop_failure:['—','不支持'],notification:['PermissionRequest','已实现 · 仅授权请求'],
    subagent_stop:['SubagentStop','已实现']}},
  workbuddy:{name:'WorkBuddy',status:'2/5 · 已激活',bindings:{
    task_start:['UserPromptSubmit','已实现'],stop:['Stop','已实现'],
    stop_failure:['StopFailure','接口已声明 · 未实现'],
    notification:['Notification','接口部分支持 · 未实现'],
    subagent_stop:['SubagentStop','接口已声明 · 未实现']}},
};
const PROFILES = [
  {id:'elevenlabs-global',label:'ElevenLabs · 全球',routes:['speech','mixed','animal','soundEffect'],kind:'styled',storage:'Keychain',validation:'只读探针'},
  {id:'minimax-global',label:'MiniMax · 全球',routes:['speech'],kind:'numbered',storage:'Keychain',validation:'只读探针'},
  {id:'qwen-singapore',label:'Qwen · 新加坡',routes:['speech'],kind:'styled',storage:'Keychain 独立槽位',validation:'首次显式生成时验证'},
  {id:'qwen-beijing',label:'Qwen · 北京',routes:['speech'],kind:'styled',storage:'Keychain 独立槽位',validation:'首次显式生成时验证'},
  {id:'senseaudio-cn',label:'SenseAudio · 中国 API',routes:['speech','animal','soundEffect'],kind:'numbered',storage:'本地私有凭证文件',validation:'只读探针'},
];
const MODALITIES={speech:'语音',mixed:'混合声音',animal:'动物叫声',soundEffect:'纯音效'};
const $=s=>document.querySelector(s);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const scopeName=s=>s==='global'?'全局默认':HOSTS[s]?.name||'未知来源';
function initialState(){return {
  page:'sounds',scope:'global',applyScope:'global',profile:'elevenlabs-global',
  credential:{'elevenlabs-global':'verified','minimax-global':'missing','qwen-singapore':'deferred','qwen-beijing':'missing','senseaudio-cn':'verified'},
  packs:[
    {id:'minimal-chime',name:'Minimal Chime',builtin:true,license:'CC0-1.0',author:'Claudio',events:{task_start:'task_start.aiff',stop:'stop.aiff',stop_failure:'stop_failure.aiff',subagent_stop:'subagent_stop.aiff'},identity:1},
    {id:'pikachu',name:'Pikachu',builtin:false,events:{task_start:'pika-go.mp3',stop:'pika-done.mp3',stop_failure:'pika-oops.mp3',notification:'pika-pika.mp3',subagent_stop:'pika-sub.mp3'},identity:2},
    {id:'lofi-focus',name:'Lo-Fi Focus',builtin:false,events:{task_start:'lofi-start.m4a',stop:'lofi-end.m4a',stop_failure:'lofi-pause.m4a'},identity:3},
    {id:'licensed-remix',name:'Licensed Remix',builtin:false,license:'CC-BY-4.0',author:'Original Artist',events:{stop:'bell.mp3'},identity:4},
  ],
  selected:{global:'pikachu',claude:null,codex:null,workbuddy:'pikachu'},
  selPack:'pikachu',draft:null,composer:null,gate:null,
  notice:null,badConfig:false,brokenPack:false,partial:false,failNext:'',
  muted:{},volume:80,serial:5,generation:0,playingKey:null,qwenPrevious:{},
};}
let S=initialState();
function currentProfile(){return PROFILES.find(p=>p.id===S.profile);}
function packById(id){return id==='draft'?S.draft:S.packs.find(p=>p.id===id);}
function healthy(p){return !!p&&!p.broken&&!(S.brokenPack&&p.id==='lofi-focus');}
function effectiveSelection(scope){
  if(scope==='codex'&&S.badConfig)return {error:'Codex 的显式声音覆盖损坏，已停止播放；不会回退全局默认。'};
  const id=scope==='global'?S.selected.global:(S.selected[scope]||S.selected.global);
  const p=packById(id);
  if(!healthy(p))return {error:`「${p?.name||id}」不可用，不能播放或假装继承。`};
  return {pack:p,inherited:scope!=='global'&&!S.selected[scope]};
}
function consumersOf(id){
  const names=[];let incomplete=false;
  for(const scope of ['global',...Object.keys(HOSTS)]){
    const resolved=effectiveSelection(scope);
    if(resolved.error){incomplete=true;continue;}
    if(resolved.pack.id===id)names.push(scopeName(scope)+(resolved.inherited?'（继承全局）':''));
  }
  return {names,incomplete};
}
function coverage(p){return EVENTS.filter(e=>p.events[e.key]).length;}
function setNotice(text,type='info'){S.notice={text,type};}
let toastTimer;
function toast(message){const t=$('#toast');t.textContent=message;t.classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>t.classList.remove('show'),2700);}
function track(p,micro=false){return `<span class="track${micro?' micro':''}" aria-label="覆盖 ${coverage(p)}/5">${EVENTS.map(e=>p.events[e.key]?`<span class="slot" style="background:${e.hex}" title="${e.zh} · 已覆盖"></span>`:`<span class="slot missing" title="${e.zh} · 未覆盖"></span>`).join('')}</span>`;}
function tile(e){return `<span class="tile" style="background:${e.hex}26;color:${e.hex}">${e.glyph}</span>`;}
function previewEvent(key,k){try{const ac=new (window.AudioContext||window.webkitAudioContext)(),o=ac.createOscillator(),g=ac.createGain();o.frequency.value=EV[key].freq;g.gain.value=.08;o.connect(g).connect(ac.destination);o.start();o.stop(ac.currentTime+.22);o.onended=()=>ac.close();}catch{}S.playingKey=k;render();setTimeout(()=>{if(S.playingKey===k){S.playingKey=null;render();}},300);}
function previewCand(i){previewEvent(S.composer.event,'candidate-'+i);}
const DESTS=[['通用','⚙️'],['集成','🔌'],['事件与提示音','🔔','events'],['通知','🔕'],['显示','🖥'],['声音','🔊','sounds'],['用量','📊'],['快捷键','⌘'],['关于','ℹ️']];
function renderSidebar(){$('#sidebar').innerHTML=DESTS.map(([name,icon,page])=>`<button class="dest ${page?(S.page===page?'active':''):'dim'}" ${page?`onclick="goPage('${page}')"`:'disabled'}><span class="ic">${icon}</span>${name}</button>`).join('');}
function leaveDraft(){if(S.draft){S.draft=null;S.selPack=S.packs[0].id;setNotice('空提示音组草稿已取消，声音包库没有新增条目。');}}
function goPage(page){if(page!=='sounds')leaveDraft();S.page=page;S.composer=null;S.gate=null;render();}
function scopeSummary(scope){const r=effectiveSelection(scope);if(r.error)return '配置/声音不可用 · 已停止播放';if(scope==='global')return '默认值 · 未覆盖来源继承';return `${HOSTS[scope].status} · ${r.inherited?'继承全局默认':'显式选包：'+r.pack.name}`;}
function renderEvents(){
  const r=effectiveSelection(S.scope),p=r.pack;
  const rail=[['global','全局默认'],...Object.keys(HOSTS).map(id=>[id,HOSTS[id].name])].map(([id,name],i)=>`${i===1?'<div class="scope-group">Agent</div>':''}<button class="scope-item ${S.scope===id?'active':''}" onclick="pickScope('${id}')"><span class="n">${name}</span><span class="s">${esc(scopeSummary(id))}</span></button>`).join('');
  const opts=(S.scope!=='global'?`<option value="" ${S.selected[S.scope]===null?'selected':''}>继承全局默认</option>`:'')+S.packs.map(pk=>`<option value="${pk.id}" ${S.selected[S.scope]===pk.id?'selected':''}>${esc(pk.name)}${pk.builtin?'（内置）':''}</option>`).join('');
  const rows=EVENTS.map(e=>{
    const binding=S.scope==='global'?null:HOSTS[S.scope].bindings[e.key];
    const implemented=!binding||binding[1].startsWith('已实现');
    const file=p?.events[e.key],canPlay=implemented&&!!file;
    return `<div class="evrow">${tile(e)}<div class="mid"><span class="name">${e.zh} ${binding?`<span class="tag ${implemented?'':'dashed'}">${esc(binding[1])}</span>`:''}</span><span class="sub mono">${binding?esc(binding[0]):e.key}</span></div><span class="file mono">${esc(file||'—')}</span><div class="acts"><button class="iconbtn" aria-label="试听 ${e.zh}" ${canPlay?`onclick="previewEvent('${e.key}','ev-${e.key}')"`:'disabled'}>${S.playingKey==='ev-'+e.key?'■':'▶'}</button><button class="iconbtn" onclick="toggleMute('${e.key}')" aria-label="${S.muted[S.scope+'.'+e.key]?'取消静音':'静音'} ${e.zh}">${S.muted[S.scope+'.'+e.key]?'🔇':'🔊'}</button></div></div>`;
  }).join('');
  const missing=p?EVENTS.filter(e=>!p.events[e.key]&&(S.scope==='global'||HOSTS[S.scope].bindings[e.key][1].startsWith('已实现'))):[];
  $('#content').innerHTML=`<div class="page-head"><h1>事件与提示音</h1><p>选择声音作用域；缺失事件合法静默。包级生成在「声音」中完成。</p></div><div class="ev-layout"><div class="scope-rail">${rail}</div><div class="scroll"><div class="card"><h2>播放设置 · ${scopeName(S.scope)}</h2><div style="display:flex;align-items:center;gap:12px"><span style="width:64px">主音量</span><input type="range" min="0" max="100" value="${S.volume}" oninput="setVol(this.value)"><span class="vol-read mono">${S.volume}%</span></div><div class="hairline"></div><div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap"><span style="width:64px">声音包</span><select onchange="pickPack(this.value)">${opts}</select><span style="font-size:11px;color:var(--muted)">${r.error?esc(r.error):(r.inherited?'继承全局默认':'当前选择：'+esc(p.name))}</span></div><div style="margin-top:10px"><button class="btn small" onclick="manageSounds()">管理声音</button></div></div>${r.error?`<div class="notice error" style="margin-top:12px"><span class="ic">✕</span><span class="grow">${esc(r.error)} 可重新选择健康包修复。</span></div>`:''}${missing.length?`<div class="notice warn" style="margin-top:12px"><span class="ic">⚠</span><span class="grow">「${esc(p.name)}」缺少 ${missing.map(e=>e.zh).join('、')}；受支持事件会静默。</span><button class="btn small" onclick="gotoGenerate('${missing[0].key}')">去生成</button></div>`:''}<div class="card" style="margin-top:12px"><h2>事件</h2>${rows}</div></div></div>`;
}
function pickScope(scope){S.scope=scope;S.applyScope=scope;render();}
function setVol(v){S.volume=Number(v);render();}
function pickPack(id){S.selected[S.scope]=id||null;if(S.scope==='codex')S.badConfig=false;render();}
function toggleMute(key){const id=S.scope+'.'+key;S.muted[id]=!S.muted[id];render();}
function manageSounds(){S.selPack=effectiveSelection(S.scope).pack?.id||S.selected.global;S.applyScope=S.scope;goPage('sounds');}
function gotoGenerate(key){const r=effectiveSelection(S.scope);if(r.error){setNotice(r.error,'error');render();return;}S.selPack=r.pack.id;S.applyScope=S.scope;S.page='sounds';S.gate=null;S.composer=null;if(r.pack.builtin){S.gate={event:key,scope:S.scope};render();revealEvent(key,'.readonly-gate button');}else startGenerate(key);}
function renderSounds(){
  const p=packById(S.selPack)||S.packs[0],profile=currentProfile(),credential=S.credential[profile.id],usage=p.id==='draft'?{names:[],incomplete:S.badConfig}:consumersOf(p.id);
  const status={verified:'✓ 已保存 · 已验证',deferred:'已保存 · 待首次显式生成验证',pending:'新 Key 待首次显式生成验证',missing:'未配置'}[credential];
  const list=S.packs.map(pk=>{const u=consumersOf(pk.id);return `<button class="pack-item ${pk.id===p.id?'active':''}" onclick="selPack('${pk.id}')"><span class="pn">${esc(pk.name)}${pk.builtin?'<span class="tag">内置 · 只读</span>':''}${u.names.length?`<span class="capsule">使用中 ${u.names.length}</span>`:''}</span><span class="meta"><span class="pi mono">${esc(pk.id)}</span><span class="pi mono">${coverage(pk)}/5</span>${track(pk,true)}</span></button>`;}).join('');
  const svc=`<div class="card" style="margin-bottom:12px"><div class="svc-head"><span class="svc-ic">✨</span><div><div class="t1">AI 声音生成服务</div><div class="t2">只选择已注册的固定 profile · 此原型不接入真实服务</div></div></div><div class="hairline"></div><div class="svc-row"><span class="lbl">生成服务与地区</span><select class="wide-select" onchange="pickProfile(this.value)">${PROFILES.map(q=>`<option value="${q.id}" ${q.id===profile.id?'selected':''}>${esc(q.label)}</option>`).join('')}</select></div><div class="svc-row"><span class="lbl">支持能力</span><span>${profile.routes.map(k=>MODALITIES[k]).join('、')}</span></div><div class="svc-row"><span class="lbl">候选政策</span><span>${profile.kind==='styled'?'3 个真实风格候选':'3 个编号候选'}${profile.id==='senseaudio-cn'?'；音效可显示 1–2/3 部分候选':''}</span></div><div class="svc-status"><span class="${credential==='missing'?'bad':'ok'}">${status}</span><span style="flex:1"></span><span style="font-size:11px;color:var(--muted)">${esc(profile.storage)} · ${profile.validation}</span>${credential==='pending'?'<button class="btn small" onclick="cancelPending()">取消替换</button>':''}<button class="btn small" onclick="openSheet()">${credential==='missing'?'配置假 Key':'管理演示状态'}</button></div></div>`;
  const rows=EVENTS.map(e=>{
    const file=p.events[e.key];
    const gate=S.gate?.event===e.key?`<div class="notice warn readonly-gate" style="margin:4px 0 8px 34px"><span class="ic">⚠</span><span class="grow">内置包只读。${S.gate.scope?`可新建空组，或复制并用于${scopeName(S.gate.scope)}；复制成功后才应用。`:'可新建空组，或复制此包后在副本中生成。'}</span><button class="btn small" onclick="gateNew('${e.key}')">新建空组</button><button class="btn small" onclick="gateFork('${e.key}')">${S.gate.scope?'复制并用于'+(S.gate.scope==='global'?'全局默认':'此来源'):'复制此包'}</button></div>`:'';
    const fileCell=!p.builtin&&file?`<select aria-label="${e.zh} 声音文件" onchange="onFileSel('${e.key}',this.value)"><option value="${esc(file)}">${esc(file)}</option><option value="__clear">清除绑定（静默）</option></select>`:`<span class="file mono">${esc(file||'—')}</span>`;
    return `<div class="sound-event" id="sound-event-${e.key}"><div class="evrow">${tile(e)}<div class="mid"><span class="name">${e.zh}</span><span class="sub mono">${e.key}</span></div>${fileCell}<div class="acts"><button class="iconbtn" aria-label="试听 ${e.zh}" ${file?`onclick="previewEvent('${e.key}','sp-${e.key}')"`:'disabled'}>▶</button><button class="btn small generate-event" aria-label="为${e.zh}描述生成" onclick="startGenerate('${e.key}')">✨ 描述生成</button></div></div>${gate}${S.composer?.event===e.key?composerHTML():''}</div>`;
  }).join('');
  const scopeOpts=['global',...Object.keys(HOSTS)].map(id=>`<option value="${id}" ${S.applyScope===id?'selected':''}>${scopeName(id)}</option>`).join('');
  const metadata=p.license||p.author?`<div class="notice warn"><span class="ic">⚠</span><span class="grow">整包声明：${esc(p.license||'—')} / ${esc(p.author||'—')}。${p.builtin?'复制后，副本':'复制副本或采纳 AI 音频后，修改后的包'}会移除整包 license/author；原包与独立许可材料保留。</span></div>`:'';
  $('#content').innerHTML=`<div class="page-head"><h1>声音</h1><p>向用户包生成与采纳；在 Global 或 Surface 选择使用哪个包。</p></div><div class="sp-layout"><div class="pack-rail"><div class="rail-head"><button class="btn primary" onclick="newPack()">＋ 新建提示音组</button><span style="font-size:10.5px;color:var(--muted)">复制任意健康包可做底子</span>${S.draft?`<div class="draft-note">未发布草稿「${esc(S.draft.name)}」· 首音采纳成功才进入下方列表</div>`:''}</div><div class="pack-list">${list}</div></div><div class="sp-main"><div class="sp-detail">${svc}${S.notice?`<div class="notice ${S.notice.type==='error'?'error':S.notice.type==='warn'?'warn':''}"><span class="ic">${S.notice.type==='error'?'✕':'ⓘ'}</span><span class="grow">${esc(S.notice.text)}</span></div>`:''}<div class="sp-head"><span class="name">${esc(p.name)}</span>${p.id==='draft'?'<span class="tag dashed">未发布草稿</span>':p.builtin?'<span class="tag">内置 · 只读</span>':'<span class="tag">用户包</span>'}<span class="cov mono">${coverage(p)}/5</span>${track(p)}</div>${p.id==='draft'?`<div style="margin:7px 0"><label>组名 <input class="name-input" value="${esc(p.name)}" oninput="renameDraft(this.value)"></label><button class="btn small" style="margin-left:8px" onclick="cancelDraft()">取消空组</button></div>`:''}<div class="notice ${usage.incomplete?'warn':''}" style="margin:8px 0"><span class="ic">ⓘ</span><span class="grow">${usage.names.length?'使用中：'+esc(usage.names.join('、'))+'。修改此包将立即影响这些有效使用者。':'当前没有可确认的使用者。'}${usage.incomplete?' 使用范围不完整：配置损坏，未将损坏覆盖当作继承。':''}</span></div>${!healthy(p)?'<div class="notice error"><span class="ic">✕</span><span class="grow">此包损坏，不能复制或采纳；请修复或重选。</span></div>':''}${metadata}<div class="card" style="padding-top:4px">${rows}</div></div><div class="sp-actions">${p.id==='draft'?'<span class="draft-note">首音成功前不入库，不可选用</span>':`<button class="btn" onclick="forkCurrent()">复制为我的包</button><span class="draft-note">若有整包 license/author，副本会移除；普通复制不应用</span>`}<span class="spacer"></span><label>选用目标 <select onchange="S.applyScope=this.value;render()">${scopeOpts}</select></label>${p.id==='draft'?'':`<button class="btn primary" onclick="useThisPack()">用于${scopeName(S.applyScope)}</button>`}</div></div></div>`;
}
function render(){renderSidebar();S.page==='sounds'?renderSounds():renderEvents();}
function selPack(id){if(S.draft&&id!=='draft')leaveDraft();S.selPack=id;S.composer=null;S.gate=null;S.notice=null;render();}
function onFileSel(key,value){const p=packById(S.selPack);if(value==='__clear'&&healthy(p)&&!p.builtin&&EV[key]){delete p.events[key];if(p.eventNames)delete p.eventNames[key];setNotice(`已清除「${EV[key].zh}」绑定；该事件将静默。`);render();}}
function revealEvent(key,focusSelector){requestAnimationFrame(()=>{const row=document.getElementById('sound-event-'+key);row?.scrollIntoView({block:'start'});row?.querySelector(focusSelector)?.focus({preventScroll:true});});}
function renameDraft(name){if(S.draft)S.draft.name=name.slice(0,64);}
function newPack(){S.composer=null;S.gate=null;S.draft={id:'draft',name:`我的提示音组 ${S.serial}`,builtin:false,events:{},identity:S.serial++};S.selPack='draft';setNotice('空组只是未发布草稿；取消不入库，首个音采纳成功才发布。');render();}
function cancelDraft(){S.draft=null;S.composer=null;S.selPack=S.packs[0].id;setNotice('空组已取消，声音包库未新增条目。');render();}
function consumeFailure(kind){if(S.failNext!==kind)return false;S.failNext='';$('#demoFail').value='';return true;}
function forkCurrent(scope=null,event=null){const src=packById(S.selPack);if(!healthy(src)||src.id==='draft'){setNotice('复制失败：源包不健康或尚未发布。','error');render();return false;}if(consumeFailure('copy')){setNotice('复制失败：未创建副本，原包和选包保持不变。','error');render();return false;}
  const id=`${src.id}-copy-${S.serial++}`;const cp={...src,id,name:src.name+' 副本',builtin:false,events:{...src.events},eventNames:{...src.eventNames},identity:S.serial};delete cp.license;delete cp.author;S.packs.push(cp);S.selPack=id;S.composer=null;S.gate=null;
  if(scope){if(!applyPack(scope,id)){setNotice(`「${cp.name}」复制成功，但未能用于${scopeName(scope)}；副本已保留在侧栏，可稍后重试。`,'error');render();if(event)revealEvent(event,'.generate-event');return true;}setNotice(`「${cp.name}」复制成功，已用于${scopeName(scope)}。现在可为「${EV[event].zh}」显式生成。`);}else setNotice(`「${cp.name}」复制成功并已发布；只查看副本，未改变 Global 或任何 Surface 的选包。`);
  render();if(event)revealEvent(event,'.generate-event');return true;
}
function applyPack(scope,id){if(!['global',...Object.keys(HOSTS)].includes(scope)||!healthy(packById(id))||scope==='codex'&&S.badConfig||consumeFailure('apply'))return false;S.selected[scope]=id;return true;}
function useThisPack(){const p=packById(S.selPack),scope=S.applyScope;if(!applyPack(scope,p?.id)){setNotice(`未能将「${p?.name||'此包'}」用于${scopeName(scope)}；现有选包保持不变。`,'error');render();return;}setNotice(`已将「${p.name}」用于${scopeName(scope)}。`);render();}
function gateNew(key){newPack();startGenerate(key);}
function gateFork(key){const scope=S.gate?.scope||null;forkCurrent(scope,key);}
function pickProfile(id){const profile=PROFILES.find(p=>p.id===id);if(!profile)return;const prior=S.composer;S.profile=id;if(prior)S.composer={...prior,phase:'edit',cands:[],generation:null,profile:id,modality:profile.routes.includes(prior.modality)?prior.modality:profile.routes[0]};S.gate=null;setNotice('已切换固定 profile；旧候选已失效，描述已保留。');render();}
function startGenerate(key){const p=packById(S.selPack);if(!p||!EV[key]){setNotice('生成目标无效。','error');render();return;}if(p.builtin){S.composer=null;S.gate={event:key,scope:null};render();revealEvent(key,'.readonly-gate button');return;}if(!healthy(p)){setNotice('包不健康，不能生成或采纳。','error');render();return;}S.gate=null;S.composer={packId:p.id,packIdentity:p.identity,event:key,profile:S.profile,modality:'soundEffect',phase:'edit',desc:'',name:'',cands:[],generation:null};if(!currentProfile().routes.includes('soundEffect'))S.composer.modality='speech';render();revealEvent(key,'.composer textarea');}
function composerHTML(){const c=S.composer,p=packById(c.packId),profile=currentProfile(),usage=p.id==='draft'?{names:[],incomplete:false}:consumersOf(p.id),locked=c.phase==='generating',ready=c.phase==='cands';
  const select=profile.routes.map(k=>`<option value="${k}" ${c.modality===k?'selected':''}>${MODALITIES[k]}</option>`).join('');
  const desc=locked||ready?`<div class="card" style="white-space:pre-wrap;max-height:95px;overflow:auto" aria-label="已锁定声音描述">${esc(c.desc)}</div>`:`<textarea placeholder="${c.modality==='speech'?'例如：清晰地说“任务完成”，短促温暖':'例如：轻快的木鱼声，短促、温暖、不刺耳'}" oninput="S.composer.desc=this.value">${esc(c.desc)}</textarea>`;
  const identities=ready?`<div class="row"><label>提示音名称 <input class="name-input" value="${esc(c.name)}" oninput="S.composer.name=this.value"></label><span class="hint">改名不重新生成；名称不发送给服务。</span></div>${c.cands.length<3?`<div class="notice warn" style="margin:9px 0 0"><span class="ic">⚠</span><span class="grow">仅生成 ${c.cands.length}/3 个可用候选（此路线允许 partial）。</span></div>`:''}<div class="cands">${c.cands.map((cd,i)=>`<div class="cand"><span class="cn">${esc(cd.label)}</span><div class="wave" id="candwave${i}">${Array.from({length:20},(_,n)=>`<i style="height:${20+((n*17+i*13)%65)}%"></i>`).join('')}</div><span class="cf">已校验 · 临时候选 ${i+1}</span><div><button class="btn small" onclick="previewCand(${i})">▶ 试听</button> <button class="btn primary small" onclick="adopt(${i})">采纳到此包</button></div></div>`).join('')}</div>`:'';
  return `<div class="composer"><div class="row" style="margin-top:0"><strong>${EV[c.event].zh} · ${esc(p.name)}</strong><span class="spacer"></span><label>声音类型 <select onchange="changeModality(this.value)" ${locked?'disabled':''}>${select}</select></label></div><div style="margin-top:9px">${desc}</div>${identities}<div class="row">${locked?'<span class="spinner"></span><span class="hint">生成中，描述已锁定；如需修改，请先取消。</span>':ready?'<button class="btn small" onclick="editDescription()">修改描述</button><button class="btn small" onclick="doGenerate()">重新生成</button>':`<button class="btn primary small" onclick="doGenerate()">生成候选</button>`}<button class="btn small" onclick="cancelComposer()">取消</button></div><div class="hint" style="margin-top:8px">${usage.names.length?'此包正被 '+esc(usage.names.join('、'))+' 使用；采纳后立即生效。':''}${usage.incomplete?'使用范围不完整。':''}${p.license||p.author?' 采纳后移除修改后包的整包 license/author 声明。':''} ${ready?'凭据后来消失不影响已验证候选的采纳。':'生成需要当前 profile 的凭据；采纳前会重新校验包、事件和候选身份。'}</div></div>`;
}
function changeModality(v){if(!currentProfile().routes.includes(v))return;S.composer.modality=v;S.composer.cands=[];S.composer.phase='edit';render();}
function editDescription(){const c=S.composer;if(!c)return;c.phase='edit';c.cands=[];c.generation=null;render();}
function cancelComposer(){S.composer=null;if(S.draft){cancelDraft();return;}setNotice('已取消，未采纳候选已失效；原有声音未变。');render();}
function doGenerate(){const c=S.composer,p=packById(c?.packId),profile=currentProfile();if(!c||!healthy(p)||p.builtin||p.identity!==c.packIdentity){setNotice('生成目标已变化，请重新选择健康用户包。','error');render();return;}if(!profile.routes.includes(c.modality)){setNotice('所选固定 profile 不支持此声音类型。','error');render();return;}if(!c.desc.trim()){setNotice('请先填写声音描述。','warn');render();return;}if(['speech','mixed'].includes(c.modality)&&!/[“"][^”"]+[”"]/.test(c.desc)){setNotice('语音需在描述中用引号写明要说的台词。','warn');render();return;}if(S.credential[S.profile]==='missing'){setNotice('G3：当前 profile 未配置。保存演示假 Key 后，请再次显式点击生成。','warn');openSheet();render();return;}
  c.phase='generating';c.cands=[];c.profile=S.profile;c.generation=++S.generation;const token=c.generation;render();setTimeout(()=>{if(S.composer!==c||c.phase!=='generating'||c.generation!==token||S.profile!==c.profile)return;const partial=S.partial&&c.profile==='senseaudio-cn'&&['animal','soundEffect'].includes(c.modality),count=partial?2:3;const kind=profile.kind;c.cands=Array.from({length:count},(_,i)=>({generation:token,profile:c.profile,route:c.modality,ordinal:i+1,kind,validated:true,label:kind==='styled'?['清晰','轻快','克制'][i]:`候选 ${i+1}`}));c.phase='cands';c.name=(c.desc.match(/[“"]([^”"]+)[”"]/)?.[1]||EV[c.event].zh+'提示音').slice(0,48);if(S.credential[c.profile]==='deferred'||S.credential[c.profile]==='pending')S.credential[c.profile]='verified';render();},900);
}
function validCandidateSet(c){if(!c||!c.generation||!PROFILES.some(p=>p.id===c.profile&&p.routes.includes(c.modality)))return false;const partial=c.profile==='senseaudio-cn'&&['animal','soundEffect'].includes(c.modality),expectedKind=PROFILES.find(p=>p.id===c.profile).kind;if(c.cands.length<1||c.cands.length>3||!partial&&c.cands.length!==3)return false;return c.cands.every((x,i)=>x.validated&&x.generation===c.generation&&x.profile===c.profile&&x.route===c.modality&&x.kind===expectedKind&&x.ordinal===i+1);}
function adopt(i){const c=S.composer,p=packById(c?.packId),cd=c?.cands?.[i];if(!c||c.phase!=='cands'||!healthy(p)||p.builtin||p.identity!==c.packIdentity||!EV[c.event]||S.profile!==c.profile||!validCandidateSet(c)||!cd||cd.ordinal!==i+1){setNotice('采纳失败：包、事件或候选身份已变化；旧绑定保留。','error');render();return;}if(!c.name.trim()){setNotice('采纳前请填写提示音名称；旧绑定保留。','warn');render();return;}if(consumeFailure('adopt')){setNotice('采纳失败：导入或绑定没有完整成功；旧声音与未发布草稿保持原状。','error');render();return;}
  const wasDraft=p.id==='draft';if(wasDraft){if(!p.name.trim()){setNotice('请先为提示音组命名；空组未发布。','warn');render();return;}p.id=`custom-${S.serial++}`;S.packs.push(p);S.draft=null;S.selPack=p.id;}
  const hadDeclaration=!!(p.license||p.author);const file=`ai-${S.serial++}.${c.profile.startsWith('qwen')?'wav':'mp3'}`;p.events[c.event]=file;p.eventNames={...p.eventNames,[c.event]:c.name.trim()};delete p.license;delete p.author;S.composer=null;setNotice(`${wasDraft?'首音采纳成功，提示音组已发布。':'采纳成功。'}「${EV[c.event].zh}」已绑定「${c.name.trim()}」；覆盖 ${coverage(p)}/5。${hadDeclaration?'修改后包的整包 license/author 已移除。':''}`);render();}
function openSheet(){const p=currentProfile();$('#sheetTitle').textContent=p.label+' · 演示凭据';$('#sheetBody').textContent=`仅切换 ${p.id} 的模拟凭据状态；不会请求 ${p.label} 或保存真实 Key。${p.storage}；${p.validation}。保存后仍需再次显式点击生成。请勿输入真实 API Key。`;$('#keySave').textContent=p.id.startsWith('qwen')?'模拟保存假 Key（待生成验证）':'模拟验证并保存假 Key';$('#sheetOverlay').style.display='flex';}
function closeSheet(){$('#sheetOverlay').style.display='none';}
$('#keyCancel').onclick=closeSheet;
$('#keySave').onclick=()=>{const id=S.profile,old=S.credential[id];if(id.startsWith('qwen')&&old!=='missing'){S.qwenPrevious[id]=old;S.credential[id]='pending';}else S.credential[id]=id.startsWith('qwen')?'deferred':'verified';closeSheet();setNotice('演示假 Key 状态已保存；没有发起生成。请再次显式点击生成。');render();};
function cancelPending(){const id=S.profile;if(S.credential[id]!=='pending')return;S.credential[id]=S.qwenPrevious[id]||'deferred';delete S.qwenPrevious[id];setNotice('已取消新假 Key 的待验证替换，原凭据状态已恢复。');render();}
$('#demoCredential').onclick=()=>{const id=S.profile;S.credential[id]=S.credential[id]==='missing'?(id.startsWith('qwen')?'deferred':'verified'):'missing';setNotice(`${currentProfile().label} 的演示凭据现为 ${S.credential[id]==='missing'?'未配置':'已保存'}；已生成的有效候选仍可采纳。`);render();};
$('#demoDamaged').onchange=e=>{S.badConfig=e.target.checked;render();};
$('#demoBroken').onchange=e=>{S.brokenPack=e.target.checked;render();};
$('#demoPartial').onchange=e=>{S.partial=e.target.checked;render();};
$('#demoFail').onchange=e=>{S.failNext=e.target.value;};
$('#demoReset').onclick=()=>{S=initialState();$('#demoDamaged').checked=false;$('#demoBroken').checked=false;$('#demoPartial').checked=false;$('#demoFail').value='';closeSheet();toast('演示数据已重置');render();};
window.demoState=()=>JSON.parse(JSON.stringify(S));
if(location.hash==='#events')S.page='events';render();
