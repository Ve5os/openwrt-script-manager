'use strict';

const state = { scripts: [], current: null, creating: false, update: null };
const $ = (id) => document.getElementById(id);

function showToast(message, error = false) {
  const el = $('toast');
  el.textContent = message;
  el.className = `toast show${error ? ' error' : ''}`;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { el.className = 'toast'; }, 3200);
}

async function api(action, data = {}) {
  const response = await fetch('/cgi-bin/api.sh', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, ...data })
  });
  let result;
  try { result = await response.json(); } catch (_) { throw new Error(`Сервер вернул некорректный ответ (${response.status})`); }
  if (!response.ok) throw new Error(result.error || `Ошибка HTTP ${response.status}`);
  return result;
}

async function apiGet(action, params = {}) {
  const query = new URLSearchParams({ action, ...params });
  if (action === 'version_check') query.set('_', `${Date.now()}-${Math.random().toString(36).slice(2)}`);
  const response = await fetch(`/cgi-bin/api.sh?${query}`);
  let result;
  try { result = await response.json(); } catch (_) { throw new Error(`Сервер вернул некорректный ответ (${response.status})`); }
  if (!response.ok) throw new Error(result.error || `Ошибка HTTP ${response.status}`);
  return result;
}

async function checkForUpdate(manual = false) {
  const button = $('updateCheckBtn');
  if (button) {
    button.classList.add('busy');
    button.textContent = '…';
  }
  try {
    const result = await apiGet('version_check');
    const buildVersion = $('buildVersion');
    if (buildVersion) buildVersion.textContent = result.current_version;
    state.update = result.update_available ? result : null;
    const notice = $('updateNotice');
    const versionText = $('updateVersionText');
    if (result.update_available) {
      versionText.textContent = `Текущая ${result.current_version} → новая ${result.latest_version}`;
      notice.classList.remove('hidden');
      if (manual) showToast(`Доступна сборка ${result.latest_version}`);
    } else {
      notice.classList.add('hidden');
      if (manual) showToast(`Установлена последняя сборка ${result.current_version}`);
    }
  } catch (error) {
    if (manual) showToast(`Не удалось проверить обновления: ${error.message}`, true);
  } finally {
    if (button) {
      button.classList.remove('busy');
      button.textContent = '↻';
    }
  }
}

async function installUpdate() {
  const button = $('updateBtn');
  if (!button) return;
  if (!window.confirm('Запустить автообновление Script Manager?\n\nБудет выполнена официальная команда установки из GitHub. Пользовательские скрипты не удаляются.')) return;
  button.disabled = true;
  button.textContent = 'Обновление…';
  try {
    await api('update');
    showToast('Обновление запущено. Панель перезапустится…');
    setTimeout(() => window.location.reload(), 5000);
  } catch (error) {
    button.disabled = false;
    button.textContent = 'Обновить';
    showToast(error.message, true);
  }
}

function displayName(name) {
  return name.endsWith('.sh') ? name.slice(0, -3) : name;
}

async function toggleListScript(script, control) {
  const enabled = !script.enabled;
  control.classList.add('busy');
  try {
    await api('toggle', {
      name: script.name,
      enabled,
      schedule: script.schedule || '*/1 * * * *'
    });
    script.enabled = enabled;
    control.classList.toggle('on', enabled);
    control.setAttribute('aria-checked', String(enabled));
    control.title = enabled ? 'Отключить cron' : 'Включить cron';

    if (state.current === script.name) {
      updateStatus(enabled);
    }

    showToast(enabled ? 'Скрипт включён в cron' : 'Скрипт отключён');
  } catch (error) {
    showToast(error.message, true);
  } finally {
    control.classList.remove('busy');
  }
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

    const name = document.createElement('span');
    name.className = 'script-name';
    name.textContent = displayName(script.name);

    const cronToggle = document.createElement('span');
    cronToggle.className = `script-cron-toggle${script.enabled ? ' on' : ''}`;
    cronToggle.setAttribute('role', 'switch');
    cronToggle.setAttribute('aria-checked', String(!!script.enabled));
    cronToggle.title = script.enabled ? 'Отключить cron' : 'Включить cron';
    cronToggle.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      toggleListScript(script, cronToggle);
    });
    cronToggle.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        event.stopPropagation();
        toggleListScript(script, cronToggle);
      }
    });

    button.append(name, cronToggle);
    list.appendChild(button);
  }
}

function setEditorVisible(visible) {
  $('editor').classList.toggle('hidden', !visible);
  $('editorEmpty').classList.toggle('hidden', visible);
}

