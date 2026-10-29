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

-- Automatic dispatch. Event detection, weapon classification and vehicle description are adapted from
-- Project Sloth ps-dispatch (client/eventhandlers.lua, client/utils.lua, client/alerts.lua · GPL-3.0) source code.

local D = Config.Dispatch

local function playerData() return exports.qbx_core:GetPlayerData() end

-- Job table if the player has an on-duty MDC job (police/medical)
local function dutyJob()
    local pd = playerData()
    local j = pd and pd.job
    if j and j.onduty and (Config.Jobs[j.name] or Config.JobTypes[j.type]) then return j end
end
Cad.dutyJob = dutyJob

local function isEms(j) return j.type == 'ems' or j.name == 'ambulance' end
local function isLeo(j) return j and not isEms(j) end

local function genderLabel()
    local pd = playerData()
    local g = pd and pd.charinfo and pd.charinfo.gender
    return tonumber(g) == 1 and L('gender.female') or L('gender.male')
end

------------------------------------------------------------------ Weapon recognition (weapon table + classification)
local WEAPON_NAMES = {
    [584646201] = 'AP Pistol', [453432689] = 'Pistol', [3219281620] = 'Pistol MK2', [1593441988] = 'Combat Pistol',
    [-1716589765] = 'Heavy Pistol', [-1076751822] = 'SNS Pistol', [-771403250] = 'Desert Eagle',
    [137902532] = 'Vintage Pistol', [-598887786] = 'Marksman Pistol', [-1045183535] = 'Revolver',
    [324215364] = 'Micro SMG', [-619010992] = 'Machine Pistol', [736523883] = 'SMG', [2024373456] = 'SMG MK2',
    [-270015777] = 'Assault SMG', [171789620] = 'Combat PDW', [-1660422300] = 'Combat MG', [3686625920] = 'Combat MG MK2',
    [1627465347] = 'Gusenberg', [-1121678507] = 'Mini SMG', [-1074790547] = 'Assault Rifle', [961495388] = 'Assault Rifle MK2',
    [-2084633992] = 'Carbine Rifle', [4208062921] = 'Carbine Rifle MK2', [-1357824103] = 'Advanced Rifle',
    [-1063057011] = 'Special Carbine', [2132975508] = 'Bullpup Rifle', [1649403952] = 'Compact Rifle',
    [100416529] = 'Sniper Rifle', [205991906] = 'Heavy Sniper', [177293209] = 'Heavy Sniper MK2',
    [-952879014] = 'Marksman Rifle', [487013001] = 'Pump Shotgun', [2017895192] = 'Sawed-Off Shotgun',
    [-1654528753] = 'Bullpup Shotgun', [-494615257] = 'Assault Shotgun', [-1466123874] = 'Musket',
    [984333226] = 'Heavy Shotgun', [-275439685] = 'Double Barrel Shotgun', [317205821] = 'Sweeper Shotgun',
    [-1568386805] = 'Grenade Launcher', [-1312131151] = 'RPG', [125959754] = 'Compact Launcher', [1119849093] = 'Minigun',
}
-- Class from the weapon group (for add-on weapons that are not in the name table)
local GROUP_CLASS = {
    [416676503] = 'pistol', [-957766203] = 'smg', [860033945] = 'shotgun', [970310034] = 'rifle',
    [1159398588] = 'heavy', [-1212426201] = 'sniper', [-1569042529] = 'heavy',
}
-- Class: label + threat level (1 handgun · 2 long gun · 3 heavy). Labels come from the locale files (weapon.class.*)
local CLASS_INFO = {
    pistol = { L('weapon.class.pistol'), 1 }, taser = { L('weapon.class.taser'), 1 }, smg = { L('weapon.class.smg'), 2 }, shotgun = { L('weapon.class.shotgun'), 2 },
    rifle = { L('weapon.class.rifle'), 2 }, sniper = { L('weapon.class.sniper'), 3 }, heavy = { L('weapon.class.heavy'), 3 },
}

