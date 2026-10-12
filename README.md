# E-Commerce Product Funnel & Retention Analytics

**SQL (BigQuery) · Product metrics · Funnel & cohort analysis · A/B test design · Power BI (in progress)**

Analysis of 4.3M real GA4 events from the Google Merchandise Store (Nov 2020 – Jan 2021) to answer: *where does the purchase funnel leak, which users are worth acquiring, do new users come back, and what should the product team test first?*

---

## TL;DR (60 seconds)

| | |
|---|---|
| **Problem** | Only ~1% of sessions convert. Leadership wants to know where users drop off, which channels bring quality users, and what to fix first. |
| **Data** | 4,295,584 events · 270,154 users · 360,129 sessions · GA4 public BigQuery sample |
| **Approach** | Raw-data QA → 5 clean analytical tables → ordered same-session funnel → 14-day channel quality → censoring-aware weekly cohorts → A/B test design |
| **Top finding** | Device and channel barely matter; **new vs returning** is the real split. New-user sessions convert **4.5× worse** (0.53% vs 2.41%) and complete checkout **42% vs 63%**. |
| **Data catch** | QA revealed add_to_cart **wasn't tracked before Nov 26** and duplicate purchases inflated revenue by **$22,708**. Without that, the funnel would point to the wrong problem. |
| **Recommendation** | Fix tracking, then A/B test a simplified checkout for first-time visitors (47.3% → 52.1%, ~1,750 users/arm, ~6–7 weeks). |

---

## 1. Business problem

Acting as a product/data analyst for an e-commerce store:
1. Where do users drop off between product view and purchase?
2. Which acquisition channels and devices bring higher-quality users?
3. Does retention differ by acquisition cohort?
4. Which KPIs should the team monitor?
5. Which problem should be tested first, and how?

## 2. Dataset

`bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`: GA4 export of the Google Merchandise Store, 92 daily shards (2020-11-01 → 2021-01-31), lightly obfuscated by Google. One row = one event, with nested `event_params` and `items`. See [`data/README.md`](data/README.md).

## 3. Data model

```
events (1 row = 1 event)
   └── user ──1:N── session ──1:0..N── transaction ──1:N── item line
        dim_users     fct_sessions        fct_transactions
```

| Table | Grain | Purpose |
|---|---|---|
| `stg_events` | event | flattened params, composite `session_key` |
| `dim_users` | user | first-touch channel/device/country, cohort week |
| `fct_sessions` | session | ordered funnel timestamps, new/returning, revenue |
| `fct_transactions` | order | deduplicated purchases (one row per transaction) |
| `dim_date` | day | calendar + tracking-quality flags |
| `mart_*` | pre-aggregated | additive tables for the dashboard |

Full detail and 16 documented data issues: [`docs/data_model.md`](docs/data_model.md).

## 4. Analytical approach

1. **Data quality first** ([`01_data_quality.sql`](sql/01_data_quality.sql)): found that `ga_session_id` alone undercounts sessions by 10,584, that `traffic_source` is not a stable first-touch field in this export, and duplicate / missing transaction IDs.
2. **Clean tables + QA** ([`02_build_tables.sql`](sql/02_build_tables.sql), [`06_qa_checks.sql`](sql/06_qa_checks.sql)): 18/18 automated checks pass (uniqueness, revenue reconciliation, orphan keys, funnel monotonicity, item double-counting).
3. **Metric framework** ([`docs/metric_dictionary.md`](docs/metric_dictionary.md)): 26 KPIs, each with numerator, denominator, grain and pitfalls.
4. **Ordered funnel** ([`03_funnel_analysis.sql`](sql/03_funnel_analysis.sql)): a step counts only if it happens after the previous step in the same session. A no-cart sensitivity funnel guards against tracking gaps.
5. **Acquisition quality** ([`04_acquisition_segments.sql`](sql/04_acquisition_segments.sql)): fixed 14-day outcome window per new user, 95% CIs, Simpson's-paradox check.
6. **Cohort retention** ([`05_cohort_retention.sql`](sql/05_cohort_retention.sql)): weekly cohorts with **right censoring** (unobservable cells are NULL, never 0).
7. **Experiment design** ([`experiment/`](experiment/)): A/B test sized from measured baselines.

## 5. Key SQL techniques

