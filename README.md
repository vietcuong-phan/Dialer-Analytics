# Dialer Performance & Data Allocation Analytics

End-to-end analytics project for an outbound call-center (dialer) operation: from messy raw data to a SQL Server star schema, a lead-allocation strategy validated on a holdout set, compliance monitoring, and a 4-page Power BI dashboard.

## Table of contents

1. [Business Problem](#1-business-problem)
2. [Database](#2-database)
3. [Problem Solving](#3-problem-solving)
4. [Outcome](#4-outcome)
5. [Insights & Recommendations](#5-insights--recommendations)
6. [Repository Structure](#6-repository-structure)
7. [Compile Introduction](#7-compile-introduction)
8. [Limitations and Future Directions](#8-limitations-and-future-directions)

---

## 1. Business Problem

A telesales operation runs 6 campaigns on three dialer modes (Predictive, Progressive, Preview) with 18 agents in 6 teams. Leads come from five sources (own database, referrals, two partners, purchased lists). Management has three recurring problems:

| # | Problem | Why it matters |
|---|---|---|
| 1 | **Performance visibility** - no single view of contact rate, abandon rate, AHT, service level and occupancy by campaign | Problems stay hidden until someone checks manually |
| 2 | **Inefficient data allocation** - every lead gets the same treatment, regardless of source, segment or timing | Limited agent capacity is spent on leads that rarely convert |
| 3 | **Compliance and data-quality risk** - Do-Not-Call (DNC) numbers, calling-window and attempt-limit rules, abandon-rate threshold, duplicate and malformed lead data | Regulatory exposure, customer complaints and wasted calls |

**Objectives**

1. Build a clean, trustworthy dataset and a reusable reporting model.
2. Monitor operational KPIs daily and weekly.
3. Design and quantify a data-allocation strategy that raises sales per call.
4. Detect compliance violations and abnormal agent behavior, and identify whether root causes are systemic or individual.

**Target users:** team leaders and operations managers (daily monitoring), data-allocation and campaign managers (weekly planning), compliance/QA (weekly review), WFM and coaches (capacity and coaching).

---

## 2. Database

### 2.1 Source data

| Item | Value |
|---|---|
| Period | 01 Aug 2026 - 31 Oct 2026 (79 operating days, Mon-Sat) |
| Leads | 83,200 rows (80,000 unique people + 3,200 duplicate leads) |
| Call log | 237,080 raw rows (236,371 after removing duplicated rows) |
| Agents / teams / campaigns | 18 / 6 / 6 |
| DNC list | 2,000 numbers |
| Agent-day activity | 1,422 rows (login, break and busy time) |

Raw files: `leads_raw.csv`, `call_log_raw.csv`, `agents.csv`, `campaigns.csv`, `dnc_list.csv`, `agent_daily.csv`.

**Planted data issues** (to practice detection and cleaning): 5 phone formats (27.7% of leads non-standard), duplicate leads (3.85%), 22 inconsistent result labels, 469 invalid `talk_sec` values, 709 duplicated call rows, invalid ages and missing provinces, DNC violations, calls outside 08:00-21:00, calls beyond the attempt limit, one campaign with mis-configured pacing, and agents with abnormal behavior.

### 2.2 Layered database design (SQL Server)

| Schema | Purpose | Rule |
|---|---|---|
| `raw` | Source files loaded as text (all `NVARCHAR`) | Never modified |
| `clean` | Standardized phones, de-duplicated calls, flags, cleaning log | Rows are flagged, not deleted, when they carry business meaning |
| `dw` | Star schema for analysis and Power BI | Facts + conformed dimensions |

### 2.3 Star schema (`dw`)

<img width="1030" height="763" alt="Image" src="https://github.com/user-attachments/assets/e2b696c0-4b91-4615-a4db-4ca40fd78be7" />

| Table | Grain | Key columns |
|---|---|---|
| `fact_calls` | 1 row = 1 call | `call_id`, keys, `attempt_no`, `wait_sec`, `talk_sec`, `handle_sec`, `is_contact`, `is_rpc`, `is_sale`, compliance flags |
| `fact_agent_daily` | 1 row = agent x day | `login_sec`, `break_sec`, `busy_sec` (for occupancy) |
| `dim_date`, `dim_hour`, `dim_call_result` | calendar / hour / outcome | day part, week start, result group |
| `dim_campaign`, `dim_agent` | campaign / agent | dialer mode, abandon threshold, team, tenure (agent key 0 = "No agent" for abandoned calls) |
| `dim_lead` | lead | source, region, age band, duplicate flag, A/B/C segment and score |

Design decisions: two facts share conformed dimensions (no direct fact-to-fact joins); `fact_calls` stores 0/1 flags so ratios are always *sum of numerator / sum of denominator*; duplicates are kept and flagged so wasted calls can be measured.

---

## 3. Problem Solving

The work follows seven scripted steps (`sql/01` to `sql/07`), then Power BI and Excel.

| Step | What was done | Key technique |
|---|---|---|
| 1. Import | Loaded 6 CSVs into `raw` as text, auto-detecting row terminators | `BULK INSERT`, dynamic SQL |
| 2. Clean | Standardized phones (`+84...`, `84...`, `090-...` to `0xxxxxxxxx`), removed duplicated call rows, normalized 22 labels to 10, nulled invalid `talk_sec`, flagged duplicate leads and compliance issues, wrote a cleaning log | CTEs, `ROW_NUMBER`, `UPDATE`, `TRY_CAST` |
| 3. Model | Built the star schema with surrogate keys and an "unknown agent" member | DDL, `IDENTITY_INSERT`, FK constraints |
| 4. Analyze | Ten business questions: campaign scorecard, source, timing, attempt curve, region/age, leakage, agents, occupancy, trend, person-level funnel | Window functions, conditional aggregation |
| 5. Allocate | Scored leads, segmented A/B/C, validated on a holdout set, simulated allocation policies | Train/holdout split, smoothed rates, `PERCENTILE_CONT` |
| 6. Comply | Quantified DNC / window / attempt-limit / abandon issues, agent anomaly detection, data-quality scorecard, daily exception procedure | Robust z-score (median/MAD), stored procedure |
| 7. Publish | Result tables for Power BI | `SELECT INTO` |

**Methodology highlights**

- **Counting unit:** attempt limits are counted per phone number, not per `lead_id`, because duplicate leads are the same person.
- **No data leakage:** lead scores are learned on 70% of people (lead-id last digit < 7) and evaluated on the other 30%. `income_band` was tested and rejected (sale rate 5.79-5.95% in every band).
- **Score:** historical sale rate of each `source x age band x region` cell (119 cells), smoothed toward the source rate (k = 100). Segment A = top 30%, C = bottom 30%.
- **Break-even policy:** tail attempts are removed per segment when marginal yield falls below a threshold (sales per 100 calls); five thresholds are scanned and the trade-off is shown explicitly.
- **Anomaly detection:** modified z-score `0.6745 * (x - median) / MAD`, |z| > 3.5, on campaign-normalized metrics; flags are review prompts, not conclusions.
- **Abandon monitoring:** evaluated weekly (weeks with >= 100 answered calls), because daily rates are noisy at about 150 answered calls per campaign-day.

**Power BI**

- Import mode; Power Query handles column selection, True/False to 0/1 conversion and the segment merge (`powerbi/powerbi_queries.m`).
- About 50 DAX measures in 7 layers (base, KPI, agent, compliance, time, thresholds and colors, text) in `powerbi/dialer_measures_all.dax`.
- 4 pages designed from wireframes, with conclusion-style titles, rule-based color (red only for breaches) and dynamic titles.

---

## 4. Outcome

### 4.1 Deliverables

| Deliverable | Description |
|---|---|
| Data pipeline | 7 SQL scripts from raw files to analysis-ready star schema, with cleaning log |
| Power BI dashboard | 4 pages: Operations Overview, Data Allocation, Compliance & Data Quality, Agent & Team |
| Allocation strategy | Lead scoring, A/B/C segments, playbook, quantified before/after simulation |
| Compliance monitoring | Violation analysis, agent risk view, daily exception stored procedure |
| Excel report | Daily, weekly and agent reports |
| Documentation | Wireframes, visual build specification, KPI definitions |

### 4.2 Baseline KPIs (whole period)

| Metric | Value |
|---|---|
| Calls | 236,371 |
| Contact rate | 23.54% |
| RPC rate | 21.37% |
| Conversion (sales / RPC) | 9.16% |
| Abandon rate | 2.53% (limit 3%) |
| Service level (answered by agent within 3 s) | 84.91% |
| AHT | 136.4 s |
| Occupancy | 55.37% |
| Sales / calls per sale | 4,630 / about 51 |

### 4.3 Headline results

| Area | Result |
|---|---|
| Lead scoring (holdout) | Segment A converts 8.99% vs 2.37% for C (3.8x) |
| Allocation policy (cap segment C at 2 attempts) | -16.3% calls, -4.3% sales, sales per 100 calls 1.905 to 2.177 (+14%) |
| Policy + compliance clean-up | -20.4% calls, -8.7% sales (upper bound; freed capacity not reinvested) |
| Compliance | Root causes identified: DNC sync (systemic), per-lead attempt counting (configuration), pacing on C04 (configuration), two agents calling out of window and two showing hang-up patterns (individual, pending review) |

---

## 5. Insights & Recommendations

Each dashboard page tells one story. Below, every page shows its screenshot, the insights it reveals (with evidence) and the recommendations that follow (with owners). IDs link recommendations to insights.

### 5.1 Page 1 - Operations Overview

*Question answered: how is the dialer performing, and which campaign is off-track? Audience: team leaders and operations managers, reviewed each morning.*

<img width="1351" height="766" alt="Image" src="https://github.com/user-attachments/assets/ecb7f2da-7cca-4866-89c5-abca1acb18a8" />

**Insights**

| ID | Insight | Evidence |
|---|---|---|
| P1-I1 | Overall performance is stable and unremarkable | 236,371 calls; contact rate 23.54%; RPC 21.37%; conversion 9.16%; abandon 2.53%; AHT 136 s; about 51 calls per sale |
| P1-I2 | Campaign C04 is off-track on dialer health | Abandon 7.10% (limit 3%) in 13 of 13 weeks; service level 58.6% vs 84-99% for the other campaigns |
| P1-I3 | Timing drives contact rate | 27.8% in 17-21h vs 18.0% in 11-14h; peak 18h at 29.8%, low at 12h at 17.2% |
| P1-I4 | Campaigns differ more in dialer behavior than in reach | Contact rate is 23.2-23.9% for all six campaigns, while abandon ranges from 0% (Preview) to 7.1% (C04) |

**Recommendations**

| ID | Recommendation | Addresses | Owner |
|---|---|---|---|
| P1-R1 | Reduce the over-dial ratio on C04 and enable an automatic pacing throttle when weekly abandon exceeds 2.5% | P1-I2 | Dialer admin / IT |
| P1-R2 | Schedule priority leads in the 17-21h window and use midday for low-priority fill | P1-I3 | Team leaders / WFM |
| P1-R3 | Review campaigns by dialer health (abandon, service level), not by contact rate alone | P1-I4 | Operations manager |

### 5.2 Page 2 - Data Allocation

*Question answered: which leads deserve capacity, and when should we stop calling? Audience: data-allocation and campaign managers, used during weekly planning.*

<img width="1351" height="769" alt="Image" src="https://github.com/user-attachments/assets/59836ac0-f42e-4e8d-b3e9-d71715672014" />

**Insights**

| ID | Insight | Evidence |
|---|---|---|
| P2-I1 | Purchased lists consume capacity but barely convert | 24.0% of calls vs 5.6% of sales; 0.46 vs 4.93 sales per 100 calls for referrals; 17.5% of answered calls are wrong numbers |
| P2-I2 | Lead segments predict outcomes (holdout set) | Segment A converts 8.99% vs 2.37% for C (3.8x); A takes 26.8% of calls for 49.3% of sales, C takes 34.0% of calls for 12.4% of sales |
| P2-I3 | Returns diminish with every attempt | Sales per 100 calls fall from 2.58 (attempt 1) to 1.10 (attempt 5); attempts 1-2 produce 71% of sales |
| P2-I4 | Capping low-value attempts saves capacity at a small cost | Cap segment C at 2 attempts: -16.3% calls, -4.3% sales, sales per 100 calls 1.905 to 2.177 (+14%); with compliance clean-up: -20.4% calls, -8.7% sales (upper bound) |
| P2-I5 | A small group of people was never called | 777 of 80,000 people (about 1%) have no call attempt |

**Recommendations**

| ID | Recommendation | Addresses | Owner |
|---|---|---|---|
| P2-R1 | Cut or renegotiate purchased lists and deprioritize them in dialing order | P2-I1 | Data-allocation manager |
| P2-R2 | Dial segment A first and in the best time window; cap segment C at 2 attempts | P2-I2, P2-I4 | Campaign manager |
| P2-R3 | Derive the break-even threshold from real cost per call and value per sale, then set caps per segment | P2-I3, P2-I4 | Management |
| P2-R4 | Run an A/B pilot with a control group before rollout (simulated savings do not include reinvestment) | P2-I4 | Campaign manager / analyst |
| P2-R5 | Start with never-called leads that score in segment A or B | P2-I5 | Data-allocation manager |

### 5.3 Page 3 - Compliance & Data Quality

*Question answered: where are we violating rules, and is the cause the system or people? Audience: compliance/QA, operations managers, and IT for configuration fixes; reviewed weekly.*

<img width="1354" height="769" alt="Image" src="https://github.com/user-attachments/assets/bbe1c105-092e-4857-acca-83dfc6d025d3" />

**Insights**

| ID | Insight | Evidence |
|---|---|---|
| P3-I1 | DNC violations are systemic | 832 calls to 588 numbers (29.4% of the DNC list), median 37 days after listing (487 calls after 30+ days), spread across all 18 agents |
| P3-I2 | Attempt-limit breaches come from duplicate leads | 5,559 over-limit calls to 2,274 numbers; 72.1% occur because the limit is counted per `lead_id` instead of per phone number |
| P3-I3 | Calling-window violations are individual | 1,037 calls: one agent after 21:00 (549 calls), another before 08:00 (488 calls); contact rate only 14.4% |
| P3-I4 | Some agents show hang-up patterns | Four agents rated HIGH (two hang-up patterns, two out-of-window) and two WATCH; hang-up agents have about 55% of right-party calls under 10 s vs a 1.2% group median |
| P3-I5 | Lead data is weak at ingestion | Only 70.5% of lead rows are fully clean; 27.7% malformed phones and 3.9% duplicates, spread evenly across sources |
| P3-I6 | The measurement window changes the conclusion | C01 exceeds 3% abandon on 28 of 79 days but only 2 of 13 weeks; C04 exceeds it in 13 of 13 weeks |

**Recommendations**

| ID | Recommendation | Addresses | Owner |
|---|---|---|---|
| P3-R1 | Sync the DNC list at list load and again before dialing; run a daily check (target: 0 violations) | P3-I1 | Compliance / IT |
| P3-R2 | Standardize phones and merge duplicates at import; enforce attempt limits per phone number | P3-I2, P3-I5 | Data team / IT |
| P3-R3 | Hard-lock dialing outside 08:00-21:00 at system level | P3-I3 | IT / team leaders |
| P3-R4 | Team leaders review recordings of flagged agents before drawing conclusions, then coach if confirmed | P3-I4 | Team leaders / QA |
| P3-R5 | Validate format and duplicates automatically on every import | P3-I5 | Data team |
| P3-R6 | Alert on weekly (or rolling-window) abandon rate rather than single days, to avoid false alarms | P3-I6 | Operations |

### 5.4 Page 4 - Agent & Team

*Question answered: who needs coaching or review, and where is capacity imbalanced? Audience: team leaders, WFM and coaches; reviewed weekly.*

<img width="1354" height="769" alt="Image" src="https://github.com/user-attachments/assets/00926194-4707-4197-93f3-686e6f80b525" />

**Insights**

| ID | Insight | Evidence |
|---|---|---|
| P4-I1 | Capacity is unevenly used | Occupancy 65.9% (T01) vs 39.8% (T05); calls per agent-day 219.2 vs 98.8; overall occupancy 55.4% |
| P4-I2 | Two agents are outliers on several signals at once | A005 and A012: about 55% right-party calls under 10 s, AHT 72-79 s vs 115-170 s for other agents, conversion about 56-61% of their campaign average |
| P4-I3 | Two other agents differ only on handle time | Two agents are flagged WATCH for AHT well above their campaign: a coaching topic, not a compliance one |
| P4-I4 | Conversion alone does not identify problem agents | No agent is flagged on conversion by itself; behavior signals (very short calls, out-of-window calls) are what separate outliers |

**Recommendations**

| ID | Recommendation | Addresses | Owner |
|---|---|---|---|
| P4-R1 | Rebalance data between T01 and T05 (same card product family) after checking cross-training needs | P4-I1 | WFM / operations |
| P4-R2 | Review recordings for the two outlier agents before any conclusion; coach if confirmed | P4-I2 | Team leaders / QA |
| P4-R3 | Coach WATCH agents on call handling efficiency | P4-I3 | Coaches |
| P4-R4 | Use multi-signal flags (short calls, handle time, out-of-window) instead of single metrics | P4-I4 | Analyst / QA |
| P4-R5 | Restrict agent-level risk views to team leaders with row-level security in Power BI | P4-I2 | BI developer |

---

## 6. Repository Structure

```
.
├── README.md
├── generate_dialer_data.py
├── data_raw/
├── sql/
│   ├── 01_import_raw.sql
│   ├── 02_cleaning.sql
│   ├── 03_model.sql
│   ├── 04_analysis.sql
│   ├── 05_allocation.sql
│   ├── 06_compliance.sql
│   └── 07_pbi_support.sql
├── powerbi/
    └── dialer_dashboard.pbix 
```

---

## 7. Compile Introduction

### 7.1 Project in one paragraph

This project turns messy outbound-dialer data (237K simulated calls, 83K leads, 18 agents, 6 campaigns) into decisions. It cleans and models the data in SQL Server, measures operational KPIs, builds and validates a lead-scoring and allocation strategy on a holdout set, quantifies compliance risks and their root causes, and presents everything in a 4-page Power BI dashboard plus an Excel daily/weekly report. The central result: capping low-value leads and fixing a few system configurations could save about 16-20% of calls for a 4-9% sales trade-off (upper bound), while removing the compliance exposure.

### 7.2 Skills demonstrated

| Area | Evidence |
|---|---|
| SQL (SELECT, JOIN, GROUP BY, UPDATE, DELETE, window functions, CTEs, stored procedure) | `sql/02` to `sql/06` |
| Data modeling | Star schema with conformed dimensions and an unknown-member design |
| Data quality | Cleaning log, duplicate detection, standardization, outlier handling |
| Power BI (DAX, Power Query, conditional formatting, dynamic titles) | `powerbi/` |
| Analytical thinking | Holdout validation, break-even analysis, root-cause separation (system vs individual) |
| Compliance mindset | DNC, calling window, attempt limits, abandon threshold, anomaly detection |
| Communication | Insight-style titles, wireframes, recommendation table with owners |

---

## 8. Limitations and Future Directions

### 8.1 Limitations

- **Scoring uses three attributes only** (`source`, `age band`, `region`) and a lookup-style estimate; no behavioral or time-of-contact features.
- **No cost or revenue model.** The break-even threshold is a parameter, not derived from real cost per call and value per sale.
- **Simulation removes calls but does not reinvest freed capacity**, so lost sales are an upper bound; the real effect needs an A/B pilot.
- **Abandon is evaluated per week**, not with a regulator-specific rolling window.
- **Agent flags are statistical prompts** (18 agents, robust z-score); they need recordings and context before any conclusion.
- **Occupancy comes from simulated agent-day logs**, and service-level and occupancy targets (80%, 50-85%) are project assumptions, not rules.
- **No live integration** with a dialer platform; the dashboard refreshes from SQL Server snapshots.

### 8.2 Future directions

| Direction | Description |
|---|---|
| Real-data integration | Connect to dialer exports/APIs (Genesys, Five9, Vicidial) and automate the load |
| Stronger scoring | Logistic regression or gradient boosting with cross-validation, adding time-of-contact and history features |
| Pilot and measurement | A/B test the allocation playbook; measure incremental sales and update thresholds |
| Economics | Add cost per call and value per sale to choose caps by expected profit |
| Workforce planning | Forecast volume and staffing; schedule teams against occupancy targets |
| Near-real-time monitoring | Intraday abandon and service-level alerts (for example with Power Automate) |
| Automated compliance controls | DNC sync and per-phone attempt limits enforced in the dialer, with daily exception reports |
| Governance | Row-level security in Power BI so only team leaders see agent-level risk flags |
| Engineering | Orchestrate the pipeline with a scheduler and add automated data-quality tests |

---
