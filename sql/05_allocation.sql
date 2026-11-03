/*
    DIALER ANALYTICS  -  05_allocation.sql  (SQL Server)
    DATA ALLOCATION STRATEGY: Lead Scoring → A/B/C Segmentation → Simulation of Calling Policies (Before vs. After) on the Validation Set.
 
    Prerequisites: Campaigns 01–04 have been executed (dw.vw_calls must be available using data from File 04).
 
    Analytical Principles:
        - Separate Training and Validation Sets: Leads whose last digit in the Lead ID is greater than or equal to 7 (e.g., L000123 → 3) belong to the validation (holdout) set, 
          representing approximately 30% of the data.
        - Prevent Data Leakage: The purpose of this split is to prevent data leakage, 
          ensuring that leads are not scored using their own historical outcomes.
        - Scoring Unit - Unique Customer: The scoring unit must be the actual customer (Master Lead), not individual lead_id records.
          Duplicate leads belonging to the same customer must be consolidated to avoid double-counting.
        - Lead Scoring Method: Score = Historical conversion rate of the corresponding group, defined by: Data Source, Age Band, Region.
          Apply smoothing toward the overall conversion rate of the corresponding data source, using a smoothing parameter of k = 100, 
          to reduce noise and stabilize scores for groups with small sample sizes.

*/

USE DialerDB;
GO

-- 1. Unique Customer Table + Data Split
DROP TABLE IF EXISTS dw.alloc_persons;
GO
SELECT l.lead_id AS master_lead_id,
       CASE WHEN CAST(SUBSTRING(l.lead_id, 2, 10) AS INT) % 10 >= 7 THEN 1 ELSE 0 END AS is_holdout,
       l.source, l.region, l.age_band, l.income_band,
       p.calls, p.reached, p.sale -- NULL = have not called
INTO dw.alloc_persons
FROM dw.dim_lead AS l
LEFT JOIN (
    SELECT master_lead_id,
           COUNT(*)        AS calls,
           MAX(is_contact) AS reached,
           MAX(is_sale)    AS sale
    FROM dw.vw_calls
    GROUP BY master_lead_id
) AS p ON p.master_lead_id = l.lead_id
WHERE l.is_duplicate = 0;
GO
 
-- Check: Called Customers in the Training / Validation Sets
SELECT is_holdout, COUNT(*) AS persons_called
FROM dw.alloc_persons WHERE calls IS NOT NULL
GROUP BY is_holdout ORDER BY is_holdout;
 
-- Does `income_band` Differentiate Conversion Outcomes?
SELECT income_band, COUNT(*) AS persons,
       CAST(100.0 * AVG(CAST(sale AS FLOAT)) AS DECIMAL(5,2)) AS pct_sale
FROM dw.alloc_persons
WHERE is_holdout = 0 AND calls IS NOT NULL
GROUP BY income_band;
GO


-- 2. Group-based scoring
DROP TABLE IF EXISTS dw.alloc_prior, dw.alloc_cell_score;
GO

SELECT source, AVG(CAST(sale AS FLOAT)) AS prior_rate
INTO dw.alloc_prior
FROM dw.alloc_persons
WHERE is_holdout = 0 AND calls IS NOT NULL
GROUP BY source;
 
SELECT c.source, c.age_band, c.region, c.n, c.sales, p.prior_rate,
       (c.sales + 100.0 * p.prior_rate) / (c.n + 100.0) AS score    -- k = 100: doi de lam muot nhieu hon/it hon
INTO dw.alloc_cell_score
FROM (
    SELECT source, age_band, region, COUNT(*) AS n, SUM(sale) AS sales
    FROM dw.alloc_persons
    WHERE is_holdout = 0 AND calls IS NOT NULL
    GROUP BY source, age_band, region
) AS c
JOIN dw.alloc_prior AS p ON p.source = c.source;
GO

SELECT COUNT(*) AS cells FROM dw.alloc_cell_score;
 
/*
    3. Score all customers + segmentation:
    A = Top 30% highest scores, C = Bottom 30% lowest scores, B = The middle 40%
*/
DROP TABLE IF EXISTS dw.alloc_scored, dw.alloc_cutoff, dw.lead_score;
GO

SELECT p.master_lead_id, p.is_holdout, p.source, p.region, p.age_band,
       p.calls, p.reached, p.sale,
       COALESCE(cs.score, pr.prior_rate) AS score      -- nhom chua tung thay -> dung ty le cua nguon
INTO dw.alloc_scored
FROM dw.alloc_persons AS p
LEFT JOIN dw.alloc_cell_score AS cs
       ON cs.source = p.source AND cs.age_band = p.age_band AND cs.region = p.region
