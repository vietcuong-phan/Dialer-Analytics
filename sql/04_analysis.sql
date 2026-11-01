/* 
   DIALER ANALYTICS  -  04_analysis.sql  (SQL Server)
   SQL Analysis on the Star Schema [dw].
 
   Working Approach:
	- Each SQL query must answer ONE business question.
	- After each query, document ONE key finding using the following structure:
	  Finding → Evidence (Metrics) → Business Impact → Recommendation
*/

USE DialerDB;
GO

/* Summary VIEW: Join the fact table with dimensions once, allowing subsequent queries to be shorter. 
   BIT columns are cast to INT so that SUM() can be applied directly. */
CREATE OR ALTER VIEW dw.vw_calls AS
SELECT f.call_id, f.call_start,
       d.full_date, d.year_month, d.week_start_date, d.day_name,
       f.hour_key AS call_hour, h.day_part, h.day_part_order,
       cp.campaign_id, cp.dialer_mode, cp.product,
       a.agent_id, a.team_id, a.tenure_band,
       l.lead_id, l.master_lead_id, l.is_duplicate, l.source, l.province, l.region, l.age_band, l.income_band,
       r.call_result, r.result_group,
       f.attempt_no, f.phone_attempt_no, f.wait_sec, f.talk_sec, f.handle_sec,
       CAST(f.is_contact AS INT)          AS is_contact,
       CAST(f.is_rpc AS INT)              AS is_rpc,
       CAST(f.is_sale AS INT)             AS is_sale,
       CASE WHEN r.call_result = 'Abandoned'    THEN 1 ELSE 0 END AS is_abandoned,
       CASE WHEN r.call_result = 'Wrong Number' THEN 1 ELSE 0 END AS is_wrong_number,
       CAST(f.flag_out_of_window AS INT)  AS flag_out_of_window,
       CAST(f.flag_over_attempt AS INT)   AS flag_over_attempt,
       CAST(f.flag_dnc_violation AS INT)  AS flag_dnc_violation
FROM dw.fact_calls       AS f
JOIN dw.dim_date         AS d  ON d.date_key      = f.date_key
JOIN dw.dim_hour         AS h  ON h.hour_key      = f.hour_key
JOIN dw.dim_campaign     AS cp ON cp.campaign_key = f.campaign_key
JOIN dw.dim_agent        AS a  ON a.agent_key     = f.agent_key
JOIN dw.dim_lead         AS l  ON l.lead_key      = f.lead_key
JOIN dw.dim_call_result  AS r  ON r.result_key    = f.result_key;
GO

-- Question 1: Campaign-Level Scorecard: What's Working and What's Going Off Track?
SELECT campaign_id, dialer_mode,
       COUNT(*)                                                                        AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2))                        AS contact_rate,
       CAST(100.0 * SUM(is_rpc)     / COUNT(*) AS DECIMAL(5,2))                        AS rpc_rate,
       CAST(100.0 * SUM(is_sale) / NULLIF(SUM(is_rpc), 0) AS DECIMAL(5,2))             AS conversion_rate,
       CAST(100.0 * SUM(is_sale) / COUNT(*) AS DECIMAL(5,2))                           AS sales_per_100_calls,
       CAST(100.0 * SUM(is_abandoned) / NULLIF(SUM(is_contact), 0) AS DECIMAL(5,2))    AS abandon_rate,
       CAST(100.0 * SUM(CASE WHEN is_contact = 1 AND wait_sec <= 3 THEN 1 ELSE 0 END)
                  / NULLIF(SUM(is_contact), 0) AS DECIMAL(5,2))                        AS service_level_3s,
       CAST(AVG(CAST(handle_sec AS FLOAT)) AS DECIMAL(6,1))                            AS aht_sec
FROM dw.vw_calls
GROUP BY campaign_id, dialer_mode
ORDER BY campaign_id;

-- Question 2: Data source performance: Which Sources Consume the Most Calls but Generate the Least Revenue?
SELECT source,
       COUNT(*)                                                                        AS calls,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))                  AS pct_of_calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2))                        AS contact_rate,
       CAST(100.0 * SUM(is_wrong_number) / NULLIF(SUM(is_contact), 0) AS DECIMAL(5,2)) AS wrong_number_pct_of_contacts,
       CAST(100.0 * SUM(is_sale) / NULLIF(SUM(is_rpc), 0) AS DECIMAL(5,2))             AS conversion_rate,
       SUM(is_sale)                                                                    AS sales,
       CAST(100.0 * SUM(is_sale) / SUM(SUM(is_sale)) OVER () AS DECIMAL(5,1))          AS pct_of_sales,
       CAST(100.0 * SUM(is_sale) / COUNT(*) AS DECIMAL(5,2))                           AS sales_per_100_calls
