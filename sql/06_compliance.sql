/*
   DIALER ANALYTICS  -  06_compliance.sql  (SQL Server)
   COMPLIANCE & DATA QUALITY:
	- Check for 4 types of violations (DNC, calling time restrictions, excessive call attempts, abandon)
	- Detect abnormal agent behavior using robust z-scores
	- Generate data quality scorecards by source
	- Generate daily exception reports (stored procedure)

	Prerequisite: Steps 01–04 must have been executed (requires dw.vw_calls, clean.dnc_list, clean.leads).
	Convention: Abandon rate = abandoned calls / answered calls; threshold: 3%.
*/

USE DialerDB;
GO

-- View by day x campaign
CREATE OR ALTER VIEW dw.vw_compliance_daily AS
SELECT full_date, week_start_date, campaign_id, dialer_mode,
       COUNT(*) AS calls,
       SUM(is_contact) AS contacts,
       SUM(is_abandoned)  AS abandoned,
       SUM(flag_dnc_violation) AS dnc_violation_calls,
       SUM(flag_out_of_window) AS out_of_window_calls,
       SUM(flag_over_attempt) AS over_attempt_calls
FROM dw.vw_calls
GROUP BY full_date, week_start_date, campaign_id, dialer_mode;
GO
 
--   Question 1: Compliance Overview
DECLARE @total INT = (SELECT COUNT(*) FROM dw.fact_calls);
 
SELECT x.violation_type, x.calls,
       CAST(100.0 * x.calls / @total AS DECIMAL(5,2)) AS pct_of_all_calls,
       x.phones_affected
FROM (
    SELECT 'DNC' AS violation_type, COUNT(*) AS calls, COUNT(DISTINCT l.phone_std) AS phones_affected, 1 AS o
    FROM dw.vw_calls AS c JOIN dw.dim_lead AS l ON l.lead_id = c.lead_id WHERE c.flag_dnc_violation = 1
    UNION ALL
    SELECT 'Ngoai khung 08:00-21:00', COUNT(*), COUNT(DISTINCT l.phone_std), 2
    FROM dw.vw_calls AS c JOIN dw.dim_lead AS l ON l.lead_id = c.lead_id WHERE c.flag_out_of_window = 1
    UNION ALL
    SELECT 'Qua 5 lan goi / SDT', COUNT(*), COUNT(DISTINCT l.phone_std), 3
    FROM dw.vw_calls AS c JOIN dw.dim_lead AS l ON l.lead_id = c.lead_id WHERE c.flag_over_attempt = 1
) AS x
ORDER BY x.o;
GO
 
-- Question 2: DNC – Root Cause Analysis: System Error or Human Error?
-- Detailed table of DNC-violating calls, including the number of days overdue
DROP TABLE IF EXISTS dw.dnc_violations;
GO
SELECT c.call_id, c.campaign_id, c.agent_id, c.team_id, c.source, c.full_date, l.phone_std,
       d.added_date,
       DATEDIFF(DAY, d.added_date, c.full_date) AS days_after_dnc
INTO dw.dnc_violations
FROM dw.vw_calls AS c
JOIN dw.dim_lead AS l ON l.lead_id = c.lead_id
JOIN clean.dnc_list AS d ON d.phone = l.phone_std
WHERE c.flag_dnc_violation = 1;
GO
 
-- Coverage: How many DNC numbers were still called after being added to the list?
SELECT (SELECT COUNT(*) FROM clean.dnc_list) AS dnc_phones,
       COUNT(DISTINCT phone_std) AS dnc_phones_still_called,
       CAST(100.0 * COUNT(DISTINCT phone_std) / (SELECT COUNT(*) FROM clean.dnc_list) AS DECIMAL(5,1)) AS pct
FROM dw.dnc_violations;
 
-- How many days after being added to the DNC list were the calls made?
SELECT CASE WHEN days_after_dnc = 0  THEN '1. same day'
            WHEN days_after_dnc <= 7  THEN '2. 1-7 days'
            WHEN days_after_dnc <= 14 THEN '3. 8-14 days'
            WHEN days_after_dnc <= 30 THEN '4. 15-30 days'
            ELSE '5. more than 30 days' END AS bucket,
       COUNT(*) AS violating_calls
FROM dw.dnc_violations
GROUP BY CASE WHEN days_after_dnc = 0 THEN '1. same day'
              WHEN days_after_dnc <= 7 THEN '2. 1-7 days'
              WHEN days_after_dnc <= 14 THEN '3. 8-14 days'
              WHEN days_after_dnc <= 30 THEN '4. 15-30 days'
              ELSE '5. more than 30 days' END
