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

/* =====================================================================
   Reports: modelled on the LAPD forms (Arrest / Crime / Follow-up /
   Citation / Arrest Warrant). Each form is defined once as a schema and
   rendered both as an entry form and as a read-only view.
   The schema is rebuilt once the locale has loaded (see buildSchemas).
   ===================================================================== */

/* ---------- Schema helpers ---------- */
let RT, CASE_LABEL, REVIEW_LABEL;
const chTh = () => ['code', 'charge', 'class', 'qty', 'fine', 'jail', 'points'].map(k => `<th>${$t('r.th_' + k)}</th>`).join('');
function buildSchemas() {
var auto = true; // { auto } shorthand: the field is filled in automatically by the CAD
const F = (k, l, o = {}) => ({ k, l, t: 'text', w: 1, ...o });
const SEX = [$t('r.male'), $t('r.female')];
const PERSON_ROLES = [$t('r.victim'), $t('r.witness'), $t('r.complainant'), $t('r.finder'), $t('r.officer'), $t('r.other')];

const P_ROWS = auto => [
  [F('last', $t('r.last_name'), { w: 1.3, auto }), F('first', $t('r.first_name'), { w: 1.3, auto }), F('dob', $t('r.date_of_birth'), { auto }), F('sex', $t('r.sex'), { t: 'select', opts: SEX, w: .8, auto })],
  [F('hair', $t('r.hair'), { w: .8 }), F('eyes', $t('r.eyes'), { w: .8 }), F('height', $t('r.height_cm'), { w: .7 }), F('weight', $t('r.weight_kg'), { w: .7 }),
   F('aka', $t('r.alias_aka')), F('citizenid', $t('r.citizen_id'), { auto, ro: true, w: 1.1 })],
  [F('clothing', $t('r.clothing'), { w: 2 }), F('marks', $t('r.distinguishing_marks_tattoos_scars'), { w: 2 }), F('phone', $t('r.phone'), { auto })],
];
const PERSONS = { side: 'INVOLVED PERSONS', kind: 'table', k: 'persons', add: $t('r.add_person'),
  cols: [F('role', $t('r.role'), { t: 'select', opts: PERSON_ROLES, w: .8 }), F('name', $t('r.full_name'), { w: 1.6 }), F('phone', $t('r.phone'), { w: .8 }), F('note', $t('r.note_statement_summary'), { w: 3 })] };
const EVIDENCE = { side: 'EVIDENCE', kind: 'table', k: 'evidence', add: $t('r.add_evidence'),
  cols: [F('qty', $t('r.qty'), { w: .5 }), F('item', $t('r.item'), { w: 1.5 }), F('serial', $t('r.serial_no_description'), { w: 1.5 }), F('loc', $t('r.found_at'), { w: 1.5 })] };
const VEHICLE = extra => ({ side: 'SUSPECT VEHICLE', rows: [[
  F('plate', $t('r.plate'), { plate: true }), F('make_model', $t('r.make_model'), { auto: 'plate' }), F('color', $t('r.color')),
  F('owner', $t('r.registered_owner'), { auto: 'plate' }), ...extra]] });
const WHEN_WHERE = [F('date', $t('r.date'), { t: 'date', auto }), F('time', $t('r.time'), { t: 'time', w: .7, auto }),
  F('location', $t('r.location'), { w: 2.2, auto }), F('postal', 'Postal', { w: .7, auto }), F('area', $t('r.area'), { w: 1.2, auto })];

RT = {
  arrest: {
    title: 'ARREST REPORT', label: $t('r.arrest'), citizen: true, charges: true, call: true, booking: true,
    sections: [
      { side: 'ARRESTEE', rows: [...P_ROWS(true), [F('flags', $t('r.flags'), { t: 'checks', opts: [$t('r.armed'), $t('r.violent_tendencies'), $t('r.mental_illness')], w: 3 }), F('residence', $t('r.address'), { w: 2 })]] },
      { side: 'ARREST', rows: [WHEN_WHERE,
        [F('warrant_at', $t('r.warrant'), { t: 'radio', opts: [$t('r.active_warrant_existed'), $t('r.no_warrant')], w: 1.4, auto }),
         F('force', $t('r.use_of_force'), { t: 'checks', opts: [$t('r.physical'), 'Taser', $t('r.firearm_discharged'), $t('r.medical_aid')], w: 2 })]] },
      { side: 'CHARGES', kind: 'charges', rows: [[F('bail', $t('r.bail'), { t: 'number', w: .6 }), F('booked', $t('r.booked_at'), { t: 'select', opts: ['Mission Row PD', 'Sandy Shores SO', 'Paleto Bay SO', $t('r.bolingbroke_penitentiary'), $t('r.hospital')], w: 1.4 })]] },
      { side: 'RIGHTS ADVISEMENT', rows: [[
        F('miranda', $t('r.status'), { t: 'radio', opts: [$t('r.read_understood'), $t('r.refused_to_speak'), $t('r.requested_attorney'), $t('r.not_read')], w: 2.4 }),
        F('miranda_by', $t('r.reading_officer'), { w: 1.4, auto }), F('miranda_time', $t('r.time'), { t: 'time', w: .7, auto })]] },
      VEHICLE([F('veh_status', $t('r.vehicle_status'), { t: 'radio', opts: [$t('r.towed'), $t('r.seized'), $t('r.released'), $t('r.no_vehicle')], w: 1.8 })]),
      PERSONS, EVIDENCE,
      { kind: 'narrative', parts: [
        { k: 'n_source', l: 'SOURCE OF ACTIVITY', ph: $t('r.how_did_the_incident_start_report_patr') },
        { k: 'n_invest', l: 'INVESTIGATION', ph: $t('r.what_was_found_at_the_scene_who_was_sp') },
        { k: 'n_arrest', l: 'ARREST', ph: $t('r.how_did_the_arrest_take_place_search_o') },
        { k: 'n_statement', l: 'STATEMENTS', ph: $t('r.statements_of_the_suspect_and_witnesse') }] },
      { kind: 'approval' },
    ],
  },
  crime: {
    title: 'CRIME REPORT', label: $t('r.crime_report'), call: true,
    sections: [
      { side: 'REPORT OF', rows: [
        [F('crime_type', $t('r.crime_type'), { w: 2, list: 'penalList' }), F('premises', $t('r.premises_type'), { t: 'select', opts: [$t('r.street_road'), $t('r.residence'), $t('r.business_store'), $t('r.bank'), $t('r.parking_lot'), $t('r.vehicle'), $t('r.rural_area'), $t('r.other')], w: 1.2 }),
         F('flags', $t('r.flags'), { t: 'checks', opts: [$t('r.hate_crime'), $t('r.domestic_violence'), $t('r.gang_related'), $t('r.narcotics')], w: 2.8 })],
        WHEN_WHERE] },
      { side: 'VICTIM', rows: [
        [F('v_name', $t('r.full_name_or_business_name'), { w: 2 }), F('v_dob', $t('r.date_of_birth')), F('v_sex', $t('r.sex'), { t: 'select', opts: ['', ...SEX], w: .8 }), F('v_phone', $t('r.phone'))],
        [F('v_address', $t('r.address'), { w: 2 }), F('v_occupation', $t('r.occupation')), F('v_injury', $t('r.injury'), { t: 'radio', opts: [$t('r.none'), $t('r.minor'), $t('r.severe'), $t('r.deceased')], w: 1.6 })]] },
      { side: 'METHOD', rows: [
        [F('entry', $t('r.point_of_entry'), { t: 'checks', opts: [$t('r.front'), $t('r.rear'), $t('r.side'), $t('r.roof'), $t('r.window'), $t('r.no_forced_entry')], w: 2.6 }), F('method', $t('r.method_lock_picking_glass_breaking'), { w: 1.6 })],
        [F('weapon', $t('r.tool_weapon_used'), { w: 1.4 }), F('mo', $t('r.modus_operandi_mo_what_the_suspect_did'), { w: 3 })]] },
      { side: 'PROPERTY', kind: 'table', k: 'property', add: $t('r.add_item'),
        cols: [F('item', $t('r.item'), { w: 1.6 }), F('serial', $t('r.serial_no_description'), { w: 1.4 }), F('status', $t('r.status'), { t: 'select', opts: [$t('r.stolen'), $t('r.damaged'), $t('r.lost'), $t('r.recovered')], w: .9 }), F('value', $t('r.value'), { w: .7 })] },
      { side: 'SUSPECTS', kind: 'group', k: 'suspects', prefix: 'S', max: 3, rows: [
        [F('name', $t('r.name_if_known'), { w: 2 }), F('sex', $t('r.sex'), { t: 'select', opts: ['', ...SEX], w: .8 }), F('age', $t('r.age'), { w: .5 }), F('hair', $t('r.hair'), { w: .7 }), F('height', $t('r.height'), { w: .6 }), F('weight', $t('r.weight'), { w: .6 })],
        [F('clothing', $t('r.clothing'), { w: 2 }), F('marks', $t('r.distinguishing_marks'), { w: 1.6 }), F('weapon', $t('r.weapon_threat'), { w: 1.4 })]] },
      VEHICLE([F('direction', $t('r.escape_direction'), { w: 1.4 })]),
      PERSONS, EVIDENCE,
      { kind: 'narrative', parts: [
        { k: 'n_notify', l: 'NOTIFICATION', ph: $t('r.how_was_the_report_received_who_was_no') },
        { k: 'n_invest', l: 'INVESTIGATION', ph: $t('r.actions_at_the_scene_people_interviewe') },
        { k: 'n_evidence', l: 'EVIDENCE', ph: $t('r.evidence_collected_and_where_it_is_hel') },
        { k: 'n_summary', l: 'CRIME SUMMARY', ph: $t('r.brief_summary_of_the_incident') }] },
      { kind: 'approval' },
    ],
  },
  followup: {
    title: 'FOLLOW-UP INVESTIGATION', label: $t('r.follow_up_investigation'),
    sections: [
      { side: 'ORIGINAL REPORT', rows: [[
        F('parent_id', $t('r.original_report_no_dr'), { t: 'number', w: 1, parent: true }), F('orig_type', $t('r.report_type'), { ro: true, auto: 'parent' }),
        F('orig_title', $t('r.crime_title'), { ro: true, auto: 'parent', w: 2 }), F('orig_date', $t('r.report_date'), { ro: true, auto: 'parent' })],
        [F('orig_victim', $t('r.victim'), { ro: true, auto: 'parent', w: 1.5 }), F('orig_person', $t('r.related_person'), { ro: true, auto: 'parent', w: 1.5 }), F('date', $t('r.this_report_date'), { t: 'date', auto })]] },
      { side: 'CASE STATUS', rows: [[F('case_status', $t('r.case_status'), { t: 'radio', w: 4,
        opts: ['CLEARED_ARREST', 'CLEARED_OTHER', 'UNFOUNDED', 'CONTINUED'],
        optLabels: { CLEARED_ARREST: $t('r.1_cleared_by_arrest'), CLEARED_OTHER: $t('r.2_cleared_by_other_means'), UNFOUNDED: $t('r.3_unfounded'), CONTINUED: $t('r.4_investigation_continuing') } })]] },
      { side: 'CORRECTIONS', rows: [
        [F('reclass', $t('r.crime_type_reclassification')), F('date_change', $t('r.incident_date_correction'))],
        [F('add_loss', $t('r.additional_loss'), { t: 'number' }), F('partial', $t('r.partial_recovery'), { t: 'number' }), F('total', $t('r.full_recovery'), { t: 'number' })]] },
      { side: 'SUSPECTS', kind: 'group', k: 'suspects', prefix: 'S', max: 3, rows: [
        [F('name', $t('r.full_name'), { w: 2 }), F('sex', $t('r.sex'), { t: 'select', opts: ['', ...SEX], w: .8 }), F('dob', $t('r.date_of_birth')),
         F('action', $t('r.action_taken'), { t: 'select', opts: ['', $t('r.arrested'), $t('r.wanted'), $t('r.questioned_released'), $t('r.not_a_suspect')], w: 1.3 })]] },
      EVIDENCE,
      { kind: 'narrative', parts: [
        { k: 'n_invest', l: 'INVESTIGATION', ph: $t('r.actions_during_follow_up_interviews_ca') },
        { k: 'n_forensic', l: 'FORENSIC / AUTOPSY INFORMATION', ph: $t('r.forensic_autopsy_findings_if_any') },
        { k: 'n_filing', l: 'FILING INFORMATION', ph: $t('r.referral_to_the_prosecutor_case_filing') },
        { k: 'n_status', l: 'CASE STATUS', ph: $t('r.note_on_the_latest_status_of_the_file') }] },
      { kind: 'approval' },
    ],
  },
  citation: {
    title: 'CITATION', label: $t('r.citation'), citizen: true, charges: true, call: true,
    sections: [
      { side: 'VIOLATOR', rows: [[F('last', $t('r.last_name'), { w: 1.3, auto }), F('first', $t('r.first_name'), { w: 1.3, auto }), F('dob', $t('r.date_of_birth'), { auto }),
        F('sex', $t('r.sex'), { t: 'select', opts: SEX, w: .8, auto }), F('citizenid', $t('r.citizen_id'), { auto, ro: true, w: 1.1 })]] },
      { side: 'VIOLATION', rows: [WHEN_WHERE, [F('plate', $t('r.plate'), { plate: true }), F('make_model', $t('r.make_model'), { auto: 'plate' }), F('color', $t('r.color')), F('owner', $t('r.registered_owner'), { auto: 'plate' })]] },
      { side: 'CHARGES', kind: 'charges' },
      { kind: 'narrative', parts: [{ k: 'n_notes', l: 'OFFICER NOTES', ph: $t('r.additional_notes_optional') }] },
      { kind: 'approval' },
    ],
  },
  warrant: {
    title: 'ARREST WARRANT', label: $t('r.arrest_warrant'), citizen: true, charges: true, chargesOptional: true,
    sections: [
      { side: 'SUBJECT', rows: [...P_ROWS(true), [F('residence', $t('r.known_address'), { w: 2 }), F('associates', $t('r.known_associates_gang'), { w: 2 })]] },
      { side: 'WARRANT', rows: [[F('expires', $t('r.valid_until'), { t: 'date' }), F('flags', $t('r.warnings'), { t: 'checks', opts: [$t('r.armed'), $t('r.dangerous'), $t('r.flight_risk')], w: 2.5 })]] },
      { side: 'CHARGES', kind: 'charges' },
      { kind: 'narrative', parts: [{ k: 'reason', l: 'PROBABLE CAUSE', ph: $t('r.reason_for_the_warrant_evidence_witnes') }] },
      { kind: 'approval' },
    ],
  },
};

CASE_LABEL = { CLEARED_ARREST: $t('r.cleared_by_arrest'), CLEARED_OTHER: $t('r.closed'), UNFOUNDED: $t('r.unfounded'), CONTINUED: $t('r.continuing'), OPEN: $t('r.open') };
REVIEW_LABEL = { PENDING: $t('r.pending_approval'), APPROVED: $t('r.approved'), RETURNED: $t('r.correction_requested') };
}
buildSchemas();

