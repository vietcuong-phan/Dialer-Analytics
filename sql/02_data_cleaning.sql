/*
   DIALER PERFORMANCE & DATA ALLOCATION ANALYTICS
   02_cleaning.sql  -  SQL Server (T-SQL)
 
   Prerequisite: All 6 CSV files must be imported into the [raw] schema: raw.leads, raw.call_log, raw.dnc_list, raw.agents, raw.campaigns, raw.agent_daily
   IMPORT NOTE: The phone columns (leads, dnc_list) must be NVARCHAR/VARCHAR. If imported as numeric types, leading zeros will be lost.

   Principle: 1. DO NOT modify data in [raw]. All transformations must be performed in [clean]. 
              2. Retain all rows that can be preserved and assign flags; only delete records when they are confirmed duplicates.
*/

USE DialerDB;
GO

IF SCHEMA_ID('clean') IS NULL EXEC('CREATE SCHEMA clean');
GO

-- Clean Leads table:
DROP TABLE IF EXISTS clean.leads;
GO

WITH s AS (
    SELECT l.*,
           -- remove white space, slash, plus, dot
           REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(l.phone)), ' ', ''), '-', ''), '+', ''), '.', '') AS p1
    FROM raw.leads AS l
),
t AS (
    SELECT s.*,
           -- 84901234567 (11 so) -> 0901234567
           CASE WHEN LEFT(p1, 2) = '84' AND LEN(p1) = 11
                THEN '0' + SUBSTRING(p1, 3, 9)
                ELSE p1 END AS phone_std
    FROM s
)
SELECT
    t.lead_id,
    t.full_name,
    t.phone                                              AS phone_raw,
    t.phone_std,
    t.source,
    COALESCE(NULLIF(LTRIM(RTRIM(t.province)), ''), 'Unknown') AS province,
    CASE WHEN TRY_CAST(t.age AS INT) BETWEEN 18 AND 70
         THEN TRY_CAST(t.age AS INT) END                 AS age,            -- invalid age -> NULL
    CASE WHEN TRY_CAST(t.age AS INT) BETWEEN 18 AND 70
         THEN 1 ELSE 0 END                               AS age_valid,
    t.income_band,
    t.campaign_id,
    CAST(t.import_date AS DATE)                          AS import_date,
    -- duplicated phone number: keep the earliest lead for "master"
    ROW_NUMBER() OVER (PARTITION BY t.phone_std
                       ORDER BY t.import_date, t.lead_id) AS phone_rank
INTO clean.leads
FROM t;
GO

ALTER TABLE clean.leads ADD master_lead_id NVARCHAR(20) NULL;
GO
UPDATE l
SET    l.master_lead_id = m.lead_id
FROM   clean.leads AS l
JOIN   clean.leads AS m ON m.phone_std = l.phone_std AND m.phone_rank = 1;
GO
ALTER TABLE clean.leads ADD is_duplicate AS (CASE WHEN phone_rank > 1 THEN 1 ELSE 0 END);
GO


-- Clean Dnc_list:
DROP TABLE IF EXISTS clean.dnc_list;
GO

SELECT DISTINCT
       LTRIM(RTRIM(phone))               AS phone,
       CAST(added_date AS DATE)          AS added_date,
       reason
INTO clean.dnc_list
FROM raw.dnc_list;
GO


-- Call_log: remove duplicated rows, label standardization, talk_sec processing 
DROP TABLE IF EXISTS clean.call_log;
GO

WITH d AS (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY c.call_id ORDER BY (SELECT NULL)) AS rn
    FROM raw.call_log AS c
)
SELECT
    d.call_id,
    d.lead_id,
    NULLIF(NULLIF(LTRIM(RTRIM(d.agent_id)), ''), 'NULL')       AS agent_id,   -- Abandoned: have no agent (valid)
    d.campaign_id,
    d.dialer_mode,
    TRY_CAST(d.call_start AS DATETIME2(0))                     AS call_start,
    CAST(TRY_CAST(d.call_start AS DATETIME2(0)) AS DATE)       AS call_date,
    DATEPART(HOUR, TRY_CAST(d.call_start AS DATETIME2(0)))     AS call_hour,
    TRY_CAST(d.attempt_no AS INT)                              AS attempt_no,
    CASE LOWER(LTRIM(RTRIM(REPLACE(d.call_result, '_', ' '))))
         WHEN 'no answer'    THEN 'No Answer'
         WHEN 'busy'         THEN 'Busy'
         WHEN 'voicemail'    THEN 'Voicemail'
         WHEN 'unreachable'  THEN 'Unreachable'
         WHEN 'wrong number' THEN 'Wrong Number'
         WHEN 'abandoned'    THEN 'Abandoned'
         WHEN 'sale'         THEN 'Sale'
         WHEN 'sold'         THEN 'Sale'
         WHEN 'interested'   THEN 'Interested'
         WHEN 'callback'     THEN 'Callback'
         WHEN 'refused'      THEN 'Refused'
         WHEN 'refuse'       THEN 'Refused'
         ELSE 'UNMAPPED' END                                   AS call_result,
    TRY_CAST(d.ring_sec AS INT)                                AS ring_sec,
    TRY_CAST(d.wait_sec AS DECIMAL(6,1))                       AS wait_sec,
    -- talk_sec <0 or >2 hours -> NULL (keep call, remove from AHT)
    CASE WHEN TRY_CAST(d.talk_sec AS INT) BETWEEN 0 AND 7200
         THEN TRY_CAST(d.talk_sec AS INT) END                  AS talk_sec,
    CASE WHEN TRY_CAST(d.talk_sec AS INT) BETWEEN 0 AND 7200
         THEN 0 ELSE 1 END                                     AS flag_talk_invalid,
    TRY_CAST(d.hold_sec AS INT)                                AS hold_sec,
    TRY_CAST(d.wrap_sec AS INT)                                AS wrap_sec
