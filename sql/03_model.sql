/*
   DIALER ANALYTICS  -  03_model.sql  (SQL Server)
   Build schema in schema [dw] from table [clean] and [raw].
 
   Grain:
     fact_calls        : 1 row = 1 call (1 dialing attempt)
     fact_agent_daily  : 1 row = 1 agent per day (used to calculate Occupancy)
 
   Dimension (conformed): dim_date, dim_agent
*/


USE DialerDB;
GO

IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
GO

-- Remove step by step: fact table first, dimension later (because it has fkey)
DROP TABLE IF EXISTS dw.fact_calls, dw.fact_agent_daily, dw.dim_date, dw.dim_hour, dw.dim_call_result, dw.dim_campaign, dw.dim_agent, dw.dim_lead;
GO


-- Dim_Date (1/8/26 - 31/10/26)
CREATE TABLE dw.dim_date (
    date_key         INT         NOT NULL PRIMARY KEY,   -- yyyymmdd
    full_date        DATE        NOT NULL,
    year_num         SMALLINT    NOT NULL,
    month_num        TINYINT     NOT NULL,
    month_name       VARCHAR(3)  NOT NULL,
    year_month       CHAR(7)     NOT NULL,               -- 2026-08
    iso_weekday      TINYINT     NOT NULL,               -- 1 = Monday ... 7 = Sunday
    day_name         VARCHAR(3)  NOT NULL,
    week_start_date  DATE        NOT NULL,               -- Monday at the beginning of the week
    is_operating_day BIT         NOT NULL                -- Moday - Saturday
);
GO

;WITH n AS (
    SELECT TOP (92) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
)
INSERT INTO dw.dim_date (date_key, full_date, year_num, month_num, month_name, year_month, iso_weekday, day_name, week_start_date, is_operating_day)
SELECT YEAR(x.d) * 10000 + MONTH(x.d) * 100 + DAY(x.d),
       x.d,
       YEAR(x.d),
       MONTH(x.d),
       CHOOSE(MONTH(x.d), 'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'),
       CONVERT(CHAR(7), x.d, 120),
       x.wd,
       CHOOSE(x.wd, 'Mon','Tue','Wed','Thu','Fri','Sat','Sun'),
       DATEADD(DAY, 1 - x.wd, x.d),
       CASE WHEN x.wd < 7 THEN 1 ELSE 0 END
FROM n
CROSS APPLY (SELECT DATEADD(DAY, n.i, CAST('2026-08-01' AS DATE)) AS d, ((DATEPART(WEEKDAY, DATEADD(DAY, n.i, CAST('2026-08-01' AS DATE))) + @@DATEFIRST - 2) % 7) + 1 AS wd) AS x;
GO


-- Dim_Hour (calling time + time group)
CREATE TABLE dw.dim_hour (
    hour_key        TINYINT      NOT NULL PRIMARY KEY,
    hour_label      VARCHAR(11)  NOT NULL,
    day_part        VARCHAR(20)  NOT NULL,
    day_part_order  TINYINT      NOT NULL,
    in_call_window  BIT          NOT NULL
);
GO

;WITH h AS (
    SELECT TOP (24) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS h
    FROM sys.all_objects
)
INSERT INTO dw.dim_hour (hour_key, hour_label, day_part, day_part_order, in_call_window)
SELECT h,
       RIGHT('0' + CAST(h AS VARCHAR(2)), 2) + ':00-' + RIGHT('0' + CAST(h AS VARCHAR(2)), 2) + ':59',
       CASE WHEN h < 8 OR h >= 21 THEN 'Outside window'
            WHEN h < 11 THEN 'Morning 08-11'
            WHEN h < 14 THEN 'Midday 11-14'
            WHEN h < 17 THEN 'Afternoon 14-17'
            ELSE 'Evening 17-21' END,
       CASE WHEN h < 8 OR h >= 21 THEN 5
            WHEN h < 11 THEN 1 WHEN h < 14 THEN 2 WHEN h < 17 THEN 3 ELSE 4 END,
       CASE WHEN h >= 8 AND h < 21 THEN 1 ELSE 0 END