local function classify(name)
    local n = tostring(name or ''):lower()
    if n:find('taser') or n:find('stun') then return 'taser' end
    if n:find('rpg') or n:find('launcher') or n:find('minigun') or n:find('grenade') then return 'heavy' end
    if n:find('mg') and not n:find('smg') then return 'heavy' end
    if n:find('sniper') or n:find('marksman rifle') or n:find('musket') then return 'sniper' end
    if n:find('shotgun') or n:find('sawed') or n:find('double barrel') then return 'shotgun' end
    if n:find('smg') or n:find('pdw') or n:find('gusenberg') or n:find('machine pistol') then return 'smg' end
    if n:find('rifle') or n:find('carbine') then return 'rifle' end
    return 'pistol'
end

local UNARMED = joaat('WEAPON_UNARMED')

-- { name = 'Carbine Rifle', class = 'rifle', label = 'Assault rifle', tier = 2, auto = true }
local function weaponInfo(hash)
    hash = hash or GetSelectedPedWeapon(cache.ped)
    if not hash or hash == UNARMED then return nil end
    local name = WEAPON_NAMES[hash] or WEAPON_NAMES[hash % 4294967296] or WEAPON_NAMES[hash - 4294967296]
    local class = name and classify(name) or GROUP_CLASS[GetWeapontypeGroup(hash)] or 'pistol'
    local ci = CLASS_INFO[class]
    return { name = name or L('weapon.unknown'), class = class, label = ci[1], tier = ci[2],
        auto = class == 'smg' or class == 'rifle' or (class == 'heavy' and name ~= 'RPG') }
end

------------------------------------------------------------------ Vehicle and heading (vehicle data / player heading)
local DIRS = { L('dir.north'), L('dir.northwest'), L('dir.west'), L('dir.southwest'), L('dir.south'), L('dir.southeast'), L('dir.east'), L('dir.northeast') }
local function headingLabel(h)
    return DIRS[math.floor(((h or 0) + 22.5) / 45) % 8 + 1]
end

local CLASS_LABEL = {
    [0] = L('vehicle.class.0'), [1] = L('vehicle.class.1'), [2] = L('vehicle.class.2'), [3] = L('vehicle.class.3'), [4] = L('vehicle.class.4'), [5] = L('vehicle.class.5'), [6] = L('vehicle.class.6'),
    [7] = L('vehicle.class.7'), [8] = L('vehicle.class.8'), [9] = L('vehicle.class.9'), [10] = L('vehicle.class.10'), [11] = L('vehicle.class.11'), [12] = L('vehicle.class.12'), [13] = L('vehicle.class.13'),
    [14] = L('vehicle.class.14'), [15] = L('vehicle.class.15'), [16] = L('vehicle.class.16'), [17] = L('vehicle.class.17'), [18] = L('vehicle.class.18'), [19] = L('vehicle.class.19'), [20] = L('vehicle.class.20'),
}

local function doorCount(veh)
    local n = 0
    for _, b in ipairs({ 'door_pside_f', 'door_pside_r', 'door_dside_f', 'door_dside_r' }) do
        if GetEntityBoneIndexByName(veh, b) ~= -1 then n = n + 1 end
    end
    return n >= 2 and n or nil
end

-- Cad.vehicleInfo (plate, color, make, model) + class, door count, direction of travel
local function vehicleData(veh)
    local v = Cad.vehicleInfo(veh)
    if not v then return nil end
    v.class = CLASS_LABEL[GetVehicleClass(veh)]
    v.doors = doorCount(veh)
    v.heading = headingLabel(GetEntityHeading(veh))
    return v
end
Cad.vehicleData = vehicleData

------------------------------------------------------------------ Sending alerts
local VEH_KEYS = { VehicleShooting = true, CarJacking = true, VehicleTheft = true, CarBoosting = true, SpeedingVehicle = true }

