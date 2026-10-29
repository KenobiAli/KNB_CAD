/*
 * knb_cad - LAPD-style MDC + dispatch system for FiveM
 * Copyright (C) 2026 kenobiali
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program (see the LICENSE file). If not, see
 * <https://www.gnu.org/licenses/>.
 *
 * Parts of the alert detection and dispatch logic are adapted from
 * Project Sloth ps-dispatch (GPL-3.0): https://github.com/Project-Sloth/ps-dispatch
 */

/* knb_cad v0.8 · LAPD-style MDC interface */
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'knb_cad';
// Every request is settled within 10 s at most; unanswered requests must not fill the browser queue and lock up the MDC
const post = (n, d = {}) => {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 10000);
  return fetch(`https://${RES}/${n}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(d), signal: ctl.signal,
  }).then(r => r.json()).catch(() => ({})).finally(() => clearTimeout(timer));
};
/* ---------- Localization ---------- */
// Strings come from locales/<code>.json through the game script (NUI callback 'locale').
let LOCALE = {};
const $t = (k, ...a) => {
  const s = LOCALE[k];
  if (s == null) return k;
  return a.length ? s.replace(/\{(\d+)\}/g, (_, i) => (a[i - 1] ?? '')) : s;
};
const LANG = () => LOCALE['meta.locale'] || 'en-US';
function applyLocale() {
  document.documentElement.lang = LANG().slice(0, 2);
  document.documentElement.style.setProperty('--auto-label', JSON.stringify(' • ' + $t('ui.auto_label')));
  $$('[data-i18n]').forEach(el => { el.textContent = $t(el.dataset.i18n); });
  $$('[data-i18n-attr]').forEach(el => el.dataset.i18nAttr.split(';').forEach(p => { const [a, k] = p.split(':'); el.setAttribute(a, $t(k)); }));
}
let localeReady = false;
async function loadLocale(tries = 0) {
  const r = await post('locale');
  if (r && Object.keys(r).length) {
    LOCALE = r; localeReady = true; applyLocale();
    if (typeof afterLocale === 'function') afterLocale();
    return;
  }
  if (tries < 120) setTimeout(() => loadLocale(tries + 1), 500); // the game script may not be ready yet
}

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const up = s => String(s ?? '').toLocaleUpperCase(LANG());
const money = n => '$' + Number(n || 0).toLocaleString(LANG());
const dt = ms => ms ? new Date(Number(ms)).toLocaleString(LANG(), { dateStyle: 'short', timeStyle: 'short' }) : '-';
const arr = v => Array.isArray(v) ? v : [];
const pad = n => String(n).padStart(2, '0');

let S = { calls: [], units: [], statuses: [], templates: [], counties: [], ticker: [], bolos: [] };
let META = { penal: [], classes: {}, licenses: {}, perms: {}, points: {}, statusInfo: {} };
let myId = 0, curForm = null, curPage = 'dash', openCallId = null, PROF = null, curRec = null;
let clockOff = 0, myPos = null, TRACK = [], selId = null, qf = 'all', seen = new Set(), firstRender = true;

/* ---------- Helpers ---------- */
const nowS = () => Math.floor(Date.now() / 1000 + clockOff);
const dur = s => { s = Math.max(0, Math.floor(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60; return h ? `${h}:${pad(m)}:${pad(x)}` : `${pad(m)}:${pad(x)}`; };
const hm = t => { if (!t) return '--:--:--'; const d = new Date((t - clockOff) * 1000); return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`; };
const km = m => m == null ? '—' : (m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`);
const dist = (a, b) => (a && b && a.x != null && b.x != null) ? Math.hypot(a.x - b.x, a.y - b.y) : null;
const eta = m => m == null ? '' : $t('ui.eta_min', Math.max(1, Math.round(m / 22 / 60))); // ~80 km/h average
const hex2 = h => { h = String(h || '#94a3b8').replace('#', ''); if (h.length === 3) h = h.split('').map(c => c + c).join(''); return [0, 2, 4].map(i => parseInt(h.substr(i, 2), 16) || 0); };
const tint = (h, a) => { const [r, g, b] = hex2(h); return `rgba(${r},${g},${b},${a})`; };
const stI = s => (META.statusInfo || {})[s] || { label: s || '—', color: '#94a3b8', key: '' };
const ssHtml = s => { const i = stI(s); return `<span class="ss" style="color:${i.color};background:${tint(i.color, .16)}">${esc(i.label)}</span>`; };
const pri = p => `<span class="pill P${p}">CODE ${p}</span>`;
const classPill = c => { const k = (META.classes || {})[c] || { label: c, color: '#666' }; return `<span class="cpill" style="background:${esc(k.color)}">${esc(k.label)}</span>`; };
const hasPage = p => !META.dept || arr(META.dept.pages).includes(p);
const canReport = t => !META.dept || arr(META.dept.reports).includes(t);
const me = () => S.units.find(u => u.src === myId);
const appOpen = () => !$('#app').classList.contains('hidden');
const typing = () => { const a = document.activeElement; return a && /INPUT|TEXTAREA|SELECT/.test(a.tagName); };
const store = { get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (_) { return d; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (_) {} } };

function toast(msg, ms = 2800) {
  const t = $('#toast'); t.textContent = msg; t.classList.remove('hidden');
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.add('hidden'), ms);
}

// Unit vehicle position (live tracking) – otherwise my own position
function unitPos(src) {
  const t = TRACK.find(e => arr(e.members).includes(src));
  if (t) return { x: t.x, y: t.y, h: t.h, veh: true };
  if (src === myId && myPos) return myPos;
  return null;
}
const callPos = c => (c && c.x != null) ? { x: c.x, y: c.y } : null;
const unitsOn = c => S.units.filter(u => u.callId === c.id);

/* ---------- Department settings ---------- */
function applyDept() {
  const d = META.dept || {};
  $$('.tab[data-go]').forEach(b => b.classList.toggle('hidden', !hasPage(b.dataset.go)));
  $$('[data-form]').forEach(b => b.classList.toggle('hidden', !canReport(b.dataset.form)));
  $$('[data-list="mine"]').forEach(b => b.classList.toggle('hidden', !arr(d.reports).length));
  $('#qqWrap').classList.toggle('hidden', !hasPage('lookup'));
  $('#hotWrap').classList.toggle('hidden', !hasPage('wanted'));
  $('#lastMsgWrap').classList.toggle('hidden', !hasPage('messages'));
  $('#btnMsgs').classList.toggle('hidden', !hasPage('messages'));
  $$('#quickStart [data-qs]').forEach(b => b.classList.toggle('hidden', b.dataset.qs !== 'custom' && !hasPage('lookup')));
  $('#seal').textContent = d.short || 'MDC'; $('#seal').title = d.name || '';
  $('#orgName').textContent = d.name || 'MOBILE DIGITAL COMPUTER';
  $('#app').dataset.theme = d.theme || '';
  const sub = $('.org small'); if (sub) { sub.textContent = d.motto || 'MOBILE DIGITAL COMPUTER'; sub.classList.toggle('motto', !!d.motto); }
  document.documentElement.style.setProperty('--dept', d.color || '#1f3a6e');
  renderFkeys();
}

/* ---------- Theme ---------- */
function setTheme(day) {
  document.body.classList.toggle('day', day);
  $('#btnTheme').textContent = day ? $t('ui.theme_day') : $t('ui.theme_night');
  store.set('knb_cad:day', day ? '1' : '0');
  [mapView, miniView].forEach(v => v && v.setTheme(day ? 'day' : 'night'));
}
$('#btnTheme').onclick = () => setTheme(!document.body.classList.contains('day'));

/* ---------- Tabs ---------- */
function go(name) {
  if (!hasPage(name)) name = 'dash';
  curPage = name;
  $$('.page').forEach(p => p.classList.add('hidden'));
  $('#pg-' + name).classList.remove('hidden');
  $$('.tab[data-go]').forEach(a => a.classList.toggle('on', a.dataset.go === name));
  if (name === 'wanted') loadWanted();
  if (name === 'history') loadHistory();
  if (name === 'records') refreshReportCounts();
  if (name === 'messages') { markRead(chan); renderMessages(); setTimeout(() => $('#mText').focus(), 50); }
  if (name === 'map') openMap();
  if (name === 'units') { renderUnitsBoard(); loadShift(); }
  if (name === 'lookup') setTimeout(() => { const i = $('#qInputs input'); if (i) i.focus(); }, 50);
}
$$('.tab[data-go]').forEach(a => a.onclick = () => go(a.dataset.go));

/* ---------- Top bar ---------- */
function renderHeader() {
  const m = me();
  if (!m) return;
  $('#unitCs').textContent = m.callsign;
  const crew = S.units.filter(u => u.callsign === m.callsign && m.callsign !== 'NEW UNIT').map(u => u.name);
  $('#unitCrew').textContent = (crew.length ? crew : [m.name]).join(' · ');
  const i = stI(m.status), st = $('#btnStatus');
  st.style.color = i.color; st.style.background = tint(i.color, .13); st.style.borderColor = tint(i.color, .45);
  $('#stLabel').textContent = i.label;
  const c = m.callId && S.calls.find(x => x.id === m.callId);
  $('#curInc').textContent = c ? `#${c.id} · ${c.title}` : '—';
  renderFkeys();
}

function tickClock() {
  const d = new Date();
  $('#clk').textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  $('#clkDate').textContent = d.toLocaleDateString(LANG(), { day: '2-digit', month: 'short', year: 'numeric' }).toUpperCase();
  const m = me();
  if (m && appOpen()) $('#stTime').textContent = dur(nowS() - (m.since || nowS()));
  if (appOpen()) liveTimes();
}
setInterval(tickClock, 1000); tickClock();

// Counters that change every second (incident ages, status durations)
function liveTimes() {
  $$('[data-age]').forEach(el => { el.textContent = dur(nowS() - Number(el.dataset.age)); });
  $$('[data-since]').forEach(el => {
    const s = nowS() - Number(el.dataset.since); el.textContent = dur(s);
    if (el.dataset.warn) el.classList.toggle('w', s >= Number(el.dataset.warn));
  });
}

function renderTicker() {
  const t = arr(S.ticker);
  const el = $('#tick');
  if (!t.length) { el.innerHTML = `<b>${$t('ui.ticker_title')}</b><span class="tm">—</span><span>${$t('ui.ticker_none')}</span>`; return; }
  el.innerHTML = `<b>${$t('ui.ticker_title')}</b>` + t.slice(0, 3).map((x, i) => `${i ? '<span class="sep">│</span>' : ''}<span class="itm"><span class="tm">${esc(x.time)}</span><span class="k-${esc(x.kind)}">${esc(x.text)}</span></span>`).join('');
}

/* ---------- F keys ---------- */
function renderFkeys() {
  const m = me() || {};
  const keyed = Object.entries(META.statusInfo || {}).filter(([, i]) => i.key).sort((a, b) => Number(a[1].key.slice(1)) - Number(b[1].key.slice(1)));
  const closeKey = META.openKey === 'F10';
  const k = (key, label, attrs, color, on) => `<button class="k${on ? ' on' : ''}" ${attrs} style="${color ? `--kc:${color};--kg:${tint(color, .18)}` : ''}"><small>${key}</small><b>${label}</b></button>`;
  $('#fk').innerHTML =
    `<div class="fkg" style="--f:${Math.max(1, keyed.length)}">${keyed.map(([s, i]) => k(i.key, esc(i.label), `data-st="${esc(s)}"`, i.color, m.status === s)).join('')}</div>` +
    (hasPage('lookup') ? `<div class="fkg" style="--f:2">${k('F7', $t('ui.fk_traffic'), 'data-fk="F7"')}${k('F8', $t('ui.fk_ped'), 'data-fk="F8"')}</div>` : '') +
    `<div class="fkg" style="--f:2">${hasPage('lookup') ? k('F9', $t('ui.fk_lookup'), 'data-fk="F9"') : ''}${closeKey ? k('F10', $t('ui.fk_close'), 'data-fk="F10"') : k('F10', $t('ui.fk_map'), 'data-fk="F10"')}</div>` +
    `<div class="fkg" style="--f:2.3">${k('F11', $t('ui.fk_backup'), 'data-fk="F11"', '#e09a2b')}<button class="k em" data-fk="F12"><small>F12</small><b>${$t('ui.fk_panic')}</b><span class="hold"></span></button></div>`;
}

$('#fk').addEventListener('click', e => {
  const b = e.target.closest('.k'); if (!b) return;
  if (b.dataset.st) return setStatus(b.dataset.st);
  if (b.dataset.fk && b.dataset.fk !== 'F12') fkey(b.dataset.fk);
});
// Panic: hold to trigger (so it is not pressed by accident)
let panicT = null;
function panicDown() {
  const b = $('.k.em'); if (!b || panicT) return;
  b.classList.add('holding');
  panicT = setTimeout(async () => { panicT = null; b.classList.remove('holding'); const r = await post('panic'); if (r.ok) toast($t('ui.toast_panic'), 4000); }, 1200);
}
function panicUp() { clearTimeout(panicT); panicT = null; const b = $('.k.em'); if (b) b.classList.remove('holding'); }
$('#fk').addEventListener('mousedown', e => { if (e.target.closest('.k.em')) panicDown(); });
window.addEventListener('mouseup', panicUp);

async function setStatus(st) {
  const r = await post('setStatus', { status: st });
  if (!r.ok) toast($t('ui.toast_status_fail'));
}

function fkey(k) {
  switch (k) {
    case 'F7': return hasPage('lookup') && openCreate('traffic');
    case 'F8': return hasPage('lookup') && openCreate('ped');
    case 'F9': go('lookup'); return;
    case 'F10': return META.openKey === 'F10' ? closeCad() : go('map');
    case 'F11': return requestBackup(3);
  }
}

async function requestBackup(code) {
  const r = await post('backup', { code });
  if (r.ok) { toast($t('ui.toast_backup', code, r.id), 4000); selId = r.id; renderDash(); }
  else toast(r.err || $t('ui.toast_backup_fail'));
}

