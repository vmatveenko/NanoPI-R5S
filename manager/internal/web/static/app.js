const $=id=>document.getElementById(id);
let csrf='',inventory=null,routerState=null,currentPlan=null,pendingRevision='',timer=null,setupMode=false,releases=[],currentVersion='';

async function api(path,options={}){
  const headers={'Content-Type':'application/json',...(options.headers||{})};
  if(csrf&&options.method&&options.method!=='GET')headers['X-CSRF-Token']=csrf;
  const response=await fetch(path,{credentials:'same-origin',...options,headers});
  let data={};try{data=await response.json()}catch{}
  if(!response.ok)throw new Error(data.error||`HTTP ${response.status}`);
  return data;
}
function toast(message,error=false){const el=$('toast');el.textContent=message;el.className=error?'show error-toast':'show';setTimeout(()=>el.className='',5000)}

async function boot(){
  try{
    const state=await api('/api/bootstrap');setupMode=!state.initialized;
    $('authHint').textContent=setupMode?'Первый вход: создайте единственного администратора. Пароль не может быть пустым.':'Войдите под локальным администратором.';
    $('authPassword').autocomplete=setupMode?'new-password':'current-password';
    $('authSubmit').textContent=setupMode?'Создать администратора':'Войти';$('authForm').classList.remove('hidden');
    try{const session=await api('/api/session');enter(session)}catch{}
  }catch(e){$('authError').textContent=e.message}
}
$('authForm').addEventListener('submit',async e=>{e.preventDefault();$('authError').textContent='';try{const data=await api(setupMode?'/api/setup':'/api/login',{method:'POST',body:JSON.stringify({username:$('authUsername').value,password:$('authPassword').value})});enter(data)}catch(err){$('authError').textContent=err.message}});
async function enter(session){csrf=session.csrfToken;$('username').textContent=session.username;$('authView').classList.add('hidden');$('appView').classList.remove('hidden');$('userArea').classList.remove('hidden');await loadAll()}
$('logout').onclick=async()=>{try{await api('/api/logout',{method:'POST',body:'{}'})}finally{location.reload()}};

document.querySelectorAll('.side-nav button').forEach(button=>button.onclick=()=>{
  if(button.disabled)return;
  document.querySelectorAll('.side-nav button,.page').forEach(el=>el.classList.remove('active'));
  button.classList.add('active');$(button.dataset.target).classList.add('active');
});

async function loadAll(){await Promise.allSettled([loadInventory(),loadDiagnostics(),loadState(),loadRouterStatus(),loadDockerStatus()])}
async function loadInventory(){try{inventory=await api('/api/inventory');$('hostName').textContent=inventory.hostname||'NanoPi';$('hostMeta').textContent=`${inventory.os||''} · ${inventory.architecture||''} · kernel ${inventory.kernel||'—'}`;renderInterfaces()}catch(e){toast(e.message,true)}}
function renderInterfaces(){
  const select=$('wanInterface'),box=$('lanInterfaces');select.innerHTML='';box.innerHTML='';
  (inventory.interfaces||[]).filter(i=>i.physical).forEach(item=>{
    const o=document.createElement('option');o.value=item.name;o.textContent=`${item.name} · ${item.mac} · ${item.state}`;o.selected=item.defaultWan;select.append(o);
    const label=document.createElement('label');label.className='check';label.innerHTML=`<input type="checkbox" value="${escapeHTML(item.name)}"> ${escapeHTML(item.name)} <span class="muted">${escapeHTML(item.state)}</span>`;box.append(label);
  });
  if(!select.value&&select.options.length)select.selectedIndex=0;
  box.querySelectorAll('input').forEach(input=>input.checked=input.value!==select.value);
  select.onchange=syncInterfaceRoles;$('macMode').onchange=syncMAC;applyInterfaceState();
}
function applyInterfaceState(){
  if(!inventory)return;const select=$('wanInterface'),box=$('lanInterfaces'),c=routerState;
  if(c){if(c.wanInterface&&[...select.options].some(option=>option.value===c.wanInterface))select.value=c.wanInterface;const saved=Boolean(c.wanInterface)||(c.lanInterfaces||[]).length>0;if(saved)box.querySelectorAll('input').forEach(input=>input.checked=(c.lanInterfaces||[]).includes(input.value))}
  syncInterfaceRoles();
}
function syncInterfaceRoles(){const wan=$('wanInterface').value;$('lanInterfaces').querySelectorAll('input').forEach(input=>{const same=input.value===wan;if(same)input.checked=false;input.disabled=same});syncMAC()}
function syncMAC(){if(!inventory)return;const mode=$('macMode').value,wan=(inventory.interfaces||[]).find(i=>i.name===$('wanInterface').value);if(mode==='factory')$('wanMac').value=wan?.permanentMac||'';if(mode==='current')$('wanMac').value='';if(mode==='clone'&&!$('wanMac').value){const source=(inventory.interfaces||[]).find(i=>i.physical&&i.name!==$('wanInterface').value);if(source)$('wanMac').value=source.mac||''}}