ORDER BY bucket;
 
SELECT DISTINCT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_after_dnc) OVER () AS median_days_after_dnc
FROM dw.dnc_violations;
 
-- Are violations concentrated in a single campaign or agent?
SELECT campaign_id,
       COUNT(*) AS violations,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct_of_violations,
       (SELECT CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dw.fact_calls) AS DECIMAL(5,1))
        FROM dw.vw_calls AS x WHERE x.campaign_id = v.campaign_id) AS pct_of_all_calls
FROM dw.dnc_violations AS v
GROUP BY campaign_id ORDER BY campaign_id;
 
SELECT COUNT(DISTINCT agent_id) AS agents_involved,
       MIN(n) AS min_violations_per_agent, MAX(n) AS max_violations_per_agent,
       CAST(100.0 * MAX(n) / SUM(n) AS DECIMAL(5,1)) AS top_agent_share_pct
FROM (SELECT agent_id, COUNT(*) AS n FROM dw.dnc_violations WHERE agent_id <> 'N/A' GROUP BY agent_id) AS t;
 
-- Monthly trend
SELECT CONVERT(CHAR(7), full_date, 120) AS year_month, COUNT(*) AS violations
FROM dw.dnc_violations GROUP BY CONVERT(CHAR(7), full_date, 120) ORDER BY year_month;
GO
 
-- Question 3: Calling time violations - Who made calls outside the permitted 08:00 - 21:00 window?
SELECT agent_id, team_id, call_hour, COUNT(*) AS calls_out_of_window,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2)) AS contact_rate
FROM dw.vw_calls
WHERE flag_out_of_window = 1
GROUP BY agent_id, team_id, call_hour
ORDER BY agent_id, call_hour;
 
/* Question 4: Excessive Call Attempts - Root Cause Analysis: 
   If the number of attempts per lead_id is <= 5 but the number of attempts per phone number is > 5, 
   the root cause is DUPLICATE LEADS (the dialer counts attempts by lead_id, not by phone number).
*/
SELECT CASE WHEN attempt_no > 5 THEN 'More than 5 attempts on the same lead_id'
            ELSE 'Due to Duplicate Leads (total attempts per phone number > 5)' END AS root_cause,
       COUNT(*) AS calls,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct
FROM dw.vw_calls
WHERE flag_over_attempt = 1
GROUP BY CASE WHEN attempt_no > 5 THEN 'More than 5 attempts on the same lead_id'
              ELSE 'Due to Duplicate Leads (total attempts per phone number > 5)' END;
 
SELECT campaign_id, COUNT(*) AS over_attempt_calls
FROM dw.vw_calls WHERE flag_over_attempt = 1 GROUP BY campaign_id ORDER BY campaign_id;
 
/* 
   Question 5: ABANDON RATE – Exceeding the 3% Threshold
          Measure by DAY and by WEEK: for the same campaign, the two measurement methods may lead to different conclusions.
          Weekly calculation is only valid when there are >= 100 answered calls (exclude the first and last partial weeks of the reporting period).
*/
WITH d AS (
    SELECT campaign_id, full_date,
           1.0 * SUM(abandoned) / NULLIF(SUM(contacts), 0) AS rate
    FROM dw.vw_compliance_daily
    WHERE dialer_mode = 'Predictive'
    GROUP BY campaign_id, full_date
), w AS (
    SELECT campaign_id, week_start_date,
           1.0 * SUM(abandoned) / NULLIF(SUM(contacts), 0) AS rate
    FROM dw.vw_compliance_daily
    WHERE dialer_mode = 'Predictive'
    GROUP BY campaign_id, week_start_date
    HAVING SUM(contacts) >= 100
), dd AS (
    SELECT campaign_id, COUNT(*) AS days_measured,
           SUM(CASE WHEN rate > 0.03 THEN 1 ELSE 0 END) AS days_over_3pct
    FROM d GROUP BY campaign_id
), ww AS (
    SELECT campaign_id, COUNT(*) AS weeks_measured,
           SUM(CASE WHEN rate > 0.03 THEN 1 ELSE 0 END) AS weeks_over_3pct,
           CAST(100 * MIN(rate) AS DECIMAL(5,2)) AS min_weekly_pct,
           CAST(100 * MAX(rate) AS DECIMAL(5,2)) AS max_weekly_pct
    FROM w GROUP BY campaign_id
)
SELECT dd.campaign_id, dd.days_measured, dd.days_over_3pct,
       ww.weeks_measured, ww.weeks_over_3pct, ww.min_weekly_pct, ww.max_weekly_pct