INTO clean.call_log
FROM d
WHERE d.rn = 1;
GO


-- Double-check: Have no tag named 'UNMAPPED'
-- SELECT call_result, COUNT(*) FROM clean.call_log GROUP BY call_result;
 
/* ---- cot dan xuat + co tuan thu ---- */
ALTER TABLE clean.call_log ADD
    phone_std            NVARCHAR(15) NULL,
    master_lead_id       NVARCHAR(20) NULL,
    phone_attempt_no     INT          NULL,
    is_contact           BIT NOT NULL DEFAULT 0,   -- customer received
    is_rpc               BIT NOT NULL DEFAULT 0,   -- connect to right people
    is_sale              BIT NOT NULL DEFAULT 0,
    flag_out_of_window   BIT NOT NULL DEFAULT 0,   -- out of time: 08:00-21:00
    flag_over_attempt    BIT NOT NULL DEFAULT 0,   -- > 5 times / phone number
    flag_dnc_violation   BIT NOT NULL DEFAULT 0;   -- call later after DNC
GO
 
UPDATE c
SET    c.phone_std      = l.phone_std,
       c.master_lead_id = l.master_lead_id
FROM   clean.call_log AS c
JOIN   clean.leads    AS l ON l.lead_id = c.lead_id;
GO
 
UPDATE clean.call_log
SET    is_contact = CASE WHEN call_result IN ('Sale','Interested','Callback','Refused','Abandoned','Wrong Number') THEN 1 ELSE 0 END,
       is_rpc     = CASE WHEN call_result IN ('Sale','Interested','Callback','Refused') THEN 1 ELSE 0 END,
       is_sale    = CASE WHEN call_result = 'Sale' THEN 1 ELSE 0 END,
       flag_out_of_window = CASE WHEN call_hour < 8 OR call_hour >= 21 THEN 1 ELSE 0 END;
GO
 
-- Count the number of calls by PHONE NUMBER (not lead_id), since duplicate leads may still belong to the same person
;WITH x AS (
    SELECT call_id,
           ROW_NUMBER() OVER (PARTITION BY phone_std ORDER BY call_start, call_id) AS rn
    FROM clean.call_log
)
UPDATE c
SET    c.phone_attempt_no  = x.rn,
       c.flag_over_attempt = CASE WHEN x.rn > 5 THEN 1 ELSE 0 END
FROM   clean.call_log AS c
JOIN   x ON x.call_id = c.call_id;
GO
 
UPDATE c
SET    c.flag_dnc_violation = 1
FROM   clean.call_log AS c
JOIN   clean.dnc_list AS d ON d.phone = c.phone_std
WHERE  c.call_date >= d.added_date;
GO

-- Cleaning History:
DROP TABLE IF EXISTS clean.cleaning_log;
CREATE TABLE clean.cleaning_log (
    log_id        INT IDENTITY(1,1) PRIMARY KEY,
    table_name    VARCHAR(30),
    issue         VARCHAR(120),
    rows_affected INT,
    action_taken  VARCHAR(160)
);
GO
INSERT INTO clean.cleaning_log (table_name, issue, rows_affected, action_taken)
SELECT 'leads', 'Phone not in 0xxxxxxxxx format', COUNT(*), 'Standardized to 10 digits starting with 0'
FROM clean.leads WHERE phone_raw <> phone_std
UNION ALL
SELECT 'leads', 'Duplicate phone (different lead_id)', COUNT(*), 'Kept earliest as master, flagged is_duplicate'
FROM clean.leads WHERE phone_rank > 1
UNION ALL
SELECT 'leads', 'Missing province', COUNT(*), 'Set to Unknown'
FROM clean.leads WHERE province = 'Unknown'
UNION ALL
SELECT 'leads', 'Invalid age', COUNT(*), 'Set to NULL, age_valid = 0'
FROM clean.leads WHERE age_valid = 0
UNION ALL
SELECT 'call_log', 'Duplicate call rows (same call_id)', (SELECT COUNT(*) FROM raw.call_log) - COUNT(*), 'Removed extra copies'
FROM clean.call_log
UNION ALL
SELECT 'call_log', 'Invalid talk_sec (<0 or >7200)', COUNT(*), 'Set to NULL, excluded from AHT'
FROM clean.call_log WHERE flag_talk_invalid = 1
UNION ALL
SELECT 'call_log', 'Calls outside 08:00-21:00', COUNT(*), 'Flagged flag_out_of_window'
FROM clean.call_log WHERE flag_out_of_window = 1
UNION ALL
SELECT 'call_log', 'Calls beyond 5th attempt per phone', COUNT(*), 'Flagged flag_over_attempt'
FROM clean.call_log WHERE flag_over_attempt = 1
UNION ALL
SELECT 'call_log', 'Calls made after DNC date', COUNT(*), 'Flagged flag_dnc_violation'
FROM clean.call_log WHERE flag_dnc_violation = 1;
GO