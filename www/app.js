'use strict';
const BUILD_VERSION='2026.11.19.09';
const state={scripts:[],current:null,update:null};
const $=id=>document.getElementById(id);

function toast(msg,error=false){const e=$('toast');e.textContent=msg;e.className='toast show'+(error?' error':'');clearTimeout(toast.t);toast.t=setTimeout(()=>e.className='toast',3200)}
async function api(action,data={}){
 const r=await fetch('/cgi-bin/api.sh',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json'},body:JSON.stringify({action,...data})});
 let j;try{j=await r.json()}catch{throw new Error(`Сервер вернул некорректный ответ (${r.status})`)}
 if(!r.ok)throw new Error(j.error||`Ошибка HTTP ${r.status}`);return j;
}
async function apiGet(action,params={}){
 const q=new URLSearchParams({action,...params});q.set('_',Date.now()+'-'+Math.random().toString(36).slice(2));
 const r=await fetch('/cgi-bin/api.sh?'+q.toString(),{cache:'no-store'});
 let j;try{j=await r.json()}catch{throw new Error(`Сервер вернул некорректный ответ (${r.status})`)}
 if(!r.ok)throw new Error(j.error||`Ошибка HTTP ${r.status}`);return j;
}
async function checkForUpdate(manual=false){
 const b=$('updateCheckBtn');b.classList.add('busy');b.textContent='…';
 try{
  const r=await apiGet('version_check');state.update=r.update_available?r:null;
  if(r.update_available){$('updateVersionText').textContent=`Текущая ${r.current_version} → новая ${r.latest_version}`;$('updateNotice').classList.remove('hidden');if(manual)toast(`Доступна сборка ${r.latest_version}`)}
  else{$('updateNotice').classList.add('hidden');if(manual)toast(`Установлена последняя сборка ${r.current_version}`)}
 }catch(e){if(manual)toast(`Не удалось проверить обновления: ${e.message}`,true)}
 finally{b.classList.remove('busy');b.textContent='↻'}
}
async function installUpdate(){
 if(!state.update)return;const v=state.update.latest_version;
 if(!confirm(`Обновить Script Manager до сборки ${v}?\n\nПанель будет автоматически перезапущена.`))return;
 const b=$('updateBtn');b.disabled=true;b.textContent='Обновление…';
 try{await api('update',{version:v});toast('Обновление запущено. Панель перезапустится…');setTimeout(()=>location.reload(),5000)}
 catch(e){b.disabled=false;b.textContent='Обновить';toast(e.message,true)}
}
function type(){return document.querySelector('input[name="scheduleType"]:checked').value}
function human(){
 const t=type();
 if(t==='startup')return 'при запуске OpenWrt';
 if(t==='manual')return $('manualCron').value.trim()||'ручное cron-расписание';
 if(t==='interval'){const v=Math.max(1,+$('intervalValue').value||1),u=$('intervalUnit').value;return u==='minute'?(v===1?'каждую минуту':`каждые ${v} мин.`):u==='hour'?(v===1?'каждый час':`каждые ${v} ч.`):(v===1?'каждый день':`каждые ${v} дн.`)}
 const tm=t==='daily'?$('dailyTime').value:$('weeklyTime').value;
 if(t==='daily')return `каждый день в ${tm}`;
 const n=['Вс','Пн','Вт','Ср','Чт','Пт','Сб'];const ds=[...document.querySelectorAll('#weeklySettings input:checked')].map(x=>n[+x.value]);return `${ds.join(', ')} в ${tm}`;
}
function updateScheduleUi(){
 const t=type();
 [['startupSettings','startup'],['manualSettings','manual'],['intervalSettings','interval'],['dailySettings','daily'],['weeklySettings','weekly']].forEach(([id,x])=>$(id).classList.toggle('hidden',t!==x));
 $('humanSchedule').textContent=human();$('scheduleSummary').textContent=human();
}
function cronFromUi(){
 const t=type();
 if(t==='startup')return '@reboot';
 if(t==='manual'){const v=$('manualCron').value.trim();if(!v)throw Error('Укажите cron-расписание');return v}
 if(t==='interval'){const v=Math.max(1,+$('intervalValue').value||1),u=$('intervalUnit').value;if(u==='minute'){if(v>59)throw Error('Для минут значение должно быть от 1 до 59');return `*/${v} * * * *`}if(u==='hour'){if(v>23)throw Error('Для часов значение должно быть от 1 до 23');return `0 */${v} * * *`}if(v>31)throw Error('Для дней значение должно быть от 1 до 31');return `0 0 */${v} * *`}
 const tm=t==='daily'?$('dailyTime').value:$('weeklyTime').value;if(!/^\d{2}:\d{2}$/.test(tm))throw Error('Укажите корректное время');const [h,m]=tm.split(':').map(Number);
 if(t==='daily')return `${m} ${h} * * *`;
 const ds=[...document.querySelectorAll('#weeklySettings input:checked')].map(x=>x.value);if(!ds.length)throw Error('Выберите хотя бы один день недели');return `${m} ${h} * * ${ds.join(',')}`;
}
function parseCron(v){
 v=(v||'@reboot').trim();
 if(v==='@reboot'){$('scheduleTypeStartup').checked=true;updateScheduleUi();return}
 const p=v.split(/\s+/);if(p.length!==5){$('scheduleTypeManual').checked=true;$('manualCron').value=v;updateScheduleUi();return}
 const [m,h,d,mo,w]=p;let x;
 if((x=/^\*\/([1-9]\d*)$/.exec(m))&&h==='*'&&d==='*'&&mo==='*'&&w==='*'){$('scheduleTypeInterval').checked=true;$('intervalValue').value=x[1];$('intervalUnit').value='minute';updateScheduleUi();return}
 if((x=/^\*\/([1-9]\d*)$/.exec(h))&&m==='0'&&d==='*'&&mo==='*'&&w==='*'){$('scheduleTypeInterval').checked=true;$('intervalValue').value=x[1];$('intervalUnit').value='hour';updateScheduleUi();return}
 if((x=/^\*\/([1-9]\d*)$/.exec(d))&&m==='0'&&h==='0'&&mo==='*'&&w==='*'){$('scheduleTypeInterval').checked=true;$('intervalValue').value=x[1];$('intervalUnit').value='day';updateScheduleUi();return}
 if(/^\d+$/.test(m)&&/^\d+$/.test(h)&&d==='*'&&mo==='*'&&w==='*'){$('scheduleTypeDaily').checked=true;$('dailyTime').value=`${String(+h).padStart(2,'0')}:${String(+m).padStart(2,'0')}`;updateScheduleUi();return}
 if(/^\d+$/.test(m)&&/^\d+$/.test(h)&&d==='*'&&mo==='*'&&/^[0-6](,[0-6])*$/.test(w)){
  $('scheduleTypeWeekly').checked=true;document.querySelectorAll('#weeklySettings input').forEach(e=>e.checked=false);w.split(',').forEach(day=>{const e=document.querySelector(`#weeklySettings input[value="${day}"]`);if(e)e.checked=true});$('weeklyTime').value=`${String(+h).padStart(2,'0')}:${String(+m).padStart(2,'0')}`;updateScheduleUi();return
 }
 $('scheduleTypeManual').checked=true;$('manualCron').value=v;updateScheduleUi();
}
function status(on){$('statusBadge').textContent=on?'Вкл.':'Выкл.';$('statusBadge').className='status-badge '+(on?'on':'off')}
function clearOutput(){$('output').textContent='';$('outputWrap').classList.add('hidden')}
async function refreshList(){const r=await apiGet('list');state.scripts=r.scripts||[];renderList()}
function renderList(){
 const l=$('scriptList');l.innerHTML='';$('emptyList').classList.toggle('hidden',state.scripts.length!==0);
 state.scripts.forEach(s=>{const b=document.createElement('button');b.className='script-item'+(state.current===s.name?' active':'');b.onclick=()=>openScript(s.name);const d=document.createElement('span');d.className='script-dot'+(s.enabled?' on':'');const n=document.createElement('span');n.className='script-name';n.textContent=s.name.replace(/\.sh$/,'');b.append(d,n);l.appendChild(b)})
}
function showEditor(v){$('editor').classList.toggle('hidden',!v);$('editorEmpty').classList.toggle('hidden',v)}
async function openScript(name){try{const r=await apiGet('get',{name});state.current=r.name;$('editorTitle').textContent=r.name.replace(/\.sh$/,'');$('nameInput').value=r.name.replace(/\.sh$/,'');$('nameInput').readOnly=true;$('contentInput').value=r.content||'';parseCron(r.schedule);status(!!r.enabled);clearOutput();showEditor(true);renderList()}catch(e){toast(e.message,true)}}
function newScript(){state.current=null;$('editorTitle').textContent='Новый скрипт';$('nameInput').value='';$('nameInput').readOnly=false;$('contentInput').value='#!/bin/sh\n\n';$('scheduleTypeStartup').checked=true;updateScheduleUi();clearOutput();showEditor(true);renderList();$('nameInput').focus()}
async function saveScript(){let n=$('nameInput').value.trim().replace(/\.sh$/,'');if(!/^[a-zA-Z0-9_-]+$/.test(n)){toast('Имя может содержать только латинские буквы, цифры, _ и -',true);return}let s;try{s=cronFromUi()}catch(e){toast(e.message,true);return}try{await api('save',{name:n+'.sh',content:$('contentInput').value,schedule:s});state.current=n+'.sh';$('nameInput').readOnly=true;$('editorTitle').textContent=n;await refreshList();toast('Скрипт сохранён')}catch(e){toast(e.message,true)}}
async function runScript(){if(!state.current)return;clearOutput();$('runBtn').disabled=true;$('runBtn').textContent='⏳ Выполнение…';try{const r=await api('run',{name:state.current});$('output').textContent=(r.output||'(нет вывода)')+`\n\n[Код завершения: ${r.exit_code}]`;$('outputWrap').classList.remove('hidden')}catch(e){toast(e.message,true)}finally{$('runBtn').disabled=false;$('runBtn').textContent='▶ Выполнить сейчас'}}
async function deleteScript(){if(!state.current)return;if(!confirm(`Удалить ${state.current}?`))return;try{await api('delete',{name:state.current});state.current=null;showEditor(false);await refreshList();toast('Скрипт удалён')}catch(e){toast(e.message,true)}}

$('newBtn').onclick=newScript;$('saveBtn').onclick=saveScript;$('runBtn').onclick=runScript;$('deleteBtn').onclick=deleteScript;$('clearOutputBtn').onclick=clearOutput;$('updateCheckBtn').onclick=()=>checkForUpdate(true);$('updateBtn').onclick=installUpdate;
document.querySelectorAll('input[name="scheduleType"]').forEach(x=>x.onchange=updateScheduleUi);
['manualCron','intervalValue','dailyTime','weeklyTime'].forEach(id=>$(id).oninput=$(id).onchange=updateScheduleUi);
$('intervalUnit').onchange=updateScheduleUi;document.querySelectorAll('#weeklySettings input').forEach(x=>x.onchange=updateScheduleUi);
(async()=>{updateScheduleUi();try{await refreshList()}catch(e){toast(e.message,true)}setTimeout(()=>checkForUpdate(false),700)})();