/* ---------- Sound (WebAudio, no files needed) ---------- */
let AC;
function tone(pattern, vol) {
  try {
    AC = AC || new (window.AudioContext || window.webkitAudioContext)();
    if (AC.state === 'suspended') AC.resume();
    const v = Math.max(0, Math.min(1, vol)) * 0.35;
    let t = AC.currentTime + .02;
    pattern.forEach(([f, d, type, gap]) => {
      const o = AC.createOscillator(), g = AC.createGain();
      o.type = type || 'square'; o.frequency.value = f;
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(v, t + .01);
      g.gain.setValueAtTime(v, t + d - .02);
      g.gain.linearRampToValueAtTime(0, t + d);
      o.connect(g); g.connect(AC.destination);
      o.start(t); o.stop(t + d + .02);
      t += d + (gap ?? .06);
    });
  } catch (_) {}
}
const SOUNDS = {
  1: [[660, .14]],
  2: [[880, .12], [880, .12]],
  3: [[1046, .1], [1318, .1], [1046, .1], [1318, .1], [1046, .1], [1318, .1]],
  crit: [[1568, .18, 'sawtooth'], [988, .18, 'sawtooth'], [1568, .18, 'sawtooth'], [988, .18, 'sawtooth', .35], [1568, .18, 'sawtooth'], [988, .18, 'sawtooth'], [1568, .18, 'sawtooth'], [988, .18, 'sawtooth']],
  backup: [[784, .12, 'triangle'], [988, .12, 'triangle'], [1175, .18, 'triangle']],
  msg: [[587, .09, 'sine'], [784, .12, 'sine']],
  direct: [[698, .1, 'sine'], [698, .1, 'sine']],
};
const beep = (k, vol = .35) => tone(SOUNDS[k] || SOUNDS[2], vol);

/* ================= Dispatch notification cards ================= */
const CARDS = new Map();
let maxCards = 4;

function cardTags(c) {
  const t = [];
  const w = c.weapon;
  if (w && w.label) t.push(`<span class="r">${esc(w.label)}${w.auto ? $t('ui.card_auto') : ''}</span>`);
  const v = c.vehicle || {};
  if (v.plate) t.push(`<span class="pl">${esc(v.plate)}</span>`);
  const vm = [v.color, v.make, v.model].filter(Boolean).join(' ');
  if (vm) t.push(`<span>${esc(vm)}${v.class ? ' · ' + esc(v.class) : ''}</span>`);
  if (c.heading) t.push(`<span>${esc($t('ui.card_heading', c.heading))}</span>`);
  if (c.gender) t.push(`<span>${esc(c.gender)}</span>`);
  if (c.camId) t.push(`<span>${esc($t('ui.card_camera', c.camId))}</span>`);
  if (c.approx && c.radius) t.push(`<span class="y">${esc($t('ui.card_area', Math.round(c.radius)))}</span>`);
  if (c.hotspot) t.push(`<span class="y">${esc($t('ui.card_hotspot', c.hotspot))}</span>`);
  arr(c.flags).filter(f => !f.startsWith($t('flag.armed_prefix'))).slice(0, 2).forEach(f => t.push(`<span class="r">${esc(f)}</span>`));
  return t.length ? `<div class="tags">${t.join('')}</div>` : '';
}

function placeCards() {
  const box = $('#alerts');
  const cards = [...box.querySelectorAll('.al')];
  cards.forEach((el, i) => el.classList.toggle('hidden', i >= maxCards));
  let more = box.querySelector('.almore');
  const extra = cards.length - maxCards;
  if (extra > 0) {
    if (!more) { more = document.createElement('div'); more.className = 'almore'; box.appendChild(more); }
    more.textContent = $t('ui.cards_more', extra);
  } else if (more) more.remove();
}

function dropCard(id) {
  const c = CARDS.get(id); if (!c) return;
  clearTimeout(c.timer); CARDS.delete(id);
  c.el.classList.add('out'); setTimeout(() => { c.el.remove(); placeCards(); }, 400);
}

function pushCard(id, el, seconds) {
  const box = $('#alerts');
  if (CARDS.has(id)) dropCard(id);
  box.prepend(el);
  const bar = el.querySelector('.cbar i');
  if (bar) { bar.style.transition = `width ${seconds}s linear`; requestAnimationFrame(() => requestAnimationFrame(() => { bar.style.width = '0%'; })); }
  const timer = setTimeout(() => dropCard(id), seconds * 1000);
  CARDS.set(id, { el, timer });
  placeCards();
}

function showAlert(c, o) {
  maxCards = o.max || maxCards;
  const el = document.createElement('div');
  const backup = !!c.backup;
  el.className = `al P${c.priority}${c.critical ? ' crit' : ''}${backup ? ' bk' : ''}`;
  el.dataset.id = c.id;
  const head = c.critical ? $t('ui.card_critical') : backup ? $t('ui.card_backup', c.backupCode || c.priority) : $t('ui.card_new', c.priority);
  const meta = [`#${c.id}`, c.distance != null ? km(c.distance) : null, c.area, c.postal].filter(Boolean).map(esc).join(' · ');
  el.innerHTML = `<div class="h">${head}<span class="cd">${o.seconds || 10}s</span></div>
    <div class="c"><div class="m">${meta}</div>
      <h3>${esc(c.title)}${(c.count || 1) > 1 ? ` <span class="x">×${c.count}</span>` : ''}</h3>
      <p>${backup ? `${esc($t('ui.card_wants_backup', c.by || ''))} · ` : ''}${esc(c.address || $t('ui.address_unknown'))}</p>${cardTags(c)}</div>
    <div class="ft">${o.key ? `<span class="acc" data-acc="${c.id}"><kbd>${esc(o.key)}</kbd> ${$t('ui.card_accept')}</span>` : ''}<span class="sp"></span>
      ${appOpen() ? `<button data-open="${c.id}">${$t('ui.card_open')}</button>` : ''}<button data-dismiss="${c.id}">${$t('ui.card_dismiss')}</button></div>
    <div class="cbar"><i></i></div>`;
  el.dataset.x = c.x ?? (c.coords && c.coords.x) ?? ''; el.dataset.y = c.y ?? (c.coords && c.coords.y) ?? '';
  pushCard('c' + c.id, el, o.seconds || 10);
  // countdown text
  let left = o.seconds || 10; const cd = el.querySelector('.cd');
  const iv = setInterval(() => { left--; if (!el.isConnected || left < 0) return clearInterval(iv); cd.textContent = left + 's'; }, 1000);
  if (o.sound) beep(c.critical ? 'crit' : backup ? 'backup' : c.priority, o.volume);
}

function mergeAlert(m, o) {
  const card = CARDS.get('c' + m.id);
  if (card) {
    const h3 = card.el.querySelector('h3');
    let x = h3.querySelector('.x');
    if (!x) { x = document.createElement('span'); x.className = 'x'; h3.appendChild(x); }
    x.textContent = '×' + m.count;
    if (m.escalated) { card.el.className = card.el.className.replace(/P[12]/, 'P3'); }
  }
  if (o.sound) beep(3, o.volume);
}

function acceptedCard(id) {
  const card = CARDS.get('c' + id); if (!card) return;
  const k = card.el.querySelector('[data-acc]');
  if (k) { k.classList.add('done'); k.innerHTML = $t('ui.card_assigned'); }
}

$('#alerts').addEventListener('click', async e => {
  const b = e.target.closest('[data-dismiss],[data-open],[data-acc]'); if (!b) return;
  if (b.dataset.dismiss) return dropCard('c' + b.dataset.dismiss);
  if (b.dataset.open) { const id = Number(b.dataset.open); go('dash'); selectCall(id); return; }
  if (b.dataset.acc && !b.classList.contains('done')) {
    const el = b.closest('.al');
    const r = await post('respond', { id: Number(b.dataset.acc), x: Number(el.dataset.x) || null, y: Number(el.dataset.y) || null });
    if (r.ok) acceptedCard(Number(b.dataset.acc)); else toast($t('ui.toast_join_fail'));
  }
});

function showDirect(a, o) {
  const el = document.createElement('div');
  el.className = `al dir P${a.priority || 2}`;
  el.innerHTML = `<div class="h">${$t('ui.card_direct')}</div>
    <div class="c"><h3>${esc(a.title)}</h3>${a.info ? `<p>${esc(a.info)}</p>` : ''}${a.plate ? `<div class="tags"><span class="pl">${esc(a.plate)}</span></div>` : ''}</div><div class="cbar"><i></i></div>`;
  pushCard('d' + Date.now(), el, 8);
  if (o.sound) beep('direct', o.volume);
}

function showMsgCard(m, o) {
  const el = document.createElement('div');
  el.className = 'al msgc';
  el.innerHTML = `<div class="h">${m.to === 'ALL' ? $t('ui.msg_general_channel') : $t('ui.msg_private')}<span>${esc(m.time)}</span></div>
    <div class="c"><div class="m">${esc(m.fromName)}</div><p>${esc(m.text)}</p></div><div class="cbar"><i></i></div>`;
  pushCard('m' + m.id, el, 8);
  if (o.sound) beep('msg', o.volume);
}

/* ================= INCIDENTS ================= */
function isPending(c) { return !arr(c.units).length; }
function filtered() {
  const m = me() || {};
  return S.calls.filter(c => qf === 'all' || (qf === 'pending' && isPending(c)) || (qf === 'mine' && m.callId === c.id) || (qf === 'p3' && c.priority === 3));
}

function queueCard(c) {
  const m = me() || {};
  const fresh = !firstRender && !seen.has(c.id);
  const d = dist(myPos, callPos(c));
  const unatt = isPending(c) && META.unattended > 0 && nowS() - c.created >= META.unattended * 60;
  const ageWarn = isPending(c) ? (META.unattended || 3) * 60 : 0;
  const tags = [];
  if (unatt) tags.push('<span class="tag r">' + $t('ui.tag_unanswered') + '</span>');
  if (c.approx) tags.push('<span class="tag">' + $t('ui.tag_approx') + '</span>');
  if (c.hotspot) tags.push(`<span class="tag">×${c.hotspot}</span>`);
  if (arr(c.flags).length) tags.push('<span class="tag r">' + $t('ui.tag_safety') + '</span>');
  const units = arr(c.units).map(u => `<span class="${u === m.callsign ? 'me' : ''}">${esc(u)}</span>`).join('');
  const pct = isPending(c) ? Math.min(100, (nowS() - c.created) / Math.max(60, ageWarn) * 100) : 0;
  return `<button class="qc${c.id === selId ? ' sel' : ''}${c.critical ? ' crit' : ''}${fresh ? ' fresh' : ''}" data-call="${c.id}" style="--bc:${c.critical ? '#ff3b42' : `var(--c${c.priority})`}">
    <div class="t1">${c.critical ? '<span class="pill CRIT">' + $t('ui.critical') + '</span>' : pri(c.priority)}<b>#${c.id}</b><span class="age" data-since="${c.created}" data-warn="${ageWarn || ''}">${dur(nowS() - c.created)}</span></div>
    <div class="ty">${esc(c.title)}${(c.count || 1) > 1 ? `<span class="cnt">×${c.count}</span>` : ''}</div>
    <div class="ad"><span>${esc([c.postal, c.address].filter(Boolean).join(' · ') || $t('ui.no_address'))}</span><span class="km">${km(d)}</span></div>
    ${units || tags.length ? `<div class="u">${units}${tags.join('')}</div>` : ''}
    ${pct ? `<div class="bar"><i style="width:${pct}%"></i></div>` : ''}</button>`;
}

function renderQueue() {
  const list = filtered(), m = me() || {};
  const crit = list.filter(c => c.critical), pend = list.filter(c => !c.critical && isPending(c)), act = list.filter(c => !c.critical && !isPending(c));
  const g = (t, l, cl = '') => l.length ? `<div class="grp ${cl}">${t}</div>${l.map(queueCard).join('')}` : '';
  $('#queue').innerHTML = (g($t('ui.critical'), crit, 'crit') + g($t('ui.grp_pending'), pend) + g($t('ui.grp_active'), act)) || '<div class="emptyd sm"><span>' + $t('ui.queue_empty') + '</span></div>';
  $('#qCount').textContent = $t('ui.n_open', S.calls.length);
  $('#qfAll').textContent = S.calls.length; $('#qfPending').textContent = S.calls.filter(isPending).length;
  $('#qfMine').textContent = S.calls.filter(c => c.id === m.callId).length; $('#qfP3').textContent = S.calls.filter(c => c.priority === 3).length;
  const tb = $('#tbCalls'); tb.textContent = S.calls.length; tb.classList.toggle('hidden', !S.calls.length);
  S.calls.forEach(c => seen.add(c.id));
  firstRender = false;
}
$('#qFilters').addEventListener('click', e => {
  const b = e.target.closest('[data-qf]'); if (!b) return;
  qf = b.dataset.qf; $$('[data-qf]').forEach(x => x.classList.toggle('on', x === b)); renderQueue();
});
$('#queue').addEventListener('click', e => { const b = e.target.closest('[data-call]'); if (b) selectCall(Number(b.dataset.call)); });
$('#quickStart').addEventListener('click', e => { const b = e.target.closest('[data-qs]'); if (b) openCreate(b.dataset.qs); });

/* ---------- Incident detail ---------- */
let detailFor = null, logSeen = {}, addrCache = {}, miniView = null;

function selectCall(id) {
  selId = id;
  renderQueue();
  buildDetail();
}

function buildDetail() {
  const c = S.calls.find(x => x.id === selId);
  const box = $('#detail');
  if (!c) {
    detailFor = null; openCallId = null; miniView = null;
    box.innerHTML = '<div class="emptyd"><b>' + $t('ui.no_incident_selected') + '</b><span>' + $t('ui.no_incident_hint2') + '</span></div>';
    return;
  }
  if (detailFor !== c.id) {
    detailFor = c.id; openCallId = c.id; logSeen[c.id] = -1;
    box.innerHTML = `<div class="ih" id="dHead"></div>
      <div class="sc">
        <div id="dHaz"></div>
        <div class="top"><div class="f" id="dFields"></div>
          <div class="mm" id="dMini" title="${$t('ui.open_on_map')}"><svg id="mmSvg" preserveAspectRatio="xMidYMid slice"></svg><div class="cap"><span id="mmPostal"></span><span>${$t('ui.open_on_map_btn')}</span></div></div></div>
        <div class="tl" id="dTl"></div>
        <div class="two">
          <div class="pn"><div class="ph">${$t('ui.assigned_units')} <span class="r" id="dUc">0</span></div><div class="scroll"><table><thead><tr><th>${$t('ui.th_unit')}</th><th>${$t('ui.th_status')}</th><th>${$t('ui.th_time')}</th><th>${$t('ui.th_distance')}</th></tr></thead><tbody id="dUnits"></tbody></table></div><div id="dRec"></div></div>
          <div class="pn"><div class="ph">${$t('ui.incident_log')} <span class="r" id="dLc"></span></div><div class="nar" id="dLog">${$t('ui.loading')}</div>
            <div class="ni"><input id="dNote" maxlength="500" placeholder="${$t('ui.log_note_ph')}"><span>ENTER</span></div></div>
        </div>
      </div>
      <div class="act" id="dActs"></div>`;
    miniView = new MAP.View($('#mmSvg'), { layers: { labels: false, routes: true } });
    miniView.setTheme(document.body.classList.contains('day') ? 'day' : 'night');
    loadAddr(c);
  }
  updateDetail();
}