function fmtDR(id, created) {
  const y = created ? new Date(Number(created)).getFullYear() : new Date().getFullYear();
  return `${String(y).slice(2)}-${String(id).padStart(6, '0')}`;
}
function statusPills(r) {
  let s = '';
  if (r.status && CASE_LABEL[r.status]) s += `<span class="pill ST_${esc(r.status)}">${CASE_LABEL[r.status]}</span> `;
  else if (r.status) s += `<span class="pill ${esc(r.status)}">${esc(r.status)}</span> `;
  if (r.review) s += `<span class="pill RV_${esc(r.review)}">${REVIEW_LABEL[r.review] || esc(r.review)}</span>`;
  return s;
}

/* ---------- Builder (edit + view) ---------- */
let curSchema = null, editRec = null;

function cellInput(f, v, name) {
  const val = v ?? '';
  const ro = f.ro ? ' readonly' : '';
  const attr = name ? `data-c="${f.k}"` : `data-k="${f.k}"`;
  if (f.t === 'select') return `<select ${attr}>${f.opts.map(o => `<option${o === val ? ' selected' : ''}>${esc(o)}</option>`).join('')}</select>`;
  if (f.t === 'radio' || f.t === 'checks') {
    const sel = f.t === 'checks' ? arr(v) : [val];
    const nm = 'r_' + f.k + '_' + Math.random().toString(36).slice(2, 7);
    return `<div class="chk" ${attr} data-type="${f.t}">${f.opts.map(o => `<label><input type="${f.t === 'radio' ? 'radio' : 'checkbox'}" name="${nm}" value="${esc(o)}"${sel.includes(o) ? ' checked' : ''}>${esc((f.optLabels || {})[o] || o)}</label>`).join('')}</div>`;
  }
  if (f.t === 'area') return `<textarea ${attr}>${esc(val)}</textarea>`;
  const type = f.t === 'number' ? 'number' : f.t === 'date' ? 'date' : f.t === 'time' ? 'time' : 'text';
  return `<input ${attr} type="${type}" value="${esc(val)}"${ro}${f.list ? ` list="${f.list}"` : ''}${f.plate ? ' data-plate="1"' : ''}${f.parent ? ' data-parent="1"' : ''} autocomplete="off">`;
}