FROM h;
GO

-- Dim_Call_Result
CREATE TABLE dw.dim_call_result (
    result_key   TINYINT     NOT NULL PRIMARY KEY,
    call_result  VARCHAR(20) NOT NULL,
    result_group VARCHAR(25) NOT NULL,
    sort_order   TINYINT     NOT NULL
);

INSERT INTO dw.dim_call_result (result_key, call_result, result_group, sort_order) VALUES
 (1,  'Sale',         'Right Party Contact', 1),
 (2,  'Interested',   'Right Party Contact', 2),
 (3,  'Callback',     'Right Party Contact', 3),
 (4,  'Refused',      'Right Party Contact', 4),
 (5,  'Wrong Number', 'Other Contact',       5),
 (6,  'Abandoned',    'Other Contact',       6),
 (7,  'No Answer',    'No Contact',          7),
 (8,  'Busy',         'No Contact',          8),
 (9,  'Voicemail',    'No Contact',          9),
 (10, 'Unreachable',  'No Contact',         10);
GO

-- Dim_Campaign
CREATE TABLE dw.dim_campaign (
    campaign_key       INT IDENTITY(1,1) PRIMARY KEY,
    campaign_id        NVARCHAR(20)  NOT NULL UNIQUE,
    campaign_name      NVARCHAR(100) NOT NULL,
    product            NVARCHAR(50)  NOT NULL,
    dialer_mode        NVARCHAR(30)  NOT NULL,
    max_attempts       TINYINT       NOT NULL,
    abandon_threshold  DECIMAL(4,3)  NOT NULL
);

INSERT INTO dw.dim_campaign (campaign_id, campaign_name, product, dialer_mode, max_attempts, abandon_threshold)
SELECT campaign_id, campaign_name, product, dialer_mode,
       TRY_CAST(max_attempts AS TINYINT), TRY_CAST(abandon_threshold AS DECIMAL(4,3))
FROM raw.campaigns
ORDER BY campaign_id;
GO

-- Dim_Agent (key 0: 'no agent': use for Abandoned call)
CREATE TABLE dw.dim_agent (
    agent_key    INT IDENTITY(1,1) PRIMARY KEY,
    agent_id     NVARCHAR(50)  NOT NULL UNIQUE,
    agent_name   NVARCHAR(100) NOT NULL,
    team_id      NVARCHAR(20)  NOT NULL,
    team_leader  NVARCHAR(20)  NOT NULL,
    campaign_id  NVARCHAR(20)  NOT NULL,
    hire_date    DATE          NULL,
    tenure_band  VARCHAR(10)   NOT NULL
);
SET IDENTITY_INSERT dw.dim_agent ON;

INSERT INTO dw.dim_agent (agent_key, agent_id, agent_name, team_id, team_leader, campaign_id, hire_date, tenure_band)
VALUES (0, 'N/A', 'No agent (abandoned)', 'N/A', 'N/A', 'N/A', NULL, 'N/A');
SET IDENTITY_INSERT dw.dim_agent OFF;
 
INSERT INTO dw.dim_agent (agent_id, agent_name, team_id, team_leader, campaign_id, hire_date, tenure_band)
SELECT a.agent_id, a.agent_name, a.team_id, a.team_leader, a.campaign_id, h.hd,
       CASE WHEN DATEDIFF(MONTH, h.hd, '2026-10-31') < 12 THEN '<1y'
            WHEN DATEDIFF(MONTH, h.hd, '2026-10-31') < 24 THEN '1-2y'
            WHEN DATEDIFF(MONTH, h.hd, '2026-10-31') < 36 THEN '2-3y'
            ELSE '3y+' END
FROM raw.agents AS a
CROSS APPLY (SELECT TRY_CAST(a.hire_date AS DATE) AS hd) AS h
ORDER BY a.agent_id;
GO


