/* =============================================================================
   01_data_quality.sql
   Phase 1 — Data understanding + raw-data QA
   Dataset : bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
   Window  : 2020-11-01 to 2021-01-31 (92 daily shards)

   WHY THIS FILE EXISTS
   Before building any funnel or cohort, we need to know:
     1. What one row represents (grain)
     2. How to identify a user, a session and a transaction (keys)
     3. Which events exist and whether every funnel step is present
     4. Which data-quality issues would distort later metrics
   Every query is read-only and filters on _TABLE_SUFFIX so only the needed
   shards are scanned. Results from the run on 2026-10-09 are recorded under
   each query (-- RESULT) so the decisions in docs/data_model.md are traceable.
============================================================================= */


-- -----------------------------------------------------------------------------
-- Q1. Table overview
-- WHY: Establish scale and date coverage. Grain check: rows >> users means one
--      row is an EVENT, not a user or a session.
-- -----------------------------------------------------------------------------
SELECT
  COUNT(*)                                            AS total_events,
  COUNT(DISTINCT user_pseudo_id)                      AS distinct_users,
  COUNT(DISTINCT event_date)                          AS distinct_days,
  MIN(event_date)                                     AS first_date,
  MAX(event_date)                                     AS last_date,
  ROUND(COUNT(*) / COUNT(DISTINCT user_pseudo_id), 1) AS events_per_user
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';
-- RESULT: 4,295,584 events | 270,154 users | 92 days | 20201101–20210131 | 15.9 events/user


-- -----------------------------------------------------------------------------
-- Q2. Event distribution
-- WHY: Confirm every funnel step exists and see how large each step is.
-- SQL: SUM(COUNT(*)) OVER () is a window over the grouped result. The empty
--      OVER () means "the whole result set", so each row sees the grand total.
-- -----------------------------------------------------------------------------
SELECT
  event_name,
  COUNT(*)                                         AS events,
  COUNT(DISTINCT user_pseudo_id)                   AS users,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_events
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY event_name
ORDER BY events DESC;
-- RESULT (events / users):
--   page_view 1,350,428 / 269,792      user_engagement 1,058,721 / 213,004
--   scroll 493,072 / 138,098           view_item 386,068 / 61,252
--   session_start 354,970 / 267,116    first_visit 257,462 / 257,314
--   view_promotion 190,104 / 102,443   add_to_cart 58,543 / 12,545
--   begin_checkout 38,757 / 9,715      select_item 31,007 / 13,180
--   view_search_results 26,172/14,449  add_shipping_info 19,722 / 9,714
--   add_payment_info 13,899 / 5,751    select_promotion 9,450 / 8,164
--   purchase 5,692 / 4,419             click 1,446 / 1,010
--   view_item_list 71 / 44
-- TAKEAWAY: all four funnel events exist. Checkout sub-steps (shipping, payment)
--   also exist, which enables a checkout drill-down later (stretch scope).


-- -----------------------------------------------------------------------------
-- Q3. event_params inventory
-- WHY: event_params is a REPEATED key/value array. ga_session_id, page_location
--      and session-level source/medium live here. We need to know which keys
--      exist, how often, and which value column holds the data.
-- SQL: The comma join to UNNEST(event_params) turns one event row into one row
--      per parameter, so we can group by parameter key.
-- -----------------------------------------------------------------------------
SELECT
  ep.key,
  COUNT(*)                                   AS param_rows,
  COUNTIF(ep.value.string_value IS NOT NULL) AS has_string,
  COUNTIF(ep.value.int_value    IS NOT NULL) AS has_int,
  COUNTIF(ep.value.double_value IS NOT NULL) AS has_double,
  COUNTIF(ep.value.float_value  IS NOT NULL) AS has_float
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
     UNNEST(event_params) AS ep
WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
GROUP BY ep.key
ORDER BY param_rows DESC;
-- RESULT (selected):
--   ga_session_id      4,295,584 (int, on every event)
--   ga_session_number  4,295,584 (int, on every event)
--   page_location      4,295,584 (string)
--   medium / source / campaign ≈ 1.43M events each (string) — only ~1/3 of events
--   transaction_id     5,242 (string 4,786 / int 456)
-- TAKEAWAY: session ID is always available as int_value. Session-level
--   source/medium is only on a subset of events (checked further in Q9).