function updateDetail() {
  const c = S.calls.find(x => x.id === selId);
  if (!c) return buildDetail();
  const m = me() || {}, mine = m.callId === c.id;
  // header
  $('#dHead').innerHTML = `<div class="code P${c.priority}">#${c.id}</div>
    <div class="ttl"><h2>${esc(c.title)}${(c.count || 1) > 1 ? ` <span class="pill P3">${$t('ui.n_reports', c.count)}</span>` : ''}</h2>
      <small>${esc(c.agency || '—')} · ${c.system ? $t('ui.auto_dispatch') : esc(c.caller || '—')}</small>
      <div class="tags">${headTags(c)}</div></div>
    <div class="r">${c.critical ? '<span class="pill CRIT">' + $t('ui.pill_critical_code3') + '</span>' : pri(c.priority)}
      <span><select id="dPri" title="${$t('ui.priority')}">${[1, 2, 3].map(p => `<option value="${p}"${p === c.priority ? ' selected' : ''}>Code ${p}</option>`).join('')}</select>
      <select id="dStatus" title="${$t('ui.status')}">${['ACTIVE', 'PENDING'].map(s => `<option${s === c.status ? ' selected' : ''}>${s}</option>`).join('')}</select></span>
      <small>${$t('ui.received_ago', hm(c.created), `<span data-since="${c.created}">${dur(nowS() - c.created)}</span>`)}</small></div>`;
  // officer safety
  const flags = arr(c.flags);
  $('#dHaz').innerHTML = flags.length ? `<div class="haz"><span class="ic">!</span><div class="tx"><b>${$t('ui.officer_safety')}</b><ul>${flags.map(f => `<li>${esc(f)}</li>`).join('')}</ul></div>
    ${c.vehicle && c.vehicle.plate && hasPage('lookup') ? `<button class="b sm" data-q="${esc(c.vehicle.plate)}">${$t('ui.query_plate')}</button>` : ''}</div>` : '';
  // alanlar
  const v = c.vehicle || {};
  const vtxt = [v.color, v.make, v.model].filter(Boolean).join(' ') + (v.plate ? ` · ${v.plate}` : '');
  const ah = addrCache[c.id];
  $('#dFields').innerHTML = `
    <div class="w2"><span class="lbl">${$t('ui.lbl_location')}</span><b title="${esc(c.address)}">${esc(c.address || '—')}</b></div><div><span class="lbl">${$t('ui.lbl_postal_area')}</span><b>${esc([c.postal, c.area].filter(Boolean).join(' · ') || '—')}</b></div>
    <div><span class="lbl">${$t('ui.lbl_caller')}</span><b title="${esc(c.caller)}">${esc(c.caller || '—')}</b></div><div><span class="lbl">${$t('ui.lbl_county')}</span><b>${esc(c.county || '—')}</b></div><div><span class="lbl">${$t('ui.lbl_agency')}</span><b>${esc(c.agency || '—')}</b></div>
    <div><span class="lbl">${$t('ui.lbl_suspect')}</span><b>${esc(c.gender || '—')}</b></div><div><span class="lbl">${$t('ui.lbl_vehicle')}</span><b title="${esc(vtxt)}">${esc(vtxt || '—')}${v.class ? ' · ' + esc(v.class) : ''}</b></div><div><span class="lbl">${$t('ui.lbl_heading')}</span><b>${esc(c.heading || v.heading || '—')}</b></div>
    <div class="w3 prem${ah && !ah.length ? ' none' : ''}"><span class="lbl" style="color:#b89a66">${$t('ui.addr_history', esc(c.postal || '—'))}</span><b>${ah === undefined ? $t('ui.loading') : ah.length ? `${$t('ui.n_incidents', ah.length)} — ${ah.map(h => `#${h.id} ${esc(h.title)} (${new Date(h.created).toLocaleDateString(LANG(), { day: '2-digit', month: 'short' })})`).join(' · ')}` : $t('ui.no_other_incidents')}</b></div>`;
  $('#mmPostal').textContent = '' + (c.postal || '—') + (c.approx ? ` · ~${Math.round(c.radius)} m` : '');
  // timeline
  const T = c.times || {}, steps = [[$t('ui.tl_received'), 'created'], [$t('ui.tl_dispatched'), 'dispatched'], [$t('ui.tl_enroute'), 'enroute'], [$t('ui.tl_onscene'), 'onscene']];
  let prev = T.created;
  $('#dTl').innerHTML = steps.map(([l, k]) => { const t = T[k]; const s = `<div class="${t ? 'd' : 'x'}"><span class="lbl">${l}</span>${t && prev && k !== 'created' ? `<em>+${dur(t - prev)}</em>` : ''}<b>${t ? hm(t) : '--:--:--'}</b></div>`; if (t) prev = t; return s; }).join('')
    + `<div class="x n"><span class="lbl">${$t('ui.tl_closed')}</span><b>--:--:--</b></div>`;
  // birimler
  const on = unitsOn(c), cp = callPos(c);
  $('#dUc').textContent = on.length;
  $('#dUnits').innerHTML = on.length ? on.map(u => {
    const d = dist(unitPos(u.src), cp);
    return `<tr class="${u.src === myId ? 'me' : ''}"><td class="m"><b>${esc(u.callsign)}</b>${u.src === myId ? ` <small>${$t('ui.you_paren')}</small>` : ''}<small>${esc(u.name)}</small></td><td>${ssHtml(u.status)}</td>
      <td class="m" data-since="${u.since}">${dur(nowS() - u.since)}</td><td class="m">${km(d)}${d != null && u.status === 'EN ROUTE' ? ' · ' + eta(d) : ''}</td></tr>`;
  }).join('') : '<tr><td colspan="4" style="color:var(--mu);text-align:center;padding:16px">' + $t('ui.no_units_yet') + '</td></tr>';
  // suggestion: nearest available unit
  const rec = cp && S.units.filter(u => u.status === 'AVAILABLE' && u.callId !== c.id && u.src !== myId)
    .map(u => ({ u, d: dist(unitPos(u.src), cp) })).filter(x => x.d != null).sort((a, b) => a.d - b.d)[0];
  $('#dRec').innerHTML = rec ? `<div class="rec">${$t('ui.suggested', esc(rec.u.callsign), km(rec.d))}
    ${hasPage('messages') ? `<button class="b pr sm" data-ask="${rec.u.src}">${$t('ui.dispatch_btn')}</button>` : ''}</div>` : '';
  // aksiyonlar
  const can = META.perms || {};
  $('#dActs').innerHTML = (mine
    ? `${m.status !== 'ON SCENE' ? `<button class="b ok" data-a="onscene">${$t('ui.act_onscene')}</button>` : ''}
       <button class="b wr" data-a="bk3">${$t('ui.act_backup3')}</button><button class="b" data-a="bk2">${$t('ui.act_backup2')}</button>`
    : `<button class="b ok" data-a="attach">${$t('ui.act_join')}</button>`)
    + `${cp ? `<button class="b" data-a="wp">${$t('ui.act_route')}</button>` : ''}
       ${mine ? `<button class="b gh" data-a="detach">${$t('ui.act_leave')}</button>` : ''}<span class="sp"></span>
       ${canReport('arrest') ? `<button class="b" data-a="arrest">Arrest Report</button>` : ''}
       ${canReport('crime') ? `<button class="b" data-a="crime">Crime Report</button>` : ''}
       ${can.closeCall !== false ? `<button class="b ok" data-a="close">${$t('ui.act_close')}</button>` : ''}`;
  // mini map
  if (miniView && cp) {
    miniView.update(mapData(c.id, true));
    if (miniView.lastFor !== c.id + ':' + c.x) { miniView.lastFor = c.id + ':' + c.x; requestAnimationFrame(() => miniView.center(c.x, c.y, 60)); }
  }
  if (c.logCount !== logSeen[c.id]) loadLog(c.id);
}

function headTags(c) {
  const t = [];
  if (c.weapon && c.weapon.label) t.push(`<span class="chip r">${esc(c.weapon.label)}${c.weapon.auto ? $t('ui.tag_auto') : ''}</span>`);
  if (c.vehicle && (c.vehicle.plate || c.vehicle.model)) t.push(`<span class="chip y">${$t('ui.tag_vehicle')}${c.heading ? ' · ' + esc(c.heading) : ''}</span>`);
  if (c.gender) t.push(`<span class="chip">${esc(c.gender)}</span>`);
  if (c.camId) t.push(`<span class="chip bl">${$t('ui.card_camera', esc(c.camId))}</span>`);
  if (c.approx) t.push(`<span class="chip y">${$t('ui.tag_approx_loc', Math.round(c.radius || 0))}</span>`);
  if (c.hotspot) t.push(`<span class="chip r">${$t('ui.card_hotspot', c.hotspot)}</span>`);
  if (isPending(c) && META.unattended && nowS() - c.created >= META.unattended * 60) t.push(`<span class="chip r">${$t('ui.tag_unanswered_short')}</span>`);
  return t.join('');
}

async function loadAddr(c) {
  if (!c.postal) { addrCache[c.id] = []; return; }
  const r = await post('addrHistory', { postal: c.postal, id: c.id });
  addrCache[c.id] = arr(r);
  if (detailFor === c.id) updateDetail();
}

const logBusy = {};
async function loadLog(id) {
  if (logBusy[id]) return;
  logBusy[id] = true;
  const r = await post('callDetail', { id });
  logBusy[id] = false;
  if (detailFor !== id) return;
  const el = $('#dLog'); if (!el) return;
  const lines = arr(r.log);
  const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 30;
  el.innerHTML = lines.map(l => {
    let cl = 'sy', t = '', txt = l;
    const m = /^\[(\d\d:\d\d)\] ([^:]+): (.*)$/.exec(l);
    if (m) { cl = 'nt'; t = m[1]; txt = `${m[2]}: ${m[3]}`; }
    else if (/^-{3,}/.test(l)) cl = 'hd';
    else if (new RegExp($t('log.hit_regex')).test(l)) cl = 'hit';
    return `<p class="${cl}"><span>${esc(t)}</span><span>${esc(txt)}</span></p>`;
  }).join('') || '—';
  if (atBottom || logSeen[id] === -1) el.scrollTop = el.scrollHeight;
  $('#dLc').textContent = $t('ui.n_lines', lines.length);
  const c = S.calls.find(x => x.id === id);
  logSeen[id] = c ? c.logCount : lines.length;
}

async function addNote() {
  const i = $('#dNote'); if (!i || !i.value.trim()) return;
  await post('addNote', { id: selId, text: i.value.trim() });
  i.value = '';
}

$('#detail').addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.id === 'dNote') addNote(); });
$('#detail').addEventListener('change', e => {
  if (e.target.id === 'dPri') post('updateCall', { id: selId, priority: Number(e.target.value) });
  if (e.target.id === 'dStatus') post('updateCall', { id: selId, status: e.target.value });
});
$('#detail').addEventListener('click', async e => {
  if (e.target.closest('#dMini')) { const c = S.calls.find(x => x.id === selId); go('map'); if (c) { mapSel = c.id; renderMapSide(); mapView.center(c.x, c.y, 80); } return; }
  const q = e.target.closest('[data-q]'); if (q) return quickQuery(q.dataset.q);
  const ask = e.target.closest('[data-ask]');
  if (ask) {
    const c = S.calls.find(x => x.id === selId);
    const r = await post('sendMessage', { to: Number(ask.dataset.ask), text: `#${c.id} ${c.title} · ${c.postal || ''} ${c.address || ''} — ${$t('ui.ask_backup_text')}` });
    return toast(r.ok ? $t('ui.toast_msg_sent_unit') : (r.err || $t('ui.toast_msg_fail')));
  }
  const b = e.target.closest('[data-a]'); if (!b) return;
  const c = S.calls.find(x => x.id === selId); if (!c) return;
  switch (b.dataset.a) {
    case 'attach': { const r = await post('attach', { id: c.id }); if (!r.ok) toast($t('ui.toast_join_fail')); else if (c.x != null) post('waypoint', { x: c.x, y: c.y }); return; }
    case 'detach': return post('detach');
    case 'onscene': return setStatus('ON SCENE');
    case 'bk3': return requestBackup(3);
    case 'bk2': return requestBackup(2);
    case 'wp': post('waypoint', { x: c.x, y: c.y }); return toast($t('ui.toast_route_set'));
    case 'arrest': go('records'); return openForm('arrest', { call_id: c.id });
    case 'crime': go('records'); return openForm('crime', { call_id: c.id });
    case 'close': {
      const r = await confirmBtn(b, $t('ui.closing'), () => post('closeCall', { id: c.id }));
      if (r && r.ok) { S.calls = S.calls.filter(x => x.id !== c.id); selId = null; renderDash(); toast($t('ui.toast_call_closed', c.id)); }
    }
  }
});

