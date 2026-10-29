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

-- Unit positions for the MDC map: the unit's police vehicle is tracked (people in the same vehicle share a single marker).
-- There are no in-game GPS / minimap blips in the MDC; the GPS resource shows those.
-- Positions are read from the server (OneSync) and sent only to players who have the MDC open.
local T = Config.Tracking
local unitVeh = {} -- [src] = server-side vehicle entity

local function jobIn(list, job)
    for _, j in ipairs(list) do
        if j == job.name or j == job.type then return true end
    end
    return false
end

local function vehicleKind(veh)
    local ok, t = pcall(GetVehicleType, veh)
    t = ok and t or 'automobile'
    if t == 'heli' then return 'heli' end
    if t == 'plane' then return 'plane' end
    if t == 'boat' or t == 'submarine' then return 'boat' end
    if t == 'bike' then return 'bike' end
    return 'car'
end

-- The client reports the emergency vehicle it got into. The server verifies that the player is really in that vehicle.
RegisterNetEvent('cad:myVehicle', function(netId)
    local src = source
    local p = exports.qbx_core:GetPlayer(src)
    if not (p and Cad.allowed(p)) then return end
    netId = tonumber(netId)
    if not netId then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if GetVehiclePedIsIn(GetPlayerPed(src), false) ~= veh then return end
    if unitVeh[src] ~= veh then
        unitVeh[src] = veh
        Cad.trackNow()
    end
end)

local function collect()
    local groups, order = {}, {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local p = exports.qbx_core:GetPlayer(src)
        local job = p and p.PlayerData.job
        if job and job.onduty and Cad.allowed(p) then
            local u = Cad.units[src]
            local cs = (u and Cad.validCallsign(u.callsign) and u.callsign) or Cad.savedCallsign(p)
            local offDuty = u and u.status == Config.OffDutyStatus
            local veh = unitVeh[src]
            if veh and not DoesEntityExist(veh) then
                unitVeh[src], veh = nil, nil -- vehicle was deleted / exploded and disappeared
            end
            if cs and veh and not offDuty and jobIn(T.Tracked, job) then
                local g = groups[veh]
                if not g then
                    g = { veh = veh, cs = {}, csSeen = {}, members = {}, names = {}, job = job.name }
                    groups[veh] = g
                    order[#order + 1] = veh
                end
                if not g.csSeen[cs] then
                    g.csSeen[cs] = true
                    g.cs[#g.cs + 1] = cs
                end
                g.members[#g.members + 1] = src
                local ci = p.PlayerData.charinfo
                g.names[#g.names + 1] = ('%s %s'):format(ci.firstname, ci.lastname)
            end
        end
    end

    local tracked = {}
    for _, veh in ipairs(order) do
        local g = groups[veh]
        local c = GetEntityCoords(veh)
        table.sort(g.cs)
        tracked[#tracked + 1] = {
            net = NetworkGetNetworkIdFromEntity(veh), members = g.members,
            cs = table.concat(g.cs, ' / '), x = c.x, y = c.y, z = c.z,
            h = math.floor(GetEntityHeading(veh)), k = vehicleKind(veh), job = g.job,
        }
    end
    return tracked
end

local function tick()
    -- Sent only to players who have the MDC open (the in-game GPS is separate)
    if not next(Cad.viewers) then return end
    local tracked = collect()
    for src in pairs(Cad.viewers) do TriggerClientEvent('cad:tracking', src, tracked) end
end

function Cad.trackNow()
    if T.Enabled then pcall(tick) end
end

if T.Enabled then
    CreateThread(function()
        while true do
            Wait(T.Interval)
            local ok, err = pcall(tick)
            if not ok then print(L('server.err_tracking', tostring(err))) end
        end
    end)
end

AddEventHandler('playerDropped', function()
    unitVeh[source] = nil
end)
