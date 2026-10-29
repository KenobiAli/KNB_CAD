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

Cad = Cad or {}

local units, calls, viewers, lastCall = {}, {}, {}, {}
Cad.units, Cad.calls, Cad.viewers = units, calls, viewers

------------------------------------------------------------------ Helpers
-- Shortens without splitting a UTF-8 character in the middle
local function cut(s, n)
    if #s <= n then return s end
    s = s:sub(1, n)
    while #s > 0 and not utf8.len(s) do s = s:sub(1, -2) end
    return s
end

local function clean(s, n)
    return cut(tostring(s or ''), n)
end

-- Single-line field: strips control characters and trims the edges
local function line(s, n)
    local v = tostring(s or ''):gsub('%c', ' ')
    return cut(v:match('^%s*(.-)%s*$'), n)
end
Cad.line = line

local function normPlate(s)
    return line(s, 12):upper()
end
Cad.clean, Cad.normPlate = clean, normPlate

local function toXYZ(v)
    local t = type(v)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local x, y = tonumber(v.x), tonumber(v.y)
    if not x or not y then return nil end
    return { x = x + 0.0, y = y + 0.0, z = (tonumber(v.z) or 0.0) + 0.0 }
end
Cad.toXYZ = toXYZ

local function stamp() return os.date(Config.DateFormat) end

local function ulen(s) return utf8.len(s) or #s end