/* ---------- Right column ---------- */
function renderRight() {
  const on = S.units.filter(u => u.status !== META.offDuty);
  const cnt = s => on.filter(u => u.status === s).length;
  const groups = ['AVAILABLE', 'EN ROUTE', 'ON SCENE', 'CODE 7'].map(s => [s, stI(s).label]);
  $('#uCount').textContent = $t('ui.n_on_duty', on.length);
  $('#uSum').innerHTML = groups.map(([s, l]) => `<div><b style="color:${stI(s).color}">${cnt(s)}</b><small>${l}</small></div>`).join('');
  const other = on.length - groups.reduce((a, [s]) => a + cnt(s), 0);
  $('#uBar').innerHTML = groups.map(([s]) => `<i style="flex:${cnt(s)};background:${stI(s).color}"></i>`).join('') + (other ? `<i style="flex:${other};background:#94a3b8"></i>` : '');
  const warn = (META.statusCheck || 0) * 60;
  const sorted = [...on].sort((a, b) => (b.src === myId) - (a.src === myId) || a.callsign.localeCompare(b.callsign));
  $('#uList').innerHTML = sorted.slice(0, 14).map(u => `<div class="ur${u.src === myId ? ' me' : ''}"><span class="cs">${esc(u.callsign)}</span>
    <span>${esc(u.name)}<small>${esc(u.agency || '')}${u.callId ? ' · #' + u.callId : ''}</small></span>${ssHtml(u.status)}
    <span class="tm" data-since="${u.since}" ${u.status === 'ON SCENE' && warn ? `data-warn="${warn}"` : ''}>${dur(nowS() - u.since)}</span></div>`).join('')
    + (sorted.length > 14 ? `<div class="hint">${$t('ui.more_units', sorted.length - 14)}</div>` : '');
  const b = arr(S.bolos);
  $('#hotCount').textContent = b.length;
  $('#hotList').innerHTML = b.length ? b.slice(0, 5).map(x => `<div class="hs" data-hs="${x.kind === 'vehicle' ? 'p:' + esc(x.plate) : 'c:' + esc(x.citizenid)}">
    <div><span><b>${esc(x.kind === 'vehicle' ? x.plate : (x.name || x.citizenid))}</b></span><small>${esc(x.reason || '—')} · ${esc(x.author || '')}</small></div></div>`).join('')
    : '<div class="hint">' + $t('ui.no_bolo') + '</div>';
  const tbB = $('#tbBolo'); tbB.textContent = b.length; tbB.classList.toggle('hidden', !b.length);
  const lm = MSGS.slice(-3).reverse();
  $('#lastMsgs').innerHTML = lm.length ? lm.map(m => `<div class="msg" data-mchan="${chanKey(m)}"><b>${esc(m.fromName.split(' · ')[0])}</b> > ${esc(m.toName)} · ${esc(m.text)}<small>${esc(m.time)}</small></div>`).join('') : '<div class="hint">' + $t('ui.no_messages_short') + '</div>';
  const n = Object.values(unread).reduce((a, x) => a + x, 0);
  $('#lmCount').textContent = n ? $t('ui.n_unread', n) : '';
}
$('#hotList').addEventListener('click', e => {
  const h = e.target.closest('[data-hs]'); if (!h) return;
  const [t, v] = h.dataset.hs.split(':');
  if (t === 'p') return quickQuery(v);
  loadProfile(v);
});
$('#lastMsgs').addEventListener('click', e => { const m = e.target.closest('[data-mchan]'); if (!m) return; chan = m.dataset.mchan === 'ALL' ? 'ALL' : Number(m.dataset.mchan); go('messages'); });

function renderDash() {
  if (selId && !S.calls.some(c => c.id === selId)) { selId = null; }
  if (!selId) { const m = me(); selId = (m && m.callId) || null; }
  renderQueue();
  if (selId && detailFor === selId) updateDetail(); else buildDetail();
  renderRight();
}

/* ================= MAP ================= */
let mapView = null, mapSel = null;
const LAYERS = () => [['units', $t('ui.ly_units')], ['calls', $t('ui.ly_calls')], ['routes', $t('ui.ly_routes')], ['rings', $t('ui.ly_rings')], ['labels', $t('ui.ly_labels')], ['postals', $t('ui.ly_postals')]];

function mapData(sel, near) {
  const calls = S.calls.filter(c => c.x != null).map(c => ({ id: c.id, x: c.x, y: c.y, priority: c.priority, critical: c.critical, radius: c.radius, label: `#${c.id}${(c.count || 1) > 1 ? ' ×' + c.count : ''}` }));
  const units = TRACK.map(t => {
    const mem = arr(t.members).map(s => S.units.find(u => u.src === s)).filter(Boolean);
    const st = mem[0] ? mem[0].status : 'AVAILABLE';
    return { key: t.net, x: t.x, y: t.y, h: t.h, label: t.cs, color: stI(st).color, mine: arr(t.members).includes(myId), members: mem };
  });
  const routes = [];
  S.calls.forEach(c => {
    if (c.x == null || (sel && near && c.id !== sel)) return;
    units.forEach(u => {
      if (u.members.some(m => m.callId === c.id && m.status === 'EN ROUTE')) {
        const d = Math.hypot(u.x - c.x, u.y - c.y);
        routes.push({ x1: u.x, y1: u.y, x2: c.x, y2: c.y, eta: eta(d) });
      }
    });
  });
  return { calls, units, routes, me: myPos, sel };
}

function openMap() {
  if (!mapView) {
    mapView = new MAP.View($('#mapSvg'), {
      interactive: true,
      onSelect: (t, id) => { if (t === 'call') { mapSel = Number(id); renderMapSide(); refreshMap(); } },
      onCursor: (x, y, p) => { $('#mapCur').textContent = $t('ui.map_cursor', p ? p.code : '—', Math.round(x), Math.round(y)); },
    });
    mapView.setTheme(document.body.classList.contains('day') ? 'day' : 'night');
    const sv = store.get('knb_cad:layers', '');
    if (sv) try { Object.assign(mapView.layers, JSON.parse(sv)); } catch (_) {}
    requestAnimationFrame(() => { mapView.fit(); refreshMap(); });
  }
  renderMapFilters(); renderMapSide(); requestAnimationFrame(() => { mapView.apply(); refreshMap(); });
}

function refreshMap() {
  if (!mapView || curPage !== 'map') return;
  mapView.update(mapData(mapSel));
  const k = mapView.k();
  $('#mapScaleT').textContent = `${Math.round(80 * k * 10)} m`;
}

function renderMapFilters() {
  $('#mapFilters').innerHTML = `<button class="chip ${mapView.layers.units ? 'on' : ''}" data-ly="units">${$t('ui.f_units')} <em>${TRACK.length}</em></button>
    <button class="chip ${mapView.layers.calls ? 'on' : ''}" data-ly="calls">${$t('ui.f_incidents')} <em>${S.calls.length}</em></button>
    <button class="chip ${mapView.layers.postals ? 'on' : ''}" data-ly="postals">${$t('ui.ly_postals')}</button>`;
}

function renderMapSide() {
  const c = S.calls.find(x => x.id === mapSel);
  const cp = callPos(c);
  const near = cp ? S.units.filter(u => u.status !== META.offDuty).map(u => ({ u, d: dist(unitPos(u.src), cp) })).filter(x => x.d != null).sort((a, b) => a.d - b.d).slice(0, 6) : [];
  $('#mapSide').innerHTML = `<div class="ph">${$t('ui.selected_incident')}</div>
    ${c ? `<div class="msel"><div class="t">${c.critical ? '<span class="pill CRIT">' + $t('ui.critical') + '</span>' : pri(c.priority)}<h3>#${c.id}</h3></div>
      <p>${esc(c.title)}<br>${esc([c.postal, c.address].filter(Boolean).join(' · '))}${c.area ? ' · ' + esc(c.area) : ''}<br>${$t('ui.assigned_colon')} <b class="m">${esc(arr(c.units).join(' · ') || '—')}</b></p>
      <div class="bt"><button class="b pr" data-ma="wp">${$t('ui.btn_give_route')}</button><button class="b" data-ma="open">${$t('ui.btn_open_incident')}</button><button class="b" data-ma="focus">${$t('ui.btn_focus')}</button></div></div>
      <div class="ph">${$t('ui.nearest_units')} <span class="r">${$t('ui.by_incident')}</span></div>
      <div class="mls">${near.length ? near.map(({ u, d }) => `<div class="r"><b>${esc(u.callsign)}</b><span>${ssHtml(u.status)}</span><small>${u.callId === c.id ? $t('ui.on_incident') : km(d)}</small><span></span></div>`).join('') : '<div class="hint">' + $t('ui.no_located_units') + '</div>'}</div>`
    : '<div class="emptyd sm"><span>' + $t('ui.click_incident') + '</span></div>'}
    <div class="ph">${$t('ui.layers')}</div>
    <div class="ly">${LAYERS().map(([k, l]) => `<label data-ly="${k}"><i class="tg ${mapView && mapView.layers[k] ? 'on' : ''}"></i><span>${l}</span><span></span></label>`).join('')}</div>`;
}

$('#pg-map').addEventListener('click', e => {
  const z = e.target.closest('[data-mz]');
  if (z) {
    if (z.dataset.mz === 'in') mapView.zoom(1 / 1.4); else if (z.dataset.mz === 'out') mapView.zoom(1.4);
    else if (z.dataset.mz === 'fit') mapView.fit();
    else if (z.dataset.mz === 'me' && myPos) mapView.center(myPos.x, myPos.y, 90);
    return refreshMap();
  }
  const ly = e.target.closest('[data-ly]');
  if (ly) { const k = ly.dataset.ly; mapView.layers[k] = !mapView.layers[k]; store.set('knb_cad:layers', JSON.stringify(mapView.layers)); renderMapFilters(); renderMapSide(); return refreshMap(); }
  const a = e.target.closest('[data-ma]'); if (!a) return;
  const c = S.calls.find(x => x.id === mapSel); if (!c) return;
  if (a.dataset.ma === 'wp') { post('waypoint', { x: c.x, y: c.y }); toast($t('ui.toast_route_set')); }
  if (a.dataset.ma === 'open') { go('dash'); selectCall(c.id); }
  if (a.dataset.ma === 'focus') mapView.center(c.x, c.y, 70);
});
window.addEventListener('resize', () => { if (mapView) { mapView.apply(); refreshMap(); } if (miniView) miniView.apply(); });

/* ================= LOOKUP ================= */
let qType = 'plate', QH = [], qLast = null;
const QIN = {
  plate: () => `<label class="in"><small>${$t('q.f_plate')}</small><input id="qPlate" maxlength="12"></label>`,
  person: () => `<div class="row2"><label class="in"><small>${$t('q.f_first')}</small><input id="qFirst" maxlength="30"></label><label class="in"><small>${$t('q.f_last')}</small><input id="qLast" maxlength="30"></label></div><label class="in"><small>${$t('q.f_cid')}</small><input id="qCid" maxlength="50"></label>`,
  weapon: () => `<label class="in"><small>${$t('q.f_serial')}</small><input id="qSerial" maxlength="32"></label>`,
};
function setQType(t) {
  qType = t; $$('#qSeg [data-qt]').forEach(b => b.classList.toggle('on', b.dataset.qt === t));
  $('#qInputs').innerHTML = QIN[t]();
  const i = $('#qInputs input'); if (i) i.focus();
}
$('#qSeg').addEventListener('click', e => { const b = e.target.closest('[data-qt]'); if (b) setQType(b.dataset.qt); });
$('#qInputs').addEventListener('keydown', e => { if (e.key === 'Enter') runQuery(); });
$('#qGo').onclick = () => runQuery();
setQType('plate');

// Quick search box at the top: recognises a plate, a "First Last" name or a serial number on its own
function quickQuery(text) {
  const t = up(String(text || '').trim()); if (!t) return;
  go('lookup');
  if (/^(S:|SN[-:]?)/.test(t)) { setQType('weapon'); $('#qSerial').value = t.replace(/^S:/, ''); }
  else if (/\s/.test(t)) { setQType('person'); const p = t.split(/\s+/); $('#qFirst').value = p[0]; $('#qLast').value = p.slice(1).join(' '); }
  else { setQType('plate'); $('#qPlate').value = t; $('#qExact').checked = true; }
  runQuery();
}
$('#qq').addEventListener('keydown', e => { if (e.key === 'Enter') { quickQuery(e.target.value); e.target.value = ''; e.target.blur(); } });

function addHist(type, label, hit, run) {
  QH = QH.filter(h => !(h.type === type && h.label === label));
  QH.unshift({ type, label, hit, run, time: new Date().toLocaleTimeString(LANG(), { hour: '2-digit', minute: '2-digit' }) });
  QH = QH.slice(0, 30);
  renderHist();
}
function renderHist() {
  const T = { plate: $t('q.t_plate'), person: $t('q.t_person'), weapon: $t('q.t_weapon') };
  $('#qhCount').textContent = $t('q.this_session', QH.length);
  $('#qHist').innerHTML = QH.length ? QH.map((h, i) => `<button class="hi${i === 0 ? ' sel' : ''}" data-qh="${i}"><span class="t">${T[h.type]}</span><div><b>${esc(h.label)}</b><small>${h.time}</small></div><span class="rs ${h.hit ? 'h' : 'c'}">${h.hit ? 'HIT' : $t('q.clear')}</span></button>`).join('')
    : `<div class="hint">${$t('q.no_queries')}</div>`;
}
$('#qHist').addEventListener('click', e => { const b = e.target.closest('[data-qh]'); if (b) QH[Number(b.dataset.qh)].run(); });
renderHist();

const stamp = () => `${new Date().toLocaleTimeString(LANG())} · ${(me() || {}).callsign || ''}`;
function retFrame(hit, title, body, actions, tabs = '') {
  $('#qRet').innerHTML = `<div class="hit${hit ? '' : ' clr'}"><span>${hit ? 'HIT' : $t('q.clear')}</span> ${esc(title)}<small>${esc(stamp())}</small></div>${tabs}
    <div class="tt" id="tt">${body}</div><div class="acts">${actions || ''}</div>`;
}
const L = (k, v, cl = '') => `${(k + '.'.repeat(Math.max(1, 11 - k.length))).slice(0, 11)}: ${cl ? `<span class="${cl}">${v}</span>` : v}\n`;
const EOR = () => `<span class="d">─── ${$t('q.end_of_return')} ───</span>`;
const H = t => `<span class="h">${esc(t)} ${'─'.repeat(Math.max(4, 60 - t.length))}</span>\n`;

async function runQuery() {
  const exact = $('#qExact').checked;
  if (qType === 'plate') {
    const plate = up(($('#qPlate') || {}).value || '').trim(); if (!plate) return toast($t('q.enter_plate'));
    return queryPlate(plate, exact);
  }
  if (qType === 'person') {
    const first = ($('#qFirst') || {}).value || '', last = ($('#qLast') || {}).value || '', cid = ($('#qCid') || {}).value || '';
    if (!first.trim() && !last.trim() && !cid.trim()) return toast($t('q.enter_name'));
    return queryPerson(first, last, cid, exact);
  }
  const serial = up(($('#qSerial') || {}).value || '').trim(); if (serial.length < 3) return toast($t('q.enter_serial'));
  return queryWeapon(serial);
}