-- -----------------------------------------------------------------------------
-- Q4 + Q5. Null IDs and session key design
-- WHY (Q4): rows without user/session ID cannot be attributed.
-- WHY (Q5): ga_session_id is the session start time in seconds, so different
--   users can share it. If distinct (user, ga_session_id) > distinct
--   ga_session_id, the composite key is required.
-- SQL: a scalar subquery extracts one param without multiplying rows
--   (a join to UNNEST would create one row per param).
-- -----------------------------------------------------------------------------
WITH base AS (
  SELECT
    user_pseudo_id,
    event_timestamp,
    (SELECT value.int_value FROM UNNEST(event_params)
      WHERE key = 'ga_session_id') AS ga_session_id
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
)
SELECT
  COUNT(*)                                       AS total_events,
  COUNTIF(user_pseudo_id IS NULL)                AS null_user_id,
  COUNTIF(ga_session_id  IS NULL)                AS null_session_id,
  COUNTIF(event_timestamp IS NULL)               AS null_timestamp,
  COUNT(DISTINCT ga_session_id)                  AS distinct_ga_session_id,
  COUNT(DISTINCT CONCAT(user_pseudo_id, '-', CAST(ga_session_id AS STRING)))
                                                 AS distinct_session_keys,
  COUNT(DISTINCT user_pseudo_id)                 AS users
FROM base;
-- RESULT: nulls = 0 / 0 / 0 | distinct ga_session_id 349,545 |
--         distinct (user, ga_session_id) 360,129 | users 270,154
-- TAKEAWAY: no null keys. Using ga_session_id alone would merge 10,584 sessions
--   from different users. Session key = user_pseudo_id + ga_session_id.
--   Sessions per user ≈ 1.33.


-- -----------------------------------------------------------------------------
-- Q6. Duplicate events
-- DUPLICATE KEY (our definition): same user, timestamp, event name AND params.
--   TO_JSON_STRING makes the params array comparable. Events that differ only
--   in params are NOT duplicates.
-- -----------------------------------------------------------------------------
WITH keyed AS (
  SELECT
    user_pseudo_id,
    event_timestamp,
    event_name,
    TO_JSON_STRING(event_params) AS params_json,
    COUNT(*)                     AS copies
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY 1, 2, 3, 4
)
SELECT
  event_name,
  COUNTIF(copies > 1) AS duplicated_keys,
  SUM(copies - 1)     AS extra_rows,
  SUM(copies)         AS total_rows
FROM keyed
GROUP BY event_name
ORDER BY extra_rows DESC;
-- RESULT: 0 exact duplicate events for every event_name.
-- TAKEAWAY: no event-level dedup needed. (Duplicate PURCHASES do exist at the
--   transaction level — see Q10b.)