--[[ info = { coords?, message?, extra = {'line'}, vehicleEntity?, camId?, weapon = weaponInfo?, noVehicle? } ]]
function Cad.sendAlert(key, info)
    if not Config.Alerts[key] then return end
    info = info or {}
    local loc = Cad.location(info.coords)
    local veh = info.vehicleEntity
    if not veh and VEH_KEYS[key] and not info.noVehicle then
        veh = cache.vehicle or GetVehiclePedIsTryingToEnter(cache.ped)
        if not veh or veh == 0 then veh = GetVehiclePedIsIn(cache.ped, true) end
    end
    loc.vehicle = veh and veh ~= 0 and vehicleData(veh) or nil
    loc.gender = genderLabel()
    loc.heading = loc.vehicle and loc.vehicle.heading or headingLabel(GetEntityHeading(cache.ped))
    loc.weapon = info.weapon
    loc.message = info.message
    loc.extra = info.extra
    loc.camId = info.camId
    TriggerServerEvent('knb_cad:server:alert', key, loc)
end

-- Interprets the arguments of the alert exports (camera ID, vehicle entity or table)
local function argInfo(a)
    if type(a) == 'table' then
        return { message = a.message or a.description or a.information, coords = a.coords, extra = a.extra,
            camId = a.camId, vehicleEntity = a.vehicle }
    end
    if type(a) == 'number' and a > 0 then
        if DoesEntityExist(a) and IsEntityAVehicle(a) then return { vehicleEntity = a } end
        if a < 100000 then return { camId = a } end
    end
    if type(a) == 'string' and a ~= '' then return { camId = a } end
    return {}
end

------------------------------------------------------------------ Exports (+ compatibility)
local function provideExport(name, fn)
    exports(name, fn)
    if Config.ExternalCompat then
        AddEventHandler(('__cfx_export_ps-dispatch_%s'):format(name), function(setCB) setCB(fn) end)
    end
end

for key in pairs(Config.Alerts) do
    provideExport(key, function(a)
        local info = argInfo(a)
        if key == 'Shooting' or key == 'VehicleShooting' or key == 'Hunting' then info.weapon = weaponInfo() end
        Cad.sendAlert(key, info)
    end)
end

-- exports['knb_cad']:CustomAlert({ message=, dispatchCode=, code=, description=, coords=, radius=, sprite=, color=,
--   jobs={'leo'}, priority=1-2 or cadCode=1-3, vehicle=entity, weapon=, camId=, icon= })
local function customAlert(data)
    if type(data) ~= 'table' then return end
    local loc = Cad.location(data.coords)
    local veh = data.vehicle
    if type(veh) == 'number' then veh = vehicleData(veh) end
    if type(veh) ~= 'table' and (data.plate or data.model) then
        veh = { plate = data.plate, model = data.model, color = data.firstColor or data.colour, class = data.class }
    end
    TriggerServerEvent('knb_cad:server:custom', {
        title = data.message, code = data.code or data.dispatchCode, description = data.description or data.information,
        priority = data.priority, cadCode = data.cadCode, jobs = data.jobs,
        radius = data.radius, sprite = data.sprite, color = data.color, icon = data.cadIcon,
        coords = loc.coords, address = loc.address, area = loc.area, county = loc.county,
        gender = data.gender and genderLabel() or nil, weapon = data.weapon, camId = data.camId,
        vehicle = type(veh) == 'table' and veh or nil, heading = data.heading,
    })
end
provideExport('CustomAlert', customAlert)

-- General purpose: exports['knb_cad']:SendAlert('StoreRobbery', { message = '...', extra = {'...'} })
exports('SendAlert', function(key, info) Cad.sendAlert(key, type(info) == 'table' and info or {}) end)

-- helper exports (some scripts call these too)
provideExport('GetStreetAndZone', function(coords)
    local l = Cad.location(coords)
    return l.address .. (l.area ~= '' and (', ' .. l.area) or '')
end)
provideExport('GetPlayerHeading', function() return headingLabel(GetEntityHeading(cache.ped)) end)