function cellView(f, v) {
  if (f.t === 'radio' || f.t === 'checks') {
    const sel = f.t === 'checks' ? arr(v) : [v];
    return `<div class="chk">${f.opts.map(o => `<span><i class="${sel.includes(o) ? 'x' : ''}"></i>${esc((f.optLabels || {})[o] || o)}</span>`).join('')}</div>`;
  }
  return `<span>${esc(v ?? '') || '&nbsp;'}</span>`;
}

function cell(f, d, mode) {
  const autoTag = f.auto && mode === 'edit' ? ' auto' : '';
  return `<div class="c${autoTag}" style="flex:${f.w}"><label>${esc(f.l)}</label>${mode === 'edit' ? cellInput(f, d[f.k]) : cellView(f, d[f.k])}</div>`;
}

function rowsHtml(rows, d, mode) {
  return rows.map(r => `<div class="g">${r.map(f => cell(f, d, mode)).join('')}</div>`).join('');
}

function tableRow(sec, row, mode) {
  return `<tr data-row>${sec.cols.map(c => `<td>${mode === 'edit' ? cellInput(c, row[c.k], true) : esc(row[c.k] ?? '')}</td>`).join('')}
    ${mode === 'edit' ? `<td class="x"><button class="rm" data-rmrow title="${$t('r.delete_row')}">×</button></td>` : ''}</tr>`;
}
function tableHtml(sec, d, mode) {
  let rows = arr(d[sec.k]);
  if (mode === 'edit' && !rows.length) rows = [{}];
  if (mode === 'view' && !rows.length) return '<div class="none">—</div>';
  const total = sec.cols.reduce((a, c) => a + c.w, 0);
  return `<table class="rt" data-tk="${sec.k}"><thead><tr>${sec.cols.map(c => `<th style="width:${(c.w / total * 100).toFixed(1)}%">${esc(c.l)}</th>`).join('')}${mode === 'edit' ? '<th class="x"></th>' : ''}</tr></thead>
    <tbody>${rows.map(r => tableRow(sec, r, mode)).join('')}</tbody></table>
    ${mode === 'edit' ? `<button class="add" data-addrow="${sec.k}">${esc(sec.add)}</button>` : ''}`;
}

function groupItem(sec, item, i, mode) {
  return `<div class="gi" data-gi><div class="gh">${sec.prefix}-${i + 1}${mode === 'edit' ? ` <button class="rm" data-rmgi title="${$t('w.remove')}">×</button>` : ''}</div>
    <div class="gb">${sec.rows.map(r => `<div class="g">${r.map(f => `<div class="c" style="flex:${f.w}"><label>${esc(f.l)}</label>${mode === 'edit' ? cellInput(f, item[f.k], true) : cellView(f, item[f.k])}</div>`).join('')}</div>`).join('')}</div></div>`;
}
function groupHtml(sec, d, mode) {
  let items = arr(d[sec.k]);
  if (mode === 'edit' && !items.length) items = [{}];
  if (mode === 'view' && !items.length) return '<div class="none">—</div>';
  return `<div class="grp" data-gk="${sec.k}">${items.map((it, i) => groupItem(sec, it, i, mode)).join('')}</div>
    ${mode === 'edit' ? `<button class="add" data-addgi="${sec.k}">${$t('r.add_suspect', sec.max)}</button>` : ''}`;
}

