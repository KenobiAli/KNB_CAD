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

local isOpen = false
local muted = GetResourceKvpInt('knb_cad:muted') == 1
local lastAlert

------------------------------------------------------------------ Location info (postal file)
local BLAINE = {}
for _, z in ipairs(Config.BlaineZones) do BLAINE[z] = true end

-- Returns street, crossing, area, county and postal info
function Cad.location(coords)
    local c = coords and vec3(coords.x + 0.0, coords.y + 0.0, (coords.z or 0.0) + 0.0) or GetEntityCoords(cache.ped)
    local s1, s2 = GetStreetNameAtCoord(c.x, c.y, c.z)
    local street = GetStreetNameFromHashKey(s1)
    local cross = (s2 and s2 ~= 0) and GetStreetNameFromHashKey(s2) or ''
    local zone = GetNameOfZone(c.x, c.y, c.z)
    local label = GetLabelText(zone)
    return {
        coords = { x = c.x, y = c.y, z = c.z },
        street = street,
        address = (cross ~= '' and cross ~= street) and (street .. ' / ' .. cross) or street,
        area = ((label ~= 'NULL' and label) or zone):upper(),
        county = BLAINE[zone] and 'BLAINE' or 'LOS SANTOS',
        postal = Postal.nearest(c.x, c.y),
    }
end

------------------------------------------------------------------ Vehicle info
local COLOR_RANGES = {
    { 0, L('color.black') }, { 1, L('color.graphite') }, { 2, L('color.black') }, { 10, L('color.silver') }, { 11, L('color.anthracite') }, { 12, L('color.black') },
    { 14, L('color.gray') }, { 16, L('color.black') }, { 20, L('color.silver') }, { 21, L('color.black') }, { 26, L('color.gray') }, { 35, L('color.red') },
    { 36, L('color.orange') }, { 37, L('color.gold') }, { 38, L('color.orange') }, { 40, L('color.red') }, { 41, L('color.orange') }, { 42, L('color.yellow') },
    { 48, L('color.red') }, { 60, L('color.green') }, { 87, L('color.blue') }, { 89, L('color.yellow') }, { 90, L('color.bronze') }, { 91, L('color.yellow') },
    { 92, L('color.light_green') }, { 93, L('color.champagne') }, { 110, L('color.brown') }, { 112, L('color.white') }, { 116, L('color.beige') },
    { 120, L('color.chrome') }, { 122, L('color.white') }, { 124, L('color.orange') }, { 125, L('color.green') }, { 126, L('color.yellow') }, { 127, L('color.blue') },
    { 128, L('color.green') }, { 129, L('color.brown') }, { 130, L('color.orange') }, { 132, L('color.white') }, { 133, L('color.khaki') },
    { 134, L('color.white') }, { 137, L('color.pink') }, { 138, L('color.orange') }, { 139, L('color.green') }, { 141, L('color.blue') }, { 142, L('color.purple') },
    { 143, L('color.red') }, { 144, L('color.green') }, { 145, L('color.purple') }, { 146, L('color.navy') }, { 147, L('color.black') }, { 149, L('color.purple') },
    { 150, L('color.red') }, { 152, L('color.green') }, { 154, L('color.sand') }, { 155, L('color.green') }, { 156, L('color.silver') },
    { 157, L('color.blue') }, { 159, L('color.gold') },
}

local function colorName(idx)
    for _, r in ipairs(COLOR_RANGES) do
        if idx <= r[1] then return r[2] end
    end
    return L('color.unknown')
end