FROM dw.vw_calls
GROUP BY source
ORDER BY sales_per_100_calls DESC;

-- Question 3: Time Slot Analysis: When Is the Best Time to Reach High-Quality Leads?
-- By time slot
SELECT day_part,
       COUNT(*)                                                           AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2))           AS contact_rate,
       CAST(100.0 * SUM(is_sale) / COUNT(*) AS DECIMAL(5,2))              AS sales_per_100_calls
FROM dw.vw_calls
GROUP BY day_part, day_part_order
ORDER BY day_part_order;
 
-- By hour
SELECT call_hour,
       COUNT(*)                                                           AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2))           AS contact_rate
FROM dw.vw_calls
GROUP BY call_hour
ORDER BY call_hour;

-- Question 4: Call Attempt Analysis: At Which Attempt Does Call Effectiveness Start to Decline?
WITH a AS (
    SELECT attempt_no,
           COUNT(*)       AS calls,
           SUM(is_contact) AS contacts,
           SUM(is_sale)    AS sales
    FROM dw.vw_calls
    GROUP BY attempt_no
)
SELECT attempt_no, calls,
       CAST(100.0 * contacts / calls AS DECIMAL(5,2))  AS contact_rate,
       CAST(100.0 * sales / calls AS DECIMAL(5,2))     AS sales_per_100_calls,
       sales,
       CAST(100.0 * SUM(sales) OVER (ORDER BY attempt_no ROWS UNBOUNDED PRECEDING)
                  / SUM(sales) OVER () AS DECIMAL(5,1)) AS cumulative_sales_pct
FROM a
ORDER BY attempt_no;

-- Question 5: Segment Performance Analysis: Are We Investing in the Right Customer Segments?
SELECT region, COUNT(*) AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2)) AS contact_rate,
       CAST(100.0 * SUM(is_sale) / NULLIF(SUM(is_rpc), 0) AS DECIMAL(5,2)) AS conversion_rate
FROM dw.vw_calls GROUP BY region ORDER BY contact_rate DESC;
 
SELECT province, COUNT(*) AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2)) AS contact_rate,
       CAST(100.0 * SUM(is_sale) / NULLIF(SUM(is_rpc), 0) AS DECIMAL(5,2)) AS conversion_rate
FROM dw.vw_calls GROUP BY province ORDER BY contact_rate DESC;
 
SELECT age_band, COUNT(*) AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2)) AS contact_rate,
       CAST(100.0 * SUM(is_sale) / NULLIF(SUM(is_rpc), 0) AS DECIMAL(5,2)) AS conversion_rate,
       CAST(100.0 * SUM(is_sale) / COUNT(*) AS DECIMAL(5,2)) AS sales_per_100_calls
FROM dw.vw_calls GROUP BY age_band ORDER BY age_band;

-- Question 6: Call ROI & Leakage Analysis: How Many Calls Are Wasted or Non-Compliant?
DECLARE @total INT = (SELECT COUNT(*) FROM dw.fact_calls);
 
SELECT leak_type, calls,
       CAST(100.0 * calls / @total AS DECIMAL(5,2)) AS pct_of_all_calls,
       sales,
       CAST(100.0 * contacts / calls AS DECIMAL(5,2)) AS contact_rate
FROM (
    SELECT 'Calling duplicate leads' AS leak_type, COUNT(*) AS calls, SUM(is_sale) AS sales, SUM(is_contact) AS contacts, 1 AS o
    FROM dw.vw_calls WHERE is_duplicate = 1
    UNION ALL
    SELECT 'Calls beyond the 5th attempt (by phone number)', COUNT(*), SUM(is_sale), SUM(is_contact), 2
    FROM dw.vw_calls WHERE flag_over_attempt = 1
    UNION ALL
    SELECT 'Calls to DNC numbers',                      COUNT(*), SUM(is_sale), SUM(is_contact), 3
    FROM dw.vw_calls WHERE flag_dnc_violation = 1
    UNION ALL
    SELECT 'Calls made outside the 08:00–21:00 time window',            COUNT(*), SUM(is_sale), SUM(is_contact), 4
    FROM dw.vw_calls WHERE flag_out_of_window = 1
    UNION ALL
    SELECT 'OVERALL (Do not double-count)',           COUNT(*), SUM(is_sale), SUM(is_contact), 5
    FROM dw.vw_calls
    WHERE is_duplicate = 1 OR flag_over_attempt = 1 OR flag_dnc_violation = 1 OR flag_out_of_window = 1
) AS x
ORDER BY o;
 
-- Call cost per closed order
SELECT CAST(1.0 * COUNT(*) / SUM(is_sale) AS DECIMAL(6,1)) AS calls_per_sale FROM dw.vw_calls;