-- -----------------------------------------------------------------------------
-- Q7. Is traffic_source constant per user (i.e., true first-touch)?
-- Also checks: device switching, first-touch timing (left censoring) and
-- first_visit consistency, because they are all user-level attributes.
-- -----------------------------------------------------------------------------
WITH u AS (
  SELECT
    user_pseudo_id,
    COUNT(DISTINCT CONCAT(IFNULL(traffic_source.source, 'N'), '|',
                          IFNULL(traffic_source.medium, 'N'), '|',
                          IFNULL(traffic_source.name,   'N'))) AS n_source_combos,
    COUNT(DISTINCT device.category)                              AS n_devices,
    MIN(user_first_touch_timestamp)                              AS first_touch_ts,
    COUNTIF(event_name = 'first_visit')                          AS n_first_visit
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT
  COUNT(*)                                                         AS users,
  COUNTIF(n_source_combos = 1)                                     AS one_source,
  COUNTIF(n_source_combos > 1)                                     AS multiple_sources,
  COUNTIF(n_devices > 1)                                           AS multiple_devices,
  COUNTIF(first_touch_ts IS NULL)                                  AS null_first_touch,
  COUNTIF(DATE(TIMESTAMP_MICROS(first_touch_ts)) <  '2020-11-01')  AS first_touch_before_window,
  COUNTIF(DATE(TIMESTAMP_MICROS(first_touch_ts))
          BETWEEN '2020-11-01' AND '2021-01-31')                   AS first_touch_in_window,
  COUNTIF(n_first_visit = 1)                                       AS first_visit_once,
  COUNTIF(n_first_visit > 1)                                       AS first_visit_multiple,
  COUNTIF(n_first_visit = 0)                                       AS first_visit_none
FROM u;
-- RESULT: users 270,154 | one source 227,891 | MULTIPLE sources 42,263 (15.6%)
--   multiple devices 4,182 | first touch: null 4,433, before window 8,417,
--   in window 257,304 | first_visit: once 257,167, >1 147, none 12,840
-- TAKEAWAY: (1) traffic_source is NOT constant for 15.6% of users, so it does
--   not behave like a clean first-touch field in this obfuscated export (Q7b).
--   (2) 257,304 users first touched inside the window → cohort population.
--   (3) 8,417 users were acquired before Nov 1 → excluded from cohorts.


-- -----------------------------------------------------------------------------
-- Q7b. How does traffic_source vary?
-- WHY: If it only changed across days, it might be re-attribution. If it
--   changes within a single day, it is not a stable user attribute at all.
-- -----------------------------------------------------------------------------
WITH user_day AS (
  SELECT
    user_pseudo_id,
    event_date,
    COUNT(DISTINCT CONCAT(IFNULL(traffic_source.source, 'N'), '|',
                          IFNULL(traffic_source.medium, 'N'), '|',
                          IFNULL(traffic_source.name,   'N'))) AS n_combos_in_day
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY 1, 2
)
SELECT
  COUNT(DISTINCT IF(n_combos_in_day > 1, user_pseudo_id, NULL)) AS users_varying_within_a_day
FROM user_day;
-- RESULT: 25,974 users have more than one source combination within a single day.
--   Most common medium mixes: organic+referral, (none)+organic, (none)+referral,
--   and obfuscated values mixed with real ones.
-- DECISION: first-touch channel = traffic_source on the user's EARLIEST event
--   (deterministic rule, documented as a limitation).


-- -----------------------------------------------------------------------------
-- Q8 + Q12. First-observed channel, device and country (user level)
-- WHY: Apply the Q7b decision and check how usable each segment field is.
-- SQL: ARRAY_AGG(... ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] picks the
--   values from each user's earliest event in one pass (an alternative to
--   ROW_NUMBER() = 1).
-- -----------------------------------------------------------------------------
WITH first_event AS (
  SELECT
    user_pseudo_id,
    ARRAY_AGG(STRUCT(traffic_source.medium AS medium,
                     traffic_source.source AS source,
                     device.category       AS device,
                     geo.country           AS country)
              ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS f
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY user_pseudo_id
)
SELECT 'medium' AS dimension, f.medium AS value, COUNT(*) AS users
FROM first_event GROUP BY 2
UNION ALL
SELECT 'device', f.device, COUNT(*) FROM first_event GROUP BY 2
UNION ALL
SELECT 'country', f.country, COUNT(*) FROM first_event GROUP BY 2 HAVING COUNT(*) >= 3000
ORDER BY dimension, users DESC;
-- RESULT (users):
--   medium : organic 101,742 | (none)=direct 64,109 | <Other> 47,101 |
--            referral 40,020 | cpc 14,282 | (data deleted) 2,900
--   device : desktop 156,905 | mobile 107,175 | tablet 6,074
--   country: United States 118,493 | India 25,367 | Canada 20,268 | UK 8,527 | ...
-- TAKEAWAY: 18.5% of users (<Other> + data deleted) have no usable channel;
--   they stay as their own "Unknown" group instead of being dropped.


-- -----------------------------------------------------------------------------
-- Q9. Session integrity and session-level source/medium
-- WHY: Decision rule from the plan: use session-level channel ONLY if reliable.
--   Also checks that each session has exactly one session_start.
-- -----------------------------------------------------------------------------
WITH e AS (
  SELECT
    user_pseudo_id,
    event_name,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'medium')        AS sess_medium
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
s AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    COUNTIF(event_name = 'session_start')                     AS n_session_start,
    COUNT(DISTINCT sess_medium)                               AS n_mediums,
    LOGICAL_OR(sess_medium IS NOT NULL)                       AS has_medium,
    LOGICAL_OR(sess_medium IS NOT NULL
               AND sess_medium NOT IN ('(data deleted)', '<Other>', '(not set)')) AS has_usable_medium
  FROM e
  GROUP BY 1, 2
)
SELECT
  COUNT(*)                     AS sessions,
  COUNTIF(n_session_start = 1) AS one_session_start,
  COUNTIF(n_session_start = 0) AS no_session_start,
  COUNTIF(n_session_start > 1) AS multiple_session_start,
  COUNTIF(has_medium)          AS sessions_with_medium,
  COUNTIF(has_usable_medium)   AS sessions_with_usable_medium,
  COUNTIF(n_mediums > 1)       AS sessions_where_medium_varies
FROM s;
-- RESULT: sessions 360,129 | one session_start 354,752 | none 5,272 | >1 105
--   with medium 265,575 (73.7%) | usable 241,664 (67.1%) | medium varies
--   inside the same session 53,993 (15.0%)
-- DECISION: session-level channel is NOT reliable → excluded from the MVP.
--   Sessions are defined by the session key, not by session_start events,
--   so the 5,272 sessions without session_start are kept.


