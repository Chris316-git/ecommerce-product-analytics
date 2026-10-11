/* =============================================================================
   04_acquisition_segments.sql
   Phase 5 — Acquisition and segment quality

   WHY THIS FILE EXISTS
   Phase 4 compared SESSIONS. Marketing decisions are made on USERS:
   "which channel brings users who go on to buy?" A fair comparison needs
   every user to be observed for the SAME amount of time, otherwise users
   acquired in early December look better than users acquired in January
   simply because we watched them longer.

   DESIGN: fixed 14-day outcome window per new user
     - population : new users (first_visit) between 2020-11-26 and 2021-01-11
         · from 2020-11-26 → cart tracking is live (Issue #16)
         · until 2021-01-11 → day 0 + 13 days ends by 2021-01-24, inside the
           window where transaction_id and revenue are tracked (≤ 2021-01-25)
     - outcomes   : purchase / orders / revenue / return visit within
                    days 0–13 after the first visit
     - segment    : first-touch channel, device and country (dim_users), so
                    each user belongs to exactly one segment
   All results are correlations between acquisition source and behaviour,
   not causal effects of the channel.
============================================================================= */


-- -----------------------------------------------------------------------------
-- MART. mart_acquisition_14d — grain: cohort week × channel × device × country group
-- WHY: Every user appears in exactly one row, so all counts are ADDITIVE and
--   Power BI can compute any rate as SUM(numerator) / SUM(denominator).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.mart_acquisition_14d` AS
WITH new_users AS (
  SELECT
    user_pseudo_id,
    first_channel,
    first_device,
    first_country,
    first_visit_dt,
    cohort_week
  FROM `ecom-product-analytics-511200.ecom_analytics.dim_users`
  WHERE is_new_in_window
    AND first_visit_dt BETWEEN DATE '2020-11-26' AND DATE '2021-01-11'
),
top_countries AS (
  -- top 10 countries by new users; the rest grouped as 'Other'
  SELECT first_country
  FROM new_users
  GROUP BY first_country
  ORDER BY COUNT(*) DESC
  LIMIT 10
),
sessions_14d AS (
  SELECT
    s.user_pseudo_id,
    COUNT(*)                                        AS sessions_14d,
    LOGICAL_OR(s.has_purchase)                      AS purchased_14d,
    LOGICAL_OR(s.session_dt > n.first_visit_dt)     AS returned_14d    -- visit on a LATER day
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s
  JOIN new_users n USING (user_pseudo_id)
  WHERE s.session_dt BETWEEN n.first_visit_dt AND DATE_ADD(n.first_visit_dt, INTERVAL 13 DAY)
  GROUP BY s.user_pseudo_id
),
orders_14d AS (
  SELECT
    t.user_pseudo_id,
    COUNT(*)                                        AS orders_14d,
    COUNTIF(t.revenue IS NOT NULL)                  AS orders_with_revenue_14d,
    SUM(t.revenue)                                  AS revenue_14d
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_transactions` t
  JOIN new_users n USING (user_pseudo_id)
  WHERE t.order_dt BETWEEN n.first_visit_dt AND DATE_ADD(n.first_visit_dt, INTERVAL 13 DAY)
  GROUP BY t.user_pseudo_id
)
SELECT
  n.cohort_week,
  n.first_channel,
  n.first_device,
  IF(tc.first_country IS NOT NULL, n.first_country, 'Other') AS country_group,
  COUNT(*)                                          AS new_users,
  SUM(IFNULL(s.sessions_14d, 0))                    AS sessions_14d,
  COUNTIF(s.purchased_14d)                          AS purchasers_14d,
  COUNTIF(s.returned_14d)                           AS returners_14d,
  SUM(IFNULL(o.orders_14d, 0))                      AS orders_14d,
  SUM(IFNULL(o.orders_with_revenue_14d, 0))         AS orders_with_revenue_14d,
  SUM(IFNULL(o.revenue_14d, 0))                     AS revenue_14d
FROM new_users n
LEFT JOIN sessions_14d s USING (user_pseudo_id)
LEFT JOIN orders_14d   o USING (user_pseudo_id)
LEFT JOIN top_countries tc ON tc.first_country = n.first_country
GROUP BY 1, 2, 3, 4;