local function rgbName(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    if mx == mn then return mx < 50 and L('color.black') or mx > 210 and L('color.white') or L('color.gray') end
    local l = (mx + mn) / 510
    local s = (mx - mn) / (255 - math.abs(mx + mn - 255))
    if s < 0.18 then return l < 0.2 and L('color.black') or l > 0.8 and L('color.white') or L('color.gray') end
    if l < 0.1 then return L('color.black') end
    local d, h = mx - mn, 0
    if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h * 60
    if h < 15 or h >= 345 then return L('color.red') end
    if h < 40 then return L('color.orange') end
    if h < 70 then return L('color.yellow') end
    if h < 165 then return L('color.green') end
    if h < 200 then return L('color.turquoise') end
    if h < 255 then return L('color.blue') end
    if h < 290 then return L('color.purple') end
    return L('color.pink')
end

local function label(s)
    if not s or s == '' then return '' end
    local l = GetLabelText(s)
    return (l ~= 'NULL' and l or s)
end

function Cad.vehicleInfo(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    local model = GetEntityModel(veh)
    local color
    if GetIsVehiclePrimaryColourCustom(veh) then
        color = rgbName(GetVehicleCustomPrimaryColour(veh))
    else
        color = colorName((GetVehicleColours(veh)))
    end
    local plate = (GetVehicleNumberPlateText(veh) or ''):match('^%s*(.-)%s*$')
    return { plate = plate, color = color, make = label(GetMakeNameFromVehicleModel(model)),
        model = label(GetDisplayNameFromVehicleModel(model)) }
end

------------------------------------------------------------------ Access (vehicle / computer)
local A = Config.Access
local extraVeh, pcModels = {}, {}
for _, m in ipairs(A.ExtraVehicles) do extraVeh[joaat(m)] = true end
for _, m in ipairs(A.ComputerModels) do pcModels[#pcModels + 1] = joaat(m) end

-- Is it a CAD vehicle? (emergency class or the extra models in the config)
function Cad.isCadVehicle(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    return GetVehicleClass(veh) == 18 or extraVeh[GetEntityModel(veh)] == true
end

local function nearComputer()
    local c = GetEntityCoords(cache.ped)
    for _, t in ipairs(A.Terminals) do
        if #(c - t.coords) <= (t.radius or 1.5) then return true end
    end
    for _, h in ipairs(pcModels) do
        if GetClosestObjectOfType(c.x, c.y, c.z, A.ComputerDistance, h, false, false, false) ~= 0 then return true end
    end
    return false
end

function Cad.canAccess()
    if A.Vehicle and Cad.isCadVehicle(cache.vehicle) then return true end
    if A.Computer and nearComputer() then return true end
    return false
end

------------------------------------------------------------------ Panel
local function toggle(state)
    if state == isOpen then return end
    if state then
        if not Cad.canAccess() then
            return lib.notify({ description = L('client.no_access'),
                type = 'error' })
        end
        local st = lib.callback.await('cad:open', false)
        if not st or not st.state then
            return lib.notify({ description = (st and st.err) or L('client.no_cad_access'), type = 'error' })
        end
        isOpen = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'open', state = st.state, meta = st.meta, id = cache.serverId })
    else
        -- Closing is handled entirely on the client; the server is only informed
        isOpen = false
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })
        TriggerServerEvent('cad:viewerClosed')
    end
end

RegisterCommand(Config.Command, function() toggle(not isOpen) end, false)
function Cad.isOpen() return isOpen end

-- Own position while the MDC is open (distance calculations and "me" on the map)
CreateThread(function()
    while true do
        if isOpen then
            local c = GetEntityCoords(cache.ped)
            SendNUIMessage({ action = 'pos', x = c.x, y = c.y, h = GetEntityHeading(cache.ped) })
            Wait(1000)
        else
            Wait(1500)
        end
    end
end)

-- The CAD closes if you leave the vehicle / walk away from the computer
CreateThread(function()
    while true do
        Wait(1000)
        if isOpen and not Cad.canAccess() then
            toggle(false)
            lib.notify({ description = L('client.closed_away'), type = 'inform' })
        end
    end
end)

-- Emergency: if the UI gets stuck, use /cadclose from the F8 console or chat
RegisterCommand('cadclose', function()
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    TriggerServerEvent('cad:viewerClosed')
end, false)
RegisterKeyMapping(Config.Command, L('client.keymap_toggle'), 'keyboard', Config.Key)

RegisterNetEvent('cad:update', function(state)
    if isOpen then SendNUIMessage({ action = 'update', state = state }) end
end)

RegisterNetEvent('cad:forceClose', function() toggle(false) end)

-- Message between units (shown as a card on screen while the CAD is closed)
RegisterNetEvent('cad:message', function(m)
    local mine = m.from == cache.serverId
    SendNUIMessage({ action = 'message', msg = m, mine = mine, sound = not muted and not mine,
        volume = Config.Sound.Volume })
end)

------------------------------------------------------------------ Civilian call commands
function Cad.publicCall(kind, anon, msg)
    if not msg or msg == '' then
        return lib.notify({ description = L('client.usage_call', kind .. (anon and 'a' or '')), type = 'error' })
    end
    local loc = Cad.location()
    local r = lib.callback.await('cad:publicCall', false,
        { kind = kind, anon = anon, message = msg, address = loc.address, area = loc.area, county = loc.county })
    lib.notify({
        description = (r and r.ok) and L('client.call_sent') or (r and r.err or L('client.call_failed')),
        type = (r and r.ok) and 'success' or 'error',
    })
end

RegisterCommand('911', function(_, args) Cad.publicCall('911', false, table.concat(args, ' ')) end, false)
RegisterCommand('911a', function(_, args) Cad.publicCall('911', true, table.concat(args, ' ')) end, false)
RegisterCommand('311', function(_, args) Cad.publicCall('311', false, table.concat(args, ' ')) end, false)

