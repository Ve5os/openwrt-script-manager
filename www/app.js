'use strict';

const BUILD_VERSION = '2026.11.18.01';

const state = { scripts: [], current: null, creating: false };
const $ = (id) => document.getElementById(id);

function showToast(message, error = false) {
  const el = $('toast');
  el.textContent = message;
  el.className = `toast show${error ? ' error' : ''}`;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { el.className = 'toast'; }, 3200);
}

async function api(action, data = null) {
  const options = data === null ? { method: 'GET' } : {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, ...data })
  };
  const url = data === null ? `/cgi-bin/api.sh?action=${encodeURIComponent(action)}${data?.name ? `&name=${encodeURIComponent(data.name)}` : ''}` : '/cgi-bin/api.sh';
  const response = await fetch(url, options);
  let result;
  try { result = await response.json(); } catch (_) { throw new Error(`Сервер вернул некорректный ответ (${response.status})`); }
  if (!response.ok) throw new Error(result.error || `Ошибка HTTP ${response.status}`);
  return result;
}

async function apiGet(action, params = {}) {
  const query = new URLSearchParams({ action, ...params });
  const response = await fetch(`/cgi-bin/api.sh?${query}`);
  let result;
  try { result = await response.json(); } catch (_) { throw new Error(`Сервер вернул некорректный ответ (${response.status})`); }
  if (!response.ok) throw new Error(result.error || `Ошибка HTTP ${response.status}`);
  return result;
}

function renderList() {
  const list = $('scriptList');
  list.innerHTML = '';
  $('emptyList').classList.toggle('hidden', state.scripts.length !== 0);

  for (const script of state.scripts) {
    const button = document.createElement('button');
    button.className = `script-item${state.current === script.name ? ' active' : ''}`;
    button.type = 'button';
    button.addEventListener('click', () => openScript(script.name));

    const dot = document.createElement('span');
    dot.className = `script-dot${script.enabled ? ' on' : ''}`;
    const name = document.createElement('span');
    name.className = 'script-name';
    name.textContent = script.name;
    button.append(dot, name);
    list.appendChild(button);
  }
}

function setEditorVisible(visible) {
  $('editor').classList.toggle('hidden', !visible);
  $('editorEmpty').classList.toggle('hidden', visible);
}

function updateStatus(enabled) {
  $('enabledToggle').checked = !!enabled;
  $('statusBadge').textContent = enabled ? 'Вкл.' : 'Выкл.';
  $('statusBadge').className = `status-badge ${enabled ? 'on' : 'off'}`;
}

function clearOutput() {
  $('output').textContent = '';
  $('outputWrap').classList.add('hidden');
}

async function refreshList(selectCurrent = true) {
  const result = await apiGet('list');
  state.scripts = result.scripts || [];
  renderList();
  if (selectCurrent && state.current && state.scripts.some(s => s.name === state.current)) {
    const item = state.scripts.find(s => s.name === state.current);
    updateStatus(item.enabled);
  }
}

async function openScript(name) {
  try {
    const result = await apiGet('get', { name });
    state.current = result.name;
    state.creating = false;
    $('editorTitle').textContent = result.name;
    $('nameInput').value = result.name;
    $('nameInput').readOnly = true;
    $('scheduleInput').value = result.schedule || '*/1 * * * *';
    $('contentInput').value = result.content || '';
    updateStatus(result.enabled);
    clearOutput();
    setEditorVisible(true);
    renderList();
  } catch (error) {
    showToast(error.message, true);
  }
}

function newScript() {
  state.current = null;
  state.creating = true;
  $('editorTitle').textContent = 'Новый скрипт';
  $('nameInput').value = '';
  $('nameInput').readOnly = false;
  $('scheduleInput').value = '*/1 * * * *';
  $('contentInput').value = '#!/bin/sh\n\n';
  updateStatus(false);
  clearOutput();
  setEditorVisible(true);
  renderList();
  $('nameInput').focus();
}

async function saveScript() {
  const name = $('nameInput').value.trim();
  const content = $('contentInput').value;
  const schedule = $('scheduleInput').value.trim();
  if (!/^[a-zA-Z0-9_-]+\.sh$/.test(name)) {
    showToast('Имя должно соответствовать формату example.sh', true);
    return;
  }
  if (schedule.split(/\s+/).length !== 5) {
    showToast('Cron-расписание должно содержать 5 полей', true);
    return;
  }
  try {
    await api('save', { name, content, schedule });
    state.current = name;
    state.creating = false;
    $('nameInput').readOnly = true;
    $('editorTitle').textContent = name;
    showToast('Скрипт сохранён');
    await refreshList();
  } catch (error) {
    showToast(error.message, true);
  }
}

async function toggleScript() {
  if (!state.current) return;
  const enabled = $('enabledToggle').checked;
  try {
    await api('toggle', { name: state.current, enabled, schedule: $('scheduleInput').value.trim() || '*/1 * * * *' });
    updateStatus(enabled);
    await refreshList();
    showToast(enabled ? 'Скрипт включён в cron' : 'Скрипт отключён');
  } catch (error) {
    $('enabledToggle').checked = !enabled;
    showToast(error.message, true);
  }
}

async function runScript() {
  if (!state.current) return;
  clearOutput();
  $('runBtn').disabled = true;
  $('runBtn').textContent = '⏳ Выполнение...';
  try {
    const result = await api('run', { name: state.current });
    $('output').textContent = `${result.output || '(нет вывода)'}\n\n[Код завершения: ${result.exit_code ?? 0}]`;
    $('outputWrap').classList.remove('hidden');
  } catch (error) {
    showToast(error.message, true);
  } finally {
    $('runBtn').disabled = false;
    $('runBtn').textContent = '▶ Выполнить сейчас';
  }
}

async function deleteScript() {
  if (!state.current) return;
  if (!window.confirm(`Удалить ${state.current}?`)) return;
  try {
    await api('delete', { name: state.current });
    state.current = null;
    state.creating = false;
    setEditorVisible(false);
    await refreshList(false);
    showToast('Скрипт удалён');
  } catch (error) {
    showToast(error.message, true);
  }
}

$('newBtn').addEventListener('click', newScript);
$('saveBtn').addEventListener('click', saveScript);
$('enabledToggle').addEventListener('change', toggleScript);
$('runBtn').addEventListener('click', runScript);
$('deleteBtn').addEventListener('click', deleteScript);
$('clearOutputBtn').addEventListener('click', clearOutput);

(async function init() {
  try {
    await refreshList(false);
  } catch (error) {
    showToast(error.message, true);
  }
})();