function chargesHtml(sec, d, mode, spec) {
  if (mode === 'edit') {
    return `<div class="chbox" id="chOpen" title="${$t('r.charge_hint')}">
        <table class="chsel"><thead><tr>${chTh()}<th></th></tr></thead><tbody id="chSel"></tbody></table>
        <div class="chadd">${$t('r.add_charge')}${spec.chargesOptional ? ' ' + $t('r.optional') : ''}</div>
      </div>
      <div class="tot"><div>${$t('r.total_fine')}<b id="tFine">$0</b></div><div>${$t('r.total_jail')}<b id="tJail">${$t('r.n_months', 0)}</b></div><div>${$t('r.license_points')}<b id="tPts">0</b></div></div>
      ${sec.rows ? rowsHtml(sec.rows, d, mode) : ''}`;
  }
  const list = arr(d.chargeList), t = d.totals || {};
  if (!list.length) return '<div class="none">—</div>' + (sec.rows ? rowsHtml(sec.rows, d, mode) : '');
  return `<table class="rt"><thead><tr>${chTh()}</tr></thead><tbody>
    ${list.map(c => `<tr><td>${esc(c.id)}</td><td>${esc(c.title)}</td><td>${classPill(c.class)}</td><td>${c.count}</td><td>${money(c.fine)}</td><td>${$t('r.n_months', c.jail)}</td><td>${c.points}</td></tr>`).join('')}</tbody></table>
    <div class="tot"><div>${$t('r.total_fine')}<b>${money(t.fine)}</b></div><div>${$t('r.total_jail')}<b>${$t('r.n_months', t.jail || 0)}</b></div><div>${$t('r.license_points')}<b>${t.points || 0}</b></div></div>
    ${sec.rows ? rowsHtml(sec.rows, d, mode) : ''}`;
}

function narrativeHtml(sec, d, mode) {
  const parts = mode === 'view' ? sec.parts.filter(p => String(d[p.k] || '').trim()) : sec.parts;
  return `<div class="bar">NARRATIVE</div><div class="narr">${parts.length ? parts.map(p => `<h3>${esc(p.l)}:</h3>${mode === 'edit'
    ? `<textarea data-k="${p.k}" placeholder="${esc(p.ph)}">${esc(d[p.k] || '')}</textarea>`
    : `<p>${esc(d[p.k])}</p>`}`).join('') : '<p class="none">—</p>'}</div>`;
}

function approvalHtml(type, d, mode, rec) {
  const needs = (META.approval || {})[type];
  const m = me() || {};
  const team = S.units.filter(u => u.src !== myId && m.callsign && u.callsign === m.callsign).map(u => `${u.callsign} · ${u.name}`);
  const officer = rec ? `${rec.callsign} · ${rec.author}` : `${m.callsign || '-'} · ${m.name || '-'}`;
  const partners = rec ? arr(d._officers) : team;
  let status;
  if (rec) status = rec.review ? `<span class="status RV_${esc(rec.review)}">${REVIEW_LABEL[rec.review] || esc(rec.review)}</span>` : `<span class="muted2">${$t('r.no_approval')}</span>`;
  else status = needs ? `<span class="muted2">${$t('r.goes_to_supervisor')}</span>` : `<span class="muted2">${$t('r.no_approval')}</span>`;
  return `<div class="sec gap"><div class="sl">REPORTING / APPROVAL</div><div>
    <div class="g">
      <div class="c${mode === 'edit' ? ' auto' : ''}" style="flex:1.5"><label>${$t('r.reporting_officer')}</label><span>${esc(officer)}</span></div>
      <div class="c${mode === 'edit' ? ' auto' : ''}" style="flex:1.5"><label>${$t('r.partner_crew')}</label><span>${esc(partners.join(', ')) || '—'}</span></div>
      <div class="c" style="flex:1.5"><label>${$t('r.approving_supervisor')}</label><span>${esc(rec && rec.reviewer || '—')}</span></div>
      <div class="c" style="flex:1.3"><label>${$t('r.report_status')}</label><span>${status}</span></div>
    </div>
    ${rec && rec.review === 'RETURNED' && rec.review_note ? `<div class="g"><div class="c ret" style="flex:1"><label>${$t('r.correction_note')}</label><span>${esc(rec.review_note)}</span></div></div>` : ''}
    ${d._edited ? `<div class="g"><div class="c" style="flex:1"><label>${$t('r.last_edit')}</label><span>${esc(d._edited)}</span></div></div>` : ''}
  </div></div>`;
}

function renderReport(type, d, mode, rec) {
  const spec = RT[type];
  const m = me() || {};
  const dept = d.dept || (META.dept && META.dept.name) || m.agency || '';
  const color = d._color || (rec ? '' : (META.dept && META.dept.color)) || '#1f3a6e';
  const callCell = spec.call
    ? `<div><label>${$t('r.linked_call')}</label>${mode === 'edit' ? callSelect(d.call_id) : `<b>${rec && rec.call_id ? '#' + rec.call_id : '—'}</b>`}</div>` : '';
  const id = rec ? rec.id : null;
  let body = '';
  for (const sec of spec.sections) {
    if (sec.kind === 'narrative') { body += narrativeHtml(sec, d, mode); continue; }
    if (sec.kind === 'approval') { body += approvalHtml(type, d, mode, rec); continue; }
    let inner;
    if (sec.kind === 'table') inner = tableHtml(sec, d, mode);
    else if (sec.kind === 'group') inner = groupHtml(sec, d, mode);
    else if (sec.kind === 'charges') inner = chargesHtml(sec, d, mode, spec);
    else inner = rowsHtml(sec.rows, d, mode);
    body += `<div class="sec"><div class="sl">${esc(sec.side)}</div><div>${inner}</div></div>`;
  }
  return `<div class="rp ${mode}" style="--n:${esc(color)}">
    <div class="head">
      <div><div class="dept">${esc(up(dept || 'POLICE DEPARTMENT'))}</div><h1>${spec.title}</h1><div class="sub2">${esc(spec.label)}</div></div>
      <div class="ids">
        <div><label>DR No.</label><b>${id ? fmtDR(id, rec.created) : $t('r.new')}</b></div>
        ${spec.booking ? `<div><label>Booking No.</label><b>${id ? 'B-' + String(id).padStart(6, '0') : '—'}</b></div>` : ''}
        ${callCell}
      </div>
    </div>

    ${body}
  </div>`;
}

function callSelect(sel) {
  const opts = S.calls.map(c => `<option value="${c.id}"${Number(sel) === c.id ? ' selected' : ''}>#${c.id} · ${esc(c.title)}</option>`).join('');
  const other = sel && !S.calls.some(c => c.id === Number(sel)) ? `<option value="${esc(sel)}" selected>#${esc(sel)}</option>` : '';
  return `<select data-k="call_id"><option value="">— ${$t('r.none_dash')} —</option>${other}${opts}</select>`;
}

/* ---------- Collect form data ---------- */
function readInput(el) {
  if (el.dataset.type === 'radio') { const c = el.querySelector('input:checked'); return c ? c.value : ''; }
  if (el.dataset.type === 'checks') return [...el.querySelectorAll('input:checked')].map(i => i.value);
  return el.value;
}
function collect() {
  const root = $('#paper .rp');
  const data = {};
  root.querySelectorAll('[data-k]').forEach(el => {
    if (el.closest('[data-tk],[data-gk]')) return;
    data[el.dataset.k] = readInput(el);
  });
  root.querySelectorAll('[data-tk]').forEach(t => {
    const sec = curSchema.sections.find(x => x.k === t.dataset.tk);
    const free = new Set(sec.cols.filter(c => c.t !== 'select').map(c => c.k));
    // Rows where only a dropdown is set and everything else is empty are not saved
    data[t.dataset.tk] = [...t.querySelectorAll('tr[data-row]')].map(tr => {
      const o = {}; tr.querySelectorAll('[data-c]').forEach(el => { o[el.dataset.c] = readInput(el); }); return o;
    }).filter(o => Object.entries(o).some(([k, v]) => free.has(k) && String(v).trim()));
  });
  root.querySelectorAll('[data-gk]').forEach(g => {
    data[g.dataset.gk] = [...g.querySelectorAll('[data-gi]')].map(it => {
      const o = {}; it.querySelectorAll('[data-c]').forEach(el => { o[el.dataset.c] = readInput(el); }); return o;
    }).filter(o => Object.values(o).some(v => String(v).trim()));
  });
  return data;
}