LEFT JOIN dw.alloc_prior AS pr ON pr.source = p.source;
 
SELECT DISTINCT
       PERCENTILE_CONT(0.7) WITHIN GROUP (ORDER BY score) OVER () AS cut_a,
       PERCENTILE_CONT(0.3) WITHIN GROUP (ORDER BY score) OVER () AS cut_c
INTO dw.alloc_cutoff
FROM dw.alloc_scored
WHERE is_holdout = 0 AND calls IS NOT NULL;
 
SELECT s.master_lead_id AS lead_id, s.score, s.is_holdout,
       CASE WHEN s.score >= c.cut_a THEN 'A'
            WHEN s.score <  c.cut_c THEN 'C'
            ELSE 'B' END AS segment
INTO dw.lead_score
FROM dw.alloc_scored AS s
CROSS JOIN dw.alloc_cutoff AS c;
GO
 
-- Segmentation thresholds and distribution across 80,000 customers (A: 31.5% / B: 39.1% / C: 29.3%)
SELECT * FROM dw.alloc_cutoff;
SELECT segment, COUNT(*) AS persons,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct
FROM dw.lead_score GROUP BY segment ORDER BY segment;
 
-- Segment mapping table for each lead_key (including duplicate leads)
DROP TABLE IF EXISTS dw.lead_segment;
GO
SELECT l.lead_key, s.segment, s.score
INTO dw.lead_segment
FROM dw.dim_lead   AS l
JOIN dw.lead_score AS s ON s.lead_id = l.master_lead_id;
GO
 
-- 4. Validation on the Holdout Set: Do the Segments Actually Differentiate High- and Low-Performing Customers?
-- 4a. Customer-Level Metrics: Contact Rate and Conversion Rate
SELECT s.segment,
       COUNT(*)                                                         AS persons_called,
       CAST(100.0 * AVG(CAST(a.reached AS FLOAT)) AS DECIMAL(5,2))      AS pct_reached,
       CAST(100.0 * AVG(CAST(a.sale    AS FLOAT)) AS DECIMAL(5,2))      AS pct_sale,
       CAST(AVG(CAST(a.calls AS FLOAT)) AS DECIMAL(4,2))                AS avg_calls_per_person
FROM dw.alloc_scored AS a
JOIN dw.lead_score   AS s ON s.lead_id = a.master_lead_id
WHERE a.is_holdout = 1 AND a.calls IS NOT NULL
GROUP BY s.segment ORDER BY s.segment;
 
-- 4b. Call-Level Metrics: Effectiveness per 100 Calls and Call Share vs. Revenue Share
SELECT s.segment,
       COUNT(*)                                                         AS calls,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))   AS pct_of_calls,
       SUM(c.is_sale)                                                   AS sales,
       CAST(100.0 * SUM(c.is_sale) / SUM(SUM(c.is_sale)) OVER () AS DECIMAL(5,1)) AS pct_of_sales,
       CAST(100.0 * SUM(c.is_sale) / COUNT(*) AS DECIMAL(5,2))          AS sales_per_100_calls
FROM dw.vw_calls   AS c
JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
WHERE s.is_holdout = 1
GROUP BY s.segment ORDER BY s.segment;

-- 5. Marginal Yield by Segment × Call Attempt
SELECT s.segment, c.attempt_no,
       COUNT(*) AS calls,
       CAST(100.0 * SUM(c.is_sale) / COUNT(*) AS DECIMAL(5,2)) AS sales_per_100_calls
FROM dw.vw_calls   AS c
JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
WHERE s.is_holdout = 0 AND c.attempt_no <= 5
GROUP BY s.segment, c.attempt_no
ORDER BY s.segment, c.attempt_no;
 
/* 
   6. Sensitivity to the break-even threshold
      Rule: Stop calling a segment from the first call attempt where the marginal yield falls below the threshold
      (Threshold = minimum number of orders per 100 calls required for calls to remain 'worthwhile')
*/
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
           COUNT(*)                                                       AS base_calls,
           SUM(h.is_sale)                                                 AS base_sales,
           SUM(CASE WHEN h.attempt_no <= k.cap THEN 1 ELSE 0 END)         AS kept_calls,
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
SELECT cp.t AS threshold_sales_per_100, cp.cap_a, cp.cap_b, cp.cap_c,
       e.kept_calls,
       CAST(100.0 * (1 - 1.0 * e.kept_calls / e.base_calls) AS DECIMAL(5,2)) AS calls_saved_pct,
       e.kept_sales,
       CAST(100.0 * (1 - 1.0 * e.kept_sales / e.base_sales) AS DECIMAL(5,2)) AS sales_lost_pct,
       CAST(100.0 * e.kept_sales / e.kept_calls AS DECIMAL(5,3))             AS sales_per_100_calls