------------------------------------------------------------------ New call notification (sound + card + blip)
local callBlips = {}

local function removeCallBlips(id)
    for _, b in ipairs(callBlips[id] or {}) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    callBlips[id] = nil
end

local function addCallBlips(c)
    removeCallBlips(c.id)
    if not (c.coords and c.coords.x) then return end
    local colour = c.color or Config.PriorityBlipColors[c.priority] or 1
    local list = {}
    local b = AddBlipForCoord(c.coords.x + 0.0, c.coords.y + 0.0, (c.coords.z or 0.0) + 0.0)
    SetBlipSprite(b, c.sprite or 161)
    SetBlipColour(b, colour)
    SetBlipScale(b, c.critical and 1.3 or 1.1)
    SetBlipFlashes(b, c.priority == 3 or c.critical == true)
    SetBlipAsShortRange(b, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(('#%s %s%s'):format(c.id, c.title, (c.count or 1) > 1 and (' ×' .. c.count) or ''))
    EndTextCommandSetBlipName(b)
    list[1] = b
    if c.radius and c.radius > 0 then
        local rb = AddBlipForRadius(c.coords.x + 0.0, c.coords.y + 0.0, (c.coords.z or 0.0) + 0.0, c.radius + 0.0)
        SetBlipColour(rb, colour)
        SetBlipAlpha(rb, 90)
        list[2] = rb
    end
    callBlips[c.id] = list
    local id = c.id
    SetTimeout(Config.BlipSeconds * 1000, function()
        if callBlips[id] == list then removeCallBlips(id) end
    end)
end

local function distanceTo(co)
    if not (co and co.x) then return nil end
    local p = GetEntityCoords(cache.ped)
    local dx, dy = p.x - co.x, p.y - co.y
    return math.floor(math.sqrt(dx * dx + dy * dy))
end

local function frontendSound(critical)
    if muted or not Config.Sound.Frontend then return end
    if critical then
        CreateThread(function()
            for _ = 1, 2 do PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true) Wait(700) end
        end)
    else
        PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)
    end
end

RegisterNetEvent('cad:newCall', function(c)
    lastAlert = { id = c.id, coords = c.coords, t = GetGameTimer() }
    c.distance = distanceTo(c.coords)
    SendNUIMessage({ action = 'alert', call = c, sound = not muted, volume = Config.Sound.Volume,
        key = Config.RespondKey, seconds = Config.AlertSeconds, max = Config.Dispatch.MaxVisible })
    frontendSound(c.critical)
    if Config.UseOxNotify then
        lib.notify({
            title = L('client.call_title', c.id),
            description = ('%s\n%s %s'):format(c.title, c.address or '', (c.postal and c.postal ~= '') and ('[' .. c.postal .. ']') or ''),
            type = c.priority == 3 and 'error' or 'inform', duration = 8000,
        })
    end
    addCallBlips(c)
end)

-- New alert from the same incident: the card and blip are updated (×N)
RegisterNetEvent('cad:alertMerge', function(m)
    SendNUIMessage({ action = 'alertMerge', data = m, sound = not muted and m.escalated, volume = Config.Sound.Volume })
    local list = callBlips[m.id]
    if list and m.coords then
        for _, b in ipairs(list) do
            if DoesBlipExist(b) then SetBlipCoords(b, m.coords.x + 0.0, m.coords.y + 0.0, (m.coords.z or 0.0) + 0.0) end
        end
        if m.escalated and list[1] then SetBlipFlashes(list[1], true) end
    end
end)

RegisterNetEvent('cad:callClosed', function(id)
    removeCallBlips(id)
    SendNUIMessage({ action = 'alertClosed', id = id })
end)

-- Direct notification that does not open a call (SendTargetedAlert)
RegisterNetEvent('cad:directAlert', function(a)
    SendNUIMessage({ action = 'direct', data = a, sound = not muted, volume = Config.Sound.Volume })
end)

-- Join the latest alert + waypoint
RegisterCommand(Config.RespondCommand, function()
    if not lastAlert or GetGameTimer() - lastAlert.t > Config.RespondWindow * 1000 then
        return lib.notify({ description = L('client.no_alert'), type = 'error' })
    end
    local r = lib.callback.await('cad:attach', false, { id = lastAlert.id })
    if lastAlert.coords then SetNewWaypoint(lastAlert.coords.x + 0.0, lastAlert.coords.y + 0.0) end
    if r and r.ok then SendNUIMessage({ action = 'alertAccepted', id = lastAlert.id }) end
    lib.notify({ description = (r and r.ok) and L('client.assigned', lastAlert.id) or L('client.join_failed'),
        type = (r and r.ok) and 'success' or 'error' })
    lastAlert = nil
end, false)
RegisterKeyMapping(Config.RespondCommand, L('client.keymap_respond'), 'keyboard', Config.RespondKey)