/* ---------- Open the form ---------- */
async function openForm(type, pf = {}, rec = null) {
  if (!RT[type]) return;
  if (!rec && !canReport(type)) return toast($t('r.no_permission'));
  curForm = type; editRec = rec; curSchema = RT[type];
  const m = me() || {};
  const d = { ...pf };
  if (!rec) {
    if (d.call_id === undefined && m.callId) d.call_id = m.callId;
    const now = new Date();
    d.date = d.date || now.toISOString().slice(0, 10);
    d.time = d.time || now.toTimeString().slice(0, 5);
    if (type === 'arrest') {
      d.miranda_by = `${m.callsign || ''} · ${m.name || ''}`;
      d.miranda_time = d.time;
      if (PROF && pf.citizenid && PROF.citizenid === pf.citizenid) {
        d.warrant_at = PROF.warrants.length ? $t('r.active_warrant_existed') : $t('r.no_warrant');
        if (PROF.warrants.length) d.n_invest = $t('r.suspect_had_warrant', PROF.warrants.map(w => fmtDR(w.id, w.created)).join(', '));
      }
    }
  } else {
    d.call_id = rec.call_id || '';
  }
  curCharges = arr(d.chargeList).map(c => ({ id: c.id, count: c.count }));

  const penalList = `<datalist id="penalList">${arr(META.penal).map(c => `<option value="${esc(c.title)}">`).join('')}</datalist>`;
  $('#paper').innerHTML = `
    ${rec ? `<div class="editing">${$t('r.editing', rec.id)}${rec.review === 'RETURNED' ? ' — ' + $t('r.resubmits') : ''} <button class="mini" id="cancelEdit">${$t('r.cancel')}</button></div>` : ''}
    ${pf.citizenid && !rec ? `<div class="linked">${$t('r.profile_colon')} <b>${esc(pf._name || '')}</b> <small>${esc(pf.citizenid)}</small></div>` : ''}
    ${penalList}${renderReport(type, d, 'edit', null)}
    ${!rec && (type === 'arrest' || type === 'citation') ? `<div class="opts">
      ${META.fines ? `<label><input type="checkbox" id="applyFine" checked> ${$t('r.apply_fine')}</label>` : ''}
      ${type === 'arrest' && META.jail ? `<label><input type="checkbox" id="applyJail" checked> ${$t('r.apply_jail')}</label>` : ''}
    </div>` : ''}
    <div class="actions"><button id="saveRec">${rec ? $t('r.save_changes') : $t('r.save_new')}</button>${rec ? '' : `<button class="del" id="clearRec" title="${$t('r.clear_form')}">${$t('r.clear')}</button>`}</div>`;
  if (RT[type].charges) { chCat = type === 'citation' ? 'TI' : 'ALL'; renderCharges(); }
  $('#paper').scrollTop = 0; $('.stage').scrollTop = 0;

  // Location info (fills empty fields on a new report)
  if (!rec) {
    const loc = await post('locInfo');
    const set = (k, v) => { const el = $(`#paper .rp [data-k="${k}"]`); if (el && !el.value && v) el.value = v; };
    set('location', loc.address); set('postal', loc.postal); set('area', loc.area);
  }
  if (type === 'followup' && d.parent_id) fillParent(d.parent_id);
}

/* ---------- Charges ---------- */
let curCharges = [];
// Search that ignores case and Turkish diacritics
const fold = t => String(t ?? '').toLocaleLowerCase(LANG())
  .replace(/[ıİ]/g, 'i').replace(/ğ/g, 'g').replace(/ü/g, 'u').replace(/ş/g, 's').replace(/ö/g, 'o').replace(/ç/g, 'c').replace(/[âà]/g, 'a')
  .replace(/[^a-z0-9$.%/()]+/g, ' ').trim();
let chCat = 'ALL', penalIndex = null;
function penalHay() {
  if (penalIndex && penalIndex.src === META.penal) return penalIndex.list;
  const list = arr(META.penal).map(c => ({ c, hay: fold(`${c.id} ${c.id.replace(/\s/g, '')} ${c.title} ${c.en || ''}`) }));
  penalIndex = { src: META.penal, list };
  return list;
}
function inCat(c, cat) {
  if (cat === 'ALL') return true;
  if (cat === 'T') return String(c.cat || '').startsWith('T');
  if (cat === 'NT') return !String(c.cat || '').startsWith('T');
  return c.cat === cat;
}
function chargeMatches(q) {
  const toks = fold(q).split(' ').filter(Boolean);
  return penalHay().filter(x => inCat(x.c, chCat) && toks.every(t => x.hay.includes(t))).map(x => x.c);
}
function renderCats() {
  const box = $('#chCats'); if (!box) return;
  const counts = {};
  arr(META.penal).forEach(c => { counts[c.cat] = (counts[c.cat] || 0) + 1; });
  const chips = [{ id: 'ALL', label: $t('u.all'), n: arr(META.penal).length },
    ...arr(META.penalCats).map(c => ({ id: c.id, label: c.label, desc: c.desc, n: counts[c.id] || 0 }))];
  box.innerHTML = chips.map(c => `<button class="chip${chCat === c.id ? ' on' : ''}${String(c.id).startsWith('T') ? ' tr' : ''}" data-cat="${esc(c.id)}"${c.desc ? ` title="${esc(c.desc)}"` : ''}>${esc(c.label)} <small>${c.n}</small></button>`).join('');
}
function renderChargeList(q = ($('#chSearch') || {}).value || '') {
  const box = $('#chList'); if (!box) return;
  const all = chargeMatches(q), list = all.slice(0, 120);
  const picked = Object.fromEntries(curCharges.map(c => [c.id, c.count]));
  $('#chCount').textContent = $t('r.n_results', all.length);
  box.innerHTML = list.length ? list.map(c => `<button class="chrow${picked[c.id] ? ' picked' : ''}" data-add="${esc(c.id)}">
      <span class="cid">${esc(c.id)}</span>
      <span class="ctitle"><b>${esc(c.title)}</b><small>${esc(c.en || '')}</small></span>
      <span class="ccls">${classPill(c.class)}</span>
      <span class="cnum">${money(c.fine)}</span><span class="cnum">${c.jail ? $t('r.n_months', c.jail) : '—'}</span><span class="cnum">${c.points ? $t('r.n_points', c.points) : '—'}</span>
      <span class="cadd">${picked[c.id] ? '×' + picked[c.id] : '+'}</span></button>`).join('')
    + (all.length > list.length ? `<p class="muted">${$t('r.first_n_shown', list.length)}</p>` : '')
    : `<p class="muted">${$t('r.no_results_hint')}</p>`;
}
function renderCharges() {
  const body = $('#chSel'); if (!body) return;
  const P = Object.fromEntries(arr(META.penal).map(c => [c.id, c]));
  let fine = 0, jail = 0, pts = 0;
  body.innerHTML = curCharges.length ? curCharges.map(({ id, count }) => {
    const c = P[id]; if (!c) return '';
    fine += c.fine * count; jail += c.jail * count; pts += c.points * count;
    return `<tr><td>${esc(c.id)}</td><td>${esc(c.title)}</td><td>${classPill(c.class)}</td>
      <td class="cnt"><button data-dec="${esc(id)}">−</button><b>${count}</b><button data-inc="${esc(id)}">+</button></td>
      <td>${money(c.fine * count)}</td><td>${$t('r.n_months', c.jail * count)}</td><td>${c.points * count}</td>
      <td><button class="rm" data-rm="${esc(id)}">×</button></td></tr>`;
  }).join('') : `<tr><td colspan="8" class="muted">${$t('r.no_charges_yet')}</td></tr>`;
  $('#tFine').textContent = money(fine); $('#tJail').textContent = $t('r.n_months', jail); $('#tPts').textContent = pts;
  renderPicker(fine, jail, pts);
}

