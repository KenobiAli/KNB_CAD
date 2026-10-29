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

-- Unit positions for the MDC map. The in-game GPS / minimap blips are not handled here;
-- this file only passes positions to the map while the MDC is open and reports the emergency vehicle the officer is in to the server.

RegisterNetEvent('cad:tracking', function(list)
    if Cad.isOpen and Cad.isOpen() then SendNUIMessage({ action = 'tracking', list = list or {} }) end
end)

-- Report to the server when getting into an emergency vehicle (this is the vehicle tracked on the MDC map)
local function report(veh)
    if veh and Cad.isCadVehicle(veh) and NetworkGetEntityIsNetworked(veh) then
        TriggerServerEvent('cad:myVehicle', VehToNet(veh))
    end
end

lib.onCache('vehicle', function(veh) if veh then report(veh) end end)
CreateThread(function()
    Wait(3000)
    report(cache.vehicle) -- in case you are already in a vehicle when the resource restarts
end)