async function loadState(){
  try{
    const data=await api('/api/state'),c=data.routerConfig;if(!c)return;routerState=c;
    $('bridge').value=c.bridge||'br0';$('lanCidr').value=c.lanCidr||'';$('dhcpStart').value=c.dhcpStart||'';$('dhcpEnd').value=c.dhcpEnd||'';$('dns').value=(c.dns||[]).join(', ');
    $('macMode').value=c.wanMacMode||'current';$('wanMac').value=c.wanMac||'';$('managerPort').value=c.managerPort||8080;$('panelPort').value=c.panelPort||2053;
    $('managerWanAccess').checked=Boolean(c.managerWanAccess);$('managerWanSources').value=(c.managerWanSources||[]).join(', ');$('panelUrl').value=`http://127.0.0.1:${c.panelPort||2053}`;
    renderFirewallRules(c.wanPorts||[]);applyInterfaceState();
  }catch(e){toast(e.message,true)}
}
function routerConfig(){return{
  wanInterface:$('wanInterface').value,wanMacMode:$('macMode').value,wanMac:$('wanMac').value.trim(),
  lanInterfaces:[...document.querySelectorAll('#lanInterfaces input:checked')].map(i=>i.value),bridge:$('bridge').value.trim(),lanCidr:$('lanCidr').value.trim(),dhcpStart:$('dhcpStart').value.trim(),dhcpEnd:$('dhcpEnd').value.trim(),dns:csv($('dns').value),
  managerPort:Number($('managerPort').value),managerWanAccess:$('managerWanAccess').checked,managerWanSources:csv($('managerWanSources').value),panelPort:Number($('panelPort').value),wanPorts:readFirewallRules()
}}
const csv=value=>value.split(',').map(x=>x.trim()).filter(Boolean);