/* ---------- Charge picker window ---------- */
const pickerOpen = () => !!$('#modal .chmodal');
function openChargePicker() {
  const title = (RT[curForm] && RT[curForm].title) || $t('r.report');
  openModal(`<div class="chead"><b class="big">${$t('r.pick_charge')}</b><span class="muted">${esc(title)}</span><button class="xbtn" data-act="x">×</button></div>
    <div class="rp chpop"><div class="chpick2">
      <div class="chtop"><input id="chSearch" placeholder="${$t('r.charge_search_ph')}" autocomplete="off"><span id="chCount"></span></div>
      <div class="chcats" id="chCats"></div>
      <div class="chlist2" id="chList"></div>
    </div></div>
    <div class="chfoot"><div class="chpicked" id="chPicked"></div><div class="chsum" id="chSum"></div><button class="btn blue" data-act="ch-done">${$t('r.done')}</button></div>`, 'chmodal');
  renderCats(); renderCharges();
  setTimeout(() => { const i = $('#chSearch'); if (i) i.focus(); }, 30);
}
function renderPicker(fine, jail, pts) {
  if (!pickerOpen()) return;
  renderChargeList();
  const P = Object.fromEntries(arr(META.penal).map(c => [c.id, c]));
  $('#chPicked').innerHTML = curCharges.length ? curCharges.map(({ id, count }) => { const c = P[id]; return c
    ? `<span class="pk"><b>${esc(c.id)}</b> ${esc(c.title)}${count > 1 ? ` ×${count}` : ''}<button data-rmp="${esc(id)}" title="${$t('r.remove_tip')}">×</button></span>` : ''; }).join('')
    : `<span class="muted">${$t('r.picker_hint')}</span>`;
  $('#chSum').innerHTML = `<span>${$t('r.n_charges', curCharges.length)}</span><b>${money(fine)}</b><b>${$t('r.n_months', jail)}</b><b>${$t('r.n_points', pts)}</b>`;
}

/* ---------- Auto-fill: plate and original report ---------- */
async function fillPlate(el) {
  const plate = el.value.trim(); if (!plate) return;
  const g = el.closest('.sec');
  const v = arr(await post('lookupVehicle', { plate, exact: true }))[0];
  if (!v) return;
  const set = (k, val) => { const x = g.querySelector(`[data-k="${k}"]`); if (x && val) x.value = val; };
  if (!v.unregistered) { set('make_model', up(v.model)); set('owner', up(`${v.firstname || ''} ${v.lastname || ''}`.trim())); }
  else set('owner', $t('lookup.unregistered'));
  if (v.bolo) toast($t('r.plate_bolo', v.bolo.reason), 6000);
  if (v.ownerWanted) toast($t('r.owner_wanted'), 6000);
}
async function fillParent(id) {
  const r = await post('recordBrief', { id: Number(id) });
  const set = (k, v) => { const x = $(`#paper .rp [data-k="${k}"]`); if (x) x.value = v || ''; };
  if (!r.ok) { ['orig_type', 'orig_title', 'orig_date', 'orig_victim', 'orig_person'].forEach(k => set(k, '')); return toast(r.err || $t('r.not_found')); }
  set('orig_type', r.typeLabel); set('orig_title', r.title); set('orig_date', dt(r.created));
  set('orig_victim', r.victim); set('orig_person', r.person);
}

/* ---------- Paper events ---------- */
const P_ = $('#paper');
M.addEventListener('input', e => { if (e.target.id === 'chSearch') renderChargeList(e.target.value); });
M.addEventListener('keydown', e => {
  if (e.target.id !== 'chSearch' || e.key !== 'Enter') return;
  e.preventDefault();
  const first = M.querySelector('#chList .chrow'); if (first) first.click();
});
M.addEventListener('click', e => {
  if (!pickerOpen()) return;
  const t = e.target.closest('[data-add],[data-cat],[data-rmp],[data-act="ch-done"]'); if (!t) return;
  if (t.dataset.act === 'ch-done') return closeModal();
  if (t.dataset.add) {
    const ex = curCharges.find(c => c.id === t.dataset.add);
    if (ex) ex.count = Math.min(10, ex.count + 1); else curCharges.push({ id: t.dataset.add, count: 1 });
  }
  if (t.dataset.rmp) curCharges = curCharges.filter(x => x.id !== t.dataset.rmp);
  if (t.dataset.cat) { chCat = t.dataset.cat; renderCats(); }
  renderCharges();
});
P_.addEventListener('change', e => {
  if (e.target.dataset.plate) fillPlate(e.target);
  if (e.target.dataset.parent) fillParent(e.target.value);
});

