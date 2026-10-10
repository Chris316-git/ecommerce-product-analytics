/* =============================================================================
   02_build_tables.sql
   Phase 2 — Clean analytical tables
   Target dataset: ecom-product-analytics-511200.ecom_analytics

   WHY THIS FILE EXISTS
   Raw GA4 data is one row per event with nested fields. Analysts should not
   re-derive sessions, dedup rules and funnel logic in every query (or in DAX).
   This script builds five clean tables once, so every later analysis and the
   Power BI dashboard read the SAME definitions.

   Build order matters (later tables read earlier ones):
     1. stg_events        1 row per event (flattened)
     2. fct_transactions  1 row per transaction (deduplicated)
     3. dim_users         1 row per user (first-touch attributes, cohort)
     4. fct_sessions      1 row per session (ordered funnel timestamps)
     5. dim_date          1 row per calendar day

   Every statement is CREATE OR REPLACE, so the whole script is re-runnable.
   Decisions referenced as "Issue #n" are documented in docs/data_model.md.
============================================================================= */


-- -----------------------------------------------------------------------------
-- 1. stg_events — grain: 1 event
-- WHY: Flatten the fields we need ONCE. Pulling ga_session_id out of the
--   event_params array here means no later query has to UNNEST again.
--   No event-level dedup: Phase 1 found 0 exact duplicates (Issue #12).
-- SQL: scalar subqueries extract single params without multiplying rows.
--   PARTITION BY date + CLUSTER BY user keep later queries cheap.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.stg_events`
PARTITION BY event_dt
CLUSTER BY user_pseudo_id, event_name
AS
SELECT
  PARSE_DATE('%Y%m%d', event_date)                          AS event_dt,      -- property-timezone date
  event_timestamp                                           AS event_ts_micros,
  TIMESTAMP_MICROS(event_timestamp)                         AS event_ts,
  event_name,
  user_pseudo_id,
  (SELECT value.int_value FROM UNNEST(event_params)
    WHERE key = 'ga_session_id')                            AS ga_session_id,
  CONCAT(user_pseudo_id, '-', CAST(
    (SELECT value.int_value FROM UNNEST(event_params)
      WHERE key = 'ga_session_id') AS STRING))              AS session_key,   -- Issue #1
  (SELECT value.int_value FROM UNNEST(event_params)
    WHERE key = 'ga_session_number')                        AS ga_session_number,
  user_first_touch_timestamp,
  device.category                                           AS device_category,
  geo.country                                               AS country,
  traffic_source.medium                                     AS ts_medium,
  traffic_source.source                                     AS ts_source,
  ecommerce.transaction_id                                  AS transaction_id,
  ecommerce.purchase_revenue                                AS purchase_revenue,
  ARRAY_LENGTH(items)                                       AS n_items
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';


-- -----------------------------------------------------------------------------
-- 2. fct_transactions — grain: 1 transaction
-- WHY: Revenue must be counted once per order.
--   - Valid transaction_id → keep the EARLIEST event per id (Issue #7)
--   - Missing / '(not set)' id → keep each purchase event, flagged (Issue #8)
--   - NULL revenue stays NULL so AOV is not understated (Issue #9)
-- SQL: QUALIFY filters on a window function without an extra subquery.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.fct_transactions` AS
WITH purchases AS (
  SELECT
    user_pseudo_id,
    session_key,
    event_dt,
    event_ts,
    event_ts_micros,
    transaction_id,
    purchase_revenue,
    n_items,
    (transaction_id IS NOT NULL AND transaction_id != '(not set)') AS has_valid_txn_id
  FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
  WHERE event_name = 'purchase'
),
valid_dedup AS (
  SELECT
    *,
    COUNT(*)                       OVER (PARTITION BY transaction_id) AS n_events_for_txn,
    COUNT(DISTINCT user_pseudo_id) OVER (PARTITION BY transaction_id) AS n_users_for_txn
  FROM purchases
  WHERE has_valid_txn_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY transaction_id
                             ORDER BY event_ts_micros, user_pseudo_id) = 1
),
missing_id AS (
  SELECT *, 1 AS n_events_for_txn, 1 AS n_users_for_txn
  FROM purchases
  WHERE NOT has_valid_txn_id
)
SELECT
  IF(has_valid_txn_id, transaction_id,
     CONCAT('missing-', session_key, '-', CAST(event_ts_micros AS STRING))) AS transaction_key,
  transaction_id,
  has_valid_txn_id,
  user_pseudo_id,
  session_key,
  event_dt          AS order_dt,
  event_ts          AS order_ts,
  purchase_revenue  AS revenue,
  n_items,
  n_events_for_txn,
  n_users_for_txn                       -- >1 flags the 15 cross-user id collisions
FROM (
  SELECT * FROM valid_dedup
  UNION ALL
  SELECT * FROM missing_id
);