FROM dd JOIN ww ON ww.campaign_id = dd.campaign_id
ORDER BY dd.campaign_id;
GO
 
/*
   Question 6: Agent Anomaly Detection (robust z-score, across 18+ agents):
   - short_rpc_pct : % of answered calls with talk time < 10 seconds (high = suspected immediate hang-ups)
   - aht_ratio     : Agent AHT / Campaign AHT (normalized by campaign)
   - conv_ratio    : Agent conversion rate / Campaign conversion rate
   - oow_calls     : Number of calls made outside permitted hours (same rule: > 0 indicates a violation)
   Modified z-score = 0.6745 * (x - median) / MAD ; |z| > 3.5 = outlier
   Risk levels: HIGH if there is a compliance-related signal (short_rpc or oow); WATCH if deviations are limited to AHT / conversion
*/
CREATE OR ALTER VIEW dw.vw_agent_risk AS
WITH camp AS (
    SELECT campaign_id,
           AVG(CAST(handle_sec AS FLOAT)) AS camp_aht,
           1.0 * SUM(is_sale) / NULLIF(SUM(is_rpc), 0) AS camp_conv
    FROM dw.vw_calls
    WHERE agent_id <> 'N/A'
    GROUP BY campaign_id
), a AS (
    SELECT c.agent_id, c.team_id, c.campaign_id,
           COUNT(*) AS calls,
           AVG(CAST(c.handle_sec AS FLOAT)) AS aht,
           1.0 * SUM(c.is_sale) / NULLIF(SUM(c.is_rpc), 0) AS conv,
           1.0 * SUM(CASE WHEN c.is_rpc = 1 AND c.talk_sec < 10 THEN 1 ELSE 0 END) / NULLIF(SUM(c.is_rpc), 0) AS short_rpc,
           SUM(c.flag_out_of_window) AS oow_calls
    FROM dw.vw_calls AS c
    WHERE c.agent_id <> 'N/A'
    GROUP BY c.agent_id, c.team_id, c.campaign_id
), f AS (
    SELECT a.agent_id, a.team_id, a.campaign_id, a.calls, a.short_rpc, a.oow_calls,
           a.aht  / k.camp_aht  AS aht_ratio,
           a.conv / k.camp_conv AS conv_ratio
    FROM a JOIN camp AS k ON k.campaign_id = a.campaign_id
), med AS (
    SELECT DISTINCT
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY short_rpc) OVER () AS m_short,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY aht_ratio) OVER () AS m_aht,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY conv_ratio) OVER () AS m_conv
    FROM f
), dev AS (
    SELECT f.*, med.m_short, med.m_aht, med.m_conv,
           ABS(f.short_rpc  - med.m_short) AS d_short,
           ABS(f.aht_ratio  - med.m_aht) AS d_aht,
           ABS(f.conv_ratio - med.m_conv) AS d_conv
    FROM f CROSS JOIN med
), mad AS (
    SELECT DISTINCT
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d_short) OVER () AS mad_short,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d_aht) OVER () AS mad_aht,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d_conv) OVER () AS mad_conv
    FROM dev
), z AS (
    SELECT dev.agent_id, dev.team_id, dev.campaign_id, dev.calls, dev.oow_calls,
           dev.short_rpc, dev.aht_ratio, dev.conv_ratio,
           0.6745 * (dev.short_rpc  - dev.m_short) / NULLIF(mad.mad_short, 0) AS z_short,
           0.6745 * (dev.aht_ratio  - dev.m_aht) / NULLIF(mad.mad_aht, 0) AS z_aht,
           0.6745 * (dev.conv_ratio - dev.m_conv) / NULLIF(mad.mad_conv, 0) AS z_conv
    FROM dev CROSS JOIN mad
)
SELECT agent_id, team_id, campaign_id, calls,
       CAST(100 * short_rpc AS DECIMAL(5,2)) AS short_rpc_pct,
       CAST(aht_ratio  AS DECIMAL(5,3)) AS aht_ratio,
       CAST(conv_ratio AS DECIMAL(5,3)) AS conv_ratio,
       oow_calls,
       CAST(z_short AS DECIMAL(9,2)) AS z_short,
       CAST(z_aht   AS DECIMAL(9,2)) AS z_aht,
       CAST(z_conv  AS DECIMAL(9,2)) AS z_conv,
       CASE WHEN ABS(z_short) > 3.5 THEN 1 ELSE 0 END AS flag_short,
       CASE WHEN ABS(z_aht)   > 3.5 THEN 1 ELSE 0 END AS flag_aht,
       CASE WHEN ABS(z_conv)  > 3.5 THEN 1 ELSE 0 END AS flag_conv,
       CASE WHEN oow_calls > 0 THEN 1 ELSE 0 END AS flag_oow,
       CASE WHEN ABS(z_short) > 3.5 OR oow_calls > 0 THEN 'HIGH'
            WHEN ABS(z_aht) > 3.5 OR ABS(z_conv) > 3.5 THEN 'WATCH'
            ELSE 'OK' END AS risk_level