/* Question 7: Agent analysis – Who Exhibits Unusual Behavior Compared to Their Own Team?
               Short RPC % = Percentage of RPC calls (Right Party Contact) with talk time under 10 seconds. */
WITH a AS (
    SELECT agent_id, team_id,
           COUNT(*)                                                  AS calls,
           SUM(is_contact)                                           AS contacts,
           SUM(is_rpc)                                               AS rpc,
           SUM(is_sale)                                              AS sales,
           AVG(CAST(handle_sec AS FLOAT))                            AS aht_sec,
           SUM(CASE WHEN is_rpc = 1 AND talk_sec < 10 THEN 1 ELSE 0 END) AS short_rpc,
           SUM(flag_out_of_window)                                   AS calls_out_of_window
    FROM dw.vw_calls
    WHERE agent_id <> 'N/A'
    GROUP BY agent_id, team_id
), b AS (
    SELECT *,
           CAST(100.0 * contacts / calls AS DECIMAL(5,2))                  AS contact_rate,
           CAST(100.0 * sales / NULLIF(rpc, 0) AS DECIMAL(5,2))            AS conversion_rate,
           CAST(100.0 * short_rpc / NULLIF(rpc, 0) AS DECIMAL(5,2))        AS short_rpc_pct
    FROM a
)
SELECT agent_id, team_id, calls, contact_rate, conversion_rate,
       CAST(AVG(conversion_rate) OVER (PARTITION BY team_id) AS DECIMAL(5,2)) AS team_avg_conversion,
       CAST(aht_sec AS DECIMAL(6,1))                                          AS aht_sec,
       short_rpc_pct,
       RANK() OVER (ORDER BY short_rpc_pct DESC)                              AS rank_short_calls,
       calls_out_of_window
FROM b
ORDER BY short_rpc_pct DESC;


-- Question 8: Team Occupancy Analysis: Which Teams Are Overloaded and Which Have Spare Capacity?
SELECT a.team_id,
       COUNT(DISTINCT a.agent_id)                                       AS agents,
       COUNT(*)                                                         AS agent_days,
       CAST(100.0 * SUM(CAST(f.busy_sec AS BIGINT))
                  / (SUM(CAST(f.login_sec AS BIGINT)) - SUM(CAST(f.break_sec AS BIGINT))) AS DECIMAL(5,2)) AS occupancy_pct
FROM dw.fact_agent_daily AS f
JOIN dw.dim_agent        AS a ON a.agent_key = f.agent_key
GROUP BY a.team_id
ORDER BY a.team_id;
 
-- Question 9: Weekly Trend - Are Abandonment and Contact Rates Getting Worse? (Predictive Campaigns)
SELECT week_start_date, campaign_id,
       COUNT(*)                                                                      AS calls,
       CAST(100.0 * SUM(is_contact) / COUNT(*) AS DECIMAL(5,2))                      AS contact_rate,
       CAST(100.0 * SUM(is_abandoned) / NULLIF(SUM(is_contact), 0) AS DECIMAL(5,2))  AS abandon_rate
FROM dw.vw_calls
WHERE dialer_mode = 'Predictive'
GROUP BY week_start_date, campaign_id
ORDER BY campaign_id, week_start_date;
 
-- Question 10: Unique Customer View (Excluding Duplicate Leads) – Performance Breakdown by Master Lead Source
WITH p AS (
    SELECT master_lead_id,
           COUNT(*)        AS calls,
           MAX(is_contact) AS contacted,
           MAX(is_rpc)     AS rpc,
           MAX(is_sale)    AS sale
    FROM dw.vw_calls
    GROUP BY master_lead_id
)
SELECT l.source,
       COUNT(*)                                                    AS persons_called,
       CAST(100.0 * AVG(CAST(p.contacted AS FLOAT)) AS DECIMAL(5,2)) AS pct_reached,
       CAST(100.0 * AVG(CAST(p.rpc AS FLOAT)) AS DECIMAL(5,2))       AS pct_right_party,
       CAST(100.0 * AVG(CAST(p.sale AS FLOAT)) AS DECIMAL(5,2))      AS pct_sale,
       CAST(AVG(CAST(p.calls AS FLOAT)) AS DECIMAL(4,2))             AS avg_calls_per_person
FROM p
JOIN dw.dim_lead AS l ON l.lead_id = p.master_lead_id
GROUP BY l.source
ORDER BY pct_sale DESC;
 
-- Unique customers never called
SELECT COUNT(*) AS persons_never_called
FROM dw.dim_lead AS l
WHERE l.is_duplicate = 0 AND NOT EXISTS (
    SELECT 1 
    FROM dw.vw_calls AS c 
    WHERE c.master_lead_id = l.lead_id
);