-- -----------------------------------------------------------------------------
-- B1. Channel quality (new users, 14-day outcomes)
-- WHY: Volume vs quality. A channel can bring many users who rarely buy.
--   The 95% confidence interval (normal approximation, p ± 1.96·√(p(1−p)/n))
--   shows whether two channels are actually different or just noisy.
-- SQL: SUM(...) OVER () gives grand totals on every row for share-of-total.
-- -----------------------------------------------------------------------------
WITH ch AS (
  SELECT
    first_channel,
    SUM(new_users)               AS new_users,
    SUM(purchasers_14d)          AS purchasers,
    SUM(returners_14d)           AS returners,
    SUM(sessions_14d)            AS sessions,
    SUM(orders_with_revenue_14d) AS orders_rev,
    SUM(revenue_14d)             AS revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_acquisition_14d`
  GROUP BY first_channel
)
SELECT
  first_channel,
  new_users,
  ROUND(100 * new_users / SUM(new_users) OVER (), 1)                         AS pct_of_new_users,
  ROUND(100 * revenue   / SUM(revenue)   OVER (), 1)                         AS pct_of_revenue,
  ROUND(100 * purchasers / new_users, 3)                                     AS purchase_rate_14d,
  ROUND(100 * 1.96 * SQRT((purchasers / new_users) * (1 - purchasers / new_users) / new_users), 3)
                                                                             AS ci95_halfwidth,
  ROUND(revenue / new_users, 3)                                              AS revenue_per_new_user,
  ROUND(SAFE_DIVIDE(revenue, orders_rev), 2)                                 AS aov,
  ROUND(100 * returners / new_users, 2)                                      AS return_rate_14d,
  ROUND(sessions / new_users, 3)                                             AS sessions_per_user_14d
FROM ch
ORDER BY new_users DESC;


-- -----------------------------------------------------------------------------
-- B2. Device and country quality (same 14-day design)
-- WHY: Check whether segment differences seen at session level (Phase 4)
--   hold at user level, and whether geography — e.g. shipping costs for
--   international buyers — is a bigger driver than channel.
-- -----------------------------------------------------------------------------
WITH seg AS (
  SELECT 'device' AS dimension, first_device AS segment, new_users, purchasers_14d, returners_14d, revenue_14d
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_acquisition_14d`
  UNION ALL
  SELECT 'country', country_group, new_users, purchasers_14d, returners_14d, revenue_14d
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_acquisition_14d`
)
SELECT
  dimension,
  segment,
  SUM(new_users)                                                           AS n_users,
  ROUND(100 * SUM(purchasers_14d) / SUM(new_users), 3)                     AS purchase_rate_14d,
  ROUND(100 * 1.96 * SQRT(SAFE_DIVIDE(SUM(purchasers_14d), SUM(new_users))
        * (1 - SAFE_DIVIDE(SUM(purchasers_14d), SUM(new_users))) / SUM(new_users)), 3)
                                                                           AS ci95_halfwidth,
  ROUND(SUM(revenue_14d) / SUM(new_users), 3)                              AS revenue_per_new_user,
  ROUND(100 * SUM(returners_14d) / SUM(new_users), 2)                      AS return_rate_14d
FROM seg
GROUP BY dimension, segment
HAVING n_users >= 1000
ORDER BY dimension, n_users DESC;


-- -----------------------------------------------------------------------------
-- B3. Channel × device interaction
-- WHY: Guard against Simpson's paradox — a channel can look better overall
--   only because its traffic is mostly on the better-converting device.
--   If the channel ranking holds inside each device, the mix is not the story.
-- -----------------------------------------------------------------------------
SELECT
  first_channel,
  first_device,
  SUM(new_users)                                                AS n_users,
  ROUND(100 * SUM(purchasers_14d) / SUM(new_users), 3)          AS purchase_rate_14d,
  ROUND(SUM(revenue_14d) / SUM(new_users), 3)                   AS revenue_per_new_user,
  SUM(purchasers_14d)                                           AS purchasers,     -- small counts → noisy rates
  SUM(orders_with_revenue_14d)                                  AS orders_rev,
  ROUND(SAFE_DIVIDE(SUM(revenue_14d), SUM(orders_with_revenue_14d)), 2) AS aov
FROM `ecom-product-analytics-511200.ecom_analytics.mart_acquisition_14d`
WHERE first_device IN ('desktop', 'mobile')
GROUP BY first_channel, first_device
HAVING n_users >= 1000
ORDER BY first_channel, first_device;