async function queryPlate(plate, exact) {
  $('#qRet').innerHTML = `<div class="emptyd"><b>${$t('q.querying')}</b><span>${$t('q.sub_plate')}</span></div>`;
  const rows = arr(await post('lookupVehicle', { plate, exact }));
  if (rows.length > 1) {
    retFrame(rows.some(r => r.bolo || r.ownerWanted), $t('q.n_matches', rows.length, plate), H($t('q.multi_result')) + rows.map(v => `<span class="pick" data-pplate="${esc(v.plate)}">${esc(v.plate.padEnd(10))} ${esc(String(v.model).padEnd(16))} ${esc((v.firstname || '-') + ' ' + (v.lastname || ''))}${v.bolo ? ' <span class="r">*BOLO*</span>' : ''}${v.ownerWanted ? ` <span class="r">*${$t('q.tag_owner_wanted')}*</span>` : ''}</span>`).join(''), '');
    addHist('plate', plate, rows.some(r => r.bolo || r.ownerWanted), () => queryPlate(plate, false));
    return;
  }
  const v = rows[0] || { plate, model: $t('lookup.unregistered'), unregistered: true };
  const P = v.citizenid ? await post('profile', { citizenid: v.citizenid }) : null;
  showVehicleReturn(v, P && P.ok ? P : null);
  addHist('plate', v.plate || plate, !!(v.bolo || v.ownerWanted || v.ownerBolo), () => queryPlate(v.plate || plate, true));
}

function personFlags(P) {
  const f = [];
  if (!P) return f;
  if (arr(P.warrants).length) f.push(['r', '', $t('q.fl_warrant')]);
  if (P.bolo) f.push(['r', '', $t('q.fl_person_bolo')]);
  if (arr(P.warrants).some(w => arr(w.flags).length)) f.push(['r', '', arr(P.warrants).flatMap(w => arr(w.flags))[0]]);
  arr(P.licenses).forEach(l => f.push([l.valid ? 'g' : (l.key === 'driver' ? 'y' : 'n'), l.valid ? '' : '', `${up(l.label)} ${l.valid ? $t('q.valid') : $t('q.none_short')}`]));
  if (P.pointsLimit) f.push([P.points >= P.pointsLimit ? 'r' : 'n', '', $t('q.points_short', P.points, P.pointsLimit)]);
  f.push(['n', '', $t('q.n_records', arr(P.records).length)]);
  return f;
}

function summaryHtml(P, v) {
  const flags = personFlags(P);
  if (v && v.bolo) flags.unshift(['r', '', $t('q.fl_vehicle_bolo')]);
  const initials = P ? ((P.firstname || '?')[0] + (P.lastname || '?')[0]).toUpperCase() : '?';
  return `<div class="ph">${$t('q.summary')}</div>
    ${P ? `<div class="card"><div class="ph2">${esc(initials)}<i>${$t('q.no_photo')}</i></div>
      <div class="who"><h3>${esc(up(P.lastname))}, ${esc(up(P.firstname))}</h3><div class="m">${esc(P.citizenid)} · ${esc(P.gender || '-')}</div>
      <dl><dt>${$t('q.dob')}</dt><dd>${esc(P.dob || '-')}</dd><dt>${$t('q.phone')}</dt><dd>${esc(P.phone || '-')}</dd><dt>${$t('q.job')}</dt><dd>${esc(P.job || '-')}</dd><dt>${$t('q.nationality')}</dt><dd>${esc(P.nationality || '-')}</dd></dl></div></div>` : ''}
    ${flags.length ? `<div class="qflags">${flags.map(([c, i, t]) => `<div class="fl ${c}">${esc(t)}</div>`).join('')}</div>` : ''}
    ${v ? `<div class="veh"><div class="plate"><small>San Andreas</small><b>${esc(v.plate)}</b></div><div class="vi"><b>${esc(v.model)}</b><br>${v.firstname ? $t('q.registered_to', `${esc(v.firstname)} ${esc(v.lastname || '')}`) : $t('q.no_owner')}${v.bolo ? `<br><span style="color:#ff8a8d">BOLO: ${esc(v.bolo.reason)}</span>` : ''}</div></div>` : ''}
    ${P && arr(P.records).length ? `<div class="ph">${$t('q.recent_records')}</div><div class="pc">${arr(P.records).slice(0, 8).map(r => `<p data-rec="${r.id}"><b>${esc(String(r.typeLabel).toUpperCase())}</b><span>${esc(r.summary)}</span><small>${new Date(Number(r.created)).toLocaleDateString(LANG(), { day: '2-digit', month: '2-digit' })}</small></p>`).join('')}</div>` : ''}`;
}

function personTT(P) {
  if (!P) return '';
  let s = H($t('q.h_driver'));
  s += `${esc(up(P.lastname))}, ${esc(up(P.firstname))} · ${$t('q.dob_abbr')} ${esc(P.dob || '-')} · ${esc(up(P.gender || '-'))} · CID ${esc(P.citizenid)}\n`;
  const drv = arr(P.licenses).find(l => l.key === 'driver'), wpn = arr(P.licenses).find(l => l.key === 'weapon');
  if (drv) s += L($t('q.l_license'), drv.valid ? $t('q.valid') : $t('q.none_susp'), drv.valid ? '' : 'r') .replace('\n', `   ${$t('q.points_line', P.points, P.pointsLimit, P.pointsDays)}\n`);
  if (wpn) s += L($t('q.l_wpn_permit'), wpn.valid ? $t('q.yes') : $t('q.no'), wpn.valid ? '' : 'y');
  if (P.bolo) s += `\n<span class="r">*** ${$t('q.fl_person_bolo')} ***  ${esc(P.bolo.reason)} · ${esc(P.bolo.author)}</span>\n`;
  arr(P.warrants).forEach(w => {
    s += `\n<span class="r">*** ${$t('q.fl_warrant')} *** #${w.id} · ${esc(w.title)}\n                   ${$t('q.issued_by')} ${esc(w.callsign)} ${esc(w.author)}${w.expires ? ' · ' + $t('q.expires_up') + ' ' + esc(w.expires) : ''}</span>\n`;
    if (arr(w.flags).length) s += `<span class="r">*** ${$t('q.caution')} ***      ${arr(w.flags).map(esc).join(' · ')}</span>\n`;
  });
  if (arr(P.vehicles).length) { s += '\n' + H($t('q.h_vehicles')); s += arr(P.vehicles).map(v => `<span class="pick" data-pplate="${esc(v.plate)}">${esc(String(v.plate).padEnd(10))} ${esc(v.model)}${v.bolo ? ' <span class="r">*BOLO*</span>' : ''}</span>`).join(''); }
  if (arr(P.weapons).length) { s += '\n' + H($t('q.h_weapons')); s += arr(P.weapons).map(w => `${esc(String(w.serial).padEnd(14))} ${esc(w.label)}\n`).join(''); }
  if (arr(P.records).length) {
    s += '\n' + H($t('q.h_contacts'));
    s += arr(P.records).slice(0, 10).map(r => `<span class="pick" data-rec="${r.id}">#${String(r.id).padEnd(7)} ${esc(String(r.typeLabel).toUpperCase().padEnd(15))} ${esc(String(r.summary).slice(0, 40).padEnd(40))} ${dt(r.created)}  ${esc(r.callsign)}</span>`).join('');
  }
  return s;
}

function showVehicleReturn(v, P) {
  const reg = !!v.unregistered;
  const hit = !!(v.bolo || v.ownerWanted || v.ownerBolo);
  let s = H($t('q.h_dmv'));
  s += L($t('q.l_plate'), esc(v.plate) + '          ' + $t('q.state_sa'));
  s += reg ? L($t('q.l_record'), $t('q.no_record_found'), 'y') : L($t('q.l_vehicle'), esc(v.model)) + L($t('q.l_owner'), `${esc(up(v.lastname || '-'))}, ${esc(up(v.firstname || ''))}   CID: ${esc(v.citizenid || '-')}`);
  if (v.bolo) s += `\n<span class="r">*** BOLO ***   ${esc(v.plate)} · ${esc(v.bolo.reason)} · ${$t('q.entered_by')} ${esc(v.bolo.author || '')}</span>\n`;
  if (v.ownerWanted) s += `<span class="r">*** ${$t('q.owner_active_warrant')} ***</span>\n`;
  if (v.ownerBolo) s += `<span class="r">*** ${$t('q.owner_person_bolo')} *** ${esc(v.ownerBolo)}</span>\n`;
  s += '\n' + personTT(P) + '\n' + EOR() + '';
  const title = hit ? (v.bolo ? $t('q.bolo_vehicle') : $t('q.owner_wanted_title')) + ' — ' + $t('q.approach_caution') : reg ? $t('q.unreg_plate') : `${v.plate} · ${v.model}`;
  qLast = { kind: 'plate', v, P };
  retFrame(hit, title, s, queryActions());
  $('#qSum').innerHTML = summaryHtml(P, v);
}

async function queryPerson(first, last, citizenid, exact) {
  $('#qRet').innerHTML = `<div class="emptyd"><b>${$t('q.querying')}</b><span>${$t('q.sub_person')}</span></div>`;
  const rows = arr(await post('lookup', { first, last, citizenid, exact }));
  const label = up([first, last].join(' ').trim() || citizenid);
  if (!rows.length) {
    retFrame(false, $t('q.no_record', label), H($t('q.h_person_query')) + $t('q.no_citizen_match') + '\n', '');
    $('#qSum').innerHTML = summaryHtml(null, null);
    return addHist('person', label, false, () => queryPerson(first, last, citizenid, exact));
  }
  if (rows.length > 1) {
    retFrame(rows.some(r => r.wanted || r.bolo), $t('q.n_matches', rows.length, label), H($t('q.multi_result')) + rows.map(r => `<span class="pick" data-pcid="${esc(r.citizenid)}">${esc((up(r.lastname) + ', ' + up(r.firstname)).padEnd(26))} ${esc(String(r.dob || '-').padEnd(12))} ${esc(r.citizenid)}${r.wanted ? ` <span class="r">*${$t('q.tag_wanted')}*</span>` : ''}${r.bolo ? ' <span class="r">*BOLO*</span>' : ''}</span>`).join(''), '');
    return addHist('person', label, rows.some(r => r.wanted || r.bolo), () => queryPerson(first, last, citizenid, exact));
  }
  return showPersonReturn(rows[0].citizenid);
}

async function showPersonReturn(cid) {
  const P = await post('profile', { citizenid: cid });
  if (!P.ok) return toast(P.err || $t('q.err_person'));
  const hit = arr(P.warrants).length > 0 || !!P.bolo;
  qLast = { kind: 'person', P };
  retFrame(hit, hit ? `${up(P.firstname)} ${up(P.lastname)} · ${arr(P.warrants).length ? $t('q.active_warrant') : $t('q.fl_person_bolo')}` : `${up(P.firstname)} ${up(P.lastname)}`,
    personTT(P) + '\n' + EOR() + '', queryActions());
  $('#qSum').innerHTML = summaryHtml(P, null);
  addHist('person', `${up(P.lastname)}, ${up(P.firstname)}`, hit, () => showPersonReturn(cid));
}

async function queryWeapon(serial) {
  $('#qRet').innerHTML = `<div class="emptyd"><b>${$t('q.querying')}</b><span>${$t('q.sub_weapon')}</span></div>`;
  const r = await post('lookupWeapon', { serial });
  if (!r.ok) { toast(r.err || $t('q.err_query')); $('#qRet').innerHTML = ''; return; }
  const list = arr(r.list), hit = list.some(w => w.ownerWanted);
  let s = H($t('q.h_weapon_query'));
  s += list.length ? list.map(w => `${L($t('q.l_serial'), esc(w.serial))}${L($t('q.l_weapon'), esc(w.label) + ' (' + esc(w.name) + ')')}<span class="pick" data-pcid="${esc(w.citizenid)}">${L($t('q.l_held_by'), esc(up(w.owner)) + '  CID ' + esc(w.citizenid))}</span>${w.ownerWanted ? `<span class="r">*** ${$t('q.owner_active_warrant')} ***</span>\n` : ''}\n`).join('')
    : $t('q.no_weapon_found') + '\n';
  qLast = null;
  retFrame(hit, list.length ? $t('q.n_weapons', list.length, serial) : $t('q.no_record', serial), s + '\n' + EOR() + '', '');
  $('#qSum').innerHTML = `<div class="ph">${$t('q.summary')}</div><div class="emptyd sm"><span>${$t('q.click_owner')}</span></div>`;
  addHist('weapon', serial, hit, () => queryWeapon(serial));
}

function queryActions() {
  const q = qLast; if (!q) return '';
  const P = q.P, v = q.v, m = me() || {};
  return `${P ? `<button class="b pr" data-qa="prof">${$t('q.open_profile')}</button>` : ''}
    ${v ? `<button class="b" data-qa="stop">${$t('q.start_stop')}</button>` : ''}
    ${m.callId ? `<button class="b" data-qa="addcall">${$t('q.add_to_call', m.callId)}</button>` : ''}
    ${v ? `<button class="b ${v.bolo ? 'wr' : ''}" data-qa="bolo">${v.bolo ? $t('q.bolo_remove') : $t('q.bolo_add')}</button>` : ''}<span class="sp"></span>
    ${P && canReport('citation') ? `<button class="b" data-qa="citation">Citation</button>` : ''}
    ${P && canReport('arrest') ? `<button class="b wr" data-qa="arrest">Arrest Report</button>` : ''}`;
}

