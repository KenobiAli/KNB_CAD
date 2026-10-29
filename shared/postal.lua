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

-- Finds the nearest postal code from the postal file (data/postals.json).
-- File format: [{"code":"3001","x":-1157.19,"y":4938.10}, ...]
Postal = {}

local list, byCode

local function load()
    if list then return end
    list, byCode = {}, {}
    local res = Config.PostalResource or GetCurrentResourceName()
    local raw = LoadResourceFile(res, Config.PostalFile)
    local ok, data = pcall(json.decode, raw or '')
    if not ok or type(data) ~= 'table' then
        print(L('shared.err_postal', res, Config.PostalFile))
        return
    end
    for _, p in ipairs(data) do
        local x, y = tonumber(p.x), tonumber(p.y)
        if x and y and p.code then
            local e = { code = tostring(p.code), x = x, y = y }
            list[#list + 1] = e
            byCode[e.code] = e
        end
    end
end

-- Nearest postal code ('' = not found)
function Postal.nearest(x, y)
    load()
    local best, bd = nil, math.huge
    for i = 1, #list do
        local p = list[i]
        local dx, dy = p.x - x, p.y - y
        local d = dx * dx + dy * dy
        if d < bd then bd, best = d, p end
    end
    return best and best.code or ''
end

-- Coordinates by postal code ({code, x, y} | nil)
function Postal.find(code)
    load()
    return byCode[tostring(code or '')]
end
