/* =============================================================================
   03_funnel_analysis.sql
   Phase 4 — Ordered funnel analysis + problem prioritization

   WHY THIS FILE EXISTS
   Answer "where do users drop off, for whom, and which leak should the
   product team fix first?" The script:
     1. builds two marts (pre-aggregated tables) that Power BI reads
     2. runs the funnel cuts used in docs/funnel_findings.md

   ANALYSIS WINDOW (Issue #16): add_to_cart was not tracked before 2020-11-26,
   so every strict-funnel cut uses sessions from 2020-11-26 to 2021-01-31
   (dim_date.is_cart_tracked). The marts keep ALL days so the dashboard can
   show the tracking gap; the filter is applied in the queries.

   Definitions (see docs/metric_dictionary.md):
     strict funnel  view_item → add_to_cart → begin_checkout → purchase,
                    in order, within one session  (main definition)
     no-cart funnel view_item → begin_checkout → purchase  (sensitivity check,
                    because add_to_cart tracking is incomplete — Issue #15)
============================================================================= */


-- -----------------------------------------------------------------------------
-- MART 1. mart_funnel_daily — grain: day × device × first channel × user type
-- WHY: Session counts are ADDITIVE, so Power BI can sum them across any
--   filter and compute rates as SUM(numerator) / SUM(denominator).
--   Funnel logic stays in SQL; DAX only divides.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily` AS
SELECT
  s.session_dt,
  s.device_category,
  u.first_channel,
  s.user_type,
  COUNT(*)                          AS sessions,
  COUNTIF(s.reached_view)           AS view_sessions,
  COUNTIF(s.reached_cart)           AS cart_sessions,
  COUNTIF(s.reached_checkout)       AS checkout_sessions,
  COUNTIF(s.reached_purchase)       AS purchase_sessions,
  COUNTIF(s.reached_checkout_nocart) AS checkout_nocart_sessions,
  COUNTIF(s.reached_purchase_nocart) AS purchase_nocart_sessions,
  COUNTIF(s.has_purchase)           AS any_purchase_sessions,
  SUM(s.n_transactions)             AS transactions,
  SUM(s.revenue)                    AS revenue
FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s
JOIN `ecom-product-analytics-511200.ecom_analytics.dim_users`    u USING (user_pseudo_id)
GROUP BY 1, 2, 3, 4;


-- -----------------------------------------------------------------------------
-- MART 2. mart_funnel_users — grain: first channel × first device
-- WHY: Distinct users are NOT additive across days, so the user-level funnel
--   is pre-computed here. Each user has exactly ONE first channel and ONE
--   first device, so users ARE additive across these two dimensions.
--   A user counts at a step if at least one of their sessions reached that
--   step in order (no stitching across sessions). Only sessions in the
--   cart-tracked window count, so users = users active from 2020-11-26.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.mart_funnel_users` AS
WITH per_user AS (
  SELECT
    user_pseudo_id,
    LOGICAL_OR(reached_view)      AS u_view,
    LOGICAL_OR(reached_cart)      AS u_cart,
    LOGICAL_OR(reached_checkout)  AS u_checkout,
    LOGICAL_OR(reached_purchase)  AS u_purchase,
    LOGICAL_OR(has_purchase)      AS u_any_purchase,
    SUM(revenue)                  AS revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions`
  WHERE session_dt >= DATE '2020-11-26'          -- cart-tracked window only
  GROUP BY user_pseudo_id
)
SELECT
  u.first_channel,
  u.first_device,
  COUNT(*)                   AS users,
  COUNTIF(p.u_view)          AS view_users,
  COUNTIF(p.u_cart)          AS cart_users,
  COUNTIF(p.u_checkout)      AS checkout_users,
  COUNTIF(p.u_purchase)      AS purchase_users,
  COUNTIF(p.u_any_purchase)  AS any_purchase_users,
  SUM(p.revenue)             AS revenue
FROM `ecom-product-analytics-511200.ecom_analytics.dim_users` u
JOIN per_user p USING (user_pseudo_id)
GROUP BY 1, 2;


-- -----------------------------------------------------------------------------
-- A1. Overall session funnel: size of each leak in ABSOLUTE sessions
-- WHY: A low rate on a small step can matter less than a moderate rate on a
--   huge step. Prioritization starts from sessions lost, not just %.
-- -----------------------------------------------------------------------------
SELECT
  SUM(sessions)                                              AS sessions,
  SUM(view_sessions)                                         AS view,
  SUM(cart_sessions)                                         AS cart,
  SUM(checkout_sessions)                                     AS checkout,
  SUM(purchase_sessions)                                     AS purchase,
  SUM(sessions)          - SUM(view_sessions)                AS lost_before_view,
  SUM(view_sessions)     - SUM(cart_sessions)                AS lost_view_to_cart,
  SUM(cart_sessions)     - SUM(checkout_sessions)            AS lost_cart_to_checkout,
  SUM(checkout_sessions) - SUM(purchase_sessions)            AS lost_checkout_to_purchase,
  -- sensitivity (no-cart) funnel
  SUM(checkout_nocart_sessions)                              AS checkout_nocart,
  SUM(purchase_nocart_sessions)                              AS purchase_nocart,
  SUM(any_purchase_sessions)                                 AS any_purchase
FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily`
WHERE session_dt >= DATE '2020-11-26';


-- -----------------------------------------------------------------------------
-- A2–A4. Funnel by segment (device, first channel, user type)
-- WHY: The same overall rate can hide one segment that is far worse.
-- SQL: UNION ALL stacks three GROUP BYs into one comparable table;
--   SAFE_DIVIDE avoids division-by-zero errors on small segments.
-- -----------------------------------------------------------------------------
WITH seg AS (
  SELECT 'device' AS dimension, device_category AS segment, * EXCEPT (device_category, first_channel, user_type, session_dt)
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily` WHERE session_dt >= DATE '2020-11-26'
  UNION ALL
  SELECT 'first_channel', first_channel, * EXCEPT (device_category, first_channel, user_type, session_dt)
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily` WHERE session_dt >= DATE '2020-11-26'
  UNION ALL
  SELECT 'user_type', user_type, * EXCEPT (device_category, first_channel, user_type, session_dt)
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily` WHERE session_dt >= DATE '2020-11-26'
)
SELECT
  dimension,
  segment,
  SUM(sessions)                                                            AS n_sessions,
  ROUND(100 * SAFE_DIVIDE(SUM(view_sessions),     SUM(sessions)), 2)       AS view_rate,
  ROUND(100 * SAFE_DIVIDE(SUM(cart_sessions),     SUM(view_sessions)), 2)  AS view_to_cart,
  ROUND(100 * SAFE_DIVIDE(SUM(checkout_sessions), SUM(cart_sessions)), 2)  AS cart_to_checkout,
  ROUND(100 * SAFE_DIVIDE(SUM(purchase_sessions), SUM(checkout_sessions)), 2) AS checkout_to_purchase,
  ROUND(100 * SAFE_DIVIDE(SUM(purchase_sessions), SUM(sessions)), 3)       AS cvr_strict,
  ROUND(100 * SAFE_DIVIDE(SUM(purchase_nocart_sessions), SUM(sessions)), 3) AS cvr_nocart,
  ROUND(SAFE_DIVIDE(SUM(revenue), SUM(sessions)), 3)                       AS revenue_per_session
FROM seg
GROUP BY dimension, segment
HAVING n_sessions >= 1000             -- ignore segments too small to compare
                                      -- (alias differs from the column: HAVING SUM(sessions)
                                      --  would resolve to SUM(SUM(sessions)) and fail)
ORDER BY dimension, n_sessions DESC;


-- -----------------------------------------------------------------------------
-- A5. Weekly trend
-- WHY: Separate a structural leak from a seasonal one (holiday peak vs January).
--   Partial weeks are flagged so they are not read as a drop.
--   Runs on ALL weeks on purpose: this view is how the add_to_cart tracking
--   gap (Issue #16) was discovered.
-- -----------------------------------------------------------------------------
SELECT
  d.week_start,
  LOGICAL_OR(d.is_partial_week)                                          AS partial_week,
  SUM(m.sessions)                                                        AS sessions,
  ROUND(100 * SAFE_DIVIDE(SUM(m.view_sessions), SUM(m.sessions)), 2)     AS view_rate,
  ROUND(100 * SAFE_DIVIDE(SUM(m.cart_sessions), SUM(m.view_sessions)), 2) AS view_to_cart,
  ROUND(100 * SAFE_DIVIDE(SUM(m.purchase_sessions), SUM(m.sessions)), 3) AS cvr_strict,
  ROUND(100 * SAFE_DIVIDE(SUM(m.any_purchase_sessions), SUM(m.sessions)), 3) AS cvr_broad,
  ROUND(SUM(m.revenue), 0)                                               AS revenue
FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily` m
JOIN `ecom-product-analytics-511200.ecom_analytics.dim_date` d ON d.date = m.session_dt
GROUP BY d.week_start
ORDER BY d.week_start;


-- -----------------------------------------------------------------------------
-- A6. User-level funnel by first channel
-- WHY: Business reporting view: "what share of each channel's users ever
--   complete a purchase journey?"
-- -----------------------------------------------------------------------------
SELECT
  first_channel,
  SUM(users)                                                               AS users,
  ROUND(100 * SAFE_DIVIDE(SUM(view_users),     SUM(users)), 2)             AS pct_view,
  ROUND(100 * SAFE_DIVIDE(SUM(cart_users),     SUM(users)), 2)             AS pct_cart,
  ROUND(100 * SAFE_DIVIDE(SUM(purchase_users), SUM(users)), 3)             AS user_cvr_strict,
  ROUND(100 * SAFE_DIVIDE(SUM(any_purchase_users), SUM(users)), 3)         AS user_cvr_broad,
  ROUND(SAFE_DIVIDE(SUM(revenue), SUM(users)), 3)                          AS revenue_per_user
FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_users`
GROUP BY first_channel
ORDER BY users DESC;


-- -----------------------------------------------------------------------------
-- A7. Prioritization: sessions lost at each step, New vs Returning sessions
-- WHY: Combines SIZE (sessions lost) with SEGMENT GAP. A2 showed device and
--   channel barely differ (CVR 0.74%–0.84%), while new-user sessions convert
--   ~4x worse than returning ones, so the gap that matters is user type.
--   "Gap sessions" = sessions that would pass the step if new-user sessions
--   matched the returning-user rate. Returning users have higher intent, so
--   this is an UPPER BOUND for sizing, not a forecast.
-- SQL: MAX(...) OVER (PARTITION BY step) finds the best rate per step
--   without a self-join.
-- -----------------------------------------------------------------------------
WITH ut AS (
  SELECT
    user_type,
    SUM(sessions)          AS sessions,
    SUM(view_sessions)     AS view,
    SUM(cart_sessions)     AS cart,
    SUM(checkout_sessions) AS checkout,
    SUM(purchase_sessions) AS purchase
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily`
  WHERE session_dt >= DATE '2020-11-26'
  GROUP BY user_type
),
steps AS (
  SELECT user_type, '1 landing -> view'    AS step, sessions AS entered, view     AS passed FROM ut UNION ALL
  SELECT user_type, '2 view -> cart',              view,                 cart              FROM ut UNION ALL
  SELECT user_type, '3 cart -> checkout',          cart,                 checkout          FROM ut UNION ALL
  SELECT user_type, '4 checkout -> purchase',      checkout,             purchase          FROM ut
)
SELECT
  step,
  user_type,
  entered,
  entered - passed                                                AS sessions_lost,
  ROUND(100 * passed / entered, 2)                                AS step_rate,
  ROUND(100 * MAX(passed / entered) OVER (PARTITION BY step), 2)  AS best_rate,
  ROUND(entered * MAX(passed / entered) OVER (PARTITION BY step) - passed, 0)
                                                                  AS gap_sessions_upper_bound
FROM steps
ORDER BY step, user_type;


-- -----------------------------------------------------------------------------
-- A8. Robustness check for the top candidate: checkout completion
-- WHY: Before recommending a problem, check that the gap is not an artifact
--   of one definition or one device. begin_checkout and purchase were tracked
--   for the whole window, so this step is the most reliably measured one.
--   Strict = checkout after cart; no-cart = checkout after any product view.
-- SQL: GROUP BY ROLLUP adds subtotal rows (user type) and a grand total
--   (both NULL) in a single query.
-- -----------------------------------------------------------------------------
SELECT
  user_type,
  device_category,
  SUM(checkout_sessions)                                                  AS checkout,
  SUM(purchase_sessions)                                                  AS purchase,
  ROUND(100 * SUM(purchase_sessions) / SUM(checkout_sessions), 2)         AS checkout_to_purchase_strict,
  SUM(checkout_nocart_sessions)                                           AS checkout_nocart,
  SUM(purchase_nocart_sessions)                                           AS purchase_nocart,
  ROUND(100 * SUM(purchase_nocart_sessions) / SUM(checkout_nocart_sessions), 2) AS checkout_to_purchase_nocart
FROM `ecom-product-analytics-511200.ecom_analytics.mart_funnel_daily`
WHERE session_dt >= DATE '2020-11-26'
GROUP BY ROLLUP (user_type, device_category);