-- -----------------------------------------------------------------------------
-- Q10. Purchase / transaction QA + revenue reconciliation
-- WHY: Revenue and conversion depend on clean transactions. Revenue exists at
--   order level (ecommerce.purchase_revenue) and item level (items[]), so we
--   check that they agree and demonstrate the item-join double-counting trap.
-- -----------------------------------------------------------------------------
WITH p AS (
  SELECT
    ecommerce.transaction_id                                AS transaction_id,
    ecommerce.purchase_revenue                              AS order_revenue,
    (SELECT SUM(i.item_revenue)       FROM UNNEST(items) i) AS item_revenue_sum,
    (SELECT SUM(i.price * i.quantity) FROM UNNEST(items) i) AS price_x_qty_sum,
    ARRAY_LENGTH(items)                                     AS n_items
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
),
dupes AS (
  SELECT transaction_id, COUNT(*) AS n
  FROM p
  WHERE transaction_id IS NOT NULL AND transaction_id != '(not set)'
  GROUP BY transaction_id
  HAVING COUNT(*) > 1
)
SELECT
  COUNT(*)                                                    AS purchase_events,
  COUNTIF(transaction_id IS NULL)                             AS null_txn_id,
  COUNTIF(transaction_id = '(not set)')                       AS not_set_txn_id,
  COUNT(DISTINCT IF(transaction_id != '(not set)', transaction_id, NULL))
                                                              AS distinct_valid_txn_ids,
  (SELECT COUNT(*) FROM dupes)                                AS txn_ids_on_multiple_events,
  (SELECT IFNULL(SUM(n - 1), 0) FROM dupes)                   AS extra_purchase_events,
  COUNTIF(order_revenue IS NULL)                              AS null_revenue,
  ROUND(SUM(order_revenue), 2)                                AS sum_order_revenue,
  ROUND(SUM(item_revenue_sum), 2)                             AS sum_item_revenue,
  ROUND(SUM(price_x_qty_sum), 2)                              AS sum_price_x_qty,
  ROUND(AVG(n_items), 2)                                      AS avg_items_per_purchase,
  -- The double-counting trap, computed on purpose:
  ROUND(SUM(order_revenue * GREATEST(IFNULL(n_items, 0), 1)), 2) AS revenue_if_joined_to_items
FROM p;
-- RESULT: 5,692 purchase events | null txn id 23 | '(not set)' 883 |
--   distinct valid txn ids 4,451 | 326 txn ids on >1 event (335 extra events) |
--   null revenue 450 | order revenue 362,165 | item revenue 362,110 |
--   price×qty 362,403 | 2.81 items per purchase |
--   revenue if summed after joining items: 1,641,077 (4.5× inflated)
-- TAKEAWAY: order-level and item-level revenue agree within 0.02% in total,
--   so ecommerce.purchase_revenue is the revenue source of truth.
--   NEVER sum order revenue after UNNEST(items).


-- -----------------------------------------------------------------------------
-- Q10b. What are the duplicate transactions?
-- WHY: Decide the dedup rule. Same user + same revenue + short gap = the same
--   purchase recorded twice (e.g., confirmation page reload).
-- -----------------------------------------------------------------------------
WITH p AS (
  SELECT
    user_pseudo_id,
    event_timestamp,
    ecommerce.transaction_id   AS transaction_id,
    ecommerce.purchase_revenue AS order_revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
),
g AS (
  SELECT
    transaction_id,
    COUNT(DISTINCT user_pseudo_id)        AS n_users,
    COUNT(DISTINCT order_revenue)         AS n_revenues,
    MAX(event_timestamp) - MIN(event_timestamp) AS span_micros
  FROM p
  WHERE transaction_id IS NOT NULL AND transaction_id != '(not set)'
  GROUP BY transaction_id
  HAVING COUNT(*) > 1
)
SELECT
  COUNT(*)                                AS duplicate_groups,
  COUNTIF(n_users = 1)                    AS same_user,
  COUNTIF(n_users > 1)                    AS different_users,
  COUNTIF(n_revenues = 1)                 AS same_revenue,
  COUNTIF(span_micros <= 3600 * 1000000)  AS within_one_hour,
  (SELECT COUNT(*) FROM p
    WHERE transaction_id IS NULL OR transaction_id = '(not set)')            AS missing_id_events,
  (SELECT ROUND(SUM(order_revenue)) FROM p
    WHERE transaction_id IS NULL OR transaction_id = '(not set)')            AS missing_id_revenue
FROM g;
-- RESULT: 326 groups | same user 311 | different users 15 | same revenue 311 |
--   within 1 hour 311 | missing-id purchase events 906 (revenue 31,817;
--   all 450 null-revenue purchases are in this group)
-- DECISION (applied in 02_build_tables.sql):
--   - valid transaction_id → keep ONE row per id (earliest event)
--   - missing / '(not set)' id → keep each event, flag has_valid_txn_id = FALSE
--   - null revenue stays NULL (not 0) so AOV is not dragged down