-- -----------------------------------------------------------------------------
-- 3. dim_users — grain: 1 user
-- WHY: Segments (channel, device, country) and the cohort must be ONE fixed
--   value per user, otherwise a user could appear in two segments.
--   - First-touch attributes = values on the user's EARLIEST event (Issue #3)
--   - New in window = user has a first_visit event in the window; cohort date
--     = date of that first_visit. Using event_date (property timezone) keeps
--     cohorts on the same calendar as every other table (Issue #6).
--   - Obfuscated channel values become 'Unknown', not dropped (Issue #4)
-- SQL: ROW_NUMBER picks the earliest event; event_name breaks timestamp ties
--   so the result is deterministic.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.dim_users` AS
WITH first_event AS (
  SELECT
    user_pseudo_id,
    ts_medium,
    ts_source,
    device_category,
    country
  FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
  WHERE TRUE                      -- BigQuery requires WHERE/GROUP BY/HAVING with QUALIFY
  QUALIFY ROW_NUMBER() OVER (PARTITION BY user_pseudo_id
                             ORDER BY event_ts_micros, event_name) = 1
),
user_agg AS (
  SELECT
    user_pseudo_id,
    MIN(event_dt)                                    AS first_seen_dt,
    MAX(event_dt)                                    AS last_seen_dt,
    MIN(IF(event_name = 'first_visit', event_dt, NULL)) AS first_visit_dt,
    COUNT(DISTINCT session_key)                      AS n_sessions
  FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
  GROUP BY user_pseudo_id
)
SELECT
  u.user_pseudo_id,
  f.ts_medium                                        AS first_medium,
  f.ts_source                                        AS first_source,
  CASE
    WHEN f.ts_medium IS NULL
      OR f.ts_medium IN ('<Other>', '(data deleted)', '(not set)') THEN 'Unknown'
    WHEN f.ts_medium = '(none)'   THEN 'Direct'
    WHEN f.ts_medium = 'organic'  THEN 'Organic Search'
    WHEN f.ts_medium = 'cpc'      THEN 'Paid Search'
    WHEN f.ts_medium = 'referral' THEN 'Referral'
    ELSE 'Other'
  END                                                AS first_channel,
  f.device_category                                  AS first_device,
  f.country                                          AS first_country,
  u.first_seen_dt,
  u.last_seen_dt,
  u.first_visit_dt,
  (u.first_visit_dt IS NOT NULL)                     AS is_new_in_window,
  DATE_TRUNC(u.first_visit_dt, WEEK(SUNDAY))         AS cohort_week,     -- NULL if not new
  u.n_sessions
FROM user_agg u
JOIN first_event f USING (user_pseudo_id);


-- -----------------------------------------------------------------------------
-- 4. fct_sessions — grain: 1 session
-- WHY: The funnel is diagnosed at session level. Each step only counts if it
--   happened AFTER the previous step IN THE SAME SESSION (ordered funnel).
--     t_view     = first view_item
--     t_cart     = first add_to_cart     with ts >= t_view
--     t_checkout = first begin_checkout  with ts >= t_cart
--     t_purchase = first purchase        with ts >= t_checkout
--   ">=" allows two steps logged in the same microsecond.
--   SENSITIVITY funnel (Issue #15, add_to_cart tracking is incomplete):
--     t_checkout_nocart = first begin_checkout with ts >= t_view
--     t_purchase_nocart = first purchase       with ts >= t_checkout_nocart
--   Unordered has_* flags are kept so QA can measure ordered vs unordered gap.
--   Sessions are defined by session_key, not session_start events (Issue #2).
-- SQL: events are collected into one array per session; each CTE adds one
--   step by searching the array relative to the previous step's timestamp.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.fct_sessions`
PARTITION BY session_dt
CLUSTER BY user_pseudo_id
AS
WITH sess AS (
  SELECT
    session_key,
    ANY_VALUE(user_pseudo_id)                                  AS user_pseudo_id,
    ANY_VALUE(ga_session_id)                                   AS ga_session_id,
    MIN(ga_session_number)                                     AS ga_session_number,
    MIN(event_dt)                                              AS session_dt,
    MIN(event_ts)                                              AS session_start_ts,
    MAX(event_ts)                                              AS session_end_ts,
    ARRAY_AGG(device_category ORDER BY event_ts_micros LIMIT 1)[OFFSET(0)] AS device_category,
    ARRAY_AGG(country         ORDER BY event_ts_micros LIMIT 1)[OFFSET(0)] AS country,
    COUNT(*)                                                   AS n_events,
    COUNTIF(event_name = 'page_view')                          AS n_page_views,
    COUNTIF(event_name = 'view_item')                          AS n_item_views,
    LOGICAL_OR(event_name = 'view_item')                       AS has_view_item,
    LOGICAL_OR(event_name = 'add_to_cart')                     AS has_add_to_cart,
    LOGICAL_OR(event_name = 'begin_checkout')                  AS has_begin_checkout,
    LOGICAL_OR(event_name = 'purchase')                        AS has_purchase,
    ARRAY_AGG(IF(event_name IN ('view_item', 'add_to_cart', 'begin_checkout', 'purchase'),
                 STRUCT(event_name AS name, event_ts_micros AS ts), NULL)
              IGNORE NULLS)                                    AS funnel_events
  FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
  GROUP BY session_key
),
step1 AS (
  SELECT *,
    (SELECT MIN(e.ts) FROM UNNEST(funnel_events) e
      WHERE e.name = 'view_item')                                AS t_view
  FROM sess
),
step2 AS (
  SELECT *,
    (SELECT MIN(e.ts) FROM UNNEST(funnel_events) e
      WHERE e.name = 'add_to_cart' AND e.ts >= t_view)           AS t_cart
  FROM step1
),
step3 AS (
  SELECT *,
    (SELECT MIN(e.ts) FROM UNNEST(funnel_events) e
      WHERE e.name = 'begin_checkout' AND e.ts >= t_cart)        AS t_checkout
  FROM step2
),
step4 AS (
  SELECT *,
    (SELECT MIN(e.ts) FROM UNNEST(funnel_events) e
      WHERE e.name = 'purchase' AND e.ts >= t_checkout)          AS t_purchase
  FROM step3
),
step5 AS (
  SELECT *,
    (SELECT MIN(e.ts) FROM UNNEST(funnel_events) e
      WHERE e.name = 'begin_checkout' AND e.ts >= t_view)        AS t_checkout_nocart
  FROM step4
),
step6 AS (
  SELECT *,
    (SELECT MIN(e.ts) FROM UNNEST(funnel_events) e
      WHERE e.name = 'purchase' AND e.ts >= t_checkout_nocart)   AS t_purchase_nocart
  FROM step5
),
session_revenue AS (
  SELECT
    session_key,
    COUNT(*)      AS n_transactions,
    SUM(revenue)  AS revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_transactions`
  GROUP BY session_key
)
SELECT
  s.session_key,
  s.user_pseudo_id,
  s.ga_session_id,
  s.ga_session_number,
  ROW_NUMBER() OVER (PARTITION BY s.user_pseudo_id
                     ORDER BY s.session_start_ts, s.session_key)  AS session_number_in_window,
  IF(s.ga_session_number = 1, 'New', 'Returning')                 AS user_type,
  s.session_dt,
  s.session_start_ts,
  s.session_end_ts,
  s.device_category,
  s.country,
  s.n_events,
  s.n_page_views,
  s.n_item_views,
  -- unordered: "did the event happen anywhere in the session?"
  s.has_view_item,
  s.has_add_to_cart,
  s.has_begin_checkout,
  s.has_purchase,
  -- ordered funnel step timestamps
  TIMESTAMP_MICROS(s.t_view)                                      AS t_view,
  TIMESTAMP_MICROS(s.t_cart)                                      AS t_cart,
  TIMESTAMP_MICROS(s.t_checkout)                                  AS t_checkout,
  TIMESTAMP_MICROS(s.t_purchase)                                  AS t_purchase,
  (s.t_view     IS NOT NULL)                                      AS reached_view,
  (s.t_cart     IS NOT NULL)                                      AS reached_cart,
  (s.t_checkout IS NOT NULL)                                      AS reached_checkout,
  (s.t_purchase IS NOT NULL)                                      AS reached_purchase,
  (s.t_checkout_nocart IS NOT NULL)                               AS reached_checkout_nocart,
  (s.t_purchase_nocart IS NOT NULL)                               AS reached_purchase_nocart,
  IFNULL(r.n_transactions, 0)                                     AS n_transactions,
  r.revenue                                                       AS revenue
FROM step6 s
LEFT JOIN session_revenue r USING (session_key);


-- -----------------------------------------------------------------------------
-- 5. dim_date — grain: 1 calendar day
-- WHY: Power BI needs a continuous date table for trends and time slicers.
--   week_start uses the SAME week definition as dim_users.cohort_week.
--   Tracking flags let every analysis (and the dashboard) restrict itself to
--   days where the relevant events were actually recorded.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `ecom-product-analytics-511200.ecom_analytics.dim_date` AS
SELECT
  d                                                    AS date,
  DATE_TRUNC(d, WEEK(SUNDAY))                          AS week_start,
  DATE_TRUNC(d, MONTH)                                 AS month_start,
  FORMAT_DATE('%Y-%m', d)                              AS year_month,
  FORMAT_DATE('%a', d)                                 AS day_of_week,
  EXTRACT(DAYOFWEEK FROM d) IN (1, 7)                  AS is_weekend,
  DATE_ADD(DATE_TRUNC(d, WEEK(SUNDAY)), INTERVAL 6 DAY) > DATE '2021-01-31'
                                                       AS is_partial_week,
  -- Tracking-quality flags (Issue #16, found in Phase 4 daily diagnostics)
  d >= DATE '2020-11-26'                               AS is_cart_tracked,     -- add_to_cart live
  d BETWEEN DATE '2020-11-12' AND DATE '2021-01-25'    AS is_txn_tracked       -- valid transaction_id + revenue
FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2020-11-01', DATE '2021-01-31')) AS d;
