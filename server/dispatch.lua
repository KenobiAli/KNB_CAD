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

-- Automatic dispatch: turns alerts into MDC calls.
-- Merging (×N), approximate location, critical calls, rate limits and compatibility handlers
-- are adapted from Project Sloth ps-dispatch (server/main.lua · GPL-3.0) logic.

local D = Config.Dispatch
local line = Cad.line

------------------------------------------------------------------ Limits
local cds, buckets = {}, {}

-- true = on cooldown (the alert is rejected)
local function onCooldown(src, key, secs)
    if not src then return false end
    local t = cds[src] or {}
    cds[src] = t
    local now = os.time()
    if t[key] and now - t[key] < secs then return true end
    t[key] = now
    return false
end

-- Per player: at most Max alerts within Window seconds (against modified clients)
local function rateAllowed(src)
    local rl = D.RateLimit
    if not rl or not src or src <= 0 then return true end
    local now = os.clock()
    local keep = {}
    for _, t in ipairs(buckets[src] or {}) do
        if t > now - (rl.Window or 10) then keep[#keep + 1] = t end
    end
    buckets[src] = keep
    if #keep >= (rl.Max or 12) then return false end
    keep[#keep + 1] = now
    return true
end

AddEventHandler('playerDropped', function() cds[source], buckets[source] = nil, nil end)

-- Validates the location reported by the client; if it is too far from the player, the player's own position is used.
-- Returns: coordinates, and whether the client's location info (address/area) can be trusted
local function safeCoords(src, claimed)
    local c = Cad.toXYZ(claimed)
    if not src then return c, true end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return c, c ~= nil end
    local pc = GetEntityCoords(ped)
    if c and #(vec3(c.x, c.y, c.z) - pc) <= Config.MaxAlertDistance then return c, true end
    return Cad.toXYZ(pc), false
end

------------------------------------------------------------------ Merging
-- Is there a recent call of the same type nearby? (by true location)
local function findRecent(key, co)
    if not co or not key then return end
    local m = D.Merge
    local now = os.time()
    for _, c in pairs(Cad.calls) do
        local tc = c.trueCoords
        if c.system and c.key == key and tc and now - (c.lastReport or c.created) <= m.Seconds then
            local dx, dy = tc.x - co.x, tc.y - co.y
            if dx * dx + dy * dy <= m.Radius * m.Radius then return c end
        end
    end
end

local function onlyEms(jobs)
    if not jobs or #jobs == 0 then return false end
    for _, j in ipairs(jobs) do if j ~= 'ems' and j ~= 'ambulance' then return false end end
    return true
end

function Cad.dispatch(d)
    local c = findRecent(d.key, Cad.toXYZ(d.coords))
    if c then
        c.lastReport = os.time()
        return Cad.mergeInto(c, d)
    end
    d.system = true
    if not d.agency and onlyEms(d.jobs) then d.agency = 'EMS' end
    local call = Cad.createCall(d)
    if call then call.lastReport = os.time() end
    return call
end

------------------------------------------------------------------ Helpers
local function officerLabel(src)
    local u = Cad.units[src]
    local p = exports.qbx_core:GetPlayer(src)
    if not p then return 'ID ' .. src end
    local ci, job = p.PlayerData.charinfo, p.PlayerData.job
    local cs = (u and Cad.validCallsign(u.callsign)) and (u.callsign .. ' · ') or ''
    return ('%s%s %s (%s)'):format(cs, ci.firstname, ci.lastname, Cad.agencyOf(job))
end

-- Class / threat from the weapon name (for weapons that arrive as plain text on the server)
local CLASS_INFO = {
    pistol = { L('weapon.class.pistol'), 1 }, taser = { L('weapon.class.taser'), 1 }, smg = { L('weapon.class.smg'), 2 }, shotgun = { L('weapon.class.shotgun'), 2 },
    rifle = { L('weapon.class.rifle'), 2 }, sniper = { L('weapon.class.sniper'), 3 }, heavy = { L('weapon.class.heavy'), 3 },
}
local function weaponFromName(name, class, tier, auto)
    if type(name) == 'table' then return name end
    if not name or name == '' then return nil end
    local n = tostring(name):lower()
    if not CLASS_INFO[class or ''] then
        if n:find('taser') or n:find('stun') then class = 'taser'
        elseif n:find('rpg') or n:find('launcher') or n:find('minigun') or (n:find('mg') and not n:find('smg')) then class = 'heavy'
        elseif n:find('sniper') or n:find('musket') then class = 'sniper'
        elseif n:find('shotgun') or n:find('sawn') or n:find('sawed') then class = 'shotgun'
        elseif n:find('smg') or n:find('pdw') or n:find('gusenberg') then class = 'smg'
        elseif n:find('rifle') or n:find('carbine') then class = 'rifle'
        else class = 'pistol' end
    end
    local ci = CLASS_INFO[class]
    return { name = tostring(name), class = class, label = ci[1], tier = tonumber(tier) or ci[2],
        auto = auto or class == 'smg' or class == 'rifle' or nil }
end

local function weaponLine(w)
    if type(w) ~= 'table' then return nil end
    local name = (w.name and w.name ~= '' and w.name ~= L('weapon.unknown')) and (' (' .. w.name .. ')') or ''
    return L('dispatch.weapon_line', w.label or w.name or '?', name, w.auto and L('dispatch.auto_fire') or '')
end

------------------------------------------------------------------ Alerts from Config.Alerts
local function fromAlert(key, info, src)
    local def = Config.Alerts[key]
    if not def then return end
    info = type(info) == 'table' and info or {}
    local co, trusted = safeCoords(src, info.coords)

    local lines = {}
    local function add(s)
        s = line(s, 160)
        if s ~= '' then lines[#lines + 1] = s end
    end
    if def.officer and src then add(L('dispatch.unit', officerLabel(src))) end
    add(info.message)
    local w = weaponFromName(info.weapon)
    if w then add(weaponLine(w)) end
    if not def.officer and info.gender then add(L('dispatch.suspect_gender', tostring(info.gender))) end
    if info.heading and type(info.vehicle) == 'table' then add(L('dispatch.heading', tostring(info.heading))) end
    if info.camId then add(L('dispatch.camera', tostring(info.camId))) end
    if type(info.extra) == 'table' then
        for i = 1, math.min(#info.extra, 6) do add(info.extra[i]) end
    end

    return Cad.dispatch({
        key = key, code = def.code, title = def.title, priority = def.priority, jobs = def.jobs, agency = def.agency,
        coords = co, address = trusted and info.address or '', area = trusted and info.area or '',
        county = trusted and info.county or nil, caller = L('dispatch.auto_caller'),
        message = table.concat(lines, '\n'), vehicle = info.vehicle,
        sprite = def.sprite, color = def.color, radius = def.radius, offset = def.offset, critical = def.critical,
        alert = { weapon = w, gender = not def.officer and info.gender or nil,
            heading = type(info.vehicle) == 'table' and info.heading or nil, camId = info.camId },
    })
end
Cad.fromAlert = fromAlert

RegisterNetEvent('knb_cad:server:alert', function(key, info)
    local src = source
    local def = type(key) == 'string' and Config.Alerts[key]
    if not def then return end
    if not rateAllowed(src) then return end
    if def.officer then
        local p = exports.qbx_core:GetPlayer(src)
        if not (p and Cad.allowed(p) and p.PlayerData.job.onduty) then return end
    end
    if onCooldown(src, key, def.cooldown) then return end
    fromAlert(key, info, src)
end)

------------------------------------------------------------------ Custom alerts (CustomAlert / notify format)
-- alert codeName -> Config.Alerts key (known types use the localized title, icon and settings)
local CODE_MAP = {
    shooting = 'Shooting', vehicleshots = 'VehicleShooting', hunting = 'Hunting', fight = 'Fight', carjack = 'CarJacking',
    vehicletheft = 'VehicleTheft', explosion = 'Explosion', speeding = 'SpeedingVehicle', officerdown = 'OfficerDown',
    officerbackup = 'OfficerBackup', platebackup = 'OfficerBackup', officerdistress = 'OfficerInDistress', emsdown = 'EmsDown',
    civdown = 'InjuriedPerson', civdead = 'DeceasedPerson', storerobbery = 'StoreRobbery', bankrobbery = 'FleecaBankRobbery',
    paletobankrobbery = 'PaletoBankRobbery', pacificbankrobbery = 'PacificBankRobbery', vangelicorobbery = 'VangelicoRobbery',
    houserobbery = 'HouseRobbery', yachtheist = 'YachtHeist', suspicioushandoff = 'DrugSale', susactivity = 'SuspiciousActivity',
    prisonbreak = 'PrisonBreak', artgalleryrobbery = 'ArtGalleryRobbery', humanelabsrobbery = 'HumaneRobbery',
    trainrobbery = 'TrainRobbery', vanrobbery = 'VanRobbery', undergroundrobbery = 'UndergroundRobbery',
    drugboatrobbery = 'DrugBoatRobbery', unionrobbery = 'UnionRobbery', carboosting = 'CarBoosting',
    signrobbery = 'SignRobbery', bobcatsecurityheist = 'BobcatSecurityHeist',
}

local function fromCustom(data, src)
    local title = line(data.title or data.message, 128)
    if title == '' then return end
    if onCooldown(src, 'custom:' .. title, Config.CustomAlertCooldown) then return end
    local co, trusted = safeCoords(src, data.coords)

    -- priority: 0/1 = high, 2 = normal. Use cadCode = 1-3 to give your own Code value.
    local pr = tonumber(data.cadCode) or ({ [0] = 3, [1] = 3, [2] = 2, [3] = 1 })[tonumber(data.priority)] or 2

    local lines = {}
    local function add(s)
        s = line(s, 160)
        if s ~= '' then lines[#lines + 1] = s end
    end
    if data.officer then add(L('dispatch.unit', data.officer)) end
    add(data.description)
    local w = weaponFromName(data.weapon, data.weaponClass, data.weaponTier, data.automaticGunFire)
    if w then add(weaponLine(w)) end
    if data.gender then add(L('dispatch.suspect_gender', tostring(data.gender))) end
    if data.heading then add(L('dispatch.heading', tostring(data.heading))) end
    if data.camId then add(L('dispatch.camera', tostring(data.camId))) end

    local veh = type(data.vehicle) == 'table' and data.vehicle or nil
    return Cad.dispatch({
        key = 'custom:' .. title, title = title, priority = pr,
        jobs = type(data.jobs) == 'table' and data.jobs or { 'leo' },
        coords = co, address = trusted and data.address or '', area = trusted and data.area or '',
        county = trusted and data.county or nil, caller = L('dispatch.auto_caller'),
        message = table.concat(lines, '\n'), vehicle = veh,
        sprite = data.sprite, color = data.color, radius = data.radius, offset = data.offset and true or nil,
        alert = { weapon = w, gender = data.gender, heading = data.heading, camId = data.camId },
    })
end

RegisterNetEvent('knb_cad:server:custom', function(data)
    local src = source
    if type(data) ~= 'table' or not rateAllowed(src) then return end
    fromCustom(data, src)
end)

-- Listen to the legacy server event (in case scripts use TriggerServerEvent directly)
if Config.ExternalBridge then
    RegisterNetEvent('ps-dispatch:server:notify', function(data)
        if type(data) ~= 'table' then return end
        local src = tonumber(source)
        if src and src <= 0 then src = nil end
        if src and not rateAllowed(src) then return end
        local alert = type(data.alert) == 'table' and data.alert or {}
        local vehicle = (data.plate or data.vehicle) and { plate = data.plate, color = data.color,
            model = data.vehicle, class = data.class, doors = tonumber(data.doors), heading = data.heading } or nil
        local key = CODE_MAP[tostring(data.codeName or ''):lower()]
        if key then
            local def = Config.Alerts[key]
            if src and onCooldown(src, key, def.cooldown) then return end
            if def.officer and src then
                local p = exports.qbx_core:GetPlayer(src)
                if not (p and Cad.allowed(p) and p.PlayerData.job.onduty) then return end
            end
            return fromAlert(key, { coords = data.coords, address = data.street, gender = data.gender,
                weapon = weaponFromName(data.weapon, data.weaponClass, data.weaponTier, data.automaticGunFire),
                vehicle = vehicle, heading = data.heading, camId = data.camId, message = data.information }, src)
        end
        fromCustom({
            title = data.message, code = data.code, description = data.information or data.description,
            priority = data.priority, coords = data.coords, address = data.street, gender = data.gender,
            weapon = data.weapon, weaponClass = data.weaponClass, weaponTier = data.weaponTier,
            automaticGunFire = data.automaticGunFire or data.automaticGunfire, camId = data.camId, jobs = data.jobs,
            vehicle = vehicle, heading = data.heading, officer = data.callsign and (data.callsign .. ' · ' .. (data.name or '')),
            radius = tonumber(alert.radius), sprite = alert.sprite, color = alert.color, offset = alert.offset,
        }, src)
    end)
end

------------------------------------------------------------------ Direct notification (does not open a call)
-- exports['knb_cad']:SendTargetedAlert(src | {src...}, { message=, code=, information=, priority= })
local function sendTargetedAlert(targets, data)
    if type(targets) == 'number' then targets = { targets } end
    if type(targets) ~= 'table' or type(data) ~= 'table' or type(data.message) ~= 'string' then return false end
    local payload = { title = line(data.message, 128), code = line(data.code or 'DIRECT', 16),
        info = line(data.information or data.description, 255), priority = tonumber(data.priority) == 1 and 3 or 2,
        plate = data.plate and Cad.normPlate(data.plate) or nil }
    for _, t in ipairs(targets) do
        t = tonumber(t)
        if t and t > 0 then TriggerClientEvent('cad:directAlert', t, payload) end
    end
    return true
end

RegisterNetEvent('ps-dispatch:server:targetAlert', function(targets, data)
    if source and tonumber(source) and tonumber(source) > 0 then return end -- only the server can trigger this
    sendTargetedAlert(targets, data)
end)

------------------------------------------------------------------ Server exports
local function provide(name, fn)
    exports(name, fn)
    if Config.ExternalCompat then
        AddEventHandler(('__cfx_export_ps-dispatch_%s'):format(name), function(setCB) setCB(fn) end)
    end
end

-- exports['knb_cad']:SendAlert('StoreRobbery', coords, { message = '...', address = '...', lines = {'...'} })
exports('SendAlert', function(key, coords, extra)
    extra = type(extra) == 'table' and extra or {}
    local r = fromAlert(key, { coords = coords, message = extra.message, address = extra.address,
        area = extra.area, county = extra.county, extra = extra.lines, vehicle = extra.vehicle,
        weapon = extra.weapon, camId = extra.camId }, nil)
    return r and r.id or nil
end)

-- exports['knb_cad']:CustomAlert({ message=, dispatchCode=, description=, coords=, jobs=, cadCode= })
exports('CustomAlert', function(data)
    if type(data) ~= 'table' then return end
    data.title = data.title or data.message
    data.code = data.code or data.dispatchCode
    local r = fromCustom(data, nil)
    return r and r.id or nil
end)

provide('SendTargetedAlert', sendTargetedAlert)
provide('GetDispatchCalls', function()
    local out = {}
    for _, c in pairs(Cad.calls) do out[#out + 1] = Cad.callState(c) end
    return out
end)

------------------------------------------------------------------ Test command
if D.TestCommand then
    local SAMPLES = {
        { 'Shooting', { weapon = { name = 'Carbine Rifle', class = 'rifle', label = L('weapon.class.rifle'), tier = 2, auto = true },
            gender = L('gender.male'), message = L('dispatch.test_gunshot') } },
        { 'CarJacking', { vehicle = { plate = 'TEST123', color = L('color.white'), make = 'Karin', model = 'Sultan', class = 'Sedan', doors = 4 },
            heading = L('dir.north'), gender = L('gender.female') } },
        { 'StoreRobbery', { camId = 23, gender = L('gender.male'), message = L('dispatch.test_store') } },
        { 'Shooting', { weapon = { name = 'Pistol', class = 'pistol', label = L('weapon.class.pistol'), tier = 1 }, gender = L('gender.male') } },
        { 'Fight', { gender = L('gender.male') } },
    }
    RegisterCommand(D.TestCommand, function(src)
        local p = src > 0 and exports.qbx_core:GetPlayer(src)
        if not (p and Cad.allowed(p) and p.PlayerData.job.onduty) then return end
        local base = GetEntityCoords(GetPlayerPed(src))
        CreateThread(function()
            for i, s in ipairs(SAMPLES) do
                local info = {}
                for k, v in pairs(s[2]) do info[k] = v end
                local near = s[1] == 'Shooting' -- two gunshots at the same point: so that merging (×2) can be seen
                info.coords = { x = base.x + (near and 10 or i * 120), y = base.y + (near and 10 or 40), z = base.z }
                info.address = L('dispatch.test_address')
                fromAlert(s[1], info, nil)
                Wait(6000)
            end
        end)
        TriggerClientEvent('ox_lib:notify', src, { description = L('dispatch.test_started'), type = 'inform' })
    end, false)
end