$('routerForm').addEventListener('submit',async e=>{
  e.preventDefault();try{
    currentPlan=await api('/api/router/plan',{method:'POST',body:JSON.stringify(routerConfig())});$('planCard').classList.remove('hidden');$('applyRouter').disabled=false;
    $('planWarnings').innerHTML=(currentPlan.warnings||[]).map(w=>`<p>⚠ ${escapeHTML(w)}</p>`).join('');
    $('planOutput').textContent=currentPlan.files.map(f=>`### ${f.path}${f.changed?' · изменяется':' · без изменений'}\n${f.diff||'(изменений нет)'}`).join('\n\n')+'\n\nКоманды:\n'+currentPlan.commands.join('\n');
    $('planBadge').textContent='проверен';toast('План сформирован, система ещё не изменена');
  }catch(e){toast(e.message,true)}
});
$('applyRouter').onclick=async()=>{
  if(!currentPlan||!confirm('Применить сетевую конфигурацию? Связь может прерваться. Через 120 секунд без подтверждения произойдёт откат.'))return;
  try{
    const result=await api('/api/router/apply',{method:'POST',body:JSON.stringify(routerConfig())});pendingRevision=result.revisionId;startCountdown(result.confirmationTtlSeconds||120);$('rollbackCard').classList.remove('hidden');toast('Конфигурация применена. Подтвердите доступ.');
    if(result.managerRestart){const next=`${location.protocol}//${location.hostname}:${result.managerPort}${location.pathname}`;setTimeout(()=>location.assign(next),2500)}
  }catch(e){toast(e.message,true)}
};
function startCountdown(seconds){clearInterval(timer);seconds=Math.max(0,Math.ceil(seconds));$('countdown').textContent=seconds;timer=setInterval(()=>{seconds--;$('countdown').textContent=Math.max(0,seconds);if(seconds<=0){clearInterval(timer);toast('Время подтверждения истекло — выполняется автоматический откат',true);setTimeout(()=>location.reload(),2500)}},1000)}
$('confirmRouter').onclick=async()=>{try{await api('/api/router/confirm',{method:'POST',body:JSON.stringify({revisionId:pendingRevision})});clearInterval(timer);$('rollbackCard').classList.add('hidden');$('planBadge').textContent='применён';toast('Конфигурация подтверждена');await loadRouterStatus()}catch(e){toast(e.message,true)}};
$('rollbackRouter').onclick=async()=>{try{const result=await api('/api/router/rollback',{method:'POST',body:JSON.stringify({revisionId:pendingRevision})});clearInterval(timer);$('rollbackCard').classList.add('hidden');toast('Предыдущая конфигурация восстановлена');returnToManagerPort(result.managerPort)}catch(e){toast(e.message,true)}};
async function loadRouterStatus(){try{const status=await api('/api/router/status');$('routerStatusText').textContent=status.pending?'Изменения ожидают подтверждения':status.active?'Активен; доступен полный откат к состоянию до первого применения':'Не применён';$('deactivateRouter').disabled=!status.active;$('deactivateRouter').textContent=status.active?'Откатить режим полностью':'Режим не применён';if(status.pending){pendingRevision=status.pendingRevision;const left=(new Date(status.rollbackDueAt).getTime()-Date.now())/1000;startCountdown(left);$('rollbackCard').classList.remove('hidden')}}catch(e){toast(e.message,true)}}
$('deactivateRouter').onclick=async()=>{if(!confirm('Полностью отключить режим маршрутизатора и восстановить сетевые файлы и состояние служб до первого применения? Соединение может прерваться.'))return;try{const result=await api('/api/router/deactivate',{method:'POST',body:'{}'});toast('Исходная конфигурация восстановлена');returnToManagerPort(result.managerPort)}catch(e){toast(e.message,true)}};
function returnToManagerPort(port){const target=Number(port)||8080;setTimeout(()=>location.assign(`${location.protocol}//${location.hostname}:${target}${location.pathname}`),2500)}