$('#qRet').addEventListener('click', async e => {
  const pk = e.target.closest('[data-pplate],[data-pcid],[data-rec]');
  if (pk) {
    if (pk.dataset.rec) return openRecord(Number(pk.dataset.rec));
    if (pk.dataset.pplate) { setQType('plate'); $('#qPlate').value = pk.dataset.pplate; return queryPlate(pk.dataset.pplate, true); }
    return showPersonReturn(pk.dataset.pcid);
  }
  const b = e.target.closest('[data-qa]'); if (!b || !qLast) return;
  const { P, v } = qLast;
  switch (b.dataset.qa) {
    case 'prof': return loadProfile(P.citizenid);
    case 'stop': return openCreate('traffic', v ? { plate: v.plate, model: !v.unregistered ? v.model : '' } : {});
    case 'addcall': {
      const m = me();
      const txt = v ? `${$t('q.note_query')} ${v.plate}: ${v.model}${v.firstname ? $t('q.note_owner') + v.firstname + ' ' + (v.lastname || '') : ''}${v.bolo ? ' · BOLO HIT' : ''}${v.ownerWanted ? $t('q.note_owner_wanted') : ''}`
        : `${$t('q.note_query')} ${P.firstname} ${P.lastname} (${P.citizenid})${arr(P.warrants).length ? $t('q.note_warrant_hit') : ''}`;
      const r = await post('addNote', { id: m.callId, text: txt });
      return toast(r.ok ? $t('q.toast_added') : $t('q.toast_add_fail'));
    }
    case 'bolo':
      if (v.bolo) { await post('setBolo', { plate: v.plate, active: false }); toast($t('q.toast_bolo_removed')); return queryPlate(v.plate, true); }
      boloPlate = v.plate; return reasonModal($t('q.bolo_add_title', v.plate), 'bolo-save', { kind: 'vehicle' });
    case 'citation': go('records'); return openForm('citation', profilePrefill(P));
    case 'arrest': go('records'); return openForm('arrest', profilePrefill(P));
  }
});
$('#qSum').addEventListener('click', e => { const r = e.target.closest('[data-rec]'); if (r) openRecord(Number(r.dataset.rec)); });

/* ---------- Citizen profile (window) ---------- */
let boloPlate = '';
async function loadProfile(cid) {
  const P = await post('profile', { citizenid: cid });
  if (!P.ok) return toast(P.err || $t('p.err_load'));
  PROF = P;
  openModal(`<div class="chead"><b class="big">${$t('p.title')}</b><button class="xbtn" data-act="x">×</button></div>${profileHtml(P)}`, 'profbox');
}

function profileHtml(P) {
  const perms = META.perms || {};
  const lim = P.pointsLimit || 0, pts = P.points || 0;
  const over = lim > 0 && pts >= lim;
  const initials = ((P.firstname || '?')[0] + (P.lastname || '?')[0]).toUpperCase();
  return `<div class="prof" id="profBody">
    ${P.warrants.length ? `<div class="alarm red">${$t('p.active_warrants_n', P.warrants.length)} ${P.warrants.map(w => esc(w.title)).join(' · ')}</div>` : ''}
    ${P.bolo ? `<div class="alarm orange">${$t('p.person_bolo_colon')} ${esc(P.bolo.reason)} <small>(${esc(P.bolo.author)} · ${dt(P.bolo.created)})</small></div>` : ''}
    <div class="phead">
      <div class="avatar">${esc(initials)}</div>
      <div class="pname"><h2>${esc(P.firstname)} ${esc(P.lastname)}</h2><small>${esc(P.citizenid)}</small></div>
      <div class="pactions">
        ${canReport('arrest') ? `<button class="b wr" data-new="arrest">${$t('p.btn_arrest')}</button>` : ''}
        ${canReport('citation') ? `<button class="b" data-new="citation">${$t('p.btn_citation')}</button>` : ''}
        ${canReport('warrant') ? `<button class="b" data-new="warrant">${$t('p.btn_warrant')}</button>` : ''}
        <button class="b ${P.bolo ? 'wr' : ''}" data-pbolo="${P.bolo ? 'off' : 'on'}">${P.bolo ? $t('q.bolo_remove') : $t('q.person_bolo_btn')}</button>
      </div>
    </div>
    <div class="pgrid">
      <div><label>${$t('p.l_dob')}</label><span>${esc(P.dob || '-')}</span></div>
      <div><label>${$t('p.l_gender')}</label><span>${esc(P.gender || '-')}</span></div>
      <div><label>${$t('p.l_phone')}</label><span>${esc(P.phone || '-')}</span></div>
      <div><label>${$t('p.l_nationality')}</label><span>${esc(P.nationality || '-')}</span></div>
      <div><label>${$t('p.l_job')}</label><span>${esc(P.job || '-')}</span></div>
    </div>
    <h4>${$t('p.licenses')}</h4>
    <div class="lics">${P.licenses.map(l => `<div class="lic ${l.valid ? 'ok' : 'no'}">
        <b>${esc(l.label)}</b><span>${l.valid ? $t('q.valid') : $t('q.none_susp')}</span>
        ${perms.licenses ? `<button class="mini" data-lic="${esc(l.key)}" data-v="${l.valid ? 0 : 1}">${l.valid ? $t('p.suspend') : $t('p.grant')}</button>` : ''}
      </div>`).join('')}</div>
    <div class="points ${over ? 'over' : ''}">${$t('p.points_label')} <b>${pts} / ${lim}</b> <small>${$t('p.points_days', P.pointsDays)}</small>${over ? ' · ' + $t('p.limit_exceeded') : ''}</div>
    ${P.warrants.length ? `<h4>${$t('p.h_warrants')}</h4>
      <table class="mt"><thead><tr><th>#</th><th>${$t('p.th_charges')}</th><th>${$t('q.expires_up')}</th><th>${$t('p.th_officer')}</th><th></th></tr></thead><tbody>
      ${P.warrants.map(w => `<tr><td>${w.id}</td><td>${esc(w.title)}${arr(w.flags).map(f => ` <span class="flag red">${esc(f)}</span>`).join('')}</td><td>${esc(w.expires || '-')}</td><td>${esc(w.callsign)} ${esc(w.author)}</td>
        <td><button class="mini" data-rec="${w.id}">${$t('p.view')}</button></td></tr>`).join('')}</tbody></table>` : ''}
    <h4>${$t('p.h_vehicles', P.vehicles.length)}</h4>
    ${P.vehicles.length ? `<table class="mt"><thead><tr><th>${$t('q.f_plate')}</th><th>${$t('p.th_model')}</th><th></th></tr></thead><tbody>
      ${P.vehicles.map(v => `<tr><td><b class="m">${esc(v.plate)}</b>${v.bolo ? ' <span class="flag red">BOLO</span>' : ''}</td><td>${esc(v.model)}</td>
        <td><button class="mini" data-vplate="${esc(v.plate)}">${$t('p.query')}</button></td></tr>`).join('')}</tbody></table>` : `<p class="muted">${$t('p.no_vehicles')}</p>`}
    <h4>${$t('p.h_weapons', P.weapons.length)}</h4>
    ${P.weapons.length ? `<table class="mt"><thead><tr><th>${$t('q.t_weapon')}</th><th>${$t('q.l_serial')}</th></tr></thead><tbody>
      ${P.weapons.map(w => `<tr><td>${esc(w.label)}</td><td class="m">${esc(w.serial)}</td></tr>`).join('')}</tbody></table>` : `<p class="muted">${$t('p.no_weapons')}</p>`}
    <h4>${$t('p.h_records', P.records.length)}</h4>
    ${P.records.length ? `<table class="mt"><thead><tr><th>#</th><th>${$t('p.th_type')}</th><th>${$t('p.th_summary')}</th><th>${$t('ui.th_status')}</th><th>${$t('p.th_officer')}</th><th>${$t('p.th_date')}</th></tr></thead><tbody>
      ${P.records.map(r => `<tr class="click" data-rec="${r.id}"><td>${r.id}</td><td>${esc(r.typeLabel)}</td><td>${esc(r.summary)}</td>
        <td>${r.status ? `<span class="pill ${esc(r.status)}">${esc(r.status)}</span>` : ''}</td>
        <td>${esc(r.callsign)} ${esc(r.author)}</td><td>${dt(r.created)}</td></tr>`).join('')}</tbody></table>` : `<p class="muted">${$t('p.no_records')}</p>`}
  </div>`;
}

function profilePrefill(P) {
  return { citizenid: P.citizenid, first: P.firstname, last: P.lastname, dob: P.dob, sex: P.gender, phone: P.phone,
    _name: `${P.firstname} ${P.lastname}` };
}

/* ---------- Modal ---------- */
const M = $('#modal');
function openModal(html, extra = '') { M.innerHTML = `<div class="box ${extra}">${html}</div>`; M.classList.remove('hidden'); }
function closeModal() { M.classList.add('hidden'); M.innerHTML = ''; curRec = null; }

async function confirmBtn(t, label, fn) {
  if (t.dataset.sure !== '1') { t.dataset.sure = '1'; t.dataset.orig = t.innerHTML; t.textContent = $t('m.sure'); return; }
  t.disabled = true; t.textContent = label;
  const r = await fn();
  if (!r || !r.ok) { t.disabled = false; t.dataset.sure = ''; t.innerHTML = t.dataset.orig; toast((r && r.err) || $t('m.failed')); }
  return r;
}

function reasonModal(title, act, attrs) {
  const a = Object.entries(attrs).map(([k, v]) => `data-${k}="${esc(v)}"`).join(' ');
  openModal(`<h3>${esc(title)}</h3><input id="mReason" maxlength="255" placeholder="${$t('m.reason_ph')}">
    <div class="row end"><button class="btn ghost" data-act="x">${$t('m.cancel')}</button><button class="btn green" data-act="${act}" ${a}>${$t('m.save')}</button></div>`);
  $('#mReason').focus();
}

M.addEventListener('click', async e => {
  if (e.target === M) return closeModal();
  const t = e.target.closest('[data-act],[data-status],[data-rec],[data-new],[data-pbolo],[data-lic],[data-vplate]'); if (!t) return;
  if (t.dataset.status) { await setStatus(t.dataset.status); return closeModal(); }
  if (t.dataset.rec) return openRecord(Number(t.dataset.rec));
  if (t.dataset.vplate) { closeModal(); return quickQuery(t.dataset.vplate); }
  if (t.dataset.new && PROF) { const pf = profilePrefill(PROF); closeModal(); go('records'); return openForm(t.dataset.new, pf); }
  if (t.dataset.pbolo === 'on' && PROF) return reasonModal($t('m.person_bolo_title', PROF.firstname, PROF.lastname), 'bolo-save', { kind: 'person', cid: PROF.citizenid });
  if (t.dataset.pbolo === 'off' && PROF) { await post('setBolo', { kind: 'person', citizenid: PROF.citizenid, active: false }); toast($t('m.toast_person_bolo_removed')); return loadProfile(PROF.citizenid); }
  if (t.dataset.lic && PROF) {
    const l = PROF.licenses.find(x => x.key === t.dataset.lic);
    return reasonModal($t(t.dataset.v === '1' ? 'm.lic_grant' : 'm.lic_suspend', l ? l.label : ''), 'lic-save', { cid: PROF.citizenid, lic: t.dataset.lic, v: t.dataset.v });
  }
  switch (t.dataset.act) {
    case 'x': return closeModal();
    case 'cs-save': {
      const r = await post('setCallsign', { callsign: $('#mCs').value });
      if (r.ok) { closeModal(); toast(r.team > 1 ? $t('m.joined_team', r.team) : $t('m.callsign_saved'), 4500); }
      else toast(r.err || $t('m.callsign_fail'));
      return;
    }
    case 'bolo-save': {
      const reason = $('#mReason').value;
      if (t.dataset.kind === 'person') await post('setBolo', { kind: 'person', citizenid: t.dataset.cid, active: true, reason });
      else await post('setBolo', { plate: boloPlate, active: true, reason });
      closeModal(); toast($t('m.toast_bolo_added'));
      if (t.dataset.kind === 'person') return loadProfile(t.dataset.cid);
      if (curPage === 'lookup' && boloPlate) return queryPlate(boloPlate, true);
      return;
    }
    case 'lic-save': {
      const r = await post('setLicense', { citizenid: t.dataset.cid, license: t.dataset.lic, value: t.dataset.v === '1', reason: $('#mReason').value });
      toast(r.ok ? $t('m.toast_lic_updated') : (r.err || $t('m.failed')));
      return loadProfile(t.dataset.cid);
    }
    case 'tpl': return applyTemplate(S.templates[Number(t.dataset.i)]);
    case 'veh-near': return fillNearVehicle();
    case 'call-create': return submitCreate();
    case 'w-serve': case 'w-void': {
      const rec = curRec;
      const r = await confirmBtn(t, $t('m.processing'), () => post('setWarrant', { id: rec.id, status: t.dataset.act === 'w-serve' ? 'SERVED' : 'VOID' }));
      if (r && r.ok) { toast($t('m.toast_warrant_updated')); closeModal(); afterRecordChange(rec); }
      return;
    }
    case 'r-del': {
      const rec = curRec;
      const r = await confirmBtn(t, $t('m.deleting'), () => post('deleteRecord', { id: rec.id }));
      if (r && r.ok) { toast($t('m.toast_record_deleted')); closeModal(); afterRecordChange(rec); }
      return;
    }
    case 'r-prof': { const cid = t.dataset.cid; closeModal(); return loadProfile(cid); }
    case 'h-report': { const id = Number(t.dataset.id); closeModal(); go('records'); return openForm('crime', { call_id: id }); }
  }
});
M.addEventListener('keydown', e => {
  if (e.key === 'Enter' && e.target.id === 'mCs') M.querySelector('[data-act="cs-save"]').click();
  if (e.key === 'Enter' && e.target.id === 'mReason') { const b = M.querySelector('.btn.green[data-act]'); if (b) b.click(); }
});

/* ---------- Status / callsign ---------- */
$('#btnStatus').onclick = () => {
  const m = me() || {};
  openModal(`<h3>${$t('m.pick_status')}</h3>${arr(S.statuses).map(s => { const i = stI(s); return `<button class="opt${m.status === s ? ' on' : ''}" data-status="${esc(s)}" style="--sc:${i.color}"><span class="ss" style="color:${i.color};background:${tint(i.color, .16)}">${esc(i.label)}</span>${esc(s)}<small>${esc(i.key || '')}</small></button>`; }).join('')}
   <div class="row end"><button class="btn ghost" data-act="x">${$t('m.cancel')}</button></div>`);
};
function callsignModal(first) {
  const cur = (me() || {}).callsign;
  openModal(`<h3>${$t('cs.title')}</h3>${first ? `<div class="alarm orange">${$t('cs.first_warn')}</div>` : ''}
   <p class="muted">${$t('cs.help')}</p>
   <input id="mCs" maxlength="12" placeholder="${$t('cs.ph')}" value="${cur && cur !== 'NEW UNIT' ? esc(cur) : ''}">
   <div class="row end"><button class="btn ghost" data-act="x">${first ? $t('cs.later') : $t('m.cancel')}</button><button class="btn green" data-act="cs-save">${$t('m.save')}</button></div>`);
  $('#mCs').focus();
}
$('#btnUnit').onclick = () => callsignModal(false);
$('#btnMyCall').onclick = () => { const m = me(); if (m && m.callId) { go('dash'); return selectCall(m.callId); } toast($t('ui.no_active_incident')); };
$('#btnMsgs').onclick = () => go('messages');
$('#btnClose').onclick = () => closeCad();