-- Dim_Lead
CREATE TABLE dw.dim_lead (
    lead_key        INT IDENTITY(1,1) PRIMARY KEY,
    lead_id         NVARCHAR(50)  NOT NULL UNIQUE,
    master_lead_id  NVARCHAR(50)  NOT NULL,
    is_duplicate    BIT           NOT NULL,
    phone_std       NVARCHAR(15)  NOT NULL,
    source          NVARCHAR(50)  NOT NULL,
    province        NVARCHAR(50)  NOT NULL,
    region          VARCHAR(10)   NOT NULL,
    age             TINYINT       NULL,
    age_band        VARCHAR(10)   NOT NULL,
    income_band     NVARCHAR(20)  NULL,
    import_date     DATE          NULL
);

INSERT INTO dw.dim_lead (lead_id, master_lead_id, is_duplicate, phone_std, source, province, region, age, age_band, income_band, import_date)
SELECT l.lead_id, l.master_lead_id, l.is_duplicate, l.phone_std, l.source, l.province,
       CASE WHEN l.province IN ('Ho Chi Minh','Binh Duong','Dong Nai','Can Tho') THEN 'South'
            WHEN l.province IN ('Ha Noi','Hai Phong') THEN 'North'
            WHEN l.province IN ('Da Nang','Khanh Hoa','Nghe An','Lam Dong') THEN 'Central'
            ELSE 'Unknown' END,
       l.age,
       CASE WHEN l.age IS NULL THEN 'Unknown'
            WHEN l.age <= 25 THEN '18-25'
            WHEN l.age <= 35 THEN '26-35'
            WHEN l.age <= 45 THEN '36-45'
            WHEN l.age <= 55 THEN '46-55'
            ELSE '56+' END,
       l.income_band, l.import_date
FROM clean.leads AS l
ORDER BY l.lead_id;
GO


-- Fact_Call:
CREATE TABLE dw.fact_calls (
    call_id              NVARCHAR(20)  NOT NULL PRIMARY KEY,                       -- degenerate dimension
    date_key             INT           NOT NULL REFERENCES dw.dim_date(date_key),
    hour_key             TINYINT       NOT NULL REFERENCES dw.dim_hour(hour_key),
    lead_key             INT           NOT NULL REFERENCES dw.dim_lead(lead_key),
    agent_key            INT           NOT NULL REFERENCES dw.dim_agent(agent_key),
    campaign_key         INT           NOT NULL REFERENCES dw.dim_campaign(campaign_key),
    result_key           TINYINT       NOT NULL REFERENCES dw.dim_call_result(result_key),
    call_start           DATETIME2(0)  NOT NULL,
    attempt_no           TINYINT       NULL,   
    phone_attempt_no     TINYINT       NULL,    
    ring_sec             SMALLINT      NULL,
    wait_sec             DECIMAL(6,1)  NULL,
    talk_sec             INT           NULL,
    hold_sec             SMALLINT      NULL,
    wrap_sec             SMALLINT      NULL,
    handle_sec           INT           NULL,
    is_contact           BIT           NOT NULL,
    is_rpc               BIT           NOT NULL,
    is_sale              BIT           NOT NULL,
    flag_out_of_window   BIT           NOT NULL,
    flag_over_attempt    BIT           NOT NULL,
    flag_dnc_violation   BIT           NOT NULL,
    flag_talk_invalid    BIT           NOT NULL
);
GO

INSERT INTO dw.fact_calls
SELECT c.call_id,
       YEAR(c.call_date) * 10000 + MONTH(c.call_date) * 100 + DAY(c.call_date),
       c.call_hour,
       l.lead_key,
       ISNULL(a.agent_key, 0),
       cp.campaign_key,
       r.result_key,
       c.call_start,
       c.attempt_no,
       c.phone_attempt_no,
       c.ring_sec,
       c.wait_sec,
       c.talk_sec,
       c.hold_sec,
       c.wrap_sec,
       CASE WHEN c.is_contact = 1 AND c.call_result <> 'Abandoned' AND c.talk_sec IS NOT NULL
            THEN c.talk_sec + ISNULL(c.hold_sec, 0) + ISNULL(c.wrap_sec, 0) END,
       c.is_contact, c.is_rpc, c.is_sale,
       c.flag_out_of_window, c.flag_over_attempt, c.flag_dnc_violation, c.flag_talk_invalid
