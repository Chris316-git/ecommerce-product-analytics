# Metric Dictionary

Every number in the analysis and the Power BI dashboard maps to exactly one metric below.
Baselines cover the full window (2020-11-01 to 2021-01-31) and come from the clean tables built in `sql/02_build_tables.sql` (query in the appendix).

## Ground rules

1. **State the grain of the denominator.** "Conversion rate" is ambiguous. Every rate here is either **session-level** (denominator = sessions) or **user-level** (denominator = distinct users).
2. **Distinct counts don't add up.** Users per day cannot be summed into users per month; a returning user would be counted once per day. Always recount distinct users at the level you report.
3. **Ratios are computed as SUM(numerator) / SUM(denominator)**, never as an average of daily or segment ratios. Averaging ratios gives small segments the same weight as large ones.
4. **Revenue comes from `fct_transactions` only.** It is deduplicated (one row per order). Never sum order revenue after joining to item lines (that inflates revenue 4.8× in this data).
5. **Strict funnel = main definition; broad = sensitivity check.** The strict funnel requires view_item → add_to_cart → begin_checkout → purchase in order within one session. Because add_to_cart tracking is incomplete (Issues #15–16 in `data_model.md`), we also report the broad version ("purchase happened in the session") so the gap is visible.
6. **Cart-based metrics use the cart-tracked window (from 2020-11-26).** add_to_cart was not tracked before then, so M09–M13 and M15 are reported on that window in the analysis (see below). The full-window baselines in the tables are kept to show the size of the tracking effect.

## Acquisition

| ID | Metric | Numerator / Denominator | Source | Baseline | Interpretation | Pitfalls |
|---|---|---|---|---|---|---|
| M01 | Users | COUNT DISTINCT `user_pseudo_id` | `dim_users` | 270,154 | Reach of the store | Cookie-based: one person on two devices = two users |
| M02 | New users | users with a `first_visit` in the window | `dim_users.is_new_in_window` | 257,314 (95.2%) | Acquisition volume; cohort population | Users first seen before Nov 1 are not new (Issue #6) |
| M03 | Sessions | COUNT `session_key` | `fct_sessions` | 360,129 | Traffic volume | Key = user + `ga_session_id`; `ga_session_id` alone undercounts |
| M04 | Sessions per user | sessions / users | `fct_sessions`, `dim_users` | 1.33 | Visit frequency in the window | Short 3-month window caps this |
| M05 | Users by first-touch channel | users grouped by `first_channel` | `dim_users` | see Phase 5 | Which channels bring users | First-touch = channel on the user's earliest event; 18.5% "Unknown" (obfuscated) |

## Engagement

| ID | Metric | Numerator / Denominator | Source | Baseline | Interpretation | Pitfalls |
|---|---|---|---|---|---|---|
| M06 | Events per session | SUM `n_events` / sessions | `fct_sessions` | 11.93 | Depth of a visit | Includes automatic events (scroll, user_engagement), so it is a rough proxy |
| M07 | Product views per session | SUM `n_item_views` / sessions | `fct_sessions` | 1.07 | Product browsing depth | Mean is skewed by heavy browsers; most sessions view 0 products |
| M08 | Product view rate | sessions with ordered `view_item` / sessions | `fct_sessions.reached_view` | 21.39% (77,020) | Share of visits that reach a product page | 79% of sessions never view a product: landing-page and navigation problem, not checkout |

## Conversion (session level unless stated)

| ID | Metric | Numerator / Denominator | Source | Baseline | Interpretation | Pitfalls |
|---|---|---|---|---|---|---|
| M09 | Add-to-cart rate | sessions reaching cart / sessions | `reached_cart` | 4.21% (15,167) | Top-of-funnel purchase intent | Understated by add_to_cart tracking gaps |
| M10 | View → cart rate | sessions reaching cart / sessions reaching view | `reached_cart`, `reached_view` | 19.69% | Product page persuasiveness | Step rate: denominator is the previous step, not all sessions |
| M11 | Cart → checkout rate | sessions reaching checkout / sessions reaching cart | `reached_checkout`, `reached_cart` | 35.71% | Cart abandonment (inverse) | Strict ordering drops checkouts without a logged cart (Issue #15) |
| M12 | Checkout → purchase rate | sessions reaching purchase / sessions reaching checkout | `reached_purchase`, `reached_checkout` | 52.33% | Checkout completion | Checkout sub-steps (shipping, payment) not split in the MVP |
| M13 | Session conversion rate (strict) | sessions reaching purchase in order / sessions | `reached_purchase` | **0.787%** (2,834) | Main funnel KPI | Undercounts purchase sessions by ~42% because of tracking gaps |
| M14 | Session conversion rate (broad) | sessions with any purchase / sessions | `has_purchase` | 1.346% (4,848) | Sensitivity check for M13 | Doesn't prove the user went through the funnel steps |
| M15 | User conversion rate (strict) | users with ≥1 strict purchase session / users | `fct_sessions`, `dim_users` | 0.987% (2,666) | Share of visitors who complete the full journey | User-level: not comparable with M13 |
| M16 | User conversion rate (broad) | users with ≥1 purchase session / users | `fct_sessions`, `dim_users` | 1.636% (4,419) | Share of visitors who ever buy | Same as above |

## Revenue

| ID | Metric | Numerator / Denominator | Source | Baseline | Interpretation | Pitfalls |
|---|---|---|---|---|---|---|
| M17 | Revenue | SUM `revenue` | `fct_transactions` | $339,457 | Top-line outcome | Raw purchase events say $362,165; the $22,708 gap is duplicate purchases removed |
| M18 | Transactions | COUNT `transaction_key` | `fct_transactions` | 5,357 | Order volume | Includes 906 purchases without a valid ID (flagged, kept) |
| M19 | AOV | revenue / transactions **with non-null revenue** | `fct_transactions` | $69.18 (4,907 orders) | Basket size | Dividing by all 5,357 orders would treat 450 NULL-revenue orders as $0 and understate AOV |
| M20 | Revenue per user (ARPU) | revenue / users | `fct_transactions`, `dim_users` | $1.257 | Value of an average visitor; compares channels | Dominated by the ~98% of users who never buy |
| M21 | Revenue per session | revenue / sessions | `fct_transactions`, `fct_sessions` | $0.943 | Value of a visit; what traffic is worth | Same as above |

## Retention

| ID | Metric | Numerator / Denominator | Source | Baseline | Interpretation | Pitfalls |
|---|---|---|---|---|---|---|
| M22 | Week-N retention | users in cohort with ≥1 session in days 7N..7N+6 after first visit / cohort size | `dim_users`, `fct_sessions` | Phase 6 | Do new users come back? | **Right censoring:** Week N is only computed for cohorts with a fully observed Week N; unobserved cells are NULL, not 0 |
| M23 | Cohort size | new users per `cohort_week` | `dim_users` | Phase 6 | Denominator for M22 | Partial first/last calendar weeks excluded |

## Acquisition quality (new users, fixed 14-day window)

Population: new users with first visit 2020-11-26 → 2021-01-11 (142,183), so every user has the same 14 observable days inside the tracked window. Source: `mart_acquisition_14d`.

| ID | Metric | Numerator / Denominator | Source | Baseline | Interpretation | Pitfalls |
|---|---|---|---|---|---|---|
| M24 | 14-day purchase rate | new users with ≥1 purchase session in days 0–13 / new users | `mart_acquisition_14d` | 1.26% (Organic 1.28%, Paid 1.34%) | Channel / segment quality | Compare with 95% CIs; small segments are noisy |
| M25 | 14-day revenue per new user | revenue in days 0–13 / new users | `mart_acquisition_14d` | $0.93 (Paid Search $1.20) | Value of an acquired user | Driven by AOV as much as conversion |
| M26 | 14-day return rate | new users with a session on a later day within days 0–13 / new users | `mart_acquisition_14d` | 7.6%–7.9% by channel | Early stickiness | Not the same as Week-N retention (M22) |

## How the main funnel fits together

```
Sessions 360,129
  └─ reached product view   77,020   (21.39% of sessions)
       └─ reached cart      15,167   (19.69% of views)
            └─ checkout      5,416   (35.71% of carts)
                 └─ purchase 2,834   (52.33% of checkouts)  → strict session CVR 0.787%

Broad check: 4,848 sessions contain a purchase (1.346%).
```

Multiplying the step rates gives back the strict CVR: 21.39% × 19.69% × 35.71% × 52.33% ≈ 0.787%. This identity is a quick sanity check for any funnel chart.

## Funnel baselines in the cart-tracked window (2020-11-26 → 2021-01-31)

| ID | Metric | Full window | Cart-tracked window |
|---|---|---|---|
| M03 | Sessions | 360,129 | 271,105 |
| M08 | Product view rate | 21.39% | 20.47% |
| M10 | View → cart | 19.69% | **26.23%** |
| M11 | Cart → checkout | 35.71% | 35.57% |
| M12 | Checkout → purchase | 52.33% | 52.87% |
| M13 | Session CVR (strict) | 0.787% | **1.010%** |
| M14 | Session CVR (broad) | 1.346% | 1.337% |
| — | Strict share of purchase sessions | 58.5% | 75.5% |

View → cart jumps from 19.7% to 26.2% once the untracked weeks are removed. That one comparison is the clearest illustration of why tracking windows matter.

## Appendix — baseline query

```sql
WITH s AS (
  SELECT
    COUNT(*)                                                 AS sessions,
    SUM(n_events)                                            AS events,
    SUM(n_item_views)                                        AS item_views,
    COUNTIF(reached_view)                                    AS v,
    COUNTIF(reached_cart)                                    AS c,
    COUNTIF(reached_checkout)                                AS k,
    COUNTIF(reached_purchase)                                AS p,
    COUNTIF(has_purchase)                                    AS p_any,
    COUNT(DISTINCT IF(reached_purchase, user_pseudo_id, NULL)) AS buyers_strict,
    COUNT(DISTINCT IF(has_purchase,     user_pseudo_id, NULL)) AS buyers_any
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions`
),
u AS (
  SELECT COUNT(*) AS users, COUNTIF(is_new_in_window) AS new_users
  FROM `ecom-product-analytics-511200.ecom_analytics.dim_users`
),
t AS (
  SELECT COUNT(*) AS txns, COUNTIF(revenue IS NOT NULL) AS txns_with_rev, SUM(revenue) AS revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_transactions`
)
SELECT
  u.users, u.new_users, s.sessions,
  ROUND(s.sessions / u.users, 3)            AS sessions_per_user,
  ROUND(s.events / s.sessions, 2)           AS events_per_session,
  ROUND(s.item_views / s.sessions, 3)       AS item_views_per_session,
  ROUND(100 * s.v / s.sessions, 2)          AS product_view_rate,
  ROUND(100 * s.c / s.sessions, 2)          AS add_to_cart_rate,
  ROUND(100 * s.c / s.v, 2)                 AS view_to_cart,
  ROUND(100 * s.k / s.c, 2)                 AS cart_to_checkout,
  ROUND(100 * s.p / s.k, 2)                 AS checkout_to_purchase,
  ROUND(100 * s.p / s.sessions, 3)          AS session_cvr_strict,
  ROUND(100 * s.p_any / s.sessions, 3)      AS session_cvr_broad,
  ROUND(100 * s.buyers_strict / u.users, 3) AS user_cvr_strict,
  ROUND(100 * s.buyers_any / u.users, 3)    AS user_cvr_broad,
  t.txns,
  ROUND(t.revenue, 2)                       AS revenue,
  ROUND(t.revenue / t.txns_with_rev, 2)     AS aov,
  ROUND(t.revenue / u.users, 3)             AS revenue_per_user,
  ROUND(t.revenue / s.sessions, 3)          AS revenue_per_session
FROM s, u, t;
```