/* ---------- Create incident ---------- */
const QUICK = {
  traffic: { get title() { return $t('c.traffic_stop'); }, priority: 1, attach: true, onscene: true, vehicle: true },
  ped: { get title() { return $t('c.ped_stop'); }, priority: 1, attach: true, onscene: true },
  sus: { get title() { return $t('c.suspicious'); }, priority: 2, attach: true, vehicle: true },
  custom: { attach: true },
};
function createHtml(q) {
  const counties = (S.counties && S.counties.length ? S.counties : ['LOS SANTOS', 'BLAINE']);
  return `
    <div class="chead"><b class="big">${q.title ? esc(q.title) : $t('c.create_title')}</b><button class="xbtn" data-act="x">×</button></div>
    <datalist id="natList">${S.templates.map(t => `<option value="${esc(t.title)}"></option>`).join('')}</datalist>
    <div class="fgrid">
      <div class="fg s4"><label>${$t('c.nature')}</label><input id="mNature" list="natList" maxlength="128" placeholder="${$t('c.traffic_stop')}" value="${esc(q.title || '')}"></div>
      <div class="fg s1"><label>${$t('c.status')}</label><select id="mStatus"><option>ACTIVE</option><option>PENDING</option></select></div>
      <div class="fg s1"><label>${$t('c.priority')}</label><select id="mPri">${[1, 2, 3].map(p => `<option value="${p}"${p === (q.priority || 2) ? ' selected' : ''}>Code ${p}</option>`).join('')}</select></div>
    </div>
    <div class="tpls">${S.templates.map((t, i) => `<button class="tpl P${t.priority || 2}" data-act="tpl" data-i="${i}">${esc(t.title)}</button>`).join('')}</div>
    <h4>${$t('c.location')}</h4>
    <div class="fgrid">
      <div class="fg s1"><label>Postal</label><input id="mPostal" maxlength="16"></div>
      <div class="fg s5"><label>${$t('c.address')}</label><input id="mAddr" maxlength="128"></div>
      <div class="fg s3"><label>${$t('c.area')}</label><input id="mArea" maxlength="64"></div>
      <div class="fg s3"><label>${$t('c.county')}</label><select id="mCounty">${counties.map(c => `<option>${esc(c)}</option>`).join('')}</select></div>
    </div>
    <h4>${$t('c.vehicle')} <button class="link" data-act="veh-near">${$t('c.nearby_vehicle')}</button></h4>
    <div class="fgrid">
      <div class="fg s2"><label>${$t('c.plate')}</label><input id="mPlate" maxlength="12" value="${esc(q.plate || '')}"></div>
      <div class="fg s1"><label>${$t('c.color')}</label><input id="mColor" maxlength="32"></div>
      <div class="fg s1"><label>${$t('c.make')}</label><input id="mMake" maxlength="32"></div>
      <div class="fg s2"><label>Model</label><input id="mModel" maxlength="32" value="${esc(q.model || '')}"></div>
      <div class="fg s6"><label>${$t('c.description')}</label><textarea id="mMsg" maxlength="1000" placeholder="${$t('c.desc_ph')}"></textarea></div>
    </div>
    <div class="row"><label class="chk"><input type="checkbox" id="mAttach"${q.attach ? ' checked' : ''}> ${$t('c.attach_me')}</label>
      <label class="chk"><input type="checkbox" id="mOnscene"${q.onscene ? ' checked' : ''}> ${$t('c.on_scene_me')}</label></div>
    <div class="row end"><button class="btn ghost" data-act="x">${$t('m.cancel')}</button><button class="btn blue" data-act="call-create">${$t('c.create')}</button></div>`;
}

function applyTemplate(t) {
  if (!t) return;
  $('#mNature').value = t.title; $('#mPri').value = String(t.priority || 2);
}

async function openCreate(kind, extra = {}) {
  const q = Object.assign({}, QUICK[kind] || QUICK.custom, extra);
  openModal(createHtml(q), 'createbox');
  $('#mNature').addEventListener('input', e => {
    const v = up(e.target.value), t = S.templates.find(x => up(x.title) === v);
    if (t) { $('#mPri').value = String(t.priority || 2); }
  });
  const loc = await post('locInfo', { vehicle: !!q.vehicle && !q.plate });
  if (!$('#mAddr')) return;
  $('#mPostal').value = loc.postal || ''; $('#mAddr').value = loc.address || ''; $('#mArea').value = loc.area || '';
  if (loc.county) $('#mCounty').value = loc.county;
  if (loc.vehicle && !q.plate) fillVeh(loc.vehicle);
  (q.title ? $('#mMsg') : $('#mNature')).focus();
}
function fillVeh(v) { $('#mPlate').value = v.plate || ''; $('#mColor').value = v.color || ''; $('#mMake').value = v.make || ''; $('#mModel').value = v.model || ''; }
async function fillNearVehicle() {
  const loc = await post('locInfo', { vehicle: true });
  if (!loc.vehicle) return toast($t('c.no_nearby_vehicle'));
  fillVeh(loc.vehicle);
}
async function submitCreate() {
  const title = up($('#mNature').value.trim());
  if (!title) return toast($t('c.nature_required'));
  const d = {
    title, status: $('#mStatus').value, priority: Number($('#mPri').value),
    postal: $('#mPostal').value.trim(), address: up($('#mAddr').value.trim()), area: up($('#mArea').value.trim()), county: $('#mCounty').value,
    plate: up($('#mPlate').value.trim()), color: $('#mColor').value.trim(), make: $('#mMake').value.trim(), model: $('#mModel').value.trim(),
    message: $('#mMsg').value.trim(), attach: $('#mAttach').checked, onscene: $('#mOnscene').checked,
  };
  const r = await post('createCall', d);
  if (r.ok) { closeModal(); toast($t('c.created', r.id)); selId = r.id; go('dash'); renderDash(); }
  else toast(r.err || $t('c.create_fail'));
}

/* ================= WANTED ================= */
const NONE_HTML = () => `<p class="empty">${$t('w.no_data')}</p>`;
async function loadWanted() {
  const r = await post('wanted');
  const W = arr(r.warrants), Pb = arr(r.persons), Vb = arr(r.vehicles);
  $('#wCount').textContent = W.filter(w => !w.expired).length; $('#wpCount').textContent = Pb.length; $('#wvCount').textContent = Vb.length;
  $('#wWarrants').innerHTML = W.length ? W.map(w => `<div class="witem${w.expired ? ' exp' : ''}">
      <div class="wtop"><b>${esc(w.name)}</b>${w.expired ? `<span class="flag">${$t('w.expired')}</span>` : ''}${arr(w.flags).map(f => ` <span class="flag red">${esc(f)}</span>`).join('')}</div>
      <div class="wbody">${esc(w.title || '-')}</div>
      <div class="wfoot"><span>${esc(w.callsign)} ${esc(w.author)} · ${dt(w.created)}${w.expires ? ' · ' + $t('w.expires_colon') + ' ' + esc(w.expires) : ''}</span>
        <span><button class="mini" data-rec="${w.id}">${$t('p.view')}</button><button class="mini" data-prof="${esc(w.citizenid)}">${$t('w.profile')}</button></span></div>
    </div>`).join('') : NONE_HTML();
  $('#wPersons').innerHTML = Pb.length ? Pb.map(b => `<div class="witem">
      <div class="wtop"><b>${esc(b.name || b.citizenid)}</b></div><div class="wbody">${esc(b.reason || '-')}</div>
      <div class="wfoot"><span>${esc(b.author)} · ${dt(b.created)}</span>
        <span><button class="mini" data-prof="${esc(b.citizenid)}">${$t('w.profile')}</button><button class="mini danger" data-unp="${esc(b.citizenid)}">${$t('w.remove')}</button></span></div>
    </div>`).join('') : NONE_HTML();
  $('#wVehicles').innerHTML = Vb.length ? Vb.map(b => `<div class="witem">
      <div class="wtop"><b class="plate2">${esc(b.plate)}</b></div><div class="wbody">${esc(b.reason || '-')}</div>
      <div class="wfoot"><span>${esc(b.author)} · ${dt(b.created)}</span>
        <span><button class="mini" data-vq="${esc(b.plate)}">${$t('p.query')}</button><button class="mini danger" data-unv="${esc(b.plate)}">${$t('w.remove')}</button></span></div>
    </div>`).join('') : NONE_HTML();
}
$('#btnWantedRefresh').onclick = loadWanted;
$('#pg-wanted').addEventListener('click', async e => {
  const b = e.target.closest('button'); if (!b) return;
  if (b.dataset.rec) return openRecord(Number(b.dataset.rec));
  if (b.dataset.prof) return loadProfile(b.dataset.prof);
  if (b.dataset.vq) return quickQuery(b.dataset.vq);
  if (b.dataset.unp) { await post('setBolo', { kind: 'person', citizenid: b.dataset.unp, active: false }); toast($t('m.toast_person_bolo_removed')); return loadWanted(); }
  if (b.dataset.unv) { await post('setBolo', { plate: b.dataset.unv, active: false }); toast($t('w.toast_veh_bolo_removed')); return loadWanted(); }
});

/* ================= HISTORY ================= */
let htab = 'calls';
$$('[data-htab]').forEach(b => b.onclick = () => { htab = b.dataset.htab; $$('[data-htab]').forEach(x => x.classList.toggle('on', x === b)); loadHistory(); });
$('#hSearch').onclick = () => loadHistory();
$('#hQ').addEventListener('keydown', e => { if (e.key === 'Enter') loadHistory(); });