P_.addEventListener('click', async e => {
  if (e.target.closest('#chOpen') && !e.target.closest('[data-inc],[data-dec],[data-rm]')) return openChargePicker();
  const t = e.target.closest('button, tr[data-rec]'); if (!t) return;
  if (t.dataset.rec) return openRecord(Number(t.dataset.rec));
  if (t.dataset.add) {
    const ex = curCharges.find(c => c.id === t.dataset.add);
    if (ex) ex.count = Math.min(10, ex.count + 1); else curCharges.push({ id: t.dataset.add, count: 1 });
    return renderCharges();
  }
  if (t.dataset.cat) { chCat = t.dataset.cat; renderCats(); renderChargeList(); return; }
  if (t.dataset.inc || t.dataset.dec) {
    const c = curCharges.find(x => x.id === (t.dataset.inc || t.dataset.dec)); if (!c) return;
    c.count = Math.max(1, Math.min(10, c.count + (t.dataset.inc ? 1 : -1)));
    return renderCharges();
  }
  if (t.dataset.rm) { curCharges = curCharges.filter(x => x.id !== t.dataset.rm); return renderCharges(); }
  if (t.dataset.addrow) {
    const sec = curSchema.sections.find(s => s.k === t.dataset.addrow);
    const tb = P_.querySelector(`[data-tk="${sec.k}"] tbody`);
    if (tb.children.length >= 20) return toast($t('r.max_rows'));
    tb.insertAdjacentHTML('beforeend', tableRow(sec, {}, 'edit'));
    return;
  }
  if (t.hasAttribute('data-rmrow')) {
    const tb = t.closest('tbody');
    if (tb.children.length > 1) t.closest('tr').remove();
    else t.closest('tr').querySelectorAll('input,select').forEach(i => { i.value = i.tagName === 'SELECT' ? i.options[0].value : ''; });
    return;
  }
  if (t.dataset.addgi) {
    const sec = curSchema.sections.find(s => s.k === t.dataset.addgi);
    const g = P_.querySelector(`[data-gk="${sec.k}"]`);
    if (g.children.length >= sec.max) return toast($t('r.max_suspects', sec.max));
    g.insertAdjacentHTML('beforeend', groupItem(sec, {}, g.children.length, 'edit'));
    return;
  }
  if (t.hasAttribute('data-rmgi')) {
    const g = t.closest('[data-gk]');
    t.closest('[data-gi]').remove();
    const sec = curSchema.sections.find(s => s.k === g.dataset.gk);
    if (!g.children.length) g.insertAdjacentHTML('beforeend', groupItem(sec, {}, 0, 'edit'));
    [...g.children].forEach((it, i) => { it.querySelector('.gh').firstChild.textContent = `${sec.prefix}-${i + 1} `; });
    return;
  }
  if (t.id === 'cancelEdit') { const r = editRec; editRec = null; P_.innerHTML = `<p class="empty dark">${$t('r.pick_type')}</p>`; return openRecord(r.id); }
  if (t.id === 'clearRec') return openForm(curForm);
  if (t.id !== 'saveRec') return;

  const spec = RT[curForm];
  const data = collect();
  data.charges = curCharges.map(c => ({ id: c.id, count: c.count }));
  data.applyFine = !!($('#applyFine') && $('#applyFine').checked);
  data.applyJail = !!($('#applyJail') && $('#applyJail').checked);
  if (spec.citizen && !data.citizenid && (!String(data.first || '').trim() || !String(data.last || '').trim())) return toast($t('r.name_required'));
  if (spec.charges && !spec.chargesOptional && !curCharges.length) return toast($t('r.charge_required'));
  if (curForm === 'crime' && !String(data.crime_type || '').trim()) return toast($t('r.crime_required'));
  if (curForm === 'followup' && !data.parent_id) return toast($t('r.parent_required'));
  if (curForm === 'followup' && !data.case_status) return toast($t('r.status_required'));
  t.disabled = true;
  const r = editRec ? await post('updateRecord', { id: editRec.id, data }) : await post('createRecord', { type: curForm, data });
  t.disabled = false;
  if (!r.ok) return toast(r.err || $t('r.save_fail'), 5000);
  toast(`${$t('r.saved', fmtDR(r.id))}${r.info ? ' ' + r.info : ''}`, 6000);
  const wasEdit = !!editRec, cid = data.citizenid;
  editRec = null;
  refreshReportCounts();
  if (wasEdit) { P_.innerHTML = `<p class="empty dark">${$t('r.pick_type')}</p>`; return openRecord(r.id); }
  openForm(curForm);
  if (cid && PROF && PROF.citizenid === cid) { go('lookup'); loadProfile(cid); }
});

$$('[data-form]').forEach(b => b.onclick = () => openForm(b.dataset.form));

/* ---------- Lists: My Reports / Pending Approval ---------- */
async function showList(kind) {
  const rows = arr(await post(kind === 'pending' ? 'pendingReports' : 'myReports'));
  P_.innerHTML = `<div class="rp view"><div class="head"><div><div class="dept">${$t('r.list')}</div><h1>${kind === 'pending' ? 'PENDING APPROVAL' : 'MY REPORTS'}</h1>
    <div class="sub2">${kind === 'pending' ? $t('r.awaiting') : $t('r.your_reports')}</div></div></div>
    ${rows.length ? `<table class="rt click"><thead><tr><th>${$t('h.th_dr')}</th><th>${$t('p.th_type')}</th><th>${$t('h.th_title')}</th><th>${$t('q.t_person')}</th><th>${$t('ui.th_status')}</th><th>${$t('p.th_officer')}</th><th>${$t('p.th_date')}</th></tr></thead><tbody>
      ${rows.map(r => `<tr data-rec="${r.id}"><td><b>${fmtDR(r.id, r.created)}</b></td><td>${esc(r.typeLabel)}</td><td>${esc(r.title)}</td>
        <td>${r.firstname ? esc(r.firstname + ' ' + (r.lastname || '')) : '—'}</td><td>${statusPills(r)}${r.review === 'RETURNED' && r.review_note ? `<div class="retnote">${esc(r.review_note)}</div>` : ''}</td>
        <td>${esc(r.callsign)} ${esc(r.author)}</td><td>${dt(r.created)}</td></tr>`).join('')}</tbody></table>` : `<p class="empty dark">${$t('r.list_empty')}</p>`}</div>`;
}
$$('[data-list]').forEach(b => b.onclick = () => showList(b.dataset.list));

async function refreshReportCounts() {
  if (!hasPage('records')) return;
  const c = await post('reportCounts');
  const pending = Number(c.pending) || 0, returned = Number(c.returned) || 0;
  const perms = META.perms || {};
  $('#btnPending').classList.toggle('hidden', !perms.approveReport);
  const setCnt = (el, n) => { el.textContent = n; el.classList.toggle('hidden', !n); };
  setCnt($('#cntPending'), pending); setCnt($('#cntReturned'), returned);
  const total = (perms.approveReport ? pending : 0) + returned;
  setCnt($('#recBadge'), total);
}

/* ---------- Report viewer ---------- */
const fieldLabel = k => { const key = 'fld.' + k, s = $t(key); return s === key ? k : s; };
const SKIP = new Set(['chargeList', 'totals', 'charges', 'flags', 'citizenid', 'applyFine', 'applyJail', 'closedBy', 'closedAt',
  'rec', 'first', 'last', 'license', 'value']);

// Old fields with no counterpart in the schema (for reports written by earlier versions)
function legacyFields(type, d) {
  const known = new Set(['dept', 'call_id', 'chargeList', 'totals', 'charges', 'citizenid', 'closedBy', 'closedAt', 'rec', 'parent_id']);
  const walk = secs => secs.forEach(s => {
    if (s.rows) s.rows.flat().forEach(f => known.add(f.k));
    if (s.k) known.add(s.k);
    if (s.parts) s.parts.forEach(p => known.add(p.k));
  });
  walk(RT[type].sections);
  const rest = Object.entries(d).filter(([k, v]) => !known.has(k) && k[0] !== '_' && typeof v !== 'object' && String(v).trim());
  if (!rest.length) return '';
  return `<div class="sec gap"><div class="sl">OTHER</div><div><div class="g">${rest.map(([k, v]) =>
    `<div class="c" style="flex:${String(v).length > 60 ? 4 : 1}"><label>${esc(fieldLabel(k))}</label><span>${esc(v)}</span></div>`).join('')}</div></div></div>`;
}

