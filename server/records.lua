-- knb_cad - LAPD-style MDC + dispatch system for FiveM
-- Copyright (C) 2026 kenobiali
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program (see the LICENSE file). If not, see
-- <https://www.gnu.org/licenses/>.
--
-- Parts of the alert detection and dispatch logic are adapted from
-- Project Sloth ps-dispatch (GPL-3.0): https://github.com/Project-Sloth/ps-dispatch

-- Citizen/vehicle lookup, profile, warrants, BOLOs, penal code, records, reports, call history
local line, clean, normPlate, reg = Cad.line, Cad.clean, Cad.normPlate, Cad.reg

local PENAL = {}
for _, c in ipairs(Config.PenalCode) do PENAL[c.id] = c end

local TYPE_LABEL = { arrest = 'Arrest Report', crime = 'Crime Report', followup = 'Follow-up', citation = 'Citation',
    warrant = 'Arrest Warrant', report = L('record.type.report'), license = L('record.type.license') }

local FN = "JSON_UNQUOTE(JSON_EXTRACT(%s.charinfo,'$.firstname'))"
local LN = "JSON_UNQUOTE(JSON_EXTRACT(%s.charinfo,'$.lastname'))"

------------------------------------------------------------------ Helpers
local function jdecode(s, def)
    if type(s) == 'table' then return s end
    if type(s) ~= 'string' or s == '' then return def end
    local ok, r = pcall(json.decode, s)
    return (ok and type(r) == 'table') and r or def
end

local function today() return os.date('%Y-%m-%d') end

local function isExpired(data)
    local e = type(data) == 'table' and data.expires
    return type(e) == 'string' and e ~= '' and e < today()
end

local function placeholders(n) return string.rep('?', n, ', ') end

