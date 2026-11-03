/*
   DIALER ANALYTICS  -  07_pbi_support.sql  (SQL Server)
   Create the following "result" tables for use in Power BI (without recalculating in DAX):
	  - `dw.pbi_segment_lift` – Validate segments A/B/C on the validation dataset.
	  - `dw.pbi_threshold_scan` – Scan break-even thresholds.
	  - `dw.pbi_scenarios` – Before/after comparison: Baseline, P0, P1, P2.
	  - `dw.pbi_dnc_buckets` – DNC calls by number of overdue days.
	  - `dw.pbi_dq_by_source` – Data quality score table by source.
*/

USE DialerDB;
GO

-- 1. Segment Lift
SELECT p.segment, p.persons_called, p.pct_reached, p.pct_sale, p.avg_calls_per_person,
       c.calls, c.pct_of_calls, c.sales, c.pct_of_sales, c.sales_per_100_calls
INTO dw.pbi_segment_lift
FROM (
    SELECT s.segment,
           COUNT(*) AS persons_called,
           CAST(100.0 * AVG(CAST(a.reached AS FLOAT)) AS DECIMAL(5,2)) AS pct_reached,
           CAST(100.0 * AVG(CAST(a.sale    AS FLOAT)) AS DECIMAL(5,2)) AS pct_sale,
           CAST(AVG(CAST(a.calls AS FLOAT)) AS DECIMAL(4,2)) AS avg_calls_per_person
    FROM dw.alloc_scored AS a
    JOIN dw.lead_score AS s ON s.lead_id = a.master_lead_id
    WHERE a.is_holdout = 1 AND a.calls IS NOT NULL
    GROUP BY s.segment
) AS p
JOIN (
    SELECT s.segment,
           COUNT(*) AS calls,
           CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct_of_calls,
           SUM(c.is_sale) AS sales,
           CAST(100.0 * SUM(c.is_sale) / SUM(SUM(c.is_sale)) OVER () AS DECIMAL(5,1)) AS pct_of_sales,
           CAST(100.0 * SUM(c.is_sale) / COUNT(*) AS DECIMAL(5,2)) AS sales_per_100_calls
    FROM dw.vw_calls AS c
    JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
    WHERE s.is_holdout = 1
    GROUP BY s.segment
) AS c ON c.segment = p.segment;
GO

-- 2. Scan Break-Even Thresholds
WITH y AS (
    SELECT s.segment, c.attempt_no,
           100.0 * SUM(c.is_sale) / COUNT(*) AS sales_per_100
    FROM dw.vw_calls AS c
    JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
    WHERE s.is_holdout = 0 AND c.attempt_no <= 5
    GROUP BY s.segment, c.attempt_no
), thr AS (
    SELECT t FROM (VALUES (0.5), (0.7), (1.0), (1.7), (2.2)) AS v(t)
), caps AS (
    SELECT thr.t, g.segment,
           COALESCE((SELECT MIN(y.attempt_no) - 1 FROM y
                     WHERE y.segment = g.segment AND y.sales_per_100 < thr.t), 5) AS cap
    FROM thr CROSS JOIN (VALUES ('A'), ('B'), ('C')) AS g(segment)
), h AS (
    SELECT s.segment, c.attempt_no, c.is_sale
    FROM dw.vw_calls AS c
    JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
    WHERE s.is_holdout = 1
), e AS (
    SELECT k.t,
           COUNT(*) AS base_calls,
           SUM(h.is_sale) AS base_sales,
           SUM(CASE WHEN h.attempt_no <= k.cap THEN 1 ELSE 0 END) AS kept_calls,
           SUM(CASE WHEN h.attempt_no <= k.cap THEN h.is_sale ELSE 0 END) AS kept_sales
    FROM h JOIN caps AS k ON k.segment = h.segment
    GROUP BY k.t
), cp AS (
    SELECT t,
           MAX(CASE WHEN segment = 'A' THEN cap END) AS cap_a,
           MAX(CASE WHEN segment = 'B' THEN cap END) AS cap_b,
           MAX(CASE WHEN segment = 'C' THEN cap END) AS cap_c
    FROM caps GROUP BY t
)
SELECT CAST(cp.t AS DECIMAL(3,1)) AS threshold_sales_per_100, cp.cap_a, cp.cap_b, cp.cap_c,
       e.kept_calls,
       CAST(100.0 * (1 - 1.0 * e.kept_calls / e.base_calls) AS DECIMAL(5,2)) AS calls_saved_pct,
       e.kept_sales,
       CAST(100.0 * (1 - 1.0 * e.kept_sales / e.base_sales) AS DECIMAL(5,2)) AS sales_lost_pct,
       CAST(100.0 * e.kept_sales / e.kept_calls AS DECIMAL(5,3)) AS sales_per_100_calls