FROM z;
GO
 
SELECT * FROM dw.vw_agent_risk
ORDER BY CASE risk_level WHEN 'HIGH' THEN 1 WHEN 'WATCH' THEN 2 ELSE 3 END, agent_id;
GO
 
-- Question 7: Data Quality Scorecard by Source (based on clean.leads: 83,200 rows)
SELECT ISNULL(source, 'TONG') AS source,
       COUNT(*) AS leads,
       CAST(100.0 * SUM(CASE WHEN phone_rank > 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS dup_pct,
       CAST(100.0 * SUM(CASE WHEN phone_raw <> phone_std THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS bad_phone_format_pct,
       CAST(100.0 * SUM(CASE WHEN province = 'Unknown' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS missing_province_pct,
       CAST(100.0 * SUM(CASE WHEN age_valid = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS invalid_age_pct,
       CAST(100.0 * SUM(CASE WHEN phone_rank = 1 AND phone_raw = phone_std AND province <> 'Unknown' AND age_valid = 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS fully_clean_pct
FROM clean.leads
GROUP BY ROLLUP (source)
ORDER BY CASE WHEN source IS NULL THEN 1 ELSE 0 END, source;
 
-- Source data quality is measured by the proportion of incorrect phone numbers (Wrong Number) among answered calls.
SELECT source,
       CAST(100.0 * SUM(is_wrong_number) / NULLIF(SUM(is_contact), 0) AS DECIMAL(5,2)) AS wrong_number_pct_of_contacts
FROM dw.vw_calls GROUP BY source ORDER BY wrong_number_pct_of_contacts DESC;
GO
 
/*
   Question 8: Daily Exception Report (EXEC dw.usp_daily_exception_report '2026-10-05') 
       Result 1: Daily campaign-level performance + alerts 
       Result 2: Agents showing abnormal signals during the day
*/
CREATE OR ALTER PROCEDURE dw.usp_daily_exception_report
    @report_date DATE
AS
BEGIN
    SET NOCOUNT ON;
 
    SELECT campaign_id, dialer_mode, calls,
           CAST(100.0 * contacts / calls AS DECIMAL(5,2)) AS contact_rate,
           CAST(100.0 * abandoned / NULLIF(contacts, 0) AS DECIMAL(5,2)) AS abandon_rate,
           dnc_violation_calls, out_of_window_calls, over_attempt_calls,
           CASE WHEN dialer_mode = 'Predictive' AND 1.0 * abandoned / NULLIF(contacts, 0) > 0.03 THEN 'ABANDON > 3%' ELSE '' END
         + CASE WHEN dnc_violation_calls > 0 THEN ' | DNC' ELSE '' END
         + CASE WHEN out_of_window_calls > 0 THEN ' | KHUNG GIO' ELSE '' END
         + CASE WHEN over_attempt_calls  > 0 THEN ' | QUA SO LAN' ELSE '' END AS alerts
    FROM dw.vw_compliance_daily
    WHERE full_date = @report_date
    ORDER BY campaign_id;
 
    SELECT agent_id, team_id,
           SUM(flag_out_of_window) AS out_of_window_calls,
           SUM(is_rpc) AS rpc_calls,
           SUM(CASE WHEN is_rpc = 1 AND talk_sec < 10 THEN 1 ELSE 0 END) AS short_rpc_calls
    FROM dw.vw_calls
    WHERE full_date = @report_date AND agent_id <> 'N/A'
    GROUP BY agent_id, team_id
    HAVING SUM(flag_out_of_window) > 0
        OR (SUM(CASE WHEN is_rpc = 1 AND talk_sec < 10 THEN 1 ELSE 0 END) >= 5
            AND 1.0 * SUM(CASE WHEN is_rpc = 1 AND talk_sec < 10 THEN 1 ELSE 0 END) / NULLIF(SUM(is_rpc), 0) >= 0.3)
    ORDER BY out_of_window_calls DESC, short_rpc_calls DESC;
END;
GO
 
-- Test Run: October 5, 2026 
-- (Expected totals: 5,369 calls; 29 DNC violations; 20 out-of-hours calls; 113 excessive call attempts; C04 abandon rate: 5.24%)
EXEC dw.usp_daily_exception_report '2026-10-05';