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

-- =====================================================================
-- knb_cad (MDC) · SINGLE SQL FILE
-- This file sets up all of the MDC's tables FROM SCRATCH.
--
-- !!! WARNING: It first DROPS the existing MDC tables (cad_calls, cad_records, cad_bolos).
-- !!! Old calls, reports, warrants and BOLOs are permanently lost.
-- !!! If you want to keep the records, back up the database before running it.
--
-- It does not touch other tables such as players, player_vehicles or inventory.
-- =====================================================================

DROP TABLE IF EXISTS `cad_calls`;
DROP TABLE IF EXISTS `cad_records`;
DROP TABLE IF EXISTS `cad_bolos`;

CREATE TABLE IF NOT EXISTS `cad_calls` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `code` VARCHAR(16) NOT NULL DEFAULT '',
    `title` VARCHAR(128) NOT NULL DEFAULT '',
    `priority` TINYINT NOT NULL DEFAULT 2,
    `status` VARCHAR(16) NOT NULL DEFAULT 'ACTIVE',
    `address` VARCHAR(128) NOT NULL DEFAULT '',
    `postal` VARCHAR(16) NOT NULL DEFAULT '',
    `area` VARCHAR(64) NOT NULL DEFAULT '',
    `county` VARCHAR(32) NOT NULL DEFAULT '',
    `agency` VARCHAR(32) NOT NULL DEFAULT '',
    `caller` VARCHAR(64) NOT NULL DEFAULT '',
    `message` VARCHAR(255) NOT NULL DEFAULT '',
    `coords` VARCHAR(96) NOT NULL DEFAULT '{}',
    `vehicle` VARCHAR(255) NOT NULL DEFAULT '{}',
    `jobs` VARCHAR(128) NOT NULL DEFAULT '',
    `log` LONGTEXT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_status` (`status`)
);

CREATE TABLE IF NOT EXISTS `cad_records` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `type` VARCHAR(16) NOT NULL,
    `citizenid` VARCHAR(50) NOT NULL DEFAULT '',
    `title` VARCHAR(128) NOT NULL DEFAULT '',
    `status` VARCHAR(16) NOT NULL DEFAULT '',
    `review` VARCHAR(16) NOT NULL DEFAULT '',
    `reviewer` VARCHAR(64) NOT NULL DEFAULT '',
    `review_note` VARCHAR(255) NOT NULL DEFAULT '',
    `call_id` INT NULL,
    `author` VARCHAR(64) NOT NULL DEFAULT '',
    `author_cid` VARCHAR(50) NOT NULL DEFAULT '',
    `callsign` VARCHAR(16) NOT NULL DEFAULT '',
    `data` LONGTEXT NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_citizenid` (`citizenid`),
    INDEX `idx_type_status` (`type`, `status`),
    INDEX `idx_call` (`call_id`),
    INDEX `idx_review` (`review`),
    INDEX `idx_author` (`author_cid`)
);

CREATE TABLE IF NOT EXISTS `cad_bolos` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `kind` VARCHAR(8) NOT NULL DEFAULT 'vehicle',
    `plate` VARCHAR(12) NOT NULL DEFAULT '',
    `citizenid` VARCHAR(50) NOT NULL DEFAULT '',
    `name` VARCHAR(64) NOT NULL DEFAULT '',
    `reason` VARCHAR(255) NOT NULL DEFAULT '',
    `author` VARCHAR(64) NOT NULL DEFAULT '',
    `active` TINYINT(1) NOT NULL DEFAULT 1,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_plate` (`plate`),
    INDEX `idx_person` (`kind`, `citizenid`)
);