-- legacy client events
if Config.ExternalCompat then
    RegisterNetEvent('ps-dispatch:client:officerdown', function() Cad.sendAlert('OfficerDown') end)
    RegisterNetEvent('ps-dispatch:client:officerbackup', function() Cad.sendAlert('OfficerBackup') end)
    RegisterNetEvent('ps-dispatch:client:platebackup', function() Cad.sendAlert('OfficerBackup') end)
    RegisterNetEvent('ps-dispatch:client:emsdown', function() Cad.sendAlert('EmsDown') end)
    -- 911/311 calls from phone scripts
    RegisterNetEvent('ps-dispatch:client:sendEmergencyMsg', function(msg, kind, anonymous)
        if type(msg) == 'table' then msg = msg.message or msg.msg or '' end
        Cad.publicCall(kind == '311' and '311' or '911', anonymous and true or false, tostring(msg or ''))
    end)
end

------------------------------------------------------------------ Zones
local ignoreWeapons = {}
for _, w in ipairs(D.IgnoreWeapons) do ignoreWeapons[joaat(w)] = true end

local function inZone(list, c)
    for _, z in ipairs(list) do
        if #(c - z.coords) <= z.radius then return z end
    end
end

------------------------------------------------------------------ Detection timer
local busy = {}
local function waitTimer(name, action)
    if not D.Detect[name] or busy[name] then return end
    busy[name] = true
    CreateThread(function()
        action()
        Wait(D.DetectDelay * 1000)
        busy[name] = false
    end)
end

local function inList(list, v)
    if not list then return false end
    for _, x in pairs(list) do if x == v then return true end end
    return false
end

local function leoOnDuty()
    local j = dutyJob()
    return j and isLeo(j)
end

------------------------------------------------------------------ Gunshots
local function shotFired()
    local ped = cache.ped
    if IsPedCurrentWeaponSilenced(ped) then return end
    local weapon = GetSelectedPedWeapon(ped)
    if ignoreWeapons[weapon] then return end
    if D.IgnoreLeo and leoOnDuty() then return end
    local c = GetEntityCoords(ped)
    if inZone(D.NoDispatchZones, c) then return end
    local w = weaponInfo(weapon)
    if inZone(D.HuntingZones, c) then
        return Cad.sendAlert('Hunting', { weapon = w })
    end
    Cad.sendAlert(cache.vehicle and 'VehicleShooting' or 'Shooting', { weapon = w })
end

if D.RequireWitness then
    -- only if the game's "gunshot heard" event lists the player among the witnesses
    AddEventHandler('CEventGunShot', function(witnesses, ped)
        if ped ~= cache.ped then return end
        if witnesses and not inList(witnesses, ped) then return end
        waitTimer('Shooting', shotFired)
    end)
else
    -- No witness check: every time the player shoots (at DetectDelay intervals)
    CreateThread(function()
        while true do
            local sleep = 500
            if cache.weapon and D.Detect.Shooting then
                sleep = 0
                if IsPedShooting(cache.ped) then waitTimer('Shooting', shotFired) end
            end
            Wait(sleep)
        end
    end)
end

------------------------------------------------------------------ Fights, carjacking, vehicle alarm, explosions
AddEventHandler('CEventShockingSeenMeleeAction', function(witnesses, ped)
    if ped ~= cache.ped then return end
    if D.RequireWitness and witnesses and not inList(witnesses, ped) then return end
    waitTimer('Melee', function()
        if not IsPedInMeleeCombat(ped) then return end
        if D.IgnoreLeo and leoOnDuty() then return end
        Cad.sendAlert('Fight')
    end)
end)

AddEventHandler('CEventPedJackingMyVehicle', function(_, ped)
    if ped ~= cache.ped then return end
    waitTimer('CarJacking', function()
        Cad.sendAlert('CarJacking', { vehicleEntity = GetVehiclePedIsUsing(ped, true) })
    end)
end)

AddEventHandler('CEventShockingCarAlarm', function(_, ped)
    if ped ~= cache.ped then return end
    waitTimer('VehicleTheft', function()
        Cad.sendAlert('VehicleTheft', { vehicleEntity = GetVehiclePedIsUsing(ped, true) })
    end)
end)

AddEventHandler('CEventExplosionHeard', function(witnesses, ped)
    if witnesses and not inList(witnesses, ped) then return end
    waitTimer('Explosion', function() Cad.sendAlert('Explosion', { noVehicle = true }) end)
end)