async function loadHistory() {
  const q = $('#hQ').value.trim().replace(/^#/, '');
  if (htab === 'calls') {
    $('#hHead').innerHTML = `<tr><th>#</th><th>${$t('p.th_date')}</th><th>${$t('h.th_nature')}</th><th>${$t('h.th_address')}</th><th>${$t('h.th_postal')}</th><th>${$t('h.th_pri')}</th><th>${$t('h.th_agency')}</th><th>${$t('h.th_caller')}</th></tr>`;
    const rows = arr(await post('callHistory', { q }));
    $('#hBody').innerHTML = rows.length ? rows.map(c => `<tr class="hrow" data-hcall="${c.id}"><td><span class="badge">${c.id}</span></td><td>${dt(c.created)}</td>
      <td>${esc(c.title)}</td><td>${esc(c.address)}</td><td class="m">${esc(c.postal)}</td><td>${pri(c.priority)}</td>
      <td>${esc(c.agency)}</td><td>${esc(c.caller)}</td></tr>`).join('') : `<tr><td colspan="9" class="empty">${$t('h.no_results')}</td></tr>`;
  } else {
    $('#hHead').innerHTML = `<tr><th>${$t('h.th_dr')}</th><th>${$t('p.th_date')}</th><th>${$t('p.th_type')}</th><th>${$t('h.th_title')}</th><th>${$t('ui.th_status')}</th><th>${$t('h.th_call')}</th><th>${$t('p.th_officer')}</th></tr>`;
    const rows = arr(await post('reports', { q }));
    $('#hBody').innerHTML = rows.length ? rows.map(r => `<tr class="hrow" data-hrec="${r.id}"><td><b>${fmtDR(r.id, r.created)}</b></td><td>${dt(r.created)}</td>
      <td>${esc(r.typeLabel)}</td><td>${esc(r.title)}</td><td>${statusPills(r)}</td><td>${r.call_id ? '#' + r.call_id : '-'}</td>
      <td>${esc(r.callsign)} ${esc(r.author)}</td></tr>`).join('') : `<tr><td colspan="7" class="empty">${$t('h.no_results')}</td></tr>`;
  }
}
$('#hBody').addEventListener('click', e => {
  const tr = e.target.closest('tr'); if (!tr) return;
  if (tr.dataset.hrec) return openRecord(Number(tr.dataset.hrec));
  if (tr.dataset.hcall) return openHistoryCall(Number(tr.dataset.hcall));
});
async function openHistoryCall(id) {
  const c = await post('historyCall', { id });
  if (!c.ok) return toast(c.err || $t('h.err_open'));
  const recs = arr(c.records), v = c.vehicle || {};
  openModal(`
    <div class="chead"><span class="badge">#${c.id}</span><b>${esc(c.title)}</b>${pri(c.priority)}<span class="pill ${esc(c.status)}">${esc(c.status)}</span>
      <button class="xbtn" data-act="x">×</button></div>
    <div class="rmeta">${dt(c.created)} · ${$t('h.caller_colon')} ${esc(c.caller || '-')} · ${esc([c.postal, c.address, c.area].filter(Boolean).join(' · '))}${v.plate ? ' · ' + $t('h.vehicle_colon') + ' ' + esc(v.plate) : ''}</div>
    <div class="nar" style="max-height:360px;border:1px solid var(--ln);border-radius:6px;background:var(--inbg)">${arr(c.log).map(l => `<p class="sy"><span></span><span>${esc(l)}</span></p>`).join('')}</div>
    <h4>${$t('h.linked_records', recs.length)}</h4>
    ${recs.length ? `<table class="mt"><tbody>${recs.map(r => `<tr class="click" data-rec="${r.id}"><td>#${r.id}</td><td>${esc(r.typeLabel)}</td><td>${esc(r.title)}</td><td>${esc(r.callsign)} ${esc(r.author)}</td><td>${dt(r.created)}</td></tr>`).join('')}</tbody></table>` : `<p class="muted">${$t('h.no_linked')}</p>`}
    <div class="row end">${canReport('crime') ? `<button class="btn" data-act="h-report" data-id="${c.id}">${$t('h.write_report')}</button>` : ''}<button class="btn ghost" data-act="x">${$t('h.close')}</button></div>`, 'createbox');
}

/* ================= MESSAGES ================= */
let MSGS = [], chan = 'ALL', unread = {};
const chanKey = m => m.to === 'ALL' ? 'ALL' : (m.from === myId ? m.to : m.from);
function updateBadge() {
  const n = Object.values(unread).reduce((a, b) => a + b, 0);
  [$('#msgBadge'), $('#tbMsg')].forEach(b => { b.textContent = n; b.classList.toggle('hidden', n === 0); });
}
function markRead(k) { delete unread[k]; updateBadge(); }
function addMsg(m, mine) {
  if (MSGS.some(x => x.id === m.id)) return;
  MSGS.push(m); if (MSGS.length > 300) MSGS.shift();
  const k = chanKey(m);
  if (!mine && !(appOpen() && curPage === 'messages' && chan === k)) { unread[k] = (unread[k] || 0) + 1; updateBadge(); }
  if (curPage === 'messages') renderMessages();
  if (appOpen()) renderRight();
}
function renderChans() {
  const units = S.units.filter(u => u.src !== myId);
  const items = [{ k: 'ALL', t: $t('ms.general'), s: $t('ms.all_units') }, ...units.map(u => ({ k: u.src, t: u.callsign, s: u.name }))];
  if (chan !== 'ALL' && !items.some(i => i.k === chan)) items.push({ k: chan, t: $t('ms.unit_n', chan), s: $t('ms.maybe_offline') });
  $('#chans').innerHTML = items.map(i => `<button class="chan${i.k === chan ? ' on' : ''}" data-chan="${i.k}">
    <b>${esc(i.t)}</b><small>${esc(i.s)}</small>${unread[i.k] ? `<span class="ub">${unread[i.k]}</span>` : ''}</button>`).join('');
}
function renderMessages() {
  renderChans();
  const u = S.units.find(x => x.src === chan);
  $('#thTitle').textContent = chan === 'ALL' ? $t('ms.general_channel') : `${u ? u.callsign + ' · ' + u.name : $t('ms.unit_n', chan)}`;
  const list = MSGS.filter(m => chanKey(m) === chan);
  const box = $('#tMsgs');
  box.innerHTML = list.length ? list.map(m => `<div class="bub${m.from === myId ? ' mine' : ''}">
    <div class="bh"><b>${esc(m.fromName)}</b><small>${esc(m.time)}</small></div><div>${esc(m.text)}</div></div>`).join('') : `<p class="empty">${$t('ms.none_yet')}</p>`;
  box.scrollTop = box.scrollHeight;
  if (appOpen() && curPage === 'messages') markRead(chan);
}
$('#chans').addEventListener('click', e => {
  const b = e.target.closest('[data-chan]'); if (!b) return;
  chan = b.dataset.chan === 'ALL' ? 'ALL' : Number(b.dataset.chan);
  renderMessages(); $('#mText').focus();
});
async function sendMsg() {
  const i = $('#mText'), text = i.value.trim(); if (!text) return;
  const r = await post('sendMessage', { to: chan, text });
  if (r.ok) i.value = ''; else toast(r.err || $t('ui.toast_msg_fail'));
}
$('#mSend').onclick = sendMsg;
$('#mText').addEventListener('keydown', e => { if (e.key === 'Enter') sendMsg(); });

/* ================= UNITS / SHIFT ================= */
let ubF = 'all';
function renderUnitsBoard() {
  if (curPage !== 'units') return;
  const q = up($('#ubSearch').value.trim());
  const all = S.units;
  const agencies = [...new Set(all.map(u => u.agency || '—'))];
  $('#ubFilters').innerHTML = ['all', ...agencies].map(a => `<button class="chip${ubF === a ? ' on' : ''}" data-ubf="${esc(a)}">${a === 'all' ? $t('u.all') : esc(a)} <em>${a === 'all' ? all.length : all.filter(u => (u.agency || '—') === a).length}</em></button>`).join('');
  const list = all.filter(u => (ubF === 'all' || (u.agency || '—') === ubF) && (!q || up(u.callsign).includes(q) || up(u.name).includes(q)));
  const warn = (META.statusCheck || 0) * 60;
  const late = warn ? list.filter(u => u.status === 'ON SCENE' && nowS() - u.since >= warn) : [];
  $('#ubWarn').innerHTML = late.map(u => `<div class="wb"><span><b>${esc(u.callsign)}</b> ${$t('u.late_text', Math.floor((nowS() - u.since) / 60))}${u.callId ? ' · #' + u.callId : ''} — ${$t('u.check_suggested')}</span>
    ${hasPage('messages') && u.src !== myId ? `<button class="b sm" data-chk="${u.src}">${$t('u.ask_status')}</button>` : ''}</div>`).join('');
  $('#ubCount').textContent = `${$t('ui.n_on_duty', all.filter(u => u.status !== META.offDuty).length)} · ${agencies.map(a => `${a} ${all.filter(u => (u.agency || '—') === a).length}`).join(' · ')}`;
  const groups = {};
  list.forEach(u => { (groups[u.agency || '—'] = groups[u.agency || '—'] || []).push(u); });
  const myP = unitPos(myId);
  $('#ubBody').innerHTML = Object.entries(groups).map(([a, us]) => `<tr class="gr"><td colspan="8">${esc(a)}</td></tr>` + us.sort((x, y) => x.callsign.localeCompare(y.callsign)).map(u => {
    const c = u.callId && S.calls.find(x => x.id === u.callId);
    const p = unitPos(u.src), d = u.src === myId ? null : dist(myP, p);
    const isLate = warn && u.status === 'ON SCENE' && nowS() - u.since >= warn;
    return `<tr class="${u.src === myId ? 'me' : ''}${isLate ? ' warn' : ''}"><td><span class="cs">${esc(u.callsign)}</span></td><td>${esc(u.name)}<small>${esc(u.rank || '')}</small></td>
      <td>${ssHtml(u.status)}</td><td class="tm" data-since="${u.since}" ${u.status === 'ON SCENE' && warn ? `data-warn="${warn}"` : ''}>${dur(nowS() - u.since)}</td>
      <td class="m">${c ? `#${c.id} · ${esc(c.title)}` : '<span style="color:var(--mu)">—</span>'}</td><td>${p ? esc(postalAt(p)) : `<span style="color:var(--mu)">${$t('u.no_vehicle')}</span>`}</td>
      <td class="m">${u.src === myId ? $t('u.you') : km(d)}</td>
      <td><div class="ra">${hasPage('messages') && u.src !== myId ? `<button data-dm="${u.src}" title="${$t('u.msg_title')}">${$t('u.msg_short')}</button>` : ''}${p && hasPage('map') ? `<button data-loc="${u.src}" title="${$t('u.show_map')}">${$t('u.map_short')}</button>` : ''}</div></td></tr>`;
  }).join('')).join('') || `<tr><td colspan="8" class="empty">${$t('u.none')}</td></tr>`;
}
function postalAt(p) { const n = MAP.nearest(p.x, p.y); return n ? $t('u.postal_n', n.code) : `${Math.round(p.x)}, ${Math.round(p.y)}`; }
$('#ubSearch').addEventListener('input', renderUnitsBoard);
$('#pg-units').addEventListener('click', async e => {
  const f = e.target.closest('[data-ubf]'); if (f) { ubF = f.dataset.ubf; return renderUnitsBoard(); }
  const dm = e.target.closest('[data-dm]'); if (dm) { chan = Number(dm.dataset.dm); return go('messages'); }
  const chk = e.target.closest('[data-chk]');
  if (chk) { const r = await post('sendMessage', { to: Number(chk.dataset.chk), text: $t('u.status_check_text') }); return toast(r.ok ? $t('u.toast_status_sent') : (r.err || $t('u.toast_send_fail'))); }
  const loc = e.target.closest('[data-loc]');
  if (loc) { const p = unitPos(Number(loc.dataset.loc)); go('map'); if (p) mapView.center(p.x, p.y, 70); }
});

async function loadShift() {
  const r = await post('shift');
  if (!r.ok) return;
  const T = r.totals || {}, total = Object.values(T).reduce((a, b) => a + b, 0) || 1;
  const rep = r.reports || {}, nrep = (rep.arrest || 0) + (rep.crime || 0) + (rep.followup || 0) + (rep.warrant || 0);
  const order = Object.keys(T).sort((a, b) => T[b] - T[a]);
  const actColor = k => k === 'hit' ? '#e5484d' : k === 'query' ? '#4f8cff' : k === 'report' ? '#94a3b8' : k === 'call' ? '#e09a2b' : k === 'info' ? '#64748b' : stI(k).color;
  $('#shiftPn').innerHTML = `<div class="ph">${$t('sh.my_shift')} <span class="r">${esc(r.agency || '')}</span></div>
    <div class="myc"><div class="bd">${esc(r.callsign)}</div><div><h3>${esc(r.rank || '')} ${esc(r.name)}</h3><small>${r.partners.length ? $t('sh.partner_colon') + ' ' + r.partners.map(esc).join(', ') : $t('sh.single_unit')}</small><small>${$t('sh.started', hm(r.start))}</small></div>
      <div class="tt2"><b data-since="${r.start}">${dur(r.now - r.start)}</b><small>${$t('sh.on_duty')}</small></div></div>
    <div class="stat"><div><b>${r.calls}</b><small>${$t('sh.incidents')}</small></div><div><b>${nrep}</b><small>${$t('sh.reports')}</small>${r.pending ? `<em>${$t('sh.pending_approval', r.pending)}</em>` : ''}</div><div><b>${rep.citation || 0}</b><small>CITATION</small></div>
      <div><b>${rep.arrest || 0}</b><small>ARREST</small></div><div><b>${r.queries}</b><small>${$t('sh.queries')}</small>${r.hits ? `<em>${r.hits} hit</em>` : ''}</div><div><b>${rep.warrant || 0}</b><small>${$t('sh.warrants')}</small></div></div>
    <div class="sb"><span class="lbl">${$t('sh.time_split')}</span>
      <div class="bar">${order.map(k => `<i style="flex:${T[k]};background:${stI(k).color}"></i>`).join('')}</div>
      <div class="lg">${order.map(k => `<span><i style="background:${stI(k).color}"></i>${esc(stI(k).label)} ${$t('sh.pct', Math.round(T[k] / total * 100))}</span>`).join('')}</div></div>
    <div class="ph">${$t('sh.activity')}</div>
    <div class="al2">${arr(r.acts).slice().reverse().map(a => `<p><span>${hm(a.t).slice(0, 5)}</span><i style="background:${actColor(a.k)}"></i><span>${esc(a.text)}</span></p>`).join('') || `<div class="hint">${$t('sh.no_activity')}</div>`}</div>`;
}
setInterval(() => { if (appOpen() && curPage === 'units') loadShift(); }, 30000);

/* ================= General rendering ================= */
function renderAll() {
  renderHeader(); renderTicker(); renderDash();
  if (curPage === 'messages') renderChans();
  if (curPage === 'units') renderUnitsBoard();
  if (curPage === 'map') { renderMapFilters(); renderMapSide(); refreshMap(); }
}

function closeCad() {
  $('#app').classList.add('hidden');
  document.body.classList.remove('cad-open');
  closeModal();
  post('close');
}

/* ---------- Messages from the game ---------- */
window.addEventListener('message', async e => {
  const d = e.data || {};
  switch (d.action) {
    case 'open': {
      myId = d.id; S = d.state; if (d.meta) META = d.meta;
      clockOff = (S.serverTime || Date.now() / 1000) - Date.now() / 1000;
      MAP.load(META.postalUrl || '../data/postals.json').then(() => { if (miniView && detailFor) { miniView.based = null; updateDetail(); } refreshMap(); });
      applyDept();
      $('#app').classList.remove('hidden'); document.body.classList.add('cad-open');
      go(curPage && hasPage(curPage) ? curPage : 'dash');
      renderAll(); refreshReportCounts();
      const list = await post('messages');
      arr(list).forEach(m => { if (!MSGS.some(x => x.id === m.id)) MSGS.push(m); });
      MSGS.sort((a, b) => a.id - b.id);
      renderRight();
      const m0 = me();
      if (m0 && m0.callsign === 'NEW UNIT' && M.classList.contains('hidden')) callsignModal(true);
      return;
    }
    case 'update':
      S = d.state; if (S.serverTime) clockOff = S.serverTime - Date.now() / 1000;
      if (appOpen()) renderAll();
      return;
    case 'close': $('#app').classList.add('hidden'); document.body.classList.remove('cad-open'); closeModal(); return;
    case 'alert': return showAlert(d.call, d);
    case 'alertMerge': return mergeAlert(d.data, d);
    case 'alertClosed': return dropCard('c' + d.id);
    case 'alertAccepted': return acceptedCard(d.id);
    case 'direct': return showDirect(d.data, d);
    case 'pos': myPos = { x: d.x, y: d.y, h: d.h }; return;
    case 'tracking':
      TRACK = arr(d.list);
      if (appOpen()) {
        if (curPage === 'map') refreshMap();
        if (curPage === 'units') renderUnitsBoard();
        if (curPage === 'dash' && detailFor) { const c = S.calls.find(x => x.id === detailFor); if (c && miniView) miniView.update(mapData(c.id, true)); }
      }
      return;
    case 'message':
      addMsg(d.msg, d.mine);
      if (!d.mine && !(appOpen() && curPage === 'messages')) showMsgCard(d.msg, d);
  }
});

/* ---------- Keyboard ---------- */
window.addEventListener('keydown', e => {
  if (!appOpen()) return;
  if (/^F([1-9]|1[0-2])$/.test(e.key)) {
    e.preventDefault();
    if (!M.classList.contains('hidden') && e.key !== 'F10') return;
    const st = Object.entries(META.statusInfo || {}).find(([, i]) => i.key === e.key);
    if (st) return setStatus(st[0]);
    if (e.key === 'F12') return panicDown();
    return fkey(e.key);
  }
  if (e.key === 'Escape') { if (!M.classList.contains('hidden')) return closeModal(); return closeCad(); }
  if (!typing() && M.classList.contains('hidden') && /^[1-8]$/.test(e.key)) {
    const t = $$('.tab[data-go]').filter(b => !b.classList.contains('hidden'))[Number(e.key) - 1];
    if (t) go(t.dataset.go);
  }
});
window.addEventListener('keyup', e => { if (e.key === 'F12') panicUp(); });

setTheme(store.get('knb_cad:day', '0') === '1');

// Called once the locale has been delivered by the game script: re-render everything that was drawn with raw keys.
function afterLocale() {
  $('#qInputs').innerHTML = QIN[qType]();
  renderHist();
  if (typeof buildSchemas === 'function') buildSchemas();
  setTheme(store.get('knb_cad:day', '0') === '1');
  if (appOpen()) { renderAll(); if (curPage === 'messages') renderMessages(); if (curPage === 'units') loadShift(); }
}
loadLocale();
