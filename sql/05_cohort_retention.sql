/* =============================================================================
   05_cohort_retention.sql
   Phase 6 — Weekly cohort retention with right censoring

   WHY THIS FILE EXISTS
   Phase 4/5 showed returning users are worth ~6x more per session than new
   users. So: how many new users ever come back, and does it depend on how
   (channel) or where (device) they arrived?

   DEFINITIONS
   - Cohort      : week (Sunday start) of the user's first_visit. Only new
                   users (dim_users.is_new_in_window). The partial week
                   starting 2021-01-31 (1 day) is excluded.
   - Week N      : days 7N … 7N+6 after the user's OWN first visit
                   (user-relative, not calendar weeks). Week 0 contains the
                   first visit, so Week 0 retention is 100% by definition.
   - Retained    : ≥1 session in Week N. Activity retention, not purchase
                   retention (purchases are too rare: ~1% of users).
   - Censoring   : Week N is OBSERVABLE for a cohort only if its LAST user
                   (first visit on cohort_week + 6) has a fully observed Week N:
                       cohort_week + 6 + 7N + 6 ≤ 2021-01-31
                   Unobservable cells are NULL, never 0. Showing them as 0
                   would make recent cohorts look like they stop returning.
   - Segments    : first-touch channel and first-touch device (dim_users), so
                   each user stays in one segment even if they switch devices.
   Sessions are tracked for the whole window, so retention does not depend on
   the cart / transaction tracking gaps (Issue #16).
============================================================================= */