INTO dw.pbi_threshold_scan
FROM e JOIN cp ON cp.t = e.t;
GO
 
-- 3. Before / After (Threshold = 0.7)
DECLARE @thr FLOAT = 0.7;
 
WITH y AS (
    SELECT s.segment, c.attempt_no,
           100.0 * SUM(c.is_sale) / COUNT(*) AS sales_per_100
    FROM dw.vw_calls AS c
    JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
    WHERE s.is_holdout = 0 AND c.attempt_no <= 5
    GROUP BY s.segment, c.attempt_no
), caps AS (
    SELECT g.segment,
           COALESCE((SELECT MIN(y.attempt_no) - 1 FROM y
                     WHERE y.segment = g.segment AND y.sales_per_100 < @thr), 5) AS cap
    FROM (VALUES ('A'), ('B'), ('C')) AS g(segment)
), sim AS (
    SELECT s.segment, c.attempt_no, c.is_sale,
           CASE WHEN c.is_duplicate = 1 OR c.flag_over_attempt = 1
                  OR c.flag_dnc_violation = 1 OR c.flag_out_of_window = 1 THEN 1 ELSE 0 END AS is_leak,
           CASE WHEN c.attempt_no <= k.cap THEN 1 ELSE 0 END AS within_cap
    FROM dw.vw_calls AS c
    JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
    JOIN caps AS k ON k.segment = s.segment
    WHERE s.is_holdout = 1
), r AS (
    SELECT 1 AS o, 'Baseline (present)' AS scenario, COUNT(*) AS calls, SUM(is_sale) AS sales FROM sim
    UNION ALL SELECT 2, 'P0: Abandoned leaked calls', COUNT(*), SUM(is_sale) FROM sim WHERE is_leak = 0
    UNION ALL SELECT 3, 'P1: Call attempt limit by segment', COUNT(*), SUM(is_sale) FROM sim WHERE within_cap = 1
    UNION ALL SELECT 4, 'P2: P0 + P1', COUNT(*), SUM(is_sale) FROM sim WHERE is_leak = 0 AND within_cap = 1
)
SELECT o, scenario, calls, sales,
       CAST(100.0 * sales / calls AS DECIMAL(5,3)) AS sales_per_100_calls,
       CAST(100.0 * (1 - 1.0 * calls / (SELECT calls FROM r WHERE o = 1)) AS DECIMAL(5,2)) AS calls_saved_pct,
       CAST(100.0 * (1 - 1.0 * sales / (SELECT sales FROM r WHERE o = 1)) AS DECIMAL(5,2)) AS sales_lost_pct
INTO dw.pbi_scenarios
FROM r;
GO
 
-- 4. DNC By Number Of Overdue Days
SELECT CASE WHEN days_after_dnc = 0  THEN '1. same day'
            WHEN days_after_dnc <= 7  THEN '2. 1-7 days'
            WHEN days_after_dnc <= 14 THEN '3. 8-14 days'
            WHEN days_after_dnc <= 30 THEN '4. 15-30 days'
            ELSE '5. more than 30 days' END AS bucket,
       COUNT(*) AS violating_calls
INTO dw.pbi_dnc_buckets
FROM dw.dnc_violations
GROUP BY CASE WHEN days_after_dnc = 0  THEN '1. same day'
              WHEN days_after_dnc <= 7  THEN '2. 1-7 days'
              WHEN days_after_dnc <= 14 THEN '3. 8-14 days'
              WHEN days_after_dnc <= 30 THEN '4. 15-30 days'
              ELSE '5. more than 30 days' END;
GO
 
-- 5. Data Quality Score By Source
SELECT ISNULL(l.source, 'Overall') AS source,
       COUNT(*) AS leads,
       CAST(100.0 * SUM(CASE WHEN l.phone_rank > 1 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS dup_pct,
       CAST(100.0 * SUM(CASE WHEN l.phone_raw <> l.phone_std THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS bad_phone_format_pct,
       CAST(100.0 * SUM(CASE WHEN l.province = 'Unknown' THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS missing_province_pct,
       CAST(100.0 * SUM(CASE WHEN l.age_valid = 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS invalid_age_pct,
       CAST(100.0 * SUM(CASE WHEN l.phone_rank = 1 AND l.phone_raw = l.phone_std AND l.province <> 'Unknown' AND l.age_valid = 1
                             THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5,2)) AS fully_clean_pct
INTO dw.pbi_dq_by_source
FROM clean.leads AS l
GROUP BY ROLLUP (l.source);
GO