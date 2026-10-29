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

-- Localization. Strings live in locales/<code>.json (flat "key": "text" maps); the language is Config.Locale.
-- L('key', a, b) replaces {1}, {2}, ... in the text with the extra arguments.
-- Missing keys fall back to English (locales/en.json), then to the key itself.
Locale = Locale or {}

local cache = {}

local function load(code)
    if cache[code] ~= nil then return cache[code] end
    local raw = LoadResourceFile(GetCurrentResourceName(), ('locales/%s.json'):format(code))
    local ok, data = pcall(json.decode, raw or '')
    cache[code] = (ok and type(data) == 'table') and data or false
    if not cache[code] and code ~= 'en' then
        print(('^3[knb_cad] Could not read locales/%s.json, falling back to English.^0'):format(code))
    end
    return cache[code]
end

local function active()
    return (Config and Config.Locale) or 'en'
end

function L(key, ...)
    local text = (load(active()) or {})[key]
    if text == nil then text = (load('en') or {})[key] end
    if text == nil then return key end
    local n = select('#', ...)
    if n == 0 then return text end
    local args = { ... }
    return (text:gsub('{(%d+)}', function(i)
        local v = args[tonumber(i)]
        if v == nil then return '' end
        return tostring(v)
    end))
end

-- All strings of the active language (English fills the gaps); sent to the NUI.
function Locale.all()
    local out = {}
    for k, v in pairs(load('en') or {}) do out[k] = v end
    local code = active()
    if code ~= 'en' then
        for k, v in pairs(load(code) or {}) do out[k] = v end
    end
    return out
end
