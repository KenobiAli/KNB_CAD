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

Config = {}

-- Language of the whole resource (CAD UI, notifications, logs): the file name in locales/ without .json.
-- Shipped: 'en', 'tr'. Add your own by copying locales/en.json to locales/<code>.json.
Config.Locale = 'en'

Config.Command = 'cad'
Config.Key = 'F10'

-- Places where the CAD panel can be opened. Alert notifications, sound, [Y] respond and panic work everywhere.
Config.Access = {
    Vehicle = true,              -- while inside an emergency vehicle (GTA vehicle class 18: police, ambulance, fire truck)
    ExtraVehicles = {            -- vehicle models that are not class 18 but should count as CAD vehicles (for add-on vehicles)
        -- 'fbi2', 'mypolicecar',
    },
    Computer = true,             -- while standing next to a computer prop
    ComputerDistance = 1.8,      -- how close you must be to the computer at most (meters)
    ComputerModels = {
        'prop_monitor_01a', 'prop_monitor_01b', 'prop_monitor_01c', 'prop_monitor_01d', 'prop_monitor_02',
        'prop_monitor_03b', 'prop_monitor_04a', 'prop_monitor_w_large', 'prop_monitor_li', 'prop_ld_monitor_01',
        'prop_trailer_monitor_01', 'v_res_monitor', 'prop_pc_01a', 'prop_pc_02a', 'prop_dyn_pc', 'prop_dyn_pc_02',
        'prop_laptop_01a', 'prop_laptop_02_closed', 'prop_laptop_jimmy', 'prop_laptop_lester', 'prop_laptop_lester2',
        'p_laptop_02_s',
    },
    -- If the computers in your station MLOs use a different model, add them here as coordinates:
    Terminals = {
        -- example: Mission Row front desk
    },
}

-- Departments (by job name). For each department:
--   name    : agency name shown in the report headers
--   short   : abbreviation shown in the CAD (unit list, call agency)
--   color   : main color of the report forms
--   theme   : interface look of the MDC: lspd, lssd, sahp, bcso (empty = default look)
--   motto   : optional line shown under the agency name
--   pages   : tabs it can see in the MDC: dash (Incidents), map (Map), lookup (Lookup), records (Reports),
--             wanted (Wanted/BOLO), messages (Messages), units (Units/Shift), history (History)
--   reports : report types it can write: arrest, crime, followup, citation, warrant
-- Pages and reports that are not listed are also blocked on the server side.
local ALL_PAGES = { 'dash', 'map', 'lookup', 'records', 'wanted', 'messages', 'units', 'history' }
local ALL_REPORTS = { 'arrest', 'crime', 'followup', 'citation', 'warrant' }
Config.Departments = {
    police    = { name = 'LOS SANTOS POLICE DEPARTMENT',      short = 'LSPD', color = '#1f3a6e', theme = 'lspd', motto = 'TO PROTECT AND TO SERVE',    pages = ALL_PAGES, reports = ALL_REPORTS },
    sheriff   = { name = 'LOS SANTOS SHERIFF DEPARTMENT',     short = 'LSSD', color = '#1e4a2c', theme = 'lssd', motto = 'A TRADITION OF SERVICE',     pages = ALL_PAGES, reports = ALL_REPORTS },
    highway   = { name = 'SAN ANDREAS HIGHWAY PATROL',        short = 'SAHP', color = '#2b2b2b', theme = 'sahp', motto = 'SAFETY · SERVICE · SECURITY', pages = ALL_PAGES, reports = ALL_REPORTS },
    bcso      = { name = 'BLAINE COUNTY SHERIFF DEPARTMENT',  short = 'BCSO', color = '#6b3f1d', theme = 'bcso', motto = 'SERVING BLAINE COUNTY',      pages = ALL_PAGES, reports = ALL_REPORTS },
    ambulance = { name = 'LOS SANTOS MEDICAL SERVICES',       short = 'EMS',  color = '#8a1f24', pages = { 'dash' }, reports = {} },
}
-- Which department settings to use by job type when the job name is not listed above
Config.DepartmentByType = { leo = 'police', ems = 'ambulance' }

