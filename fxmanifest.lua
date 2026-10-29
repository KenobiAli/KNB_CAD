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

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'knb_cad'
author 'kenobiali'
license 'GPL-3.0-or-later'
description 'LAPD-style MDC + dispatch system (Qbox + ox_lib + oxmysql)'
version '0.9.2'

-- Lets other scripts' alert exports reach this resource. To disable, delete this line and set Config.ExternalCompat = false in the config.
provide 'ps-dispatch'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/locale.lua',
    'config.lua',
    'shared/penalcode.lua',
    'shared/postal.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/records.lua',
    'server/messages.lua',
    'server/dispatch.lua',
    'server/tracking.lua',
}

client_scripts {
    'client/main.lua',
    'client/dispatch.lua',
    'client/tracking.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/map.js',
    'html/script.js',
    'html/reports.js',
    'html/map/*.jpg',
    'html/img/*.png',
    'data/postals.json',
    'locales/*.json',
}

dependencies { 'qbx_core', 'ox_lib', 'oxmysql' }