CTEs · `UNNEST` of nested arrays · scalar subqueries · window functions (`ROW_NUMBER`, `COUNT/SUM OVER`, `MAX OVER PARTITION BY`, running `LOGICAL_OR`) · `QUALIFY` for dedup · conditional aggregation / pivots · `GROUP BY ROLLUP` · `GENERATE_ARRAY` grids for cohort matrices · date math for cohort weeks and censoring · partitioned and clustered tables.

## 6. Dashboard

Power BI dashboard (Executive overview · Funnel & acquisition · Cohort retention), built on the `mart_*` tables with simple `DIVIDE`-based DAX measures. All business logic stays in SQL. *In progress; screenshots will be added to [`dashboard/`](dashboard/).*

## 7. Key findings

| # | Finding | Evidence |
|---|---|---|
| 1 | **Tracking gaps change the story** | add_to_cart ≈0 before Nov 26; view → cart rises from 19.7% to 26.2% once untracked weeks are excluded |
| 2 | **79.5% of sessions never view a product** | 215,607 of 271,105 sessions (clean window); strict session CVR 1.01% |
| 3 | **New vs returning is the real gap** | Session CVR 0.53% vs 2.41%; revenue/session $0.40 vs $2.40; device and channel CVR range only 0.95–1.11% |
| 4 | **New users abandon checkout** | Checkout → purchase 42.2% (new) vs 63.1% (returning), robust across definitions and devices |
| 5 | **Channel barely predicts quality** | 14-day purchase rate 1.20–1.34%, overlapping CIs; Paid Search higher AOV ($83, desktop only, small sample) |
| 6 | **New users rarely return; holiday users least** | Week-1 retention 2.14%; Christmas cohorts 1.35% vs early-Nov 3.09% |

Details: [`funnel_findings`](docs/funnel_findings.md) · [`acquisition_findings`](docs/acquisition_findings.md) · [`retention_findings`](docs/retention_findings.md)

## 8. Experiment design

Simplified checkout for first-time visitors. **User-level sticky randomization**, primary metric = checkout completion among users who reach checkout (baseline **47.3%**), α = 0.05, power = 80%, MDE = 10% relative → **1,752 users per arm, ~6.4 weeks**. Guardrails: AOV, payment errors, SRM. Design only, no results claimed. See [`experiment/ab_test_design.md`](experiment/ab_test_design.md) and [`sample_size.py`](experiment/sample_size.py).

## 9. Business recommendations

1. **Fix event tracking** (add_to_cart, transaction_id, revenue) and alert on gaps
2. **A/B test a simplified checkout** for first-time visitors
3. **Re-engage new users** (especially holiday cohorts), measured against a holdout
4. **Don't reallocate channel budget** on attributed data; test Paid Search incrementality
5. **Analyze landing pages** to cut the 79.5% of sessions that never view a product

Full Finding → Evidence → Implication → Action → Metric: [`docs/business_recommendations.md`](docs/business_recommendations.md)

## 10. Tech stack

**BigQuery (Standard SQL)** · **Power BI** · Python (stdlib only, sample-size calculation) · Git / GitHub

## Repository structure

```
├── data/README.md                 dataset source and access
├── sql/
│   ├── 01_data_quality.sql        raw profiling + QA (results recorded inline)
│   ├── 02_build_tables.sql        clean analytical tables
│   ├── 03_funnel_analysis.sql     funnel marts + analysis
│   ├── 04_acquisition_segments.sql
│   ├── 05_cohort_retention.sql
│   ├── 06_qa_checks.sql           post-build QA (18 checks)
│   └── 07_experiment_baseline.sql
├── docs/                          data model, metric dictionary, findings, recommendations
├── experiment/                    A/B test design + sample-size script
└── dashboard/                     Power BI file + screenshots
```

## Reproduce

1. Create a Google Cloud project and a BigQuery dataset `ecom_analytics` (location: US).
2. Replace the project ID `ecom-product-analytics-511200` in the SQL files with yours.
3. Run `02_build_tables.sql`, then the `CREATE` statements in `03`–`05`, then `06_qa_checks.sql`.
4. Run `python experiment/sample_size.py`.

## Limitations

Obfuscated public sample (18% of users have an unknown channel) · cookie-based identity understates retention · 3-month window (holiday season) · findings are correlational except where an experiment is proposed.