-- Jobs (job name) and job types (Qbox job.type) that can access the CAD
Config.Jobs = { police = true, sheriff = true, highway = true, bcso = true, ambulance = true }
Config.JobTypes = { leo = true, ems = true }

-- Agency for automatic alerts, by county
Config.CountyAgency = { ['LOS SANTOS'] = 'LSPD', ['BLAINE'] = 'BCSO' }

-- Units that share the same callsign form a team (partners in the same vehicle):
-- joining/leaving a call and status changes apply to the whole team, and team members in the same vehicle show as a single blip on the map.
-- If false, every callsign belongs to a single unit.
Config.CallsignGroups = true

-- The callsign is shared with other resources (the player's metadata.callsign field): a callsign entered in the MDC is the same as one set with /callsign,
-- and one set with /callsign is the same in the MDC.
-- true: the callsign is not persistent; it is cleared when you load into the game and when you go on/off duty, and must be entered again.
Config.ResetCallsign = true

-- Unit statuses (the first entry is the default status). The keys must stay fixed; the display names are in locales/*.json (status.*).
Config.Statuses = { 'AVAILABLE', 'EN ROUTE', 'ON SCENE', 'CODE 7', 'REPORT', 'TRANSPORT', 'BUSY', 'OFF DUTY' }
Config.OffDutyStatus = 'OFF DUTY'
-- Color and F key shown in the MDC (if key is empty, the status can only be picked from the status menu). Labels come from the locale files.
Config.StatusInfo = {
    ['AVAILABLE'] = { label = L('status.available'),  color = '#2fae5b', key = 'F1' },
    ['EN ROUTE']  = { label = L('status.en_route'),   color = '#3b82f6', key = 'F2' },
    ['ON SCENE']  = { label = L('status.on_scene'),  color = '#e09a2b', key = 'F3' },
    ['CODE 7']    = { label = L('status.code_7'),  color = '#8b5cf6', key = 'F4' },
    ['REPORT']    = { label = L('status.report'),   color = '#94a3b8', key = 'F5' },
    ['TRANSPORT'] = { label = L('status.transport'),   color = '#94a3b8', key = 'F6' },
    ['BUSY']      = { label = L('status.busy'),  color = '#a1a1aa', key = '' },
    ['OFF DUTY']  = { label = L('status.off_duty'), color = '#52525b', key = '' },
}
-- If a unit has been on CODE 6 for this many minutes, the MDC shows a "status check" warning (0 = off)
Config.StatusCheckMinutes = 20

-- Record types. arrest = Arrest Report, crime = Crime Report, followup = Follow-up Investigation,
-- citation = Citation, warrant = Arrest Warrant. report = legacy "Incident Report" (view only),
-- license = automatic record of license actions.
Config.RecordTypes = { arrest = true, crime = true, followup = true, citation = true, warrant = true, report = true, license = true }

-- Supervisor approval: types set to true are saved as "PENDING APPROVAL"; a supervisor at the Config.Permissions.approveReport
-- grade approves them or requests corrections. A report that needs corrections is edited by its author and submitted again.
Config.Reports = {
    RequireApproval = { arrest = true, crime = true, followup = true, citation = false, warrant = false },
    SelfApprove = false,  -- can a supervisor approve their own report?
}

-- Civilian call commands: /911 [message], /311 [message], /911a [message] (anonymous)
Config.CallCooldown = 30      -- between two calls from the same player (seconds)

-- Quick plate lookup for on-duty units: /plate ABC123
Config.QuickPlateCommand = 'plate'
-- Panic button for on-duty officers/medics: /panic  (if the key is empty, players bind it themselves)
Config.PanicCommand = 'panic'
Config.PanicKey = ''
-- Join the latest alert + mark it on the map
Config.RespondCommand = 'cadrespond'
Config.RespondKey = 'Y'
Config.RespondWindow = 30     -- how many seconds after an alert arrives it can still be answered
-- Toggle the call sound for yourself: /cadmute
Config.MuteCommand = 'cadmute'

-- Date format in the incident log (os.date)
Config.DateFormat = '%d/%m/%Y %H:%M:%S'

-- Postal file. Default: data/postals.json inside this resource (1687 postals).
-- To use a file from another resource: Config.PostalResource = '<resource name>' and Config.PostalFile = '<file path inside that resource>'
--   (that file must be listed in files{} of that resource so the client can read it.)
Config.PostalResource = nil
Config.PostalFile = 'data/postals.json'

-- When the location does not come from the client (server exports etc.), everything north of this Y coordinate counts as BLAINE
Config.BlaineMinY = 1500.0

-- County options and the GTA zone codes that count as Blaine
Config.Counties = { 'LOS SANTOS', 'BLAINE' }
Config.BlaineZones = {
    'ALAMO', 'ARMYB', 'BRADP', 'BRADT', 'CALAFB', 'CANNY', 'CCREAK', 'CMSW', 'DESRT', 'ELGORL', 'GALFISH',
    'GRAPES', 'GREATC', 'HARMO', 'HUMLAB', 'JAIL', 'LAGO', 'MTCHIL', 'MTGORDO', 'MTJOSE', 'NCHU', 'PALCOV',
    'PALETO', 'PALFOR', 'PROCOB', 'RTRAK', 'SANAND', 'SANCHIA', 'SANDY', 'SLAB', 'WINDF', 'ZANCUDO', 'ZQ_UAR',
}

-- New alert notification
Config.AlertSeconds = 10      -- how long the on-screen notification card stays (seconds)
Config.UseOxNotify = false    -- true: also show an ox_lib notification
Config.Sound = {
    Volume = 0.35,            -- 0.0 - 1.0 (played through the NUI, also audible while the CAD is closed)
    Frontend = false,         -- true: also play the game's own beep sound
}
Config.BlipSeconds = 90       -- how long a call blip stays on the map
Config.PriorityBlipColors = { [1] = 2, [2] = 47, [3] = 1 } -- Code 1 green, Code 2 orange, Code 3 red

-- Ready-made templates in the "Create Call" window (priority: 1-3 = Code 1-3). Titles come from the locale files (template.*).
Config.CallTemplates = {
    { title = L('template.1'),               priority = 1 },
    { title = L('template.2'), priority = 1 },
    { title = L('template.3'),                 priority = 3 },
    { title = L('template.4'),           priority = 3 },
    { title = L('template.5'),                 priority = 2 },
    { title = L('template.6'),                  priority = 3 },
    { title = L('template.7'),                    priority = 3 },
    { title = L('template.8'),                   priority = 3 },
    { title = L('template.9'),                 priority = 2 },
    { title = L('template.10'),                        priority = 3 },
}

------------------------------------------------------------------ Automatic dispatch
-- The detection logic is adapted from the Project Sloth ps-dispatch (GPL-3.0) source code.
-- Other scripts' robbery / alert calls (e.g. StoreRobbery) are routed straight to the MDC (see Config.ExternalCompat).
Config.Dispatch = {
    -- Events detected automatically in game
    Detect = {
        Shooting       = true,  -- gunshots (including shooting from a vehicle)
        Melee          = true,  -- fights (if an NPC sees it)
        CarJacking     = true,  -- carjacking (pulling the driver out)
        VehicleTheft   = true,  -- vehicle alarm went off
        Explosion      = true,  -- explosions
        Speeding       = true,  -- dangerous / excessive-speed driving
        PlayerDowned   = true,  -- officer / medic / civilian went down
        OfficerInjured = true,  -- assault on an on-duty officer
    },
    RequireWitness = true,   -- gunshots and fights are only reported if an NPC witness saw them
    IgnoreLeo = true,        -- shooting / speeding by on-duty police is not reported
    DetectDelay = 5,         -- between two automatic detections of the same type (sec)
    SpeedLimit = 130,        -- km/h; 0-20 random is added on top
    CivilianDowned = true,   -- when a civilian goes down, send an "injured civilian" alert to EMS
    IgnoreWeapons = {        -- weapons that do not create an alert when fired
        'WEAPON_STUNGUN', 'WEAPON_STUNGUN_MP', 'WEAPON_FIREEXTINGUISHER', 'WEAPON_PETROLCAN', 'WEAPON_HAZARDCAN',
        'WEAPON_SNOWBALL', 'WEAPON_BALL', 'WEAPON_FLARE', 'WEAPON_FLAREGUN', 'WEAPON_GRENADE', 'WEAPON_BZGAS',
        'WEAPON_MOLOTOV', 'WEAPON_STICKYBOMB', 'WEAPON_PROXMINE', 'WEAPON_PIPEBOMB', 'WEAPON_SMOKEGRENADE',
        'WEAPON_RAYCARBINE',
    },
    -- Gunshots in these areas are not reported (shooting ranges etc.)
    NoDispatchZones = {
        { label = 'Ammu-Nation Pillbox shooting range', coords = vec3(13.53, -1097.92, 29.8), radius = 18.0 },
        { label = 'Ammu-Nation Cypress shooting range', coords = vec3(821.96, -2163.09, 29.62), radius = 18.0 },
    },
    -- Gunshots in hunting zones are reported as "illegal hunting" (Code 1)
    HuntingZones = {
        { label = 'Hunting Zone', coords = vec3(-938.61, 4823.99, 313.92), radius = 650.0 },
    },
    PhoneRequired = false,   -- does /911 /311 require a phone item?
    PhoneItems = { 'phone' },

    -- Server side
    RateLimit = { Max = 12, Window = 10 },        -- per player: at most Max alerts within Window seconds
    Merge = { Radius = 80.0, Seconds = 90, EscalateAt = 4 }, -- same type + nearby + short time = a single call (×N); at N>=EscalateAt it becomes Code 3
    Offset = { Min = 10, Max = 120 },             -- offset for approximate-location alerts (m). The real location is not sent to officers.
    Hotspot = { Window = 30, Threshold = 3 },     -- Threshold separate calls on the same street within Window min = "HOT SPOT"
    AutoClose = 20,          -- automatic alert with no unit assigned closes itself after this many minutes (0 = off)
    UnattendedAfter = 3,     -- min: "UNANSWERED" badge on a call with no unit assigned
    MaxVisible = 4,          -- how many notification cards are visible on screen at once
    TestCommand = 'dispatchtest', -- sample alert command for on-duty officers (false = off)
}

-- If the alert location is farther than this from the player's real position, the player's position is used (anti-cheat)
Config.MaxAlertDistance = 300.0
-- Cooldown for the same title in custom alerts (CustomAlert / alert event) (sec)
Config.CustomAlertCooldown = 10
-- Route robbery / alert export calls from other scripts to this resource
Config.ExternalCompat = true
-- Also route legacy server-event alert calls to the MDC
Config.ExternalBridge = true

local LEO, EMS, ALL = { 'leo' }, { 'ems' }, { 'leo', 'ems' }
--[[ Alert type:
    (the first field is left empty: alerts are not shown with 10-codes), title, priority (1-3 = Code 1-3), jobs, cooldown (seconds per player)
    o = { officer = only triggered by an on-duty officer, critical = CRITICAL (pinned to the top, distinct alarm),
          offset = approximate location (circle with a radius), radius = circle (m), sprite/color = map blip } ]]
local function A(_, title, priority, jobs, cooldown, o)
    o = o or {}
    return { code = '', title = title, priority = priority, jobs = jobs, cooldown = cooldown or 30, officer = o.officer,
        critical = o.critical, offset = o.offset, radius = o.radius, sprite = o.sprite, color = o.color }
end

-- Key names are the alert export names (e.g. StoreRobbery)
Config.Alerts = {
    -- Detected automatically
    Shooting           = A('', L('alert.Shooting'),                 3, LEO, 30, { offset = true, radius = 110.0, sprite = 110, color = 1 }),
    VehicleShooting    = A('', L('alert.VehicleShooting'),        3, LEO, 30, { offset = true, radius = 110.0, sprite = 119, color = 1 }),
    Hunting            = A('', L('alert.Hunting'),           1, LEO, 60, { sprite = 141, color = 2 }),
    Fight              = A('', L('alert.Fight'),                      2, LEO, 45, { offset = true, radius = 60.0, sprite = 685, color = 69 }),
    CarJacking         = A('', L('alert.CarJacking'),                 2, LEO, 45, { offset = true, radius = 80.0, sprite = 595, color = 60 }),
    VehicleTheft       = A('', L('alert.VehicleTheft'),    2, LEO, 45, { offset = true, radius = 80.0, sprite = 595, color = 60 }),
    Explosion          = A('', L('alert.Explosion'),                    3, ALL, 30, { offset = true, radius = 75.0, sprite = 436, color = 1 }),
    SpeedingVehicle    = A('', L('alert.SpeedingVehicle'), 1, LEO, 60, { sprite = 326, color = 84 }),

    -- Officer / medic alarms
    OfficerDown        = A('', L('alert.OfficerDown'),           3, ALL, 60, { officer = true, critical = true, sprite = 526, color = 1 }),
    OfficerInjured     = A('', L('alert.OfficerInjured'),            3, ALL, 60, { officer = true, sprite = 526, color = 1 }),
    EmsDown            = A('', L('alert.EmsDown'), 3, ALL, 60, { officer = true, critical = true, sprite = 526, color = 3 }),
    OfficerInDistress  = A('', L('alert.OfficerInDistress'),               3, ALL, 20, { officer = true, critical = true, sprite = 526, color = 1 }),
    OfficerBackup      = A('', L('alert.OfficerBackup'),              3, LEO, 20, { officer = true, sprite = 526, color = 1 }),

    -- Robberies
    StoreRobbery       = A('', L('alert.StoreRobbery'),             3, LEO, 30, { sprite = 52,  color = 1 }),
    FleecaBankRobbery  = A('', L('alert.FleecaBankRobbery'),       3, LEO, 30, { critical = true, sprite = 500, color = 2 }),
    PaletoBankRobbery  = A('', L('alert.PaletoBankRobbery'),       3, LEO, 30, { critical = true, sprite = 500, color = 12 }),
    PacificBankRobbery = A('', L('alert.PacificBankRobbery'),      3, LEO, 30, { critical = true, sprite = 500, color = 5 }),
    VangelicoRobbery   = A('', L('alert.VangelicoRobbery'),            3, LEO, 30, { critical = true, sprite = 434, color = 5 }),
    ArtGalleryRobbery  = A('', L('alert.ArtGalleryRobbery'),     3, LEO, 30, { sprite = 269, color = 59 }),
    YachtHeist         = A('', L('alert.YachtHeist'),                3, LEO, 30, { sprite = 455, color = 60 }),
    UnionRobbery       = A('', L('alert.UnionRobbery'),   3, LEO, 30, { critical = true, sprite = 500, color = 60 }),
    HumaneRobbery      = A('', L('alert.HumaneRobbery'),        3, LEO, 30, { critical = true, sprite = 499, color = 1 }),
    TrainRobbery       = A('', L('alert.TrainRobbery'),               3, LEO, 30, { sprite = 667, color = 78 }),
    VanRobbery         = A('', L('alert.VanRobbery'),        3, LEO, 30, { sprite = 67,  color = 59 }),
    UndergroundRobbery = A('', L('alert.UndergroundRobbery'),            3, LEO, 30, { sprite = 486, color = 59 }),
    DrugBoatRobbery    = A('', L('alert.DrugBoatRobbery'), 3, LEO, 30, { sprite = 427, color = 26 }),
    BobcatSecurityHeist= A('', L('alert.BobcatSecurityHeist'),    3, LEO, 30, { critical = true, sprite = 500, color = 5 }),
    HouseRobbery       = A('', L('alert.HouseRobbery'),                 2, LEO, 30, { offset = true, radius = 60.0, sprite = 40, color = 5 }),
    SignRobbery        = A('', L('alert.SignRobbery'),          1, LEO, 30, { sprite = 358, color = 60 }),
    PrisonBreak        = A('', L('alert.PrisonBreak'),             3, LEO, 30, { critical = true, sprite = 189, color = 59 }),

    -- Other
    CarBoosting        = A('', L('alert.CarBoosting'),      2, LEO, 30, { sprite = 595, color = 60 }),
    SuspiciousActivity = A('', L('alert.SuspiciousActivity'),            1, LEO, 30, { offset = true, radius = 130.0, sprite = 66, color = 37 }),
    DrugSale           = A('', L('alert.DrugSale'),          1, LEO, 30, { offset = true, radius = 120.0, sprite = 469, color = 52 }),
    InjuriedPerson     = A('', L('alert.InjuriedPerson'),            2, EMS, 60, { sprite = 126, color = 3 }),
    DeceasedPerson     = A('', L('alert.DeceasedPerson'),        2, EMS, 60, { sprite = 126, color = 3 }),
}
-- For scripts that call it with the old spelling (old misspelling)
Config.Alerts.HumaneRobery = Config.Alerts.HumaneRobbery

------------------------------------------------------------------ Permissions (grade)
-- Minimum job grade level required (0 = everyone). In Qbox grade levels start at 0.
Config.Permissions = {
    closeCall    = 0,   -- closing a call
    deleteRecord = 3,   -- deleting a record
    voidWarrant  = 2,   -- voiding a warrant (serving one is open to everyone)
    licenses     = 2,   -- suspending / reinstating licenses
    approveReport = 3,  -- approving reports / requesting corrections
}

------------------------------------------------------------------ Citizen profile
-- Qbox metadata.licences keys -> name shown in the CAD (labels come from the locale files, license.*)
Config.Licenses = { driver = L('license.driver'), weapon = L('license.weapon'), business = L('license.business') }

-- Driver license points: when the points from fines in the last WindowDays days reach Limit, a warning appears on the profile
Config.Points = { WindowDays = 30, Limit = 12 }

------------------------------------------------------------------ Messaging
Config.Messages = { Keep = 200, Cooldown = 1 }  -- number of latest messages kept in memory, seconds between messages

------------------------------------------------------------------ Penal code
-- Fines: if "collect" is ticked when saving the record and the person is in game, it is deducted from their account
Config.Fines = { Enabled = true, Account = 'bank' }

-- Jail: set Enabled = true and connect your own prison script inside Hook.
-- targetSrc: the player going to jail, months: total sentence (months), officerSrc: the officer who opened the record
Config.Jail = {
    Enabled = false,
    Hook = function(targetSrc, months, officerSrc, recordId)
        -- Examples (enable one depending on the script you use):
        -- exports['xt-prison']:SetJailTime(targetSrc, months)
        -- TriggerEvent('prison:server:SetJailStatus', targetSrc, months)
        -- TriggerClientEvent('police:client:SendToJail', targetSrc, months)
    end,
}

Config.PenalClasses = {
    infraction  = { label = L('penal.class.infraction'),    color = '#2e9d4f' },
    misdemeanor = { label = L('penal.class.misdemeanor'),  color = '#d4861f' },
    felony      = { label = L('penal.class.felony'), color = '#d6322f' },
}

-- The list of offenses and categories is in shared/penalcode.lua (CA Laws; titles come from the locale files).

------------------------------------------------------------------ Unit positions on the MDC map
-- The MDC does not create in-game GPS / minimap blips of its own.
-- This setting only affects the Map tab in the MDC and the small map in the incident detail: the emergency vehicles of on-duty units
-- that have a callsign are shown. Positions are only sent to players who have the MDC open.
Config.Tracking = {
    Enabled = true,
    Interval = 1500,            -- position update interval while the MDC is open (ms)
    Tracked = { 'leo', 'ems' }, -- who appears on the MDC map (job type or job name)
}

