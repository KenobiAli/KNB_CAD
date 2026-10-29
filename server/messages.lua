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

-- CAD messaging between units (GENERAL channel + direct message to a unit). Messages are kept in memory.
local msgs, seq, last = {}, 0, {}

local function canSee(m, src)
    return m.to == 'ALL' or m.to == src or m.from == src
end

Cad.reg('messages', function(src)
    local out = {}
    for _, m in ipairs(msgs) do
        if canSee(m, src) then out[#out + 1] = m end
    end
    return out
end)

Cad.reg('sendMessage', function(src, p, d)
    local text = Cad.line(d.text, 300)
    if text == '' then return { ok = false } end
    local now = os.time()
    if last[src] and now - last[src] < Config.Messages.Cooldown then
        return { ok = false, err = L('server.err_msg_fast') }
    end
    local to = d.to == 'ALL' and 'ALL' or tonumber(d.to)
    if to ~= 'ALL' and not (to and Cad.units[to]) then return { ok = false, err = L('server.err_unit_not_found') } end
    if to ~= 'ALL' and not Cad.hasPage(exports.qbx_core:GetPlayer(to), 'messages') then
        return { ok = false, err = L('server.err_unit_no_messages') }
    end
    last[src] = now

    local u = Cad.units[src]
    local ci = p.PlayerData.charinfo
    seq = seq + 1
    local m = {
        id = seq, from = src, to = to, text = text, time = os.date('%H:%M'),
        fromName = u and ('%s · %s'):format(u.callsign, u.name) or ('%s %s'):format(ci.firstname, ci.lastname),
        toName = to == 'ALL' and L('server.channel_general') or Cad.units[to].callsign,
    }
    msgs[#msgs + 1] = m
    while #msgs > Config.Messages.Keep do table.remove(msgs, 1) end

    if to == 'ALL' then
        for _, id in ipairs(GetPlayers()) do
            local s = tonumber(id)
            local tp = exports.qbx_core:GetPlayer(s)
            if tp and Cad.allowed(tp) and Cad.hasPage(tp, 'messages') and (tp.PlayerData.job.onduty or Cad.units[s]) then
                TriggerClientEvent('cad:message', s, m)
            end
        end
    else
        TriggerClientEvent('cad:message', to, m)
        if to ~= src then TriggerClientEvent('cad:message', src, m) end
    end
    return { ok = true }
end)

AddEventHandler('playerDropped', function() last[source] = nil end)
