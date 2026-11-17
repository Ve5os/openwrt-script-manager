const $=s=>document.querySelector(s);
let scripts=[], editing=null;

async function api(action, params={}) {
  const q=new URLSearchParams({action,...params});
  const r=await fetch('/cgi-bin/api?'+q.toString(),{cache:'no-store'});
  return r.json();
}
function showApp(){ $('#login').classList.add('hidden'); $('#app').classList.remove('hidden'); load(); }
async function load(){
  const d=await api('list');
  if(!d.ok){ $('#app').classList.add('hidden'); $('#login').classList.remove('hidden'); return; }
  scripts=d.scripts||[]; render();
}
function render(){
  const box=$('#cards');
  if(!scripts.length){box.innerHTML='<div class="empty">Пока нет скриптов.<br><br><button class="primary" onclick="newScript()">＋ Создать первый</button></div>';return;}
  box.innerHTML=scripts.map(s=>`
  <div class="card">
    <div>
      <div class="card-title">${esc(s.name)} <span class="badge ${s.enabled?'on':'off'}">${s.enabled?'ВКЛ':'ВЫКЛ'}</span></div>
      <div class="path">${esc(s.path)}</div>
      <div class="schedule">${scheduleText(s)}</div>
    </div>
    <div class="actions">
      <button class="small run" onclick="runScript('${escAttr(s.id)}')">▶ Запустить</button>
      <button class="small" onclick="editScript('${escAttr(s.id)}')">Изменить</button>
      <button class="small" onclick="toggleScript('${escAttr(s.id)}')">${s.enabled?'Выключить':'Включить'}</button>
      <button class="small" onclick="deleteScript('${escAttr(s.id)}')">Удалить</button>
    </div>
  </div>`).join('');
}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function escAttr(s){return String(s??'').replace(/'/g,"\\'")}
function scheduleText(s){
  if(!s.enabled)return 'Расписание выключено';
  if(s.minute==='*'&&s.hour==='*'&&s.dom==='*'&&s.month==='*'&&s.dow==='*')return 'Каждую минуту';
  if(s.minute==='0'&&s.hour==='*'&&s.dom==='*'&&s.month==='*'&&s.dow==='*')return 'Каждый час';
  if(s.minute==='0'&&s.hour==='0'&&s.dom==='*'&&s.month==='*'&&s.dow==='*')return 'Каждый день в 00:00';
  return `По расписанию: ${s.minute} ${s.hour} ${s.dom} ${s.month} ${s.dow}`;
}
function newScript(){
 editing=null;
 $('#modalTitle').textContent='Новый скрипт';
 $('#f-name').value=''; $('#f-path').value='/usr/bin/example.sh'; $('#f-content').value='#!/bin/sh\\n\\n';
 $('#f-minute').value='*';$('#f-hour').value='*';$('#f-dom').value='*';$('#f-month').value='*';$('#f-dow').value='*';$('#f-enabled').checked=false;
 updatePreview();$('#modal').classList.remove('hidden');
}
function editScript(id){
 const s=scripts.find(x=>x.id===id);if(!s)return;
 editing=s.id;$('#modalTitle').textContent='Редактировать скрипт';
 $('#f-name').value=s.name;$('#f-path').value=s.path;$('#f-content').value=s.content;
 $('#f-minute').value=s.minute;$('#f-hour').value=s.hour;$('#f-dom').value=s.dom;$('#f-month').value=s.month;$('#f-dow').value=s.dow;$('#f-enabled').checked=!!s.enabled;
 updatePreview();$('#modal').classList.remove('hidden');
}
async function saveScript(){
 const id=editing||slug($('#f-name').value)||'script';
 const p={id,name:$('#f-name').value,path:$('#f-path').value,content:$('#f-content').value,minute:$('#f-minute').value,hour:$('#f-hour').value,dom:$('#f-dom').value,month:$('#f-month').value,dow:$('#f-dow').value,enabled:$('#f-enabled').checked?'1':'0'};
 const d=await api('save',p);if(!d.ok){alert(d.error||'Ошибка');return}
 $('#modal').classList.add('hidden');load();
}
async function toggleScript(id){const d=await api('toggle',{id});if(!d.ok)alert(d.error||'Ошибка');load()}
async function deleteScript(id){if(!confirm('Удалить этот скрипт из Script Manager? Сам файл не будет удалён.'))return;const d=await api('delete',{id});if(!d.ok)alert(d.error||'Ошибка');load()}
async function runScript(id){
  const d=await api('run',{id});
  $('#runBox').classList.remove('empty');
  $('#runBox').textContent=`Exit code: ${d.exit}\\n\\n${d.output||'(нет вывода)'}`;
  document.querySelector('[data-tab="runs"]').click();
}
function slug(v){return String(v).toLowerCase().replace(/[^a-z0-9_-]+/g,'-').replace(/^-+|-+$/g,'')}
function updatePreview(){$('#cronPreview').textContent=`Cron: ${$('#f-minute').value} ${$('#f-hour').value} ${$('#f-dom').value} ${$('#f-month').value} ${$('#f-dow').value}`}

document.addEventListener('DOMContentLoaded',()=>{
 $('#loginBtn').onclick=async()=>{const d=await api('login',{password:$('#password').value});if(d.ok)showApp();else $('#loginError').textContent=d.error||'Ошибка входа'};
 $('#password').onkeydown=e=>{if(e.key==='Enter')$('#loginBtn').click()};
 $('#newBtn').onclick=newScript;$('#closeModal').onclick=()=>$('#modal').classList.add('hidden');$('#cancel').onclick=()=>$('#modal').classList.add('hidden');$('#save').onclick=saveScript;
 ['f-minute','f-hour','f-dom','f-month','f-dow'].forEach(id=>$('#'+id).onchange=updatePreview);
 document.querySelectorAll('.preset').forEach(b=>b.onclick=()=>{
   const p=b.dataset.preset;
   if(p==='minute'){$('#f-minute').value='*';$('#f-hour').value='*';$('#f-dom').value='*';$('#f-month').value='*';$('#f-dow').value='*'}
   if(p==='hour'){$('#f-minute').value='0';$('#f-hour').value='*';$('#f-dom').value='*';$('#f-month').value='*';$('#f-dow').value='*'}
   if(p==='day'){$('#f-minute').value='0';$('#f-hour').value='0';$('#f-dom').value='*';$('#f-month').value='*';$('#f-dow').value='*'}
   if(p==='week'){$('#f-minute').value='0';$('#f-hour').value='0';$('#f-dom').value='*';$('#f-month').value='*';$('#f-dow').value='1'}
   if(p==='month'){$('#f-minute').value='0';$('#f-hour').value='0';$('#f-dom').value='1';$('#f-month').value='*';$('#f-dow').value='*'}
   updatePreview();
 });
 document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.tabpage').forEach(x=>x.classList.add('hidden'));t.classList.add('active');$('#tab-'+t.dataset.tab).classList.remove('hidden')});
 $('#logout').onclick=async()=>{await api('logout');location.reload()};
});