FROM clean.call_log AS c
JOIN dw.dim_lead        AS l  ON l.lead_id       = c.lead_id
JOIN dw.dim_campaign    AS cp ON cp.campaign_id  = c.campaign_id
JOIN dw.dim_call_result AS r  ON r.call_result   = c.call_result
LEFT JOIN dw.dim_agent  AS a  ON a.agent_id      = c.agent_id;
GO


-- Fact_Agent_Daily
CREATE TABLE dw.fact_agent_daily (
    date_key   INT NOT NULL REFERENCES dw.dim_date(date_key),
    agent_key  INT NOT NULL REFERENCES dw.dim_agent(agent_key),
    login_sec  INT NOT NULL,
    break_sec  INT NOT NULL,
    busy_sec   INT NOT NULL,
    idle_sec   INT NOT NULL,
    PRIMARY KEY (date_key, agent_key)
);
GO

INSERT INTO dw.fact_agent_daily (date_key, agent_key, login_sec, break_sec, busy_sec, idle_sec)
SELECT YEAR(w.wd) * 10000 + MONTH(w.wd) * 100 + DAY(w.wd),
       a.agent_key,
       TRY_CAST(d.login_sec AS INT), TRY_CAST(d.break_sec AS INT),
       TRY_CAST(d.busy_sec  AS INT), TRY_CAST(d.idle_sec  AS INT)
FROM raw.agent_daily AS d
CROSS APPLY (SELECT TRY_CAST(d.work_date AS DATE) AS wd) AS w
JOIN dw.dim_agent AS a ON a.agent_id = d.agent_id;
GO



---- Double-check:
-- Number of rows in each table
SELECT 'dim_date' AS tbl, COUNT(*) AS n FROM dw.dim_date UNION ALL
SELECT 'dim_hour',         COUNT(*)      FROM dw.dim_hour UNION ALL
SELECT 'dim_call_result',  COUNT(*)      FROM dw.dim_call_result UNION ALL
SELECT 'dim_campaign',     COUNT(*)      FROM dw.dim_campaign UNION ALL
SELECT 'dim_agent',        COUNT(*)      FROM dw.dim_agent UNION ALL
SELECT 'dim_lead',         COUNT(*)      FROM dw.dim_lead UNION ALL
SELECT 'fact_calls',       COUNT(*)      FROM dw.fact_calls UNION ALL
SELECT 'fact_agent_daily', COUNT(*)      FROM dw.fact_agent_daily;
 
-- The fact table must match clean.call_log exactly (no rows lost or duplicated due to JOINs)
SELECT (SELECT COUNT(*) FROM clean.call_log) AS clean_rows, (SELECT COUNT(*) FROM dw.fact_calls)  AS fact_rows;
 
-- Overall KPIs and Campaign-level KPIs
SELECT cp.campaign_id, cp.dialer_mode,
       COUNT(*)                                                           AS calls,
       SUM(CAST(f.is_contact AS INT))                                     AS contacts,
       CAST(100.0 * SUM(CAST(f.is_contact AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS contact_rate_pct,
       CAST(100.0 * SUM(CASE WHEN r.call_result = 'Abandoned' THEN 1 ELSE 0 END)
                  / NULLIF(SUM(CAST(f.is_contact AS INT)), 0) AS DECIMAL(5,2)) AS abandon_rate_pct,
       CAST(AVG(CAST(f.handle_sec AS FLOAT)) AS DECIMAL(6,1))             AS aht_sec
FROM dw.fact_calls AS f
JOIN dw.dim_campaign    AS cp ON cp.campaign_key = f.campaign_key
JOIN dw.dim_call_result AS r  ON r.result_key     = f.result_key
GROUP BY cp.campaign_id, cp.dialer_mode
ORDER BY cp.campaign_id;
 
-- Overall Occupancy (expectation ~ 55.37%)
SELECT CAST(100.0 * SUM(CAST(busy_sec AS BIGINT)) / (SUM(CAST(login_sec AS BIGINT)) - SUM(CAST(break_sec AS BIGINT))) AS DECIMAL(5,2)) AS occupancy_pct
FROM dw.fact_agent_daily;