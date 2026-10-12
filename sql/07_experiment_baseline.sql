/* =============================================================================
   07_experiment_baseline.sql
   Phase 8 — Baseline inputs for the checkout A/B test design

   WHY THIS FILE EXISTS
   A sample-size calculation is only as good as its baseline. This query
   measures, for the population the experiment would target, the two numbers
   the design needs:
     1. baseline checkout completion rate (primary metric)
     2. weekly volume of eligible users (→ experiment duration)
   plus revenue per eligible user and its standard deviation (secondary metric).

   POPULATION = who the treatment would actually reach
     - new users (first_visit on/after 2020-11-26, cart-tracked window)
     - who reach checkout (begin_checkout after a product view in a session;
       the no-cart definition is used because add_to_cart tracking is
       incomplete, Issue #15)
   UNIT = user (the experiment randomizes users, so the baseline must be
   per user, not per session)
   PRIMARY METRIC = user completes a purchase after checkout
                    (purchase after begin_checkout within the same session,
                     in any of the user's sessions)
============================================================================= */

WITH new_users AS (
  SELECT user_pseudo_id
  FROM `ecom-product-analytics-511200.ecom_analytics.dim_users`
  WHERE is_new_in_window
    AND first_visit_dt >= DATE '2020-11-26'
),
per_user AS (
  SELECT
    s.user_pseudo_id,
    DATE_TRUNC(MIN(IF(s.reached_checkout_nocart, s.session_dt, NULL)), WEEK(SUNDAY)) AS checkout_week,
    LOGICAL_OR(s.reached_checkout_nocart)                AS reached_checkout,
    LOGICAL_OR(s.reached_purchase_nocart)                AS completed,
    LOGICAL_OR(s.reached_checkout)                       AS reached_checkout_strict,
    LOGICAL_OR(s.reached_purchase)                       AS completed_strict,
    -- revenue only where revenue tracking is complete (≤ 2021-01-25, Issue #16)
    SUM(IF(s.session_dt <= DATE '2021-01-25', s.revenue, NULL)) AS revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s
  JOIN new_users USING (user_pseudo_id)
  WHERE s.session_dt >= DATE '2020-11-26'
  GROUP BY s.user_pseudo_id
)
SELECT
  IFNULL(CAST(checkout_week AS STRING), 'TOTAL')                         AS week,
  COUNT(*)                                                               AS checkout_users,
  COUNTIF(completed)                                                     AS completers,
  ROUND(100 * COUNTIF(completed) / COUNT(*), 2)                          AS completion_pct,
  ROUND(100 * COUNTIF(completed_strict AND reached_checkout_strict)
        / NULLIF(COUNTIF(reached_checkout_strict), 0), 2)                AS completion_strict_pct,
  ROUND(SUM(IFNULL(revenue, 0)) / COUNT(*), 3)                           AS revenue_per_checkout_user,
  ROUND(STDDEV(IFNULL(revenue, 0)), 2)                                   AS sd_revenue_per_user
FROM per_user
WHERE reached_checkout
GROUP BY ROLLUP (checkout_week)                  -- weekly rows + a TOTAL row
ORDER BY week;