local function uniq(list)
    local seen, out = {}, {}
    for _, v in ipairs(list) do
        if v and v ~= '' and not seen[v] then seen[v] = true out[#out + 1] = v end
    end
    return out
end

-- citizenids that have an active (not expired) warrant
local function wantedSet(cids)
    local set = {}
    cids = uniq(cids)
    if #cids == 0 then return set end
    local rows = MySQL.query.await(("SELECT citizenid, data FROM cad_records WHERE type = 'warrant' AND status = 'ACTIVE' AND citizenid IN (%s)")
        :format(placeholders(#cids)), cids) or {}
    for _, r in ipairs(rows) do
        if not isExpired(jdecode(r.data, {})) then set[r.citizenid] = true end
    end
    return set
end

-- citizenid -> person BOLO reason
local function personBolos(cids)
    local map = {}
    cids = uniq(cids)
    if #cids == 0 then return map end
    local rows = MySQL.query.await(("SELECT citizenid, reason FROM cad_bolos WHERE kind = 'person' AND active = 1 AND citizenid IN (%s)")
        :format(placeholders(#cids)), cids) or {}
    for _, r in ipairs(rows) do map[r.citizenid] = r.reason end
    return map
end

local function vehicleBolos()
    local map = {}
    for _, b in ipairs(MySQL.query.await("SELECT plate, reason, author FROM cad_bolos WHERE kind = 'vehicle' AND active = 1") or {}) do
        map[b.plate] = { reason = b.reason, author = b.author }
    end
    return map
end

local function summary(rtype, data, title)
    if rtype == 'license' then
        return L(data.value and 'server.lic_reinstated' or 'server.lic_suspended', data.label or '')
    end
    local s = data.charges
    if not s or s == '' then s = title end
    if not s or s == '' then s = data.narrative or data.reason or '' end
    return line(s, 120)
end

-- Static info sent to the NUI on open + the player's permissions
function Cad.meta(p)
    return {
        penal = Config.PenalCode, penalCats = Config.PenalCategories, classes = Config.PenalClasses, licenses = Config.Licenses,
        fines = Config.Fines.Enabled, jail = Config.Jail.Enabled, points = Config.Points,
        approval = Config.Reports.RequireApproval,
        statusInfo = Config.StatusInfo, statusCheck = Config.StatusCheckMinutes, offDuty = Config.OffDutyStatus,
        unattended = Config.Dispatch.UnattendedAfter, respondKey = Config.RespondKey, openKey = Config.Key,
        cid = p.PlayerData.citizenid,
        postalUrl = Config.PostalResource and ('nui://%s/%s'):format(Config.PostalResource, Config.PostalFile) or ('../' .. Config.PostalFile),
        dept = (function()
            local d = Cad.dept(p.PlayerData.job)
            return { name = d.name, short = d.short, color = d.color, theme = d.theme, motto = d.motto, pages = d.pages, reports = d.reports }
        end)(),
        perms = {
            closeCall = Cad.can(p, 'closeCall'), deleteRecord = Cad.can(p, 'deleteRecord'),
            voidWarrant = Cad.can(p, 'voidWarrant'), licenses = Cad.can(p, 'licenses'),
            approveReport = Cad.can(p, 'approveReport'),
        },
    }
end

------------------------------------------------------------------ Vehicle lookup
function Cad.searchVehicles(plate, exact)
    plate = normPlate(plate)
    if plate == '' then return {} end
    local rows = MySQL.query.await(([[SELECT pv.plate, pv.vehicle AS model, pv.citizenid,
        %s AS firstname, %s AS lastname
        FROM player_vehicles pv LEFT JOIN players p ON p.citizenid = pv.citizenid
        WHERE UPPER(TRIM(pv.plate)) %s LIMIT 25]]):format(FN:format('p'), LN:format('p'), exact and '= ?' or 'LIKE ?'),
        { exact and plate or ('%' .. plate .. '%') }) or {}
    local bolos = vehicleBolos()
    local cids = {}
    for _, r in ipairs(rows) do
        r.bolo = bolos[normPlate(r.plate)]
        cids[#cids + 1] = r.citizenid
    end
    local wanted, pb = wantedSet(cids), personBolos(cids)
    for _, r in ipairs(rows) do
        r.ownerWanted = wanted[r.citizenid] or nil
        r.ownerBolo = pb[r.citizenid]
    end
    if #rows == 0 then rows[1] = { plate = plate, model = L('lookup.unregistered'), unregistered = true, bolo = bolos[plate] } end
    return rows
end

local function vehicleHit(rows)
    for _, r in ipairs(rows) do
        if r.bolo or r.ownerWanted or r.ownerBolo then return true end
    end
    return false
end

reg('lookupVehicle', function(src, _, q)
    local rows = Cad.searchVehicles(q.plate, q.exact)
    if #rows > 0 then Cad.shiftQuery(src, normPlate(q.plate), vehicleHit(rows)) end
    return rows
end)
reg('quickPlate', function(src, _, q)
    local r = Cad.searchVehicles(q.plate, true)[1] or {}
    if r.plate then Cad.shiftQuery(src, r.plate, vehicleHit({ r })) end
    return r
end)

------------------------------------------------------------------ Weapon serial number lookup (ox_inventory)
reg('lookupWeapon', function(src, _, q)
    local serial = line(q.serial, 32):upper()
    if #serial < 3 then return { ok = false, err = L('server.err_serial_short') } end
    local ok, rows = pcall(MySQL.query.await, ([[SELECT citizenid, %s AS firstname, %s AS lastname, inventory
        FROM players WHERE inventory LIKE ? LIMIT 10]]):format(FN:format('players'), LN:format('players')), { '%' .. serial .. '%' })
    local out = {}
    for _, r in ipairs(ok and rows or {}) do
        for _, it in ipairs(jdecode(r.inventory, {})) do
            local m = type(it) == 'table' and type(it.metadata) == 'table' and it.metadata or {}
            if type(it.name) == 'string' and it.name:upper():find('^WEAPON_') and tostring(m.serial or ''):upper():find(serial, 1, true) then
                out[#out + 1] = { serial = tostring(m.serial), name = it.name, label = m.label or it.name,
                    registered = m.registered or '', citizenid = r.citizenid,
                    owner = ('%s %s'):format(r.firstname or '?', r.lastname or '') }
            end
        end
    end
    local cids = {}
    for _, w in ipairs(out) do cids[#cids + 1] = w.citizenid end
    local wanted = wantedSet(cids)
    for _, w in ipairs(out) do w.ownerWanted = wanted[w.citizenid] or nil end
    Cad.shiftQuery(src, serial, next(wanted) ~= nil)
    return { ok = true, list = out }
end)

------------------------------------------------------------------ Citizen lookup
reg('lookup', function(src, _, q)
    local where, params = {}, {}
    local function add(col, val)
        val = line(val, 40):lower()
        if val == '' then return end
        where[#where + 1] = 'LOWER(' .. col .. ')' .. (q.exact and ' = ?' or ' LIKE ?')
        params[#params + 1] = q.exact and val or ('%' .. val .. '%')
    end
    add(FN:format('players'), q.first)
    add(LN:format('players'), q.last)
    local cid = line(q.citizenid, 50)
    if cid ~= '' then where[#where + 1] = 'citizenid = ?' params[#params + 1] = cid end
    if #where == 0 then return {} end
    local rows = MySQL.query.await(([[SELECT citizenid, %s AS firstname, %s AS lastname,
        JSON_UNQUOTE(JSON_EXTRACT(charinfo,'$.birthdate')) AS dob,
        JSON_UNQUOTE(JSON_EXTRACT(charinfo,'$.phone')) AS phone
        FROM players WHERE %s LIMIT 25]]):format(FN:format('players'), LN:format('players'), table.concat(where, ' AND ')), params) or {}
    local cids = {}
    for _, r in ipairs(rows) do cids[#cids + 1] = r.citizenid end
    local wanted, pb = wantedSet(cids), personBolos(cids)
    local hit = false
    for _, r in ipairs(rows) do
        r.wanted = wanted[r.citizenid] or nil
        r.bolo = pb[r.citizenid]
        if r.wanted or r.bolo then hit = true end
    end
    Cad.shiftQuery(src, line(('%s %s'):format(q.first or '', q.last or ''), 40):upper(), hit)
    return rows
end)

------------------------------------------------------------------ Citizen profile
reg('profile', function(_, _, d)
    local cid = line(d.citizenid, 50)
    local row = MySQL.single.await('SELECT citizenid, charinfo, metadata, job FROM players WHERE citizenid = ?', { cid })
    if not row then return { ok = false, err = L('server.err_citizen_not_found') } end
    local ci, md, job = jdecode(row.charinfo, {}), jdecode(row.metadata, {}), jdecode(row.job, {})

    -- Licenses
    local have = type(md.licences) == 'table' and md.licences or {}
    local licenses = {}
    for key, label in pairs(Config.Licenses) do
        licenses[#licenses + 1] = { key = key, label = label, valid = have[key] and true or false }
    end
    table.sort(licenses, function(a, b) return a.label < b.label end)

    -- Vehicles
    local bolos = vehicleBolos()
    local vehicles = {}
    for _, v in ipairs(MySQL.query.await('SELECT plate, vehicle FROM player_vehicles WHERE citizenid = ?', { cid }) or {}) do
        vehicles[#vehicles + 1] = { plate = v.plate, model = v.vehicle, bolo = bolos[normPlate(v.plate)] and true or nil }
    end

    -- Weapons (ox_inventory: weapons with serial numbers in players.inventory)
    local weapons = {}
    local okInv, inv = pcall(MySQL.scalar.await, 'SELECT inventory FROM players WHERE citizenid = ?', { cid })
    for _, it in ipairs(okInv and jdecode(inv, {}) or {}) do
        if type(it) == 'table' and type(it.name) == 'string' and it.name:upper():find('^WEAPON_') then
            local m = type(it.metadata) == 'table' and it.metadata or {}
            weapons[#weapons + 1] = { name = it.name, label = m.label or it.name, serial = m.serial or '-',
                registered = m.registered or '' }
        end
    end

    -- Records
    local rows = MySQL.query.await([[SELECT id, type, title, status, call_id, author, callsign, data,
        UNIX_TIMESTAMP(created_at) * 1000 AS created
        FROM cad_records WHERE citizenid = ? ORDER BY id DESC LIMIT 100]], { cid }) or {}
    local records, warrants, points = {}, {}, 0
    local since = (os.time() - Config.Points.WindowDays * 86400) * 1000
    for _, r in ipairs(rows) do
        local data = jdecode(r.data, {})
        local expired = r.type == 'warrant' and isExpired(data)
        records[#records + 1] = { id = r.id, type = r.type, typeLabel = TYPE_LABEL[r.type] or r.type,
            status = expired and r.status == 'ACTIVE' and 'EXPIRED' or r.status, summary = summary(r.type, data, r.title),
            author = r.author, callsign = r.callsign, created = r.created, totals = data.totals }
        if r.type == 'warrant' and r.status == 'ACTIVE' and not expired then
            warrants[#warrants + 1] = { id = r.id, title = r.title, expires = data.expires or '', author = r.author,
                callsign = r.callsign, created = r.created, flags = data.flags }
        end
        if r.type == 'citation' and (tonumber(r.created) or 0) >= since and type(data.totals) == 'table' then
            points = points + (tonumber(data.totals.points) or 0)
        end
    end

    local bolo = MySQL.single.await([[SELECT id, reason, author, UNIX_TIMESTAMP(created_at) * 1000 AS created
        FROM cad_bolos WHERE kind = 'person' AND citizenid = ? AND active = 1 ORDER BY id DESC LIMIT 1]], { cid })

    local g = tonumber(ci.gender)
    return {
        ok = true, citizenid = cid, firstname = ci.firstname, lastname = ci.lastname, dob = ci.birthdate,
        gender = g == 1 and L('gender.female') or (g == 0 and L('gender.male') or tostring(ci.gender or '-')),
        phone = ci.phone, nationality = ci.nationality, job = job.label or job.name,
        licenses = licenses, vehicles = vehicles, weapons = weapons, records = records, warrants = warrants,
        points = points, pointsLimit = Config.Points.Limit, pointsDays = Config.Points.WindowDays, bolo = bolo,
    }
end)

------------------------------------------------------------------ License suspend / reinstate
reg('setLicense', function(src, p, d)
    if not Cad.can(p, 'licenses') then return { ok = false, err = L('server.err_license_perm') } end
    local key = tostring(d.license or '')
    if not Config.Licenses[key] then return { ok = false, err = L('server.err_license_invalid') } end
    local cid, value = line(d.citizenid, 50), d.value and true or false

    local target = exports.qbx_core:GetPlayerByCitizenId(cid)
    if target then
        local l = target.PlayerData.metadata.licences or {}
        l[key] = value
        target.Functions.SetMetaData('licences', l)
        TriggerClientEvent('ox_lib:notify', target.PlayerData.source, {
            title = L('server.notify_license_title'), type = value and 'success' or 'error',
            description = L(value and 'server.lic_reinstated' or 'server.lic_suspended', Config.Licenses[key]) .. '.' })
    else
        local md = jdecode(MySQL.scalar.await('SELECT metadata FROM players WHERE citizenid = ?', { cid }), nil)
        if not md then return { ok = false, err = L('server.err_citizen_not_found') } end
        md.licences = type(md.licences) == 'table' and md.licences or {}
        md.licences[key] = value
        MySQL.update.await('UPDATE players SET metadata = ? WHERE citizenid = ?', { json.encode(md), cid })
    end

    local u = Cad.units[src] or {}
    local label = Config.Licenses[key]
    MySQL.insert.await('INSERT INTO cad_records (type, citizenid, title, status, author, callsign, data) VALUES (?, ?, ?, ?, ?, ?, ?)', {
        'license', cid, L(value and 'server.lic_reinstated' or 'server.lic_suspended', label), '', u.name or '', u.callsign or '',
        json.encode({ license = key, label = label, value = value, reason = line(d.reason, 255) }) })
    return { ok = true }
end)

------------------------------------------------------------------ Penal code
local function computeCharges(list)
    local out, t = {}, { fine = 0, jail = 0, points = 0 }
    if type(list) ~= 'table' then return out, t end
    local seen = {}
    for i = 1, math.min(#list, 30) do
        local e = list[i]
        local c = type(e) == 'table' and PENAL[tostring(e.id)]
        if c and not seen[c.id] then
            seen[c.id] = true
            local n = math.max(1, math.min(10, math.floor(tonumber(e.count) or 1)))
            out[#out + 1] = { id = c.id, title = c.title, class = c.class, count = n,
                fine = c.fine * n, jail = c.jail * n, points = c.points * n }
            t.fine, t.jail, t.points = t.fine + c.fine * n, t.jail + c.jail * n, t.points + c.points * n
        end
    end
    return out, t
end

local function chargeMoney(target, amount, reason)
    local src = target.PlayerData.source
    local ok, r = pcall(function() return exports.qbx_core:RemoveMoney(src, Config.Fines.Account, amount, reason) end)
    if ok and r then return true end
    ok, r = pcall(function() return target.Functions.RemoveMoney(Config.Fines.Account, amount, reason) end)
    return ok and r and true or false
end

------------------------------------------------------------------ Records / reports
local function resolveCitizen(data)
    local cid = line(data.citizenid, 50)
    if cid ~= '' then
        local found = MySQL.scalar.await('SELECT citizenid FROM players WHERE citizenid = ?', { cid })
        if found then return found end
        return nil, L('server.err_citizen_id_not_found')
    end
    local rows = MySQL.query.await(([[SELECT citizenid FROM players
        WHERE LOWER(%s) = ? AND LOWER(%s) = ? LIMIT 2]]):format(FN:format('players'), LN:format('players')),
        { line(data.first, 40):lower(), line(data.last, 40):lower() }) or {}
    if #rows == 0 then return nil, L('server.err_name_not_found') end
    if #rows > 1 then return nil, L('server.err_name_multiple') end
    return rows[1].citizenid
end

-- Types that require a person
local NEEDS_CITIZEN = { arrest = true, citation = true, warrant = true }
local CASE_STATUS = { CLEARED_ARREST = true, CLEARED_OTHER = true, UNFOUNDED = true, CONTINUED = true }
local SKIP_KEYS = { charges = true, chargeList = true, totals = true, applyFine = true, applyJail = true }

-- Cleans the data coming from the form: plain values, text lists (checkboxes) and tables (row lists)
local function sanitize(raw)
    local data = {}
    for k, v in pairs(raw) do
        if type(k) == 'string' and #k <= 32 and not SKIP_KEYS[k] and k:sub(1, 1) ~= '_' then
            local tv = type(v)
            if tv == 'string' then
                data[k] = clean(v, 4000)
            elseif tv == 'number' or tv == 'boolean' then
                data[k] = v
            elseif tv == 'table' then
                local list = {}
                for i = 1, math.min(#v, 20) do
                    local e = v[i]
                    if type(e) == 'string' then
                        list[#list + 1] = line(e, 64)
                    elseif type(e) == 'table' then
                        local row, any = {}, false
                        for rk, rv in pairs(e) do
                            if type(rk) == 'string' and #rk <= 32 and (type(rv) == 'string' or type(rv) == 'number') then
                                row[rk] = clean(tostring(rv), 500)
                                if row[rk] ~= '' then any = true end
                            end
                        end
                        if any then list[#list + 1] = row end
                    end
                end
                data[k] = list
            end
        end
    end
    return data
end

-- Validates by type rules; computes citizenid, title and charge totals
local function build(rtype, raw)
    local data = sanitize(raw)
    local cid, title = '', ''

    if NEEDS_CITIZEN[rtype] then
        local e
        cid, e = resolveCitizen(data)
        if not cid then return nil, e end
    elseif line(data.citizenid, 50) ~= '' then
        cid = resolveCitizen(data) or ''
    end

    if rtype == 'arrest' or rtype == 'citation' or rtype == 'warrant' then
        local list, totals = computeCharges(raw.charges)
        if (rtype == 'arrest' or rtype == 'citation') and #list == 0 then
            return nil, L('server.err_need_charge')
        end
        local names = {}
        for _, c in ipairs(list) do names[#names + 1] = (c.count > 1 and (c.count .. 'x ') or '') .. c.title end
        data.chargeList, data.totals, data.charges = list, totals, table.concat(names, ', ')
        if rtype == 'warrant' and #list == 0 and line(data.reason, 10) == '' then
            return nil, L('server.err_warrant_reason')
        end
        title = line(data.charges ~= '' and data.charges or data.reason, 128)
    elseif rtype == 'crime' then
        title = line(data.crime_type, 128)
        if title == '' then return nil, L('server.err_crime_type') end
    elseif rtype == 'followup' then
        local pid = tonumber(data.parent_id)
        local parent = pid and MySQL.single.await('SELECT id, type, citizenid, title FROM cad_records WHERE id = ?', { pid })
        if not parent or not (parent.type == 'crime' or parent.type == 'arrest' or parent.type == 'report') then
            return nil, L('server.err_followup_parent')
        end
        if not CASE_STATUS[data.case_status] then return nil, L('server.err_case_status') end
        data.parent_id = parent.id
        if cid == '' then cid = parent.citizenid or '' end
        title = line(L('server.followup_title', parent.title or ''), 128)
    elseif rtype == 'report' then
        title = line(data.title, 128)
        if title == '' then return nil, L('server.err_report_title') end
    end
    return data, nil, cid, title
end

local function officerOf(src, p)
    local u = Cad.units[src] or {}
    local ci = p.PlayerData.charinfo
    return u.name or ('%s %s'):format(ci.firstname, ci.lastname), u.callsign or ''
end

-- Partners of the officer writing the report (same callsign)
local function partners(src)
    local out = {}
    for _, m in ipairs(Cad.members and Cad.members(src) or {}) do
        local u = Cad.units[m]
        if m ~= src and u then out[#out + 1] = ('%s · %s'):format(u.callsign, u.name or '?') end
    end
    return out
end

local function needsApproval(rtype) return Config.Reports.RequireApproval[rtype] == true end

local function parentStatus(data)
    if data.parent_id and data.case_status then
        MySQL.update.await("UPDATE cad_records SET status = ? WHERE id = ? AND type IN ('crime', 'arrest', 'report')",
            { data.case_status, data.parent_id })
    end
end

local function notifyCid(cid, payload)
    local t = cid and cid ~= '' and exports.qbx_core:GetPlayerByCitizenId(cid)
    if t then TriggerClientEvent('ox_lib:notify', t.PlayerData.source, payload) end
end

reg('createRecord', function(src, p, d)
    local rtype = d.type
    if not Config.RecordTypes[rtype] or rtype == 'license' or type(d.data) ~= 'table' then
        return { ok = false, err = L('server.err_invalid_record') }
    end
    if not Cad.canReport(p, rtype) and rtype ~= 'report' then
        return { ok = false, err = L('server.err_report_type_write') }
    end
    local raw = d.data
    local data, err, cid, title = build(rtype, raw)
    if not data then return { ok = false, err = err } end

    local author, callsign = officerOf(src, p)
    data._officers = partners(src)
    -- Agency name and color come from the server (the client cannot change them)
    local dept = Cad.dept(p.PlayerData.job)
    data.dept, data._color = dept.name, dept.color

    local callId = tonumber(data.call_id)
    if callId and callId < 1 then callId = nil end
    local enc = json.encode(data)
    if #enc > 60000 then return { ok = false, err = L('server.err_record_too_long') } end

    local status = rtype == 'warrant' and 'ACTIVE' or (rtype == 'crime' and 'OPEN' or '')
    local review = needsApproval(rtype) and 'PENDING' or ''
    local id = MySQL.insert.await([[INSERT INTO cad_records
        (type, citizenid, title, status, review, call_id, author, author_cid, callsign, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], { rtype, cid, title, status, review, callId,
        author, p.PlayerData.citizenid or '', callsign, enc })
    if not id then return { ok = false, err = L('server.err_record_insert') } end
    if rtype == 'followup' then parentStatus(data) end

    local info = {}
    -- If linked to an active call, leave a note in the call log
    local c = callId and Cad.calls[callId]
    if c then
        Cad.addLog(c, L('server.log_record_added', TYPE_LABEL[rtype], id, callsign ~= '' and callsign or '?'))
        Cad.saveLog(c)
        Cad.broadcast()
    end

    -- Fine / jail (only on the first save)
    if rtype == 'arrest' or rtype == 'citation' then
        local t = data.totals
        local target = exports.qbx_core:GetPlayerByCitizenId(cid)
        if raw.applyFine and Config.Fines.Enabled and t.fine > 0 then
            if not target then
                info[#info + 1] = L('server.info_not_ingame')
            elseif chargeMoney(target, t.fine, ('CAD %s #%d'):format(TYPE_LABEL[rtype], id)) then
                info[#info + 1] = L('server.info_fine_collected', t.fine)
            else
                info[#info + 1] = L('server.info_fine_failed')
            end
        end
        if rtype == 'arrest' and t.jail > 0 then
            if raw.applyJail and Config.Jail.Enabled and target then
                local ok, e = pcall(Config.Jail.Hook, target.PlayerData.source, t.jail, src, id)
                info[#info + 1] = ok and L('server.info_jail_applied', t.jail) or L('server.info_jail_failed')
                if not ok then print(L('server.err_jail_hook', tostring(e))) end
            else
                info[#info + 1] = L('server.info_jail_manual', t.jail)
            end
        end
        if target then
            TriggerClientEvent('ox_lib:notify', target.PlayerData.source, { title = L('server.notify_record_title'), type = 'inform', duration = 10000,
                description = L('server.notify_record_body', TYPE_LABEL[rtype]:lower(), line(data.charges, 150)) })
        end
    end
    if review == 'PENDING' then info[#info + 1] = L('server.info_sent_for_approval') end
    Cad.activity(src, 'report', ('%s #%d · %s'):format(TYPE_LABEL[rtype], id, line(title, 60)))
    return { ok = true, id = id, info = table.concat(info, ' ') }
end)

local function canEdit(p, r)
    if Cad.can(p, 'approveReport') then return true end
    return r.author_cid ~= '' and r.author_cid == p.PlayerData.citizenid and r.review ~= 'APPROVED'
end

local function canReview(p, r)
    if r.review ~= 'PENDING' or not Cad.can(p, 'approveReport') then return false end
    return Config.Reports.SelfApprove or r.author_cid ~= p.PlayerData.citizenid
end

reg('updateRecord', function(src, p, d)
    local r = MySQL.single.await('SELECT id, type, review, author_cid, citizenid, data FROM cad_records WHERE id = ?', { tonumber(d.id) })
    if not r or r.type == 'license' or type(d.data) ~= 'table' then return { ok = false, err = L('server.err_record_not_found') } end
    if not canEdit(p, r) then return { ok = false, err = L('server.err_edit_perm') } end
    if not Cad.canReport(p, r.type) and not Cad.can(p, 'approveReport') then
        return { ok = false, err = L('server.err_report_type_edit') }
    end
    local data, err, cid, title = build(r.type, d.data)
    if not data then return { ok = false, err = err } end
    local old = jdecode(r.data, {})
    data._officers = old._officers or {}
    data.dept, data._color = old.dept or data.dept, old._color
    local author = officerOf(src, p)
    data._edited = ('%s · %s'):format(author, os.date(Config.DateFormat))
    local enc = json.encode(data)
    if #enc > 60000 then return { ok = false, err = L('server.err_record_too_long') } end
    -- If the author edits, it goes back for approval; if a supervisor edits, the approval status is kept
    local review = r.review
    if needsApproval(r.type) and r.author_cid == p.PlayerData.citizenid and not Cad.can(p, 'approveReport') then
        review = 'PENDING'
    end
    MySQL.update.await('UPDATE cad_records SET citizenid = ?, title = ?, review = ?, data = ? WHERE id = ?',
        { cid, title, review, enc, r.id })
    if r.type == 'followup' then parentStatus(data) end
    return { ok = true, id = r.id, info = review == 'PENDING' and L('server.info_resubmitted') or '' }
end)

reg('reviewRecord', function(src, p, d)
    local r = MySQL.single.await('SELECT id, type, review, author_cid FROM cad_records WHERE id = ?', { tonumber(d.id) })
    if not r then return { ok = false, err = L('server.err_record_not_found') } end
    if not canReview(p, r) then
        return { ok = false, err = Cad.can(p, 'approveReport') and L('server.err_self_approve') or L('server.err_approve_perm') }
    end
    local approve = d.action == 'approve'
    local note = line(d.note, 255)
    if not approve and note == '' then return { ok = false, err = L('server.err_correction_note') } end
    local name, cs = officerOf(src, p)
    MySQL.update.await('UPDATE cad_records SET review = ?, reviewer = ?, review_note = ? WHERE id = ?',
        { approve and 'APPROVED' or 'RETURNED', line(('%s · %s'):format(cs, name), 64), note, r.id })
    notifyCid(r.author_cid, { title = L('server.notify_report_title', r.id), type = approve and 'success' or 'error', duration = 10000,
        description = approve and L('server.notify_approved') or L('server.notify_returned', note) })
    return { ok = true }
end)

local LIST_COLS = [[r.id, r.type, r.title, r.status, r.review, r.review_note, r.author, r.callsign, r.call_id,
    UNIX_TIMESTAMP(r.created_at) * 1000 AS created, %s AS firstname, %s AS lastname]]

local function listRows(where, params)
    local rows = MySQL.query.await(('SELECT ' .. LIST_COLS .. [[ FROM cad_records r
        LEFT JOIN players p ON p.citizenid = r.citizenid WHERE %s ORDER BY r.id DESC LIMIT 100]])
        :format(FN:format('p'), LN:format('p'), where), params) or {}
    for _, r in ipairs(rows) do r.typeLabel = TYPE_LABEL[r.type] or r.type end
    return rows
end

reg('myReports', function(_, p)
    return listRows("r.author_cid = ? AND r.type <> 'license'", { p.PlayerData.citizenid })
end)

reg('pendingReports', function(_, p)
    if not Cad.can(p, 'approveReport') then return {} end
    return listRows("r.review = 'PENDING'", {})
end)

reg('reportCounts', function(_, p)
    local pending = Cad.can(p, 'approveReport')
        and (MySQL.scalar.await("SELECT COUNT(*) FROM cad_records WHERE review = 'PENDING'") or 0) or 0
    local returned = MySQL.scalar.await("SELECT COUNT(*) FROM cad_records WHERE review = 'RETURNED' AND author_cid = ?",
        { p.PlayerData.citizenid }) or 0
    return { pending = tonumber(pending) or 0, returned = tonumber(returned) or 0 }
end)

-- Summary of the original report in the follow-up investigation form
reg('recordBrief', function(_, _, d)
    local r = MySQL.single.await(([[SELECT r.id, r.type, r.title, r.status, r.citizenid, r.data,
        UNIX_TIMESTAMP(r.created_at) * 1000 AS created, %s AS firstname, %s AS lastname
        FROM cad_records r LEFT JOIN players p ON p.citizenid = r.citizenid WHERE r.id = ?]]):format(FN:format('p'), LN:format('p')),
        { tonumber(d.id) })
    if not r or not (r.type == 'crime' or r.type == 'arrest' or r.type == 'report') then
        return { ok = false, err = L('server.err_no_crime_report') }
    end
    local data = jdecode(r.data, {})
    return { ok = true, id = r.id, type = r.type, typeLabel = TYPE_LABEL[r.type], title = r.title, status = r.status,
        created = r.created, victim = data.v_name or '', citizenid = r.citizenid,
        person = r.firstname and (r.firstname .. ' ' .. (r.lastname or '')) or '' }
end)

reg('recordDetail', function(_, p, d)
    local r = MySQL.single.await(([[SELECT r.id, r.type, r.citizenid, r.title, r.status, r.review, r.reviewer, r.review_note,
        r.call_id, r.author, r.author_cid, r.callsign, r.data,
        UNIX_TIMESTAMP(r.created_at) * 1000 AS created, %s AS firstname, %s AS lastname
        FROM cad_records r LEFT JOIN players p ON p.citizenid = r.citizenid WHERE r.id = ?]]):format(FN:format('p'), LN:format('p')),
        { tonumber(d.id) })
    if not r then return { ok = false, err = L('server.err_record_not_found') } end
    r.data = jdecode(r.data, {})
    if r.type == 'warrant' and r.status == 'ACTIVE' and isExpired(r.data) then r.status = 'EXPIRED' end
    r.typeLabel = TYPE_LABEL[r.type] or r.type
    r.canEdit = r.type ~= 'license' and canEdit(p, r) or false
    r.canReview = canReview(p, r)
    r.isAuthor = r.author_cid ~= '' and r.author_cid == p.PlayerData.citizenid
    if r.type == 'crime' or r.type == 'arrest' or r.type == 'report' then
        r.followups = MySQL.query.await([[SELECT id, title, review, author, callsign, data,
            UNIX_TIMESTAMP(created_at) * 1000 AS created FROM cad_records
            WHERE type = 'followup' AND JSON_EXTRACT(data, '$.parent_id') = ? ORDER BY id]], { r.id }) or {}
        for _, f in ipairs(r.followups) do
            f.case_status = jdecode(f.data, {}).case_status
            f.data = nil
        end
    end
    r.author_cid = nil
    r.ok = true
    return r
end)

reg('deleteRecord', function(_, p, d)
    if not Cad.can(p, 'deleteRecord') then return { ok = false, err = L('server.err_delete_perm') } end
    MySQL.update.await('DELETE FROM cad_records WHERE id = ?', { tonumber(d.id) })
    return { ok = true }
end)

------------------------------------------------------------------ Warrants
reg('setWarrant', function(src, p, d)
    local id, st = tonumber(d.id), d.status
    if st ~= 'SERVED' and st ~= 'VOID' then return { ok = false, err = L('server.err_invalid_action') } end
    if st == 'VOID' and not Cad.can(p, 'voidWarrant') then return { ok = false, err = L('server.err_void_perm') } end
    local r = MySQL.single.await("SELECT data, status FROM cad_records WHERE id = ? AND type = 'warrant'", { id })
    if not r or r.status ~= 'ACTIVE' then return { ok = false, err = L('server.err_no_active_warrant') } end
    local data = jdecode(r.data, {})
    local u = Cad.units[src] or {}
    data.closedBy = line(('%s %s'):format(u.callsign or '', u.name or ''), 80)
    data.closedAt = os.date(Config.DateFormat)
    MySQL.update.await('UPDATE cad_records SET status = ?, data = ? WHERE id = ?', { st, json.encode(data), id })
    return { ok = true }
end)

-- Wanted list: active warrants + person BOLOs + vehicle BOLOs
reg('wanted', function()
    local warrants = {}
    local rows = MySQL.query.await(([[SELECT r.id, r.citizenid, r.title, r.author, r.callsign, r.data,
        UNIX_TIMESTAMP(r.created_at) * 1000 AS created, %s AS firstname, %s AS lastname
        FROM cad_records r LEFT JOIN players p ON p.citizenid = r.citizenid
        WHERE r.type = 'warrant' AND r.status = 'ACTIVE' ORDER BY r.id DESC LIMIT 100]]):format(FN:format('p'), LN:format('p'))) or {}
    for _, r in ipairs(rows) do
        local data = jdecode(r.data, {})
        warrants[#warrants + 1] = { id = r.id, citizenid = r.citizenid, name = ('%s %s'):format(r.firstname or '?', r.lastname or ''),
            title = r.title, author = r.author, callsign = r.callsign, created = r.created,
            expires = data.expires or '', expired = isExpired(data), flags = data.flags }
    end
    local persons = MySQL.query.await([[SELECT id, citizenid, name, reason, author, UNIX_TIMESTAMP(created_at) * 1000 AS created
        FROM cad_bolos WHERE kind = 'person' AND active = 1 ORDER BY id DESC LIMIT 100]]) or {}
    local vehicles = MySQL.query.await([[SELECT id, plate, reason, author, UNIX_TIMESTAMP(created_at) * 1000 AS created
        FROM cad_bolos WHERE kind = 'vehicle' AND active = 1 ORDER BY id DESC LIMIT 100]]) or {}
    return { warrants = warrants, persons = persons, vehicles = vehicles }
end)

------------------------------------------------------------------ BOLO (vehicle + person)
reg('setBolo', function(src, _, d)
    local u = Cad.units[src] or {}
    if d.kind == 'person' then
        local cid = line(d.citizenid, 50)
        if cid == '' then return { ok = false } end
        MySQL.update.await("UPDATE cad_bolos SET active = 0 WHERE kind = 'person' AND citizenid = ? AND active = 1", { cid })
        if d.active then
            local name = MySQL.scalar.await(([[SELECT CONCAT(%s, ' ', %s) FROM players WHERE citizenid = ?]])
                :format(FN:format('players'), LN:format('players')), { cid }) or ''
            MySQL.insert.await("INSERT INTO cad_bolos (kind, plate, citizenid, name, reason, author) VALUES ('person', '', ?, ?, ?, ?)",
                { cid, line(name, 64), line(d.reason, 255), u.name or '' })
            Cad.refreshBolos()
            Cad.pushTicker('bolo', L('server.ticker_person_bolo', line(name, 64), line(d.reason, 120), u.callsign or ''))
        else
            Cad.refreshBolos() Cad.broadcast()
        end
        return { ok = true }
    end
    local plate = normPlate(d.plate)
    if plate == '' then return { ok = false } end
    MySQL.update.await("UPDATE cad_bolos SET active = 0 WHERE kind = 'vehicle' AND plate = ? AND active = 1", { plate })
    if d.active then
        MySQL.insert.await("INSERT INTO cad_bolos (kind, plate, reason, author) VALUES ('vehicle', ?, ?, ?)",
            { plate, line(d.reason, 255), u.name or '' })
        Cad.refreshBolos()
        Cad.pushTicker('bolo', L('server.ticker_vehicle_bolo', plate, line(d.reason, 120), u.callsign or ''))
    else
        Cad.refreshBolos() Cad.broadcast()
    end
    return { ok = true }
end)

-- exports['knb_cad']:IsPlateBolo('ABC123') -> reason | false
exports('IsPlateBolo', function(plate)
    local r = MySQL.scalar.await("SELECT reason FROM cad_bolos WHERE kind = 'vehicle' AND plate = ? AND active = 1 LIMIT 1", { normPlate(plate) })
    return r or false
end)

-- exports['knb_cad']:IsWanted(citizenid) -> true | false
exports('IsWanted', function(cid)
    return wantedSet({ tostring(cid or '') })[tostring(cid or '')] or false
end)

------------------------------------------------------------------ Call history + reports
reg('callHistory', function(_, _, d)
    local q = line(d.q, 64)
    local where, params = { "status = 'CLOSED'" }, {}
    if q ~= '' then
        local n = tonumber(q)
        if n then
            where[#where + 1] = 'id = ?'
            params[#params + 1] = n
        else
            where[#where + 1] = '(title LIKE ? OR address LIKE ? OR caller LIKE ? OR code LIKE ? OR postal = ?)'
            local l = '%' .. q .. '%'
            params[#params + 1], params[#params + 2], params[#params + 3], params[#params + 4], params[#params + 5] = l, l, l, l, q
        end
    end
    return MySQL.query.await(([[SELECT id, code, title, priority, status, address, postal, area, agency, caller,
        UNIX_TIMESTAMP(created_at) * 1000 AS created FROM cad_calls WHERE %s ORDER BY id DESC LIMIT 100]])
        :format(table.concat(where, ' AND ')), params) or {}
end)

reg('historyCall', function(_, _, d)
    local id = tonumber(d.id)
    local c = MySQL.single.await([[SELECT id, code, title, priority, status, address, postal, area, county, agency, caller,
        vehicle, log, UNIX_TIMESTAMP(created_at) * 1000 AS created FROM cad_calls WHERE id = ?]], { id })
    if not c then return { ok = false, err = L('server.err_call_not_found') } end
    c.log = jdecode(c.log, {})
    c.vehicle = jdecode(c.vehicle, {})
    c.records = MySQL.query.await([[SELECT id, type, title, author, callsign, UNIX_TIMESTAMP(created_at) * 1000 AS created
        FROM cad_records WHERE call_id = ? ORDER BY id]], { id }) or {}
    for _, r in ipairs(c.records) do r.typeLabel = TYPE_LABEL[r.type] or r.type end
    c.ok = true
    return c
end)

reg('reports', function(_, _, d)
    local q = line(d.q, 64)
    local where, params = "r.type IN ('crime', 'followup', 'report')", {}
    if q ~= '' then
        local l = '%' .. q .. '%'
        where = where .. ' AND (r.title LIKE ? OR r.author LIKE ? OR r.callsign LIKE ? OR r.call_id = ? OR r.id = ?)'
        params = { l, l, l, tonumber(q) or -1, tonumber(q) or -1 }
    end
    return listRows(where, params)
end)

------------------------------------------------------------------ Table check
CreateThread(function()
    local function cols(t)
        local ok, rows = pcall(MySQL.query.await, 'SHOW COLUMNS FROM ' .. t)
        local have = {}
        for _, c in ipairs(ok and rows or {}) do have[c.Field] = true end
        return have
    end
    local missing = {}
    local r, b = cols('cad_records'), cols('cad_bolos')
    for _, f in ipairs({ 'title', 'status', 'call_id' }) do if not r[f] then missing[#missing + 1] = 'cad_records.' .. f end end
    local v5 = {}
    for _, f in ipairs({ 'review', 'reviewer', 'review_note', 'author_cid' }) do if not r[f] then v5[#v5 + 1] = 'cad_records.' .. f end end
    if #v5 > 0 then
        print(L('server.err_missing_cols', table.concat(v5, ', ')))
        print(L('server.err_run_sql'))
    end
    for _, f in ipairs({ 'kind', 'citizenid', 'name' }) do if not b[f] then missing[#missing + 1] = 'cad_bolos.' .. f end end
    if #missing > 0 then
        print(L('server.err_missing_cols', table.concat(missing, ', ')))
        print(L('server.err_run_sql'))
    end
end)