FROM e JOIN cp ON cp.t = e.t
ORDER BY cp.t;
GO
 
/* 
   7. Before / After Simulation for the Selected Strategy (Vary `@thr` to Test Different Thresholds)
      P0 = Exclude only wasted calls (duplicate leads, DNC, calls outside permitted hours, and more than 5 attempts per phone number).
      P1 = Limit the number of call attempts by segment only.
      P2 = P0 + P1
*/
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
           CASE WHEN c.attempt_no <= k.cap THEN 1 ELSE 0 END                                AS within_cap
    FROM dw.vw_calls AS c
    JOIN dw.lead_score AS s ON s.lead_id = c.master_lead_id
    JOIN caps AS k ON k.segment = s.segment
    WHERE s.is_holdout = 1
), r AS (
    SELECT 1 AS o, 'Baseline (hien tai)' AS scenario, COUNT(*) AS calls, SUM(is_sale) AS sales FROM sim
    UNION ALL SELECT 2, 'P0: bo cuoc goi ro ri',               COUNT(*), SUM(is_sale) FROM sim WHERE is_leak = 0
    UNION ALL SELECT 3, 'P1: gioi han lan goi theo segment',   COUNT(*), SUM(is_sale) FROM sim WHERE within_cap = 1
    UNION ALL SELECT 4, 'P2: P0 + P1',                         COUNT(*), SUM(is_sale) FROM sim WHERE is_leak = 0 AND within_cap = 1
)
SELECT o, scenario, calls, sales,
       CAST(100.0 * sales / calls AS DECIMAL(5,3))                                AS sales_per_100_calls,
       CAST(100.0 * (1 - 1.0 * calls / (SELECT calls FROM r WHERE o = 1)) AS DECIMAL(5,2)) AS calls_saved_pct,
       CAST(100.0 * (1 - 1.0 * sales / (SELECT sales FROM r WHERE o = 1)) AS DECIMAL(5,2)) AS sales_lost_pct
FROM r
ORDER BY o;
GO
 
-- 8. Balancing Workload Across Teams (Calls per Agent per Day vs. Occupancy)
WITH c AS (
    SELECT a.team_id, COUNT(*) AS calls
    FROM dw.fact_calls AS f
    JOIN dw.dim_agent  AS a ON a.agent_key = f.agent_key
    WHERE f.agent_key <> 0
    GROUP BY a.team_id
), d AS (
    SELECT a.team_id, COUNT(*) AS agent_days,
           100.0 * SUM(CAST(f.busy_sec AS BIGINT))
                 / (SUM(CAST(f.login_sec AS BIGINT)) - SUM(CAST(f.break_sec AS BIGINT))) AS occupancy_pct
    FROM dw.fact_agent_daily AS f
    JOIN dw.dim_agent        AS a ON a.agent_key = f.agent_key
    GROUP BY a.team_id
)
SELECT c.team_id, c.calls, d.agent_days,
       CAST(1.0 * c.calls / d.agent_days AS DECIMAL(6,1)) AS calls_per_agent_day,
       CAST(d.occupancy_pct AS DECIMAL(5,2))              AS occupancy_pct
FROM c JOIN d ON d.team_id = c.team_id
ORDER BY c.team_id;
GO
 
-- 9. Allocation Playbook. The dialer_mode and calling time window columns are HYPOTHESES that require A/B pilot testing, not validated results.
DROP TABLE IF EXISTS dw.alloc_playbook;
GO

CREATE TABLE dw.alloc_playbook (
    segment CHAR(1) NOT NULL PRIMARY KEY,
    priority TINYINT NOT NULL,
    max_attempts TINYINT NOT NULL,
    preferred_window VARCHAR(100) NOT NULL,
    dialer_mode_hint VARCHAR(100) NOT NULL,
    rationale VARCHAR(200) NOT NULL
);
INSERT INTO dw.alloc_playbook VALUES
 ('A', 1, 5, '17:00-21:00 first, followed by 14:00-17:00', 'Progressive', 'Highest conversion rate: prioritize peak calling hours and reduce abandonment risk'),
 ('B', 2, 5, '14:00-21:00', 'Progressive / Predictive', 'Average effectiveness: use all permitted call attempts'),
 ('C', 3, 2, 'Off-peak hours to fill idle capacity', 'Predictive (monitor abandonment <= 3%)', 'Low marginal yield from the 3rd attempt onward: limit to 2 attempts and use to fill spare capacity');
GO
SELECT * FROM dw.alloc_playbook ORDER BY priority;