-- -----------------------------------------------------------------------------
-- MART. mart_cohort_retention — grain: cohort week × channel × device × week N
-- WHY: Power BI heatmap source. retained_users is additive across channel and
--   device. cohort_users repeats on every week_n row, so a retention measure
--   must always be evaluated with week_n in context (DIVIDE(SUM(retained),
--   SUM(cohort_users)) per week_n cell).
-- SQL: CROSS JOIN with a generated week array builds the full grid, so weeks
--   with zero returners still appear (as 0) instead of disappearing.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.mart_cohort_retention` AS
WITH cohort_users AS (
  SELECT user_pseudo_id, first_visit_dt, cohort_week, first_channel, first_device
  FROM `ecom-product-analytics-511200.ecom_analytics.dim_users`
  WHERE is_new_in_window
    AND cohort_week <= DATE '2021-01-24'                 -- drop the 1-day partial cohort
),
activity AS (
  -- one row per user per active week since first visit
  SELECT DISTINCT
    c.user_pseudo_id,
    DIV(DATE_DIFF(s.session_dt, c.first_visit_dt, DAY), 7) AS week_n
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s
  JOIN cohort_users c USING (user_pseudo_id)
  WHERE s.session_dt >= c.first_visit_dt
),
grid AS (
  SELECT cohort_week, first_channel, first_device, COUNT(*) AS cohort_users
  FROM cohort_users
  GROUP BY 1, 2, 3
),
retained AS (
  SELECT c.cohort_week, c.first_channel, c.first_device, a.week_n,
         COUNT(*) AS retained_users
  FROM activity a
  JOIN cohort_users c USING (user_pseudo_id)
  GROUP BY 1, 2, 3, 4
)
SELECT
  g.cohort_week,
  g.first_channel,
  g.first_device,
  wk                                                                              AS week_n,
  g.cohort_users,
  DATE_ADD(g.cohort_week, INTERVAL 6 + 7 * wk + 6 DAY) <= DATE '2021-01-31' AS is_observable,
  IF(DATE_ADD(g.cohort_week, INTERVAL 6 + 7 * wk + 6 DAY) <= DATE '2021-01-31',
     IFNULL(r.retained_users, 0), NULL)                                          AS retained_users
FROM grid g
CROSS JOIN UNNEST(GENERATE_ARRAY(0, 12)) AS wk          -- alias ≠ r.week_n to avoid ambiguity
LEFT JOIN retained r
  ON  r.cohort_week   = g.cohort_week
  AND r.first_channel = g.first_channel
  AND r.first_device  = g.first_device
  AND r.week_n        = wk;


-- -----------------------------------------------------------------------------
-- C1. Retention matrix (cohort × week N), all channels and devices
-- WHY: The classic cohort triangle. The NULL lower-right triangle is the
--   censoring rule at work.
-- SQL: conditional aggregation pivots week_n rows into W1…W11 columns.
-- -----------------------------------------------------------------------------
SELECT
  cohort_week,
  SUM(IF(week_n = 0, cohort_users, NULL))                                             AS cohort_size,
  ROUND(100 * SUM(IF(week_n = 1,  retained_users, NULL)) / SUM(IF(week_n = 1  AND is_observable, cohort_users, NULL)), 2) AS w1,
  ROUND(100 * SUM(IF(week_n = 2,  retained_users, NULL)) / SUM(IF(week_n = 2  AND is_observable, cohort_users, NULL)), 2) AS w2,
  ROUND(100 * SUM(IF(week_n = 3,  retained_users, NULL)) / SUM(IF(week_n = 3  AND is_observable, cohort_users, NULL)), 2) AS w3,
  ROUND(100 * SUM(IF(week_n = 4,  retained_users, NULL)) / SUM(IF(week_n = 4  AND is_observable, cohort_users, NULL)), 2) AS w4,
  ROUND(100 * SUM(IF(week_n = 6,  retained_users, NULL)) / SUM(IF(week_n = 6  AND is_observable, cohort_users, NULL)), 2) AS w6,
  ROUND(100 * SUM(IF(week_n = 8,  retained_users, NULL)) / SUM(IF(week_n = 8  AND is_observable, cohort_users, NULL)), 2) AS w8,
  ROUND(100 * SUM(IF(week_n = 11, retained_users, NULL)) / SUM(IF(week_n = 11 AND is_observable, cohort_users, NULL)), 2) AS w11
FROM `ecom-product-analytics-511200.ecom_analytics.mart_cohort_retention`
GROUP BY cohort_week
ORDER BY cohort_week;


-- -----------------------------------------------------------------------------
-- C2. Average retention curve — observable cohorts only
-- WHY: One curve for the dashboard and the README. Each week uses only the
--   cohorts that can be observed at that week, weighted by cohort size
--   (SUM / SUM, not an average of cohort percentages).
-- -----------------------------------------------------------------------------
SELECT
  week_n,
  COUNT(DISTINCT IF(is_observable, cohort_week, NULL))          AS cohorts_included,
  SUM(IF(is_observable, cohort_users, 0))                       AS users_included,
  SUM(retained_users)                                           AS retained_users,
  ROUND(100 * SUM(retained_users) / SUM(IF(is_observable, cohort_users, NULL)), 2) AS retention_pct
FROM `ecom-product-analytics-511200.ecom_analytics.mart_cohort_retention`
WHERE week_n BETWEEN 1 AND 11
GROUP BY week_n
ORDER BY week_n;


-- -----------------------------------------------------------------------------
-- C3. Retention by first-touch channel and first device (W1, W2, W4, W8)
-- WHY: Does acquisition source predict stickiness? Each column uses only the
--   cohorts observable at that week, so channels are compared like-for-like.
--   95% CI on W1 shows whether gaps are real.
-- -----------------------------------------------------------------------------
WITH seg AS (
  SELECT 'channel' AS dimension, first_channel AS segment, * EXCEPT (first_channel, first_device)
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_cohort_retention`
  UNION ALL
  SELECT 'device', first_device, * EXCEPT (first_channel, first_device)
  FROM `ecom-product-analytics-511200.ecom_analytics.mart_cohort_retention`
),
agg AS (
  SELECT
    dimension, segment,
    SUM(IF(week_n = 0, cohort_users, 0))                                        AS n_users,
    SUM(IF(week_n = 1, retained_users, NULL)) / SUM(IF(week_n = 1 AND is_observable, cohort_users, NULL)) AS w1,
    SUM(IF(week_n = 1 AND is_observable, cohort_users, NULL))                   AS w1_n,
    SUM(IF(week_n = 2, retained_users, NULL)) / SUM(IF(week_n = 2 AND is_observable, cohort_users, NULL)) AS w2,
    SUM(IF(week_n = 4, retained_users, NULL)) / SUM(IF(week_n = 4 AND is_observable, cohort_users, NULL)) AS w4,
    SUM(IF(week_n = 8, retained_users, NULL)) / SUM(IF(week_n = 8 AND is_observable, cohort_users, NULL)) AS w8
  FROM seg
  GROUP BY dimension, segment
)
SELECT
  dimension, segment, n_users,
  ROUND(100 * w1, 2)                                   AS w1_pct,
  ROUND(100 * 1.96 * SQRT(w1 * (1 - w1) / w1_n), 2)    AS w1_ci95,
  ROUND(100 * w2, 2)                                   AS w2_pct,
  ROUND(100 * w4, 2)                                   AS w4_pct,
  ROUND(100 * w8, 2)                                   AS w8_pct
FROM agg
WHERE n_users >= 3000
ORDER BY dimension, n_users DESC;


-- -----------------------------------------------------------------------------
-- C4. Holiday vs post-holiday cohorts (W1 and W2)
-- WHY: Holiday gift shoppers may be one-time buyers. Grouping cohorts by
--   acquisition period tests whether retention is seasonal.
-- -----------------------------------------------------------------------------
SELECT
  CASE
    WHEN cohort_week <  DATE '2020-11-22' THEN '1 Early Nov'
    WHEN cohort_week <  DATE '2020-12-20' THEN '2 Holiday peak (Nov 22 - Dec 19)'
    WHEN cohort_week <  DATE '2021-01-03' THEN '3 Christmas / New Year'
    ELSE                                       '4 January'
  END                                                                           AS period,
  SUM(IF(week_n = 0, cohort_users, 0))                                          AS n_users,
  ROUND(100 * SUM(IF(week_n = 1, retained_users, NULL)) / SUM(IF(week_n = 1 AND is_observable, cohort_users, NULL)), 2) AS w1_pct,
  ROUND(100 * SUM(IF(week_n = 2, retained_users, NULL)) / SUM(IF(week_n = 2 AND is_observable, cohort_users, NULL)), 2) AS w2_pct
FROM `ecom-product-analytics-511200.ecom_analytics.mart_cohort_retention`
GROUP BY period
ORDER BY period;