function updateStatus(enabled) {
  $('statusBadge').textContent = enabled ? 'Вкл.' : 'Выкл.';
  $('statusBadge').className = `status-badge ${enabled ? 'on' : 'off'}`;
}

function clearOutput() {
  $('output').textContent = '';
  $('outputWrap').classList.add('hidden');
}

function cronFromUi() {
  const type = document.querySelector('input[name="scheduleType"]:checked').value;

  if (type === 'startup') return '@reboot';

  if (type === 'manual') {
    const value = $('manualCron').value.trim();
    if (!value) throw new Error('Укажите cron-расписание');
    return value;
  }

  if (type === 'interval') {
    const value = Math.max(1, Number.parseInt($('intervalValue').value, 10) || 1);
    const unit = $('intervalUnit').value;

    if (unit === 'minute') {
      if (value > 59) throw new Error('Для минут можно указать значение от 1 до 59');
      return `*/${value} * * * *`;
    }

    if (unit === 'hour') {
      if (value > 23) throw new Error('Для часов можно указать значение от 1 до 23');
      return `0 */${value} * * *`;
    }

    if (value > 31) throw new Error('Для дней можно указать значение от 1 до 31');
    return `0 0 */${value} * *`;
  }

  const time = type === 'daily' ? $('dailyTime').value : $('weeklyTime').value;
  if (!/^\d{2}:\d{2}$/.test(time)) throw new Error('Укажите корректное время');
  const [hour, minute] = time.split(':').map(Number);

  if (type === 'daily') return `${minute} ${hour} * * *`;

  const days = [...document.querySelectorAll('#weeklySettings .day-option input:checked')].map((el) => el.value);
  if (!days.length) throw new Error('Выберите хотя бы один день недели');
  return `${minute} ${hour} * * ${days.join(',')}`;
}