RegisterCommand(Config.MuteCommand, function()
    muted = not muted
    SetResourceKvpInt('knb_cad:muted', muted and 1 or 0)
    lib.notify({ description = muted and L('client.sound_off') or L('client.sound_on'), type = 'inform' })
end, false)

------------------------------------------------------------------ Quick plate lookup
RegisterCommand(Config.QuickPlateCommand, function(_, args)
    local plate = table.concat(args, ' ')
    if plate == '' then
        return lib.notify({ description = L('client.usage_plate', Config.QuickPlateCommand), type = 'error' })
    end
    local r = lib.callback.await('cad:quickPlate', false, { plate = plate })
    if not r or not r.plate then
        return lib.notify({ description = L('client.no_permission'), type = 'error' })
    end
    lib.notify({
        title = L('client.plate_title', r.plate),
        description = L('client.plate_body', r.model or '-', r.firstname or '-', r.lastname or '',
            r.bolo and ('\nBOLO: ' .. r.bolo.reason) or '',
            r.ownerWanted and ('\n' .. L('client.owner_wanted')) or ''),
        type = (r.bolo or r.ownerWanted) and 'error' or 'inform', duration = 9000,
    })
end, false)

------------------------------------------------------------------ NUI bridge
-- If the server does not answer, do not make the NUI request wait forever (otherwise the UI locks up)
local function serverCall(name, data, timeout)
    local p, done = promise.new(), false
    lib.callback(name, false, function(r)
        if done then return end
        done = true
        p:resolve(r)
    end, data)
    SetTimeout(timeout or 8000, function()
        if done then return end
        done = true
        print(L('client.server_no_answer', name))
        p:resolve({ ok = false, err = L('client.server_timeout') })
    end)
    return Citizen.Await(p)
end

for _, name in ipairs({ 'lookup', 'lookupVehicle', 'setBolo', 'createRecord', 'setStatus', 'setCallsign',
    'attach', 'detach', 'closeCall', 'myCall', 'callDetail', 'updateCall', 'addNote',
    'profile', 'setLicense', 'recordDetail', 'deleteRecord', 'setWarrant', 'wanted',
    'callHistory', 'historyCall', 'reports', 'messages', 'sendMessage',
    'updateRecord', 'reviewRecord', 'myReports', 'pendingReports', 'reportCounts', 'recordBrief',
    'shift', 'addrHistory', 'lookupWeapon' }) do
    RegisterNUICallback(name, function(data, cb)
        cb(serverCall('cad:' .. name, data) or {})
    end)
end

-- The NUI asks for its strings once on load (and retries until the client script is ready)
RegisterNUICallback('locale', function(_, cb)
    cb(Locale.all())
end)

-- Location (and the nearby vehicle if requested) when the Create Call window opens
RegisterNUICallback('locInfo', function(d, cb)
    local loc = Cad.location()
    if d and d.vehicle then
        local veh = lib.getClosestVehicle(GetEntityCoords(cache.ped), 25.0, false)
        loc.vehicle = Cad.vehicleInfo(veh or cache.vehicle)
    end
    cb(loc)
end)

RegisterNUICallback('createCall', function(d, cb)
    local loc = Cad.location()
    d.coords = loc.coords
    if not d.address or d.address == '' then d.address = loc.address end
    if not d.area or d.area == '' then d.area = loc.area end
    if not d.county or d.county == '' then d.county = loc.county end
    if not d.postal or d.postal == '' then d.postal = loc.postal end
    cb(serverCall('cad:createCall', d) or {})
end)

-- Request backup (to the call if on one, otherwise a new backup call at the current position)
RegisterNUICallback('backup', function(d, cb)
    local loc = Cad.location()
    cb(serverCall('cad:backup', { code = d.code, address = loc.address, area = loc.area, county = loc.county,
        postal = loc.postal }) or {})
end)

RegisterNUICallback('panic', function(_, cb) cb({ ok = Cad.panic() }) end)

-- "Accept" on the notification card: join the call + route
RegisterNUICallback('respond', function(d, cb)
    local r = serverCall('cad:attach', { id = d.id }) or {}
    if r.ok and d.x and d.y then SetNewWaypoint(tonumber(d.x) + 0.0, tonumber(d.y) + 0.0) end
    lastAlert = nil
    cb(r)
end)

RegisterNUICallback('waypoint', function(d, cb)
    SetNewWaypoint((tonumber(d.x) or 0) + 0.0, (tonumber(d.y) or 0) + 0.0)
    cb(1)
end)

RegisterNUICallback('close', function(_, cb)
    toggle(false)
    cb(1)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then SetNuiFocus(false, false) end
end)