function legacyRecordHtml(r) {
  const d = r.data || {};
  const charges = arr(d.chargeList), t = d.totals || {};
  const fields = Object.entries(d).filter(([k, v]) => !SKIP.has(k) && k[0] !== '_' && v !== '' && v !== null && typeof v !== 'object');
  return `
    <div class="chead"><span class="badge">#${r.id}</span><b>${esc(r.typeLabel)}</b>${statusPills(r)}<button class="xbtn" data-act="x">×</button></div>
    ${r.citizenid ? `<div class="rperson"><b>${esc(r.firstname || '?')} ${esc(r.lastname || '')}</b> <small>${esc(r.citizenid)}</small></div>` : ''}
    <div class="rmeta">${$t('r.officer_colon')} <b>${esc(r.callsign)} ${esc(r.author)}</b> · ${dt(r.created)}${r.call_id ? ` · ${$t('r.call_n', r.call_id)}` : ''}</div>
    ${r.type === 'license' ? `<div class="alarm ${d.value ? 'green' : 'orange'}">${esc(d.label)} ${d.value ? $t('r.lic_restored') : $t('r.lic_suspended')}</div>` : ''}
    ${charges.length ? `<table class="mt"><thead><tr>${chTh()}</tr></thead><tbody>
      ${charges.map(c => `<tr><td>${esc(c.id)}</td><td>${esc(c.title)}</td><td>${classPill(c.class)}</td><td>${c.count}</td><td>${money(c.fine)}</td><td>${$t('r.n_months', c.jail)}</td><td>${c.points}</td></tr>`).join('')}
      </tbody></table>
      <div class="totals sm"><div>${$t('r.fine')}<b>${money(t.fine)}</b></div><div>${$t('r.jail')}<b>${$t('r.n_months', t.jail || 0)}</b></div><div>${$t('r.points')}<b>${t.points || 0}</b></div></div>` : ''}
    <div class="rfields">${fields.map(([k, v]) => `<div class="${String(v).length > 60 ? 'wide' : ''}"><label>${esc(fieldLabel(k))}</label><span>${esc(v)}</span></div>`).join('')}</div>`;
}

async function openRecord(id) {
  const r = await post('recordDetail', { id });
  if (!r.ok) return toast(r.err || $t('r.err_open'));
  curRec = r; openCallId = null;
  const perms = META.perms || {};
  const d = r.data || {};
  const typed = !!RT[r.type];
  const fups = arr(r.followups);
  const top = `<div class="rvbar"><span class="badge">${fmtDR(r.id, r.created)}</span><b>${esc(r.typeLabel)}</b>${statusPills(r)}
      ${r.citizenid ? `<button class="mini" data-act="r-prof" data-cid="${esc(r.citizenid)}">${esc(r.firstname || '?')} ${esc(r.lastname || '')}</button>` : ''}
      <button class="xbtn" data-act="x">×</button></div>`;
  const body = typed
    ? `<div class="rpwrap">${renderReport(r.type, { ...d }, 'view', r)}${legacyFields(r.type, d)}
        ${fups.length ? `<div class="bar">FOLLOW-UP REPORTS</div><table class="rt click"><tbody>${fups.map(f => `<tr data-rec="${f.id}"><td><b>${fmtDR(f.id, f.created)}</b></td>
          <td>${esc(CASE_LABEL[f.case_status] || '')}</td><td>${esc(f.callsign)} ${esc(f.author)}</td><td>${dt(f.created)}</td><td>${f.review ? `<span class="pill RV_${esc(f.review)}">${REVIEW_LABEL[f.review]}</span>` : ''}</td></tr>`).join('')}</tbody></table>` : ''}
        ${r.type === 'followup' && d.parent_id ? `<div class="linkrow">${$t('r.original_report')} <button class="mini" data-rec="${d.parent_id}">${$t('r.open_x', fmtDR(d.parent_id))}</button></div>` : ''}
      </div>`
    : legacyRecordHtml(r);
  const btns = `<div class="row rvbtns">
      ${r.canReview ? `<button class="btn green" data-act="rv-approve">${$t('r.approve')}</button><button class="btn orange" data-act="rv-return">${$t('r.request_fix')}</button>` : ''}
      ${r.canEdit && typed ? `<button class="btn blue" data-act="rv-edit">${$t('r.edit')}</button>` : ''}
      ${(r.type === 'crime' || r.type === 'arrest' || r.type === 'report') && canReport('followup') ? `<button class="btn" data-act="rv-followup">${$t('r.add_followup')}</button>` : ''}
      ${r.type === 'warrant' && r.status === 'ACTIVE' ? `<button class="btn green" data-act="w-serve">${$t('r.served')}</button>` : ''}
      ${r.type === 'warrant' && (r.status === 'ACTIVE' || r.status === 'EXPIRED') && perms.voidWarrant ? `<button class="btn" data-act="w-void">${$t('r.void')}</button>` : ''}
      ${perms.deleteRecord ? `<button class="btn red" data-act="r-del">${$t('r.delete_record')}</button>` : ''}
      <button class="btn ghost" data-act="x">${$t('h.close')}</button>
    </div>`;
  openModal(top + body + btns, typed ? 'rpbox' : 'recbox');
}

function afterRecordChange(rec) {
  if (PROF && rec.citizenid === PROF.citizenid && curPage === 'lookup') loadProfile(PROF.citizenid);
  if (curPage === 'wanted') loadWanted();
  if (curPage === 'history') loadHistory();
  refreshReportCounts();
}

// Report buttons in the viewer
M.addEventListener('click', async e => {
  const t = e.target.closest('[data-act]'); if (!t) return;
  const rec = curRec;
  switch (t.dataset.act) {
    case 'rv-approve': {
      const r = await confirmBtn(t, $t('r.approving'), () => post('reviewRecord', { id: rec.id, action: 'approve' }));
      if (r && r.ok) { toast($t('r.toast_approved')); closeModal(); afterRecordChange(rec); if (curPage === 'records') showList('pending'); }
      return;
    }
    case 'rv-return':
      return reasonModal($t('r.request_fix_title', fmtDR(rec.id, rec.created)), 'rv-return-send', { id: rec.id, cid: rec.citizenid || '' });
    case 'rv-return-send': {
      const note = $('#mReason').value.trim();
      if (!note) return toast($t('r.fix_note_required'));
      const r = await post('reviewRecord', { id: Number(t.dataset.id), action: 'return', note });
      if (!r.ok) return toast(r.err || $t('m.failed'));
      toast($t('r.fix_sent')); closeModal(); refreshReportCounts();
      if (curPage === 'records') showList('pending');
      return;
    }
    case 'rv-edit': {
      closeModal(); go('records');
      return openForm(rec.type, { ...rec.data }, rec);
    }
    case 'rv-followup': {
      closeModal(); go('records');
      return openForm('followup', { parent_id: rec.id, citizenid: '' });
    }
  }
});