function renderFirewallRules(rules){const box=$('firewallRules');box.innerHTML='';rules.forEach(addFirewallRule);if(!rules.length)box.innerHTML='<p class="muted empty-rules">Пользовательских правил нет.</p>'}
function addFirewallRule(rule={protocol:'tcp',port:443,description:'',sources:[],disabled:false}){
  const empty=$('firewallRules').querySelector('.empty-rules');if(empty)empty.remove();
  const row=document.createElement('div');row.className='rule-row';row.innerHTML=`
    <label>Протокол<select data-field="protocol"><option value="tcp">TCP</option><option value="udp">UDP</option></select></label>
    <label>Порт<input data-field="port" type="number" min="1" max="65535" value="${Number(rule.port)||443}"></label>
    <label>Описание<input data-field="description" maxlength="128" value="${escapeHTML(rule.description||'')}"></label>
    <label class="rule-sources">IPv4/CIDR через запятую<input data-field="sources" value="${escapeHTML((rule.sources||[]).join(', '))}" placeholder="пусто = любой источник"></label>
    <label class="inline-check"><input data-field="enabled" type="checkbox" ${rule.disabled?'':'checked'}> Включено</label>
    <button type="button" class="secondary remove-rule">Удалить</button>`;
  row.querySelector('[data-field="protocol"]').value=rule.protocol||'tcp';row.querySelector('.remove-rule').onclick=()=>{row.remove();if(!$('firewallRules').children.length)renderFirewallRules([])};$('firewallRules').append(row);
}
function readFirewallRules(){return[...$('firewallRules').querySelectorAll('.rule-row')].map(row=>({protocol:row.querySelector('[data-field="protocol"]').value,port:Number(row.querySelector('[data-field="port"]').value),description:row.querySelector('[data-field="description"]').value.trim(),sources:csv(row.querySelector('[data-field="sources"]').value),disabled:!row.querySelector('[data-field="enabled"]').checked}))}
$('addFirewallRule').onclick=()=>addFirewallRule();
async function loadFirewallStatus(){try{const data=await api('/api/firewall/status',{method:'POST',body:JSON.stringify(routerConfig())});$('systemRules').innerHTML=(data.systemRules||[]).map(x=>`<span>${escapeHTML(x)}</span>`).join('');$('firewallResult').textContent=`${data.routerActive?'Режим маршрутизатора активен':'Режим маршрутизатора не применён'} · ${data.inSync?'конфигурация синхронизирована':'есть неприменённые изменения'}`}catch(e){toast(e.message,true)}}
$('refreshFirewall').onclick=loadFirewallStatus;
$('saveFirewall').onclick=async()=>{try{const result=await api('/api/firewall/apply',{method:'POST',body:JSON.stringify(routerConfig())});routerState=routerConfig();$('firewallResult').textContent=result.message;toast(result.applied?'Правила firewall применены':'Правила сохранены и будут применены вместе с режимом маршрутизатора');await loadFirewallStatus()}catch(e){toast(e.message,true)}};

async function loadDockerStatus(){try{const data=await api('/api/docker/status');const ready=data.installed&&data.daemonActive;$('xuiTab').disabled=!ready;$('xuiTab').title=ready?'':'Сначала запустите Docker';$('dockerSummary').innerHTML=`<b class="${ready?'ok':'bad'}">${ready?'Docker работает':'Docker не готов'}</b><span>${escapeHTML(data.version||'не установлен')}</span>${data.serverVersion?`<small>Engine ${escapeHTML(data.serverVersion)}</small>`:''}${data.error?`<small class="bad">${escapeHTML(data.error)}</small>`:''}`;$('containerList').innerHTML=(data.containers||[]).length?(data.containers||[]).map(c=>`<div class="container-row"><div><b>${escapeHTML(c.name)}</b><small>${escapeHTML(c.image)}</small></div><span class="${c.state==='running'?'ok':'bad'}">${escapeHTML(c.status||c.state)}</span><small>restart: ${escapeHTML(c.restartPolicy||'—')}</small></div>`).join(''):'<p class="muted">Контейнеров нет.</p>'}catch(e){$('dockerSummary').textContent=e.message}}
$('refreshDocker').onclick=loadDockerStatus;
$('installDocker').onclick=()=>operation('/api/docker/install',{},'Docker установлен или обновлён',$('dockerResult'),loadDockerStatus);
document.querySelectorAll('[data-xui]').forEach(button=>button.onclick=()=>operation('/api/xui/action',{action:button.dataset.xui,panelPort:Number($('panelPort').value)},`3x-ui: ${button.textContent}`,$('serviceResult'),loadDockerStatus));
$('bootstrapTun').onclick=()=>operation('/api/xui/bootstrap-tun',{panelUrl:$('panelUrl').value.trim(),apiToken:$('xuiToken').value,wanInterface:$('wanInterface').value},'TUN проверен',$('serviceResult'),()=>{$('xuiToken').value=''});
async function operation(path,payload,message,target,after){target.textContent='Выполняется…';try{const result=await api(path,{method:'POST',body:JSON.stringify(payload)});target.textContent=result.message||message;toast(target.textContent);if(after)await after();await loadDiagnostics()}catch(e){target.textContent=e.message;toast(e.message,true)}}