function humanSchedule() {
  const type = document.querySelector('input[name="scheduleType"]:checked').value;

  if (type === 'startup') return 'при запуске OpenWrt';
  if (type === 'manual') return $('manualCron').value.trim() || 'ручное cron-расписание';

  if (type === 'interval') {
    const value = Math.max(1, Number.parseInt($('intervalValue').value, 10) || 1);
    const unit = $('intervalUnit').value;
    if (unit === 'minute') return value === 1 ? 'каждую минуту' : `каждые ${value} мин.`;
    if (unit === 'hour') return value === 1 ? 'каждый час' : `каждые ${value} ч.`;
    return value === 1 ? 'каждый день' : `каждые ${value} дн.`;
  }

  const time = type === 'daily' ? $('dailyTime').value : $('weeklyTime').value;
  if (type === 'daily') return `каждый день в ${time}`;

  const names = ['Вс', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб'];
  const days = [...document.querySelectorAll('#weeklySettings .day-option input:checked')].map((el) => names[Number(el.value)]);
  return `${days.join(', ')} в ${time}`;
}

function updateScheduleUi() {
  const type = document.querySelector('input[name="scheduleType"]:checked').value;
  $('startupSettings').classList.toggle('hidden', type !== 'startup');
  $('manualSettings').classList.toggle('hidden', type !== 'manual');
  $('intervalSettings').classList.toggle('hidden', type !== 'interval');
  $('dailySettings').classList.toggle('hidden', type !== 'daily');
  $('weeklySettings').classList.toggle('hidden', type !== 'weekly');
  $('humanSchedule').textContent = humanSchedule();
  $('scheduleSummary').textContent = humanSchedule();
}

function parseCronToUi(schedule) {
  const value = (schedule || '@reboot').trim();
  if (value === '@reboot') {
    $('scheduleTypeStartup').checked = true;
    updateScheduleUi();
    return true;
  }
  const parts = value.split(/\s+/);
  if (parts.length !== 5) {
    $('scheduleTypeManual').checked = true;
    $('manualCron').value = value;
    updateScheduleUi();
    return true;
  }
  const [minute, hour, day, month, weekday] = parts;

  if (/^\*\/([1-9]\d*)$/.test(minute) && hour === '*' && day === '*' && month === '*' && weekday === '*') {
    $('scheduleTypeInterval').checked = true;
    $('intervalValue').value = RegExp.$1;
    $('intervalUnit').value = 'minute';
    updateScheduleUi();
    return true;
  }

  if (minute === '0' && /^\*\/([1-9]\d*)$/.test(hour) && day === '*' && month === '*' && weekday === '*') {
    $('scheduleTypeInterval').checked = true;
    $('intervalValue').value = RegExp.$1;
    $('intervalUnit').value = 'hour';
    updateScheduleUi();
    return true;
  }

  if (minute === '0' && hour === '0' && /^\*\/([1-9]\d*)$/.test(day) && month === '*' && weekday === '*') {
    $('scheduleTypeInterval').checked = true;
    $('intervalValue').value = RegExp.$1;
    $('intervalUnit').value = 'day';
    updateScheduleUi();
    return true;
  }

  if (/^\d+$/.test(minute) && /^\d+$/.test(hour) && day === '*' && month === '*' && weekday === '*') {
    $('scheduleTypeDaily').checked = true;
    $('dailyTime').value = `${String(Number(hour)).padStart(2, '0')}:${String(Number(minute)).padStart(2, '0')}`;
    updateScheduleUi();
    return true;
  }

  if (/^\d+$/.test(minute) && /^\d+$/.test(hour) && day === '*' && month === '*' && /^[0-6](,[0-6])*$/.test(weekday)) {
    $('scheduleTypeWeekly').checked = true;
    document.querySelectorAll('#weeklySettings .day-option input').forEach((el) => { el.checked = false; });
    weekday.split(',').forEach((d) => {
      const el = document.querySelector(`#weeklySettings .day-option input[value="${d}"]`);
      if (el) el.checked = true;
    });
    $('weeklyTime').value = `${String(Number(hour)).padStart(2, '0')}:${String(Number(minute)).padStart(2, '0')}`;
    updateScheduleUi();
    return true;
  }

  $('scheduleTypeManual').checked = true;
  $('manualCron').value = value;
  updateScheduleUi();
  return true;
}

function setScheduleFromCron(schedule) {
  const parsed = parseCronToUi(schedule);
  if (!parsed) {
    $('scheduleTypeManual').checked = true;
    $('manualCron').value = (schedule || '').trim();
    updateScheduleUi();
    showToast('Расписание не распознано — оно открыто в ручном режиме.', true);
  }
}

async function refreshList(selectCurrent = true) {
  const result = await apiGet('list');
  state.scripts = result.scripts || [];
  renderList();

  if (selectCurrent && state.current && state.scripts.some(s => s.name === state.current)) {
    updateStatus(state.scripts.find(s => s.name === state.current).enabled);
  }
}

async function openScript(name) {
  try {
    const result = await apiGet('get', { name });
    state.current = result.name;
    state.creating = false;
    $('editorTitle').textContent = displayName(result.name);
    $('nameInput').value = displayName(result.name);
    $('nameInput').readOnly = true;
    setScheduleFromCron(result.schedule || '@reboot');
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
  $('scheduleTypeStartup').checked = true;
  $('contentInput').value = '#!/bin/sh\n\n';
  updateScheduleUi();
  clearOutput();
  setEditorVisible(true);
  renderList();
  $('nameInput').focus();
}

async function saveScript() {
  const rawName = $('nameInput').value.trim();
  const name = rawName.endsWith('.sh') ? rawName : `${rawName}.sh`;
  const content = $('contentInput').value;
  let schedule;

  if (!/^[a-zA-Z0-9_-]+$/.test(rawName.replace(/\.sh$/, ''))) {
    showToast('Имя может содержать только латинские буквы, цифры, _ и -', true);
    return;
  }

  try {
    schedule = cronFromUi();
  } catch (error) {
    showToast(error.message, true);
    return;
  }

  try {
    await api('save', { name, content, schedule });
    state.current = name;
    state.creating = false;
    $('nameInput').readOnly = true;
    $('editorTitle').textContent = displayName(name);
    showToast('Скрипт сохранён');
    await refreshList();
  } catch (error) {
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
  if (!window.confirm(`Удалить ${displayName(state.current)}?`)) return;

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

$('updateCheckBtn').addEventListener('click', () => checkForUpdate(true));
$('updateBtn').addEventListener('click', installUpdate);
$('newBtn').addEventListener('click', newScript);
$('saveBtn').addEventListener('click', saveScript);
$('runBtn').addEventListener('click', runScript);
$('deleteBtn').addEventListener('click', deleteScript);
$('clearOutputBtn').addEventListener('click', clearOutput);
document.querySelectorAll('input[name="scheduleType"]').forEach((el) => el.addEventListener('change', updateScheduleUi));
$('intervalValue').addEventListener('input', updateScheduleUi);
$('intervalUnit').addEventListener('change', updateScheduleUi);
$('dailyTime').addEventListener('change', updateScheduleUi);
$('weeklyTime').addEventListener('change', updateScheduleUi);
$('manualCron').addEventListener('input', updateScheduleUi);
document.querySelectorAll('#weeklySettings .day-option input').forEach((el) => el.addEventListener('change', updateScheduleUi));

(async function init() {
  try {
    await refreshList(false);
    updateScheduleUi();
    checkForUpdate(false);
  } catch (error) {
    showToast(error.message, true);
  }
})();