-- Splits text into lines of at most `width` characters (does not split words)
local function wrap(text, width)
    local out = {}
    for para in (tostring(text or '') .. '\n'):gmatch('(.-)\r?\n') do
        local cur = ''
        for word in para:gmatch('%S+') do
            if cur == '' then
                cur = word
            elseif ulen(cur) + 1 + ulen(word) <= width then
                cur = cur .. ' ' .. word
            else
                out[#out + 1] = cur
                cur = word
            end
        end
        if cur ~= '' then out[#out + 1] = cur end
    end
    return out
end

local MAX_LOG = 80
local function addLog(c, text)
    for _, l in ipairs(wrap(text, 70)) do c.log[#c.log + 1] = l end
    while #c.log > MAX_LOG do table.remove(c.log, 2) end -- the first line (INCIDENT OPENED) is kept
end
Cad.addLog = addLog

local function saveLog(c)
    MySQL.update('UPDATE cad_calls SET log = ? WHERE id = ?', { json.encode(c.log), c.id })
end
Cad.saveLog = saveLog

local function allowedJob(job)
    return job and (Config.Jobs[job.name] or Config.JobTypes[job.type]) and true or false
end

local function allowed(p)
    return allowedJob(p and p.PlayerData.job)
end
Cad.allowed = allowed

local function access(src)
    local p = exports.qbx_core:GetPlayer(src)
    if allowed(p) then return p end
end

-- Grade permission: Config.Permissions[action] = minimum job grade level required
function Cad.grade(p)
    local g = p and p.PlayerData.job.grade
    return (type(g) == 'table' and tonumber(g.level)) or tonumber(g) or 0
end

function Cad.can(p, action)
    return Cad.grade(p) >= (Config.Permissions[action] or 0)
end

local function jobMatch(jobs, job)
    if not jobs or #jobs == 0 then return true end
    if not job then return false end
    for _, j in ipairs(jobs) do
        if j == job.name or j == job.type then return true end
    end
    return false
end

-- The player's department settings (Config.Departments)
function Cad.dept(job)
    if not job then return nil end
    local d = Config.Departments[job.name] or Config.Departments[Config.DepartmentByType[job.type] or '']
    if d then return d end
    return { name = (job.label or job.name or 'DEPARTMENT'):upper(), short = job.label or job.name, color = '#1f3a6e',
        pages = { 'dash', 'map', 'lookup', 'records', 'wanted', 'messages', 'units', 'history' },
        reports = { 'arrest', 'crime', 'followup', 'citation', 'warrant' } }
end

local function listHas(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

function Cad.hasPage(p, page)
    local d = Cad.dept(p and p.PlayerData.job)
    return d ~= nil and listHas(d.pages, page)
end

function Cad.canReport(p, rtype)
    local d = Cad.dept(p and p.PlayerData.job)
    return d ~= nil and listHas(d.reports, rtype)
end

local function agencyOf(job)
    local d = Cad.dept(job)
    return d and d.short or job.label or job.name
end
Cad.agencyOf = agencyOf

-- Callback -> required page(s). If the unit has none of those pages, the request is rejected.
local PAGE_OF = {
    lookup = { 'lookup' }, lookupVehicle = { 'lookup' }, lookupWeapon = { 'lookup' }, quickPlate = { 'lookup' }, profile = { 'lookup' },
    setLicense = { 'lookup' }, setBolo = { 'lookup', 'wanted' },
    createRecord = { 'records' }, updateRecord = { 'records' }, reviewRecord = { 'records' }, myReports = { 'records' },
    pendingReports = { 'records' }, reportCounts = { 'records' }, recordBrief = { 'records' }, deleteRecord = { 'records' },
    recordDetail = { 'records', 'lookup', 'wanted', 'history' }, setWarrant = { 'records', 'wanted', 'lookup' },
    wanted = { 'wanted' }, callHistory = { 'history' }, historyCall = { 'history' }, reports = { 'history' },
    messages = { 'messages' }, sendMessage = { 'messages' },
}

local function pageAllowed(p, name)
    local need = PAGE_OF[name]
    if not need then return true end
    for _, pg in ipairs(need) do if Cad.hasPage(p, pg) then return true end end
    return false
end

local NO_CALLSIGN = { [''] = true, ['NEW UNIT'] = true, ['NO CALLSIGN'] = true, ['NEWUNIT'] = true, ['NOCALLSIGN'] = true }

-- Is it a valid callsign? (empty / default values do not count)
function Cad.validCallsign(cs)
    return type(cs) == 'string' and not NO_CALLSIGN[cs:upper()]
end

function Cad.savedCallsign(p)
    local cs = p and p.PlayerData.metadata and p.PlayerData.metadata.callsign
    if Cad.validCallsign(cs) then return line(cs, 12):upper() end
end

------------------------------------------------------------------ Shift (MDC "My Shift")
local function newShift()
    return { start = os.time(), totals = {}, acts = {}, calls = 0, queries = 0, hits = 0 }
end

-- Adds a line to the unit's shift activity. kind: status key or 'query', 'hit', 'call', 'report', 'info'
local function activity(u, kind, text)
    if not u or not u.shift then return end
    local a = u.shift.acts
    a[#a + 1] = { t = os.time(), k = kind, text = line(text, 140) }
    while #a > 40 do table.remove(a, 1) end
end
Cad.activity = function(src, kind, text) activity(units[src], kind, text) end

-- Status change: the time spent in that status is added to the shift totals
local function setUnitStatus(u, st, note)
    if not u or u.status == st then return end
    local now = os.time()
    if u.shift then
        u.shift.totals[u.status] = (u.shift.totals[u.status] or 0) + (now - (u.statusSince or now))
    end
    u.status, u.statusSince = st, now
    local info = Config.StatusInfo[st]
    activity(u, st, (info and info.label or st) .. (note and (' · ' .. note) or ''))
end
Cad.setUnitStatus = setUnitStatus

function Cad.shiftQuery(src, text, hit)
    local u = units[src]
    if not u or not u.shift then return end
    u.shift.queries = u.shift.queries + 1
    if hit then u.shift.hits = u.shift.hits + 1 end
    activity(u, hit and 'hit' or 'query', L('server.shift_query', text, hit and ' → HIT' or ''))
end

local function ensureUnit(src, p)
    local u = units[src]
    if not u then
        -- A previously chosen callsign is stored in the player data
        local saved = Cad.savedCallsign(p)
        u = { src = src, callsign = saved or 'NEW UNIT', status = Config.Statuses[1], statusSince = os.time(), shift = newShift() }
        units[src] = u
        activity(u, 'AVAILABLE', L('server.went_on_duty_cs', u.callsign))
    end
    local ci, job = p.PlayerData.charinfo, p.PlayerData.job
    u.name = ('%s %s'):format(ci.firstname, ci.lastname)
    u.dept = job.label
    u.agency = agencyOf(job)
    u.rank = job.grade and job.grade.name or '-'
    u.job = job.name
    u.cid = p.PlayerData.citizenid
    return u
end

local function cleanVehicle(v)
    if type(v) ~= 'table' then return nil end
    local r = { plate = normPlate(v.plate), color = line(v.color, 32), make = line(v.make, 32), model = line(v.model, 32),
        class = line(v.class, 24), doors = tonumber(v.doors), heading = line(v.heading, 16) }
    if r.plate == '' and r.color == '' and r.make == '' and r.model == '' then return nil end
    return r
end

local function vehicleLine(v)
    local parts = {}
    local mm = line(('%s %s'):format(v.make or '', v.model or ''), 64)
    if mm ~= '' then parts[#parts + 1] = L('server.veh_vehicle', mm) end
    if v.color ~= '' then parts[#parts + 1] = L('server.veh_color', v.color) end
    if v.class and v.class ~= '' then parts[#parts + 1] = L('server.veh_class', v.class, v.doors and L('server.veh_doors', v.doors) or '') end
    if v.plate ~= '' then parts[#parts + 1] = L('server.veh_plate', v.plate) end
    return table.concat(parts, ' | ')
end

local function cleanJobs(j)
    if type(j) ~= 'table' then return nil end
    local r = {}
    for i = 1, math.min(#j, 8) do
        local v = line(j[i], 32)
        if v ~= '' then r[#r + 1] = v end
    end
    return #r > 0 and r or nil
end


------------------------------------------------------------------ General broadcast ticker + BOLO list
local ticker = {}
function Cad.pushTicker(kind, text)
    table.insert(ticker, 1, { t = os.time(), time = os.date('%H:%M'), kind = kind, text = line(text, 180) })
    while #ticker > 6 do table.remove(ticker) end
    if Cad.broadcast then Cad.broadcast() end
end

local boloCache = {}
function Cad.refreshBolos()
    local ok, rows = pcall(MySQL.query.await, [[SELECT kind, plate, name, citizenid, reason, author,
        UNIX_TIMESTAMP(created_at) AS t FROM cad_bolos WHERE active = 1 ORDER BY id DESC LIMIT 8]])
    boloCache = ok and rows or {}
end

------------------------------------------------------------------ State broadcast
local function callState(c)
    local cs, seenCs = {}, {}
    for src in pairs(c.units) do
        local u = units[src]
        if u and not seenCs[u.callsign] then
            seenCs[u.callsign] = true
            cs[#cs + 1] = u.callsign
        end
    end
    table.sort(cs)
    local a = c.alert or {}
    return { id = c.id, code = c.code, title = c.title, priority = c.priority, status = c.status,
        address = c.address, postal = c.postal, area = c.area, county = c.county, agency = c.agency,
        caller = c.caller, message = c.message, vehicle = c.vehicle, units = cs, logCount = #c.log,
        time = os.date('%H:%M', c.created), created = c.created, times = c.times,
        x = c.hasCoords and c.coords.x or nil, y = c.hasCoords and c.coords.y or nil,
        radius = c.blip.radius, approx = c.approx or nil, critical = c.critical or nil, hotspot = c.hotspot,
        count = c.count or 1, icon = c.icon, system = c.system or nil, ever = c.ever or nil, flags = c.flags,
        weapon = a.weapon, gender = a.gender, heading = a.heading, camId = a.camId }
end
Cad.callState = callState

local function unitState(u)
    local c = u.callId and calls[u.callId]
    return { src = u.src, callsign = u.callsign, name = u.name, dept = u.dept, agency = u.agency, job = u.job,
        rank = u.rank, status = u.status, since = u.statusSince, callId = u.callId, location = c and c.address or '' }
end

local function sortCalls(a, b)
    if (a.critical and 1 or 0) ~= (b.critical and 1 or 0) then return a.critical == true end
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.id > b.id
end

local function buildState(job)
    local cl, ul = {}, {}
    for _, c in pairs(calls) do
        if jobMatch(c.jobs, job) then cl[#cl + 1] = callState(c) end
    end
    table.sort(cl, sortCalls)
    for _, u in pairs(units) do ul[#ul + 1] = unitState(u) end
    table.sort(ul, function(a, b) return a.callsign < b.callsign end)
    local d = Cad.dept(job)
    local seesWanted = d and listHas(d.pages, 'wanted')
    return { calls = cl, units = ul, statuses = Config.Statuses, templates = Config.CallTemplates,
        counties = Config.Counties, serverTime = os.time(), ticker = ticker, bolos = seesWanted and boloCache or {} }
end

local function broadcast()
    local cache = {}
    for src, job in pairs(viewers) do
        local k = tostring(job.name) .. '|' .. tostring(job.type)
        cache[k] = cache[k] or buildState(job)
        TriggerClientEvent('cad:update', src, cache[k])
    end
end
Cad.broadcast = broadcast

------------------------------------------------------------------ Unit <-> call
-- Units with the same callsign form a team (partners in the same vehicle).
-- When one team member joins / leaves a call / changes status, it is applied to the others as well.
local function members(src)
    local u = units[src]
    if not (Config.CallsignGroups and u and Cad.validCallsign(u.callsign)) then return { src } end
    local list = {}
    for s2, u2 in pairs(units) do
        if u2.callsign == u.callsign then list[#list + 1] = s2 end
    end
    return list
end
Cad.members = members

-- Is there any other unit left on the call with this callsign?
local function callsignOnCall(c, cs)
    for s2 in pairs(c.units) do
        if units[s2] and units[s2].callsign == cs then return true end
    end
    return false
end

-- Timestamp of the call (the first time it happens)
local function stampTime(c, key)
    c.times = c.times or {}
    if not c.times[key] then c.times[key] = os.time() end
end

-- Removes a single unit from its call (writes no log); returns the call it was removed from
local function leave(src)
    local u = units[src]
    local c = u and u.callId and calls[u.callId]
    if c then c.units[src] = nil end
    if u then u.callId = nil end
    return c
end

local function attach(src, id)
    local u, c = units[src], calls[id]
    if not u or not c then return false end
    local group = members(src)
    local left = {}
    for _, m in ipairs(group) do
        local mu = units[m]
        if mu.callId ~= id then
            local old = leave(m)
            if old then left[old] = true end
            mu.callId = id
            setUnitStatus(mu, 'EN ROUTE', ('#%d %s'):format(c.id, c.title))
            if mu.shift then mu.shift.calls = mu.shift.calls + 1 end
            c.units[m] = true
        end
    end
    for old in pairs(left) do
        if not callsignOnCall(old, u.callsign) then
            addLog(old, L('server.log_left', u.callsign))
            saveLog(old)
        end
    end
    c.ever = true
    stampTime(c, 'dispatched')
    stampTime(c, 'enroute')
    local names = {}
    for _, m in ipairs(group) do names[#names + 1] = units[m].name end
    addLog(c, L('server.log_assigned', u.callsign,
        #group > 1 and (' (' .. table.concat(names, ', ') .. ')') or ''))
    saveLog(c)
    return true
end
Cad.attach = attach

-- single = true: only this player (going off duty, leaving the game etc.), otherwise the whole team
local function detach(src, silent, single)
    local u = units[src]
    if not u then return end
    local group = single and { src } or members(src)
    local touched = {}
    for _, m in ipairs(group) do
        local c = leave(m)
        if c then touched[c] = true end
        setUnitStatus(units[m], Config.Statuses[1])
    end
    if silent then return end
    for c in pairs(touched) do
        if not callsignOnCall(c, u.callsign) then
            addLog(c, L('server.log_left', u.callsign))
            saveLog(c)
        end
    end
end

------------------------------------------------------------------ Creating calls
local function alertPayload(call, extra)
    local st = callState(call)
    st.coords = call.hasCoords and call.coords or nil
    st.sprite, st.color = call.blip.sprite, call.blip.color
    for k, v in pairs(extra or {}) do st[k] = v end
    st.except = nil
    return st
end

-- Sends a notification + blip + sound to all on-duty units whose job matches
local function alertUnits(call, extra)
    local payload = alertPayload(call, extra)
    local except = extra and extra.except or {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local p = exports.qbx_core:GetPlayer(src)
        local job = p and p.PlayerData.job
        if not except[src] and allowedJob(job) and job.onduty and jobMatch(call.jobs, job) then
            TriggerClientEvent('cad:newCall', src, payload)
        end
    end
end
Cad.alertUnits = alertUnits

local function sendToCallJobs(call, event, payload)
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local p = exports.qbx_core:GetPlayer(src)
        local job = p and p.PlayerData.job
        if allowedJob(job) and job.onduty and jobMatch(call.jobs, job) then
            TriggerClientEvent(event, src, payload)
        end
    end
end
Cad.sendToCallJobs = sendToCallJobs

local CALL_STATUS = { ACTIVE = true, PENDING = true }

-- When the client does not send the county, it is estimated from the coordinates (not tied to the postal number)
local function countyAt(co)
    return (co and co.y >= Config.BlaineMinY) and 'BLAINE' or 'LOS SANTOS'
end

-- Approximate location: the real point is shown with a random offset that does not exceed the radius.
-- The area is uniformly distributed (sqrt) — so officers do not get into the habit of "always searching the middle". The real coordinates never go to the client.
local function offsetVec(radius)
    local o = Config.Dispatch.Offset
    local minOff, maxOff = math.max(0, o.Min or 0), math.max(0, o.Max or 100)
    if radius and radius > 0 then maxOff = math.min(maxOff, radius) end
    if minOff > maxOff then minOff = 0 end
    local u = math.random()
    local dist = math.sqrt(minOff * minOff + u * (maxOff * maxOff - minOff * minOff))
    local ang = math.random() * math.pi * 2
    return { x = math.cos(ang) * dist, y = math.sin(ang) * dist }
end

-- Hot spot: many separate calls on the same street in a short time
local recentStreets = {}
local function streetKey(addr)
    local s = tostring(addr or ''):match('^([^/]+)') or ''
    return s:match('^%s*(.-)%s*$'):upper()
end
local function hotspotCount(addr)
    local h = Config.Dispatch.Hotspot
    local key = streetKey(addr)
    if not h or key == '' then return nil end
    local now, n, keep = os.time(), 1, {}
    for _, r in ipairs(recentStreets) do
        if now - r.t <= h.Window * 60 then
            keep[#keep + 1] = r
            if r.k == key then n = n + 1 end
        end
    end
    keep[#keep + 1] = { k = key, t = now }
    recentStreets = keep
    return n >= h.Threshold and n or nil
end

-- Officer safety warnings: vehicle plate has a BOLO / owner is wanted, weapon
local function computeFlags(call, d)
    local flags = {}
    for _, f in ipairs(type(d.flags) == 'table' and d.flags or {}) do flags[#flags + 1] = line(f, 120) end
    local v = call.vehicle
    if not d.flags and v and v.plate ~= '' and Cad.searchVehicles then
        local ok, rows = pcall(Cad.searchVehicles, v.plate, true)
        local r = ok and rows and rows[1]
        if r and r.bolo then flags[#flags + 1] = ('BOLO %s: %s'):format(v.plate, r.bolo.reason or '') end
        if r and r.ownerWanted then flags[#flags + 1] = L('server.flag_owner_warrant', v.plate) end
        if r and r.ownerBolo then flags[#flags + 1] = L('server.flag_owner_bolo', r.ownerBolo) end
    end
    local w = call.alert and call.alert.weapon
    if type(w) == 'table' and w.label then
        flags[#flags + 1] = L('server.flag_armed', w.label, w.auto and L('server.flag_auto_fire') or '')
    end
    return #flags > 0 and flags or nil
end

local function cleanWeapon(w)
    if type(w) ~= 'table' then return nil end
    local tier = math.floor(tonumber(w.tier) or 1)
    return { name = line(w.name, 32), label = line(w.label, 32), class = line(w.class, 12),
        tier = math.max(1, math.min(3, tier)), auto = w.auto and true or nil }
end

--[[ d = {
    code, title, priority (1-3), status ('ACTIVE'|'PENDING'), address, postal, area, county, agency,
    caller, message (may be multi-line), coords, vehicle = {plate,color,make,model,class,doors,heading},
    jobs = {'leo','ems',...}, extra = {'line', ...}, sprite, color, radius, system, silent,
    offset (approximate location), critical, icon, key (alert type), alert = {weapon, gender, heading, camId}, flags = {...}
} ]]
function Cad.createCall(d)
    local co = toXYZ(d.coords)
    local pr = math.floor(tonumber(d.priority) or 2)
    if pr < 1 or pr > 3 then pr = 2 end
    local radius = tonumber(d.radius)
    local display, vec = co, nil
    if co and d.offset then
        vec = offsetVec(radius)
        display = { x = co.x + vec.x, y = co.y + vec.y, z = co.z }
    end
    local postal = line(d.postal, 16)
    if (postal == '' or vec) and display then postal = Postal.nearest(display.x, display.y) end
    local county = line(d.county, 32):upper()
    if county == '' then county = countyAt(co) end
    local agency = line(d.agency, 32)
    if agency == '' then agency = Config.CountyAgency[county] or 'DISPATCH' end
    local msg = clean(d.message, 2000)
    local a = type(d.alert) == 'table' and d.alert or {}

    local call = {
        code = '', title = line(d.title, 128), priority = pr,
        status = CALL_STATUS[d.status] and d.status or 'ACTIVE',
        address = line(d.address, 128), postal = postal, area = line(d.area, 64), county = county, agency = agency,
        caller = line(d.caller, 64), message = line(msg, 255),
        coords = display or { x = 0.0, y = 0.0, z = 0.0 }, hasCoords = display ~= nil, trueCoords = co, offsetVec = vec,
        approx = vec ~= nil, critical = d.critical and true or nil, icon = line(d.icon, 8), key = d.key,
        vehicle = cleanVehicle(d.vehicle), jobs = cleanJobs(d.jobs), count = 1,
        alert = { weapon = cleanWeapon(a.weapon), gender = line(a.gender, 12), heading = line(a.heading, 16),
            camId = a.camId and line(a.camId, 16) or nil },
        units = {}, created = os.time(), times = { created = os.time() }, system = d.system and true or false,
        blip = { sprite = tonumber(d.sprite), color = tonumber(d.color), radius = radius },
        log = { L('server.log_opened', stamp()) },
    }
    if call.icon == '' then call.icon = nil end
    if call.alert.heading == '' then call.alert.heading = nil end
    if call.alert.gender == '' then call.alert.gender = nil end
    call.hotspot = hotspotCount(call.address)
    call.flags = computeFlags(call, d)

    if call.caller ~= '' then addLog(call, L('server.log_caller', call.caller)) end
    if msg ~= '' then addLog(call, msg) end
    if call.vehicle then addLog(call, vehicleLine(call.vehicle)) end
    if type(d.extra) == 'table' then
        for i = 1, math.min(#d.extra, 10) do addLog(call, line(d.extra[i], 200)) end
    end
    if call.approx then addLog(call, L('server.log_approx', math.floor(radius or Config.Dispatch.Offset.Max))) end
    if call.hotspot then addLog(call, L('server.log_hotspot', Config.Dispatch.Hotspot.Window, call.hotspot)) end

    local ok, insertId = pcall(MySQL.insert.await, [[INSERT INTO cad_calls
        (code, title, priority, status, address, postal, area, county, agency, caller, message, coords, vehicle, jobs, log)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
        call.code, call.title, call.priority, call.status, call.address, call.postal, call.area, call.county,
        call.agency, call.caller, call.message, json.encode(display or {}), json.encode(call.vehicle or {}),
        table.concat(call.jobs or {}, ','), json.encode(call.log) })
    if not ok or not insertId then
        print(L('server.err_call_insert', tostring(insertId)))
        return nil
    end
    call.id = insertId

    calls[call.id] = call
    if call.critical then
        Cad.pushTicker('critical', ('#%d %s · %s %s'):format(call.id, call.title, call.postal, call.address))
    end
    if not d.silent then alertUnits(call) end
    broadcast()
    return call
end

-- New alert from the same incident: the call counter (×N) goes up, the description is updated, escalates to Code 3 if needed
function Cad.mergeInto(c, d)
    c.count = (c.count or 1) + 1
    local co = toXYZ(d.coords)
    if co then
        c.trueCoords = co
        if c.offsetVec then
            c.coords = { x = co.x + c.offsetVec.x, y = co.y + c.offsetVec.y, z = co.z }
        else
            c.coords = co
        end
        c.hasCoords = true
    end
    local a = type(d.alert) == 'table' and d.alert or {}
    local w = cleanWeapon(a.weapon)
    if w then c.alert.weapon = w end
    if a.heading and a.heading ~= '' then c.alert.heading = line(a.heading, 16) end
    local v = cleanVehicle(d.vehicle)
    if v then c.vehicle = v end
    local esc = Config.Dispatch.Merge.EscalateAt or 0
    local escalated = false
    if esc > 0 and c.count >= esc and c.priority < 3 then
        c.priority, escalated = 3, true
        MySQL.update('UPDATE cad_calls SET priority = ? WHERE id = ?', { 3, c.id })
    end
    c.flags = computeFlags(c, { flags = c.flags })
    addLog(c, L('server.log_merge', os.date('%H:%M:%S'), c.count, escalated and L('server.log_escalated') or ''))
    if v then addLog(c, vehicleLine(v)) end
    saveLog(c)
    sendToCallJobs(c, 'cad:alertMerge', { id = c.id, count = c.count, priority = c.priority, escalated = escalated,
        coords = c.hasCoords and c.coords or nil, radius = c.blip.radius })
    broadcast()
    return c
end

local function closeCall(id, by)
    local c = calls[id]
    if not c then return false end
    for src in pairs(c.units) do detach(src, true, true) end
    calls[id] = nil
    addLog(c, L('server.log_closed', stamp(), by and (' (' .. by .. ')') or ''))
    MySQL.update('UPDATE cad_calls SET status = ?, log = ? WHERE id = ?', { 'CLOSED', json.encode(c.log), id })
    sendToCallJobs(c, 'cad:callClosed', id)
    broadcast()
    return true
end
Cad.closeCall = closeCall

-- Automatic alerts with no assigned unit close by themselves after a while
CreateThread(function()
    while true do
        Wait(60000)
        local mins = Config.Dispatch.AutoClose or 0
        if mins > 0 then
            local now = os.time()
            for id, c in pairs(calls) do
                if c.system and not c.ever and not c.critical and next(c.units) == nil and now - c.created >= mins * 60 then
                    closeCall(id, L('server.autoclose_by'))
                end
            end
        end
    end
end)

------------------------------------------------------------------ Callback registration
local function reg(name, fn)
    lib.callback.register('cad:' .. name, function(src, d)
        local p = access(src)
        if not p then return false end
        if not pageAllowed(p, name) then return { ok = false, err = L('server.err_no_section') } end
        -- Always answer the client even on errors (otherwise the UI locks up)
        local ok, res = pcall(fn, src, p, type(d) == 'table' and d or {})
        if not ok then
            print(L('server.err_callback', name, tostring(res)))
            return { ok = false, err = L('server.err_server') }
        end
        return res
    end)
end
Cad.reg = reg

RegisterNetEvent('cad:viewerClosed', function() viewers[source] = nil end)

------------------------------------------------------------------ Civilian calls (/911 /311)
local function hasPhone(src)
    for _, item in ipairs(Config.Dispatch.PhoneItems) do
        local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
        if ok and (tonumber(n) or 0) > 0 then return true end
    end
    return false
end

lib.callback.register('cad:publicCall', function(src, d)
    if type(d) ~= 'table' then return { ok = false } end
    local now = os.time()
    if lastCall[src] and now - lastCall[src] < Config.CallCooldown then
        return { ok = false, err = L('server.err_call_cooldown') }
    end
    local msg = line(d.message, 200)
    if msg == '' then return { ok = false, err = L('server.err_need_message') } end
    if Config.Dispatch.PhoneRequired and not hasPhone(src) then
        return { ok = false, err = L('server.err_need_phone') }
    end
    local kind = d.kind == '311' and '311' or '911'
    local caller = L('server.anonymous')
    local p = exports.qbx_core:GetPlayer(src)
    if p and not d.anon then
        caller = ('%s %s'):format(p.PlayerData.charinfo.firstname, p.PlayerData.charinfo.lastname)
        local phone = p.PlayerData.charinfo.phone
        if phone and phone ~= '' then caller = caller .. ' (' .. tostring(phone) .. ')' end
    end
    lastCall[src] = now
    -- The position is taken from the server (the coordinates sent by the client are not trusted)
    local co = toXYZ(GetEntityCoords(GetPlayerPed(src)))
    local ok, call = pcall(Cad.createCall, { title = kind == '911' and L('server.title_911') or L('server.title_311'),
        priority = kind == '911' and 2 or 1, caller = caller, message = msg,
        address = d.address, area = d.area, county = d.county, coords = co })
    if not ok then print(L('server.err_public_call', tostring(call))) end
    return { ok = ok and call ~= nil, err = (not ok or not call) and L('server.call_failed') or nil }
end)

------------------------------------------------------------------ Open / close the panel
reg('open', function(src, p)
    ensureUnit(src, p)
    local job = p.PlayerData.job
    viewers[src] = { name = job.name, type = job.type }
    broadcast()
    return { state = buildState(viewers[src]), meta = Cad.meta(p) }
end)

reg('close', function(src) viewers[src] = nil return true end)

------------------------------------------------------------------ Unit actions
local function validStatus(st)
    for _, s in ipairs(Config.Statuses) do if s == st then return true end end
    return false
end

local function applyStatus(src, st)
    local u = units[src]
    if st == Config.OffDutyStatus then
        -- Leaving duty is personal; the partner can continue
        detach(src, false, true)
        setUnitStatus(u, st)
        return
    end
    local c = u.callId and calls[u.callId]
    for _, m in ipairs(members(src)) do setUnitStatus(units[m], st, c and ('#' .. c.id) or nil) end
    if c and st == 'ON SCENE' then
        stampTime(c, 'onscene')
        addLog(c, L('server.log_on_scene', u.callsign)) saveLog(c)
    elseif c and st == 'EN ROUTE' then
        stampTime(c, 'enroute')
    elseif c and st == 'TRANSPORT' then
        addLog(c, L('server.log_transport', u.callsign)) saveLog(c)
    end
end

reg('setStatus', function(src, p, d)
    if not validStatus(d.status) then return { ok = false } end
    ensureUnit(src, p)
    applyStatus(src, d.status)
    broadcast()
    return { ok = true }
end)

-- The callsign is kept in one place: the player's metadata.callsign field (used by /callsign and the GPS blips).
-- A callsign entered in the MDC is written there; one entered with /callsign automatically passes to the MDC.
local metaBusy = {}
local function setMetaCallsign(src, p, value)
    if not p then return end
    metaBusy[src] = true
    pcall(p.Functions.SetMetaData, 'callsign', value)
    metaBusy[src] = nil
end

-- Changes the unit's callsign; if someone already has that callsign, the unit joins their team (call and status)
local function applyCallsign(src, cs)
    local me = units[src]
    if not me then return false, L('server.err_unit_not_found') end
    local partner
    for s2, u2 in pairs(units) do
        if s2 ~= src and u2.callsign == cs then
            if not Config.CallsignGroups then return false, L('server.err_callsign_taken', cs) end
            partner = partner or u2
        end
    end
    if me.callsign == cs then return true end
    if me.callId then detach(src, false, true) end
    me.callsign = cs
    activity(me, 'info', L('server.activity_callsign', cs))
    if partner then
        setUnitStatus(me, partner.status)
        local c = partner.callId and calls[partner.callId]
        if c then
            me.callId = c.id
            c.units[src] = true
            addLog(c, L('server.log_joined_team', me.name or '?', cs))
            saveLog(c)
        end
    end
    return true
end

reg('setCallsign', function(src, p, d)
    local cs = line(d.callsign, 12):upper():gsub('[^%w%-]', '')
    if not Cad.validCallsign(cs) or not units[src] then
        return { ok = false, err = L('server.err_callsign_invalid') }
    end
    local ok, err = applyCallsign(src, cs)
    if not ok then return { ok = false, err = err } end
    setMetaCallsign(src, p, cs)
    broadcast()
    Cad.trackNow()
    return { ok = true, team = #members(src) }
end)

-- Reflect it in the MDC if /callsign or another script changed the callsign
AddEventHandler('qbx_core:server:onSetMetaData', function(key, _, value, src)
    if key ~= 'callsign' or not src or metaBusy[src] then return end
    local p = exports.qbx_core:GetPlayer(src)
    if not (p and allowed(p)) then return end
    local u = ensureUnit(src, p)
    local cs = Cad.validCallsign(tostring(value or '')) and line(tostring(value), 12):upper() or nil
    if cs then
        if not applyCallsign(src, cs) then
            -- If the callsign is taken while teams are disabled: write the old callsign back
            setMetaCallsign(src, p, u.callsign ~= 'NEW UNIT' and u.callsign or 'NO CALLSIGN')
        end
    elseif u.callsign ~= 'NEW UNIT' then
        if u.callId then detach(src, false, true) end
        u.callsign = 'NEW UNIT'
    end
    broadcast()
    Cad.trackNow()
end)

-- The callsign is not persistent: it is reset when loading into the game and when going on/off duty
local function resetCallsign(src, p)
    if not Config.ResetCallsign then return end
    p = p or exports.qbx_core:GetPlayer(src)
    local u = units[src]
    if u and u.callsign ~= 'NEW UNIT' then
        if u.callId then detach(src, true, true) end
        u.callsign = 'NEW UNIT'
    end
    if p and Cad.validCallsign(p.PlayerData.metadata and p.PlayerData.metadata.callsign) then
        setMetaCallsign(src, p, 'NO CALLSIGN')
    end
end
Cad.resetCallsign = resetCallsign

AddEventHandler('QBCore:Server:PlayerLoaded', function(p)
    local src = p and p.PlayerData and p.PlayerData.source
    if src then resetCallsign(src, p) end
end)
AddEventHandler('playerDropped', function() metaBusy[source] = nil end)
Cad.ensureUnit = ensureUnit

------------------------------------------------------------------ Call actions
reg('createCall', function(src, p, d)
    local u = ensureUnit(src, p)
    local title = line(d.title, 128)
    if title == '' then return { ok = false, err = L('server.err_title_empty') } end

    -- If the officer typed a different postal, the call location becomes that postal
    local co = toXYZ(d.coords)
    local postal = line(d.postal, 16)
    if co and postal ~= '' and postal ~= Postal.nearest(co.x, co.y) then
        local pt = Postal.find(postal)
        if pt then co = { x = pt.x, y = pt.y, z = 0.0 } end
    end

    local veh = cleanVehicle({ plate = d.plate, color = d.color, make = d.make, model = d.model })
    local extra, flags = {}, {}
    if veh and veh.plate ~= '' then
        local r = Cad.searchVehicles(veh.plate, true)[1]
        if r and r.unregistered then
            extra[#extra + 1] = L('server.log_plate_unregistered')
        elseif r then
            extra[#extra + 1] = L('server.log_registered_owner', r.firstname or '-', r.lastname or '', r.model or '-')
        end
        if r and r.bolo then
            extra[#extra + 1] = L('server.log_active_bolo', r.bolo.reason or '')
            flags[#flags + 1] = ('BOLO %s: %s'):format(veh.plate, r.bolo.reason or '')
        end
        if r and r.ownerWanted then
            extra[#extra + 1] = L('server.log_owner_warrant')
            flags[#flags + 1] = L('server.flag_owner_warrant', veh.plate)
        end
        if r and r.ownerBolo then
            extra[#extra + 1] = L('server.log_owner_bolo', r.ownerBolo)
            flags[#flags + 1] = L('server.flag_owner_bolo', r.ownerBolo)
        end
    end

    local call = Cad.createCall({ title = title,
        priority = d.priority, status = d.status, address = d.address, postal = postal, area = d.area,
        county = d.county, agency = u.agency, caller = ('%s · %s'):format(u.callsign, u.name),
        message = d.message, coords = co, vehicle = veh, extra = extra, flags = flags })
    if not call then return { ok = false, err = L('server.err_call_create') } end
    activity(u, 'call', L('server.activity_opened_call', call.id, title))
    if d.attach then
        attach(src, call.id)
        if d.onscene then applyStatus(src, 'ON SCENE') end
    end
    broadcast()
    return { ok = true, id = call.id }
end)

reg('callDetail', function(_, _, d)
    local c = calls[tonumber(d.id)]
    return c and { log = c.log } or { log = {} }
end)

reg('updateCall', function(src, _, d)
    local c = calls[tonumber(d.id)]
    if not c then return { ok = false } end
    local who = units[src] and units[src].callsign or '?'
    local pr = tonumber(d.priority)
    if pr and pr >= 1 and pr <= 3 and pr ~= c.priority then
        c.priority = math.floor(pr)
        addLog(c, L('server.log_priority', c.priority, who))
        MySQL.update('UPDATE cad_calls SET priority = ? WHERE id = ?', { c.priority, c.id })
    end
    if CALL_STATUS[d.status] and d.status ~= c.status then
        c.status = d.status
        addLog(c, L('server.log_status', c.status, who))
        MySQL.update('UPDATE cad_calls SET status = ? WHERE id = ?', { c.status, c.id })
    end
    saveLog(c)
    broadcast()
    return { ok = true }
end)

reg('addNote', function(src, _, d)
    local c = calls[tonumber(d.id)]
    local text = clean(d.text, 500):gsub('^%s+', ''):gsub('%s+$', '')
    if not c or text == '' then return { ok = false } end
    local who = units[src] and units[src].callsign or '?'
    addLog(c, ('[%s] %s: %s'):format(os.date('%H:%M'), who, text))
    saveLog(c)
    broadcast()
    return { ok = true }
end)

reg('attach', function(src, p, d)
    ensureUnit(src, p)
    local ok = attach(src, tonumber(d.id))
    broadcast()
    return { ok = ok }
end)

reg('detach', function(src) detach(src) broadcast() return { ok = true } end)

reg('closeCall', function(src, p, d)
    if not Cad.can(p, 'closeCall') then return { ok = false, err = L('server.err_close_perm') } end
    local id = tonumber(d.id)
    local u = units[src]
    local okc = closeCall(id, u and u.callsign)
    if okc and u then activity(u, 'info', L('server.activity_closed', id or 0)) end
    return { ok = okc }
end)

reg('myCall', function(src)
    local u = units[src]
    local c = u and u.callId and calls[u.callId]
    return (c and c.hasCoords) and c.coords or {}
end)

-- Request backup: if on a call, its priority is raised and the other units are notified again;
-- otherwise a new backup call is opened at the current position.
reg('backup', function(src, p, d)
    local u = ensureUnit(src, p)
    local code = tonumber(d.code) == 2 and 2 or 3
    local c = u.callId and calls[u.callId]
    if c then
        if code > c.priority then
            c.priority = code
            MySQL.update('UPDATE cad_calls SET priority = ? WHERE id = ?', { code, c.id })
        end
        addLog(c, L('server.log_backup', u.callsign, code))
        saveLog(c)
        activity(u, 'call', L('server.activity_backup', code, c.id))
        alertUnits(c, { backup = true, by = u.callsign, backupCode = code, except = c.units })
        broadcast()
        return { ok = true, id = c.id }
    end
    local co = toXYZ(GetEntityCoords(GetPlayerPed(src)))
    local call = Cad.createCall({ title = L('server.backup_title'), priority = code,
        address = d.address, area = d.area, county = d.county, postal = d.postal, agency = u.agency, jobs = { 'leo' },
        caller = ('%s · %s'):format(u.callsign, u.name), coords = co, sprite = 526, color = 1 })
    if not call then return { ok = false, err = L('server.err_backup') } end
    attach(src, call.id)
    applyStatus(src, 'ON SCENE')
    activity(u, 'call', L('server.activity_backup', code, call.id))
    broadcast()
    return { ok = true, id = call.id }
end)

-- Calls from the last 30 days at the same postal code (address history)
reg('addrHistory', function(_, _, d)
    local postal = line(d.postal, 16)
    if postal == '' then return {} end
    return MySQL.query.await([[SELECT id, code, title, UNIX_TIMESTAMP(created_at) * 1000 AS created FROM cad_calls
        WHERE postal = ? AND id <> ? AND created_at >= (NOW() - INTERVAL 30 DAY) ORDER BY id DESC LIMIT 6]],
        { postal, tonumber(d.id) or 0 }) or {}
end)

-- My Shift: shift start, status durations, activity, report counts
reg('shift', function(src, p)
    local u = ensureUnit(src, p)
    local sh = u.shift
    local totals = {}
    for k, v in pairs(sh.totals) do totals[k] = v end
    totals[u.status] = (totals[u.status] or 0) + (os.time() - (u.statusSince or os.time()))
    local reports = {}
    local okR, rows = pcall(MySQL.query.await, [[SELECT type, COUNT(*) AS n FROM cad_records
        WHERE author_cid = ? AND created_at >= FROM_UNIXTIME(?) GROUP BY type]], { u.cid or '', sh.start })
    for _, r in ipairs(okR and rows or {}) do reports[r.type] = tonumber(r.n) or 0 end
    local pending = 0
    local okP, n = pcall(MySQL.scalar.await, "SELECT COUNT(*) FROM cad_records WHERE author_cid = ? AND review = 'PENDING'", { u.cid or '' })
    if okP then pending = tonumber(n) or 0 end
    local partners = {}
    for _, m in ipairs(members(src)) do
        if m ~= src and units[m] then partners[#partners + 1] = units[m].name end
    end
    return { ok = true, start = sh.start, now = os.time(), totals = totals, acts = sh.acts, calls = sh.calls,
        queries = sh.queries, hits = sh.hits, reports = reports, pending = pending, partners = partners,
        callsign = u.callsign, name = u.name, rank = u.rank, agency = u.agency }
end)

------------------------------------------------------------------ Exports
-- exports['knb_cad']:CreateCall({ code=, title=, priority=1-3, address=, coords=, message=, jobs={'leo'} }) -> id
exports('CreateCall', function(d)
    local c = type(d) == 'table' and Cad.createCall(d)
    return c and c.id or nil
end)
exports('CloseCall', function(id) return closeCall(tonumber(id)) end)
exports('GetCalls', function()
    local out = {}
    for _, c in pairs(calls) do out[#out + 1] = callState(c) end
    table.sort(out, sortCalls)
    return out
end)

------------------------------------------------------------------ Player / job events
AddEventHandler('playerDropped', function()
    local src = source
    if units[src] then detach(src, false, true) units[src] = nil end
    viewers[src], lastCall[src] = nil, nil
    broadcast()
end)

-- CAD access is removed when the job changes
AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    if not units[src] and not viewers[src] then return end
    if allowedJob(job) then
        local p = exports.qbx_core:GetPlayer(src)
        if p and units[src] then ensureUnit(src, p) end
        if viewers[src] then viewers[src] = { name = job.name, type = job.type } end
    else
        detach(src, false, true)
        units[src], viewers[src] = nil, nil
        resetCallsign(src)
        TriggerClientEvent('cad:forceClose', src)
    end
    broadcast()
end)

-- Going on duty starts a new shift, going off duty sets the unit to OFF DUTY
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    resetCallsign(src)
    local u = units[src]
    if not u then return end
    if onDuty then
        u.shift = newShift()
        u.status, u.statusSince = Config.Statuses[1], os.time()
        activity(u, 'AVAILABLE', L('server.went_on_duty'))
    else
        detach(src, false, true)
        setUnitStatus(u, Config.OffDutyStatus)
    end
    broadcast()
end)

------------------------------------------------------------------ Load active calls on startup
CreateThread(function()
    -- Is the table up to date? (columns are missing if sql/knb_cad.sql was not run)
    local okCols, cols = pcall(MySQL.query.await, "SHOW COLUMNS FROM cad_calls")
    local have = {}
    for _, c in ipairs(okCols and cols or {}) do have[c.Field] = true end
    local missing = {}
    for _, f in ipairs({ 'priority', 'area', 'county', 'agency', 'vehicle', 'jobs', 'log', 'caller', 'message' }) do
        if not have[f] then missing[#missing + 1] = f end
    end
    if #missing > 0 then
        print(L('server.err_missing_cols_calls', table.concat(missing, ', ')))
        print(L('server.err_run_sql'))
        return
    end
    Cad.refreshBolos()

    local rows = MySQL.query.await([[SELECT *, UNIX_TIMESTAMP(created_at) AS created_ts FROM cad_calls
        WHERE status IN ('ACTIVE', 'PENDING')]])
    for _, r in ipairs(rows or {}) do
        local co = toXYZ(json.decode(r.coords or '{}') or {})
        local jobs = {}
        for j in tostring(r.jobs or ''):gmatch('[^,]+') do jobs[#jobs + 1] = j end
        local ok, log = pcall(json.decode, r.log or '')
        local created = tonumber(r.created_ts) or os.time()
        calls[r.id] = { id = r.id, code = r.code, title = r.title, priority = tonumber(r.priority) or 2,
            status = r.status, address = r.address, postal = r.postal, area = r.area or '', county = r.county or '',
            agency = r.agency or '', caller = r.caller, message = r.message,
            coords = co or { x = 0.0, y = 0.0, z = 0.0 }, hasCoords = co ~= nil, trueCoords = co,
            vehicle = cleanVehicle(json.decode(r.vehicle or '{}')), jobs = #jobs > 0 and jobs or nil,
            units = {}, created = created, times = { created = created }, system = false, blip = {}, alert = {}, count = 1,
            log = (ok and type(log) == 'table' and #log > 0) and log
                or { L('server.log_opened', stamp()) } }
    end
end)