$('passwordForm').addEventListener('submit',async e=>{e.preventDefault();if($('newPassword').value!==$('confirmPassword').value){toast('Новый пароль и подтверждение не совпадают',true);return}try{await api('/api/password',{method:'POST',body:JSON.stringify({currentPassword:$('currentPassword').value,newPassword:$('newPassword').value,confirmation:$('confirmPassword').value})});alert('Пароль изменён. Все сеансы завершены, войдите снова.');location.reload()}catch(err){toast(err.message,true)}});

$('checkUpdates').onclick=loadReleases;$('includePrerelease').onchange=loadReleases;
async function loadReleases(){try{const data=await api(`/api/manager/releases?prerelease=${$('includePrerelease').checked}`);releases=data.releases||[];currentVersion=data.currentVersion||'dev';const select=$('releaseVersion');select.innerHTML='';releases.forEach(r=>{const option=document.createElement('option');option.value=r.version;option.textContent=`${r.version}${r.prerelease?' · prerelease':''}${r.version===currentVersion?' · установлена':''}`;select.append(option)});if(!releases.length){select.innerHTML='<option>Подходящих релизов нет</option>';select.disabled=true;$('installUpdate').disabled=true}else{select.disabled=false;$('installUpdate').disabled=false}select.onchange=syncUpdateRisk;syncUpdateRisk();$('updateResult').textContent=`Текущая версия: ${currentVersion}`}catch(e){$('updateResult').textContent=e.message;toast(e.message,true)}}
function versionParts(value){const m=String(value).replace(/^v/,'').split('-')[0].split('.').map(Number);return m.every(Number.isFinite)?m:null}
function older(a,b){const x=versionParts(a),y=versionParts(b);if(!x||!y)return false;for(let i=0;i<Math.max(x.length,y.length);i++){if((x[i]||0)!==(y[i]||0))return(x[i]||0)<(y[i]||0)}return false}
function syncUpdateRisk(){const chosen=releases.find(r=>r.version===$('releaseVersion').value),risk=chosen&&(chosen.prerelease||older(chosen.version,currentVersion));$('updateRiskWrap').classList.toggle('hidden',!risk);if(!risk)$('updateRisk').checked=false}
$('installUpdate').onclick=async()=>{const version=$('releaseVersion').value,chosen=releases.find(r=>r.version===version);if(!chosen)return;const risk=chosen.prerelease||older(version,currentVersion);if(risk&&!$('updateRisk').checked){toast('Подтвердите риск выбранной версии',true);return}if(!confirm(`Установить NanoPi Manager ${version}? Службы будут перезапущены; при неуспешной проверке версия откатится автоматически.`))return;try{const result=await api('/api/manager/update',{method:'POST',body:JSON.stringify({version,confirmRisk:risk&&$('updateRisk').checked})});$('updateResult').textContent=result.message;toast('Обновление запланировано, ожидайте перезапуска');setTimeout(()=>location.reload(),6000)}catch(e){$('updateResult').textContent=e.message;toast(e.message,true)}};

async function loadDiagnostics(){try{const data=await api('/api/diagnostics');const comps=data.components||[];$('diagnosticsGrid').innerHTML=comps.map(c=>`<article class="diag-item"><b class="${c.ok?'ok':'bad'}">${c.ok?'●':'○'} ${escapeHTML(c.name)}</b><span>${escapeHTML(c.summary)}</span>${c.detail?`<small>${escapeHTML(c.detail)}</small>`:''}</article>`).join('');$('statusGrid').innerHTML=comps.slice(0,6).map(c=>`<article class="status-item"><b>${escapeHTML(c.name)}</b><span class="${c.ok?'ok':'bad'}">${escapeHTML(c.summary)}</span></article>`).join('')}catch(e){toast(e.message,true)}}
$('refreshDiagnostics').onclick=loadDiagnostics;$('refreshAll').onclick=loadAll;
function escapeHTML(value){return String(value??'').replace(/[&<>'"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]))}
boot();