------------------------------------------------------------------ Excessive speed / dangerous driving
local SPEED_EVENTS = {
    'CEventShockingCarChase', 'CEventShockingDrivingOnPavement', 'CEventShockingBicycleOnPavement',
    'CEventShockingMadDriverBicycle', 'CEventShockingMadDriverExtreme', 'CEventShockingEngineRevved',
    'CEventShockingInDangerousVehicle',
}
local EXEMPT_CLASS = { [15] = true, [16] = true, [18] = true }
local lastSpeed = 0
for _, ev in ipairs(SPEED_EVENTS) do
    AddEventHandler(ev, function(_, ped)
        if ped ~= cache.ped then return end
        waitTimer('Speeding', function()
            if GetGameTimer() - lastSpeed < 10000 then return end
            local veh = cache.vehicle
            if not veh or GetPedInVehicleSeat(veh, -1) ~= ped then return end
            if D.IgnoreLeo and leoOnDuty() then return end
            if EXEMPT_CLASS[GetVehicleClass(veh)] then return end
            if GetEntitySpeed(veh) * 3.6 < D.SpeedLimit + math.random(0, 20) then return end
            lastSpeed = GetGameTimer()
            Cad.sendAlert('SpeedingVehicle', { extra = { L('client.est_speed', math.floor(GetEntitySpeed(veh) * 3.6)) } })
        end)
    end)
end

------------------------------------------------------------------ Going down (officer / medic / civilian)
local function isDown(ped)
    if IsEntityDead(ped) or IsPedFatallyInjured(ped) then return true end
    local st = LocalPlayer.state
    if st.isDead or st.inLastStand or st.laststand then return true end
    local pd = playerData()
    local md = pd and pd.metadata
    if md and (md.isdead or md.inlaststand) then return true end
    if GetResourceState('qbx_medical') == 'started' then
        local ok, r = pcall(function() return exports.qbx_medical:IsDead() or exports.qbx_medical:IsLaststand() end)
        if ok and r then return true end
    end
    return false
end

CreateThread(function()
    local wasDown = false
    while true do
        Wait(1000)
        local down = D.Detect.PlayerDowned and isDown(cache.ped)
        if down and not wasDown then
            local j = dutyJob()
            if j then
                Cad.sendAlert(isEms(j) and 'EmsDown' or 'OfficerDown')
            elseif D.CivilianDowned then
                Cad.sendAlert('InjuriedPerson')
            end
        end
        wasDown = down
    end
end)

------------------------------------------------------------------ Assault on an officer
local lastInjured = -math.huge
AddEventHandler('gameEventTriggered', function(name, args)
    if not D.Detect.OfficerInjured or name ~= 'CEventNetworkEntityDamage' then return end
    local victim, attacker = args[1], args[2]
    if victim ~= cache.ped or attacker == victim or not attacker or attacker == 0 then return end
    if not DoesEntityExist(attacker) then return end
    if GetGameTimer() - lastInjured < 20000 then return end
    local j = dutyJob()
    if not j or isDown(cache.ped) then return end
    -- If the attacker is a vehicle, take its driver (hit by a vehicle)
    if IsEntityAVehicle(attacker) then attacker = GetPedInVehicleSeat(attacker, -1) end
    if not attacker or attacker == 0 or not IsEntityAPed(attacker) then return end
    lastInjured = GetGameTimer()
    local w = IsPedArmed(attacker, 4) and weaponInfo(GetSelectedPedWeapon(attacker)) or nil
    Cad.sendAlert('OfficerInjured', { weapon = w })
end)

------------------------------------------------------------------ Panic button
function Cad.panic()
    if not dutyJob() then
        lib.notify({ description = L('client.panic_duty_only'), type = 'error' })
        return false
    end
    Cad.sendAlert('OfficerInDistress')
    lib.notify({ description = L('client.panic_sent'), type = 'error' })
    return true
end
RegisterCommand(Config.PanicCommand, function() Cad.panic() end, false)
RegisterKeyMapping(Config.PanicCommand, L('client.keymap_panic'), 'keyboard', Config.PanicKey)
