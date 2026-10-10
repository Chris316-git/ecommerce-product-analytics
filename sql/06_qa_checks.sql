/* =============================================================================
   06_qa_checks.sql
   Post-build QA — re-run after every change to 02_build_tables.sql

   WHY THIS FILE EXISTS
   Clean tables are only useful if they can be trusted. Each row below is one
   test with an expected value, the actual value, and PASS / FAIL. INFO rows
   are not pass/fail; they quantify known data behaviour we report on.

   Checks covered:
     row counts · null IDs · session uniqueness · transaction uniqueness ·
     revenue reconciliation · dedup reconciliation · orphan keys ·
     funnel monotonicity (overall + every segment) · ordered vs unordered gap ·
     item-level double counting · date dimension completeness
============================================================================= */

WITH
raw AS (
  SELECT COUNT(*) AS n
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
stg AS (
  SELECT
    COUNT(*)                                       AS n_rows,
    COUNTIF(session_key IS NULL)                   AS null_session_key,
    COUNTIF(user_pseudo_id IS NULL)                AS null_user,
    COUNT(DISTINCT session_key)                    AS n_sessions,
    COUNT(DISTINCT user_pseudo_id)                 AS n_users
  FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
),
stg_purchases AS (
  SELECT
    COUNT(DISTINCT IF(transaction_id IS NOT NULL AND transaction_id != '(not set)',
                      transaction_id, NULL))       AS n_valid_ids,
    COUNTIF(transaction_id IS NULL OR transaction_id = '(not set)') AS n_missing_id_events,
    SUM(purchase_revenue)                          AS raw_revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
  WHERE event_name = 'purchase'
),
-- Revenue of purchase events REMOVED by dedup (2nd+ event per transaction_id)
removed_dupes AS (
  SELECT IFNULL(SUM(purchase_revenue), 0) AS removed_revenue
  FROM (
    SELECT purchase_revenue
    FROM `ecom-product-analytics-511200.ecom_analytics.stg_events`
    WHERE event_name = 'purchase'
      AND transaction_id IS NOT NULL AND transaction_id != '(not set)'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY transaction_id
                               ORDER BY event_ts_micros, user_pseudo_id) > 1
  )
),
txn AS (
  SELECT
    COUNT(*)                                       AS n_rows,
    COUNT(DISTINCT transaction_key)                AS n_keys,
    COUNTIF(has_valid_txn_id)                      AS n_valid,
    COUNTIF(NOT has_valid_txn_id)                  AS n_missing,
    COUNTIF(revenue IS NULL)                       AS n_null_revenue,
    SUM(revenue)                                   AS revenue
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_transactions`
),
sess AS (
  SELECT
    COUNT(*)                                       AS n_rows,
    COUNT(DISTINCT session_key)                    AS n_keys,
    SUM(revenue)                                   AS revenue,
    COUNTIF(reached_view)                          AS s_view,
    COUNTIF(reached_cart)                          AS s_cart,
    COUNTIF(reached_checkout)                      AS s_checkout,
    COUNTIF(reached_purchase)                      AS s_purchase,
    COUNTIF(has_add_to_cart)                       AS u_cart,
    COUNTIF(has_begin_checkout)                    AS u_checkout,
    COUNTIF(has_purchase)                          AS u_purchase,
    -- a later step without the earlier step would break the funnel
    COUNTIF(reached_cart     AND NOT reached_view)
      + COUNTIF(reached_checkout AND NOT reached_cart)
      + COUNTIF(reached_purchase AND NOT reached_checkout) AS broken_order
  FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions`
),
-- Monotonicity inside every device × first-channel segment
seg AS (
  SELECT
    COUNTIF(s_cart > s_view OR s_checkout > s_cart OR s_purchase > s_checkout) AS bad_segments,
    COUNT(*) AS n_segments
  FROM (
    SELECT
      s.device_category, u.first_channel,
      COUNTIF(s.reached_view)     AS s_view,
      COUNTIF(s.reached_cart)     AS s_cart,
      COUNTIF(s.reached_checkout) AS s_checkout,
      COUNTIF(s.reached_purchase) AS s_purchase
    FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s
    JOIN `ecom-product-analytics-511200.ecom_analytics.dim_users` u USING (user_pseudo_id)
    GROUP BY 1, 2
  )
),
users AS (
  SELECT
    COUNT(*)                                       AS n_rows,
    COUNT(DISTINCT user_pseudo_id)                 AS n_keys,
    COUNTIF(is_new_in_window)                      AS n_new
  FROM `ecom-product-analytics-511200.ecom_analytics.dim_users`
),
orphans AS (
  SELECT
    (SELECT COUNT(*) FROM `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s
      LEFT JOIN `ecom-product-analytics-511200.ecom_analytics.dim_users` u USING (user_pseudo_id)
      WHERE u.user_pseudo_id IS NULL)              AS sessions_without_user,
    (SELECT COUNT(*) FROM `ecom-product-analytics-511200.ecom_analytics.fct_transactions` t
      LEFT JOIN `ecom-product-analytics-511200.ecom_analytics.fct_sessions` s USING (session_key)
      WHERE s.session_key IS NULL)                 AS transactions_without_session
),
-- The trap: summing ORDER revenue after joining to ITEMS
item_trap AS (
  SELECT SUM(e.ecommerce.purchase_revenue) AS inflated_revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` e,
       UNNEST(e.items) AS i
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND e.event_name = 'purchase'
),
dates AS (
  SELECT COUNT(*) AS n_rows, COUNT(DISTINCT date) AS n_dates,
         DATE_DIFF(MAX(date), MIN(date), DAY) + 1 AS span_days
  FROM `ecom-product-analytics-511200.ecom_analytics.dim_date`
),
checks AS (
  SELECT 'stg_events row count = raw'                AS check_name, raw.n AS expected, stg.n_rows AS actual, 'TEST' AS kind FROM raw, stg
  UNION ALL SELECT 'stg_events null session_key',     0, stg.null_session_key, 'TEST' FROM stg
  UNION ALL SELECT 'stg_events null user_pseudo_id',  0, stg.null_user,        'TEST' FROM stg
  UNION ALL SELECT 'fct_sessions unique session_key', sess.n_rows, sess.n_keys, 'TEST' FROM sess
  UNION ALL SELECT 'fct_sessions rows = distinct stg sessions', stg.n_sessions, sess.n_rows, 'TEST' FROM stg, sess
  UNION ALL SELECT 'dim_users unique user',           users.n_rows, users.n_keys, 'TEST' FROM users
  UNION ALL SELECT 'dim_users rows = distinct stg users', stg.n_users, users.n_rows, 'TEST' FROM stg, users
  UNION ALL SELECT 'fct_transactions unique transaction_key', txn.n_rows, txn.n_keys, 'TEST' FROM txn
  UNION ALL SELECT 'fct_transactions valid ids = distinct raw valid ids', p.n_valid_ids, txn.n_valid, 'TEST' FROM stg_purchases p, txn
  UNION ALL SELECT 'fct_transactions missing-id rows = raw missing-id events', p.n_missing_id_events, txn.n_missing, 'TEST' FROM stg_purchases p, txn
  UNION ALL SELECT 'revenue: sessions = transactions', ROUND(txn.revenue, 2), ROUND(sess.revenue, 2), 'TEST' FROM txn, sess
  UNION ALL SELECT 'revenue: raw = kept + removed duplicates', ROUND(p.raw_revenue, 2),
                   ROUND(txn.revenue + (SELECT removed_revenue FROM removed_dupes), 2), 'TEST' FROM stg_purchases p, txn
  UNION ALL SELECT 'orphans: sessions without user',  0, o.sessions_without_user, 'TEST' FROM orphans o
  UNION ALL SELECT 'orphans: transactions without session', 0, o.transactions_without_session, 'TEST' FROM orphans o
  UNION ALL SELECT 'funnel monotonic: sessions skipping a step', 0, sess.broken_order, 'TEST' FROM sess
  UNION ALL SELECT 'funnel monotonic: bad device x channel segments', 0, seg.bad_segments, 'TEST' FROM seg
  UNION ALL SELECT 'dim_date: 92 consecutive days', 92, dates.n_dates, 'TEST' FROM dates
  UNION ALL SELECT 'dim_date: no gaps (span = rows)', dates.span_days, dates.n_rows, 'TEST' FROM dates
  -- INFO rows: expected = unordered / correct value, actual = ordered / wrong value
  UNION ALL SELECT 'INFO cart sessions: unordered vs ordered',     sess.u_cart,     sess.s_cart,     'INFO' FROM sess
  UNION ALL SELECT 'INFO checkout sessions: unordered vs ordered', sess.u_checkout, sess.s_checkout, 'INFO' FROM sess
  UNION ALL SELECT 'INFO purchase sessions: unordered vs ordered', sess.u_purchase, sess.s_purchase, 'INFO' FROM sess
  UNION ALL SELECT 'INFO revenue: correct vs summed after item join', ROUND(txn.revenue, 2), ROUND(it.inflated_revenue, 2), 'INFO' FROM txn, item_trap it
  UNION ALL SELECT 'INFO transactions with NULL revenue',          0, txn.n_null_revenue, 'INFO' FROM txn
  UNION ALL SELECT 'INFO users new in window (cohort population)', users.n_rows, users.n_new, 'INFO' FROM users
)
SELECT
  check_name,
  expected,
  actual,
  CASE WHEN kind = 'INFO' THEN 'INFO'
       WHEN expected = actual THEN 'PASS'
       ELSE 'FAIL' END AS status
FROM checks;

/* -----------------------------------------------------------------------------
   RESULT of the run on 2026-10-09 — 18 / 18 TEST rows PASS

   TEST                                                expected     actual
   stg_events row count = raw                         4,295,584  4,295,584
   stg_events null session_key / null user                    0          0
   fct_sessions unique session_key                      360,129    360,129
   dim_users unique user / rows = stg users             270,154    270,154
   fct_transactions unique transaction_key                5,357      5,357
   fct_transactions valid ids                             4,451      4,451
   fct_transactions missing-id rows                         906        906
   revenue: sessions = transactions                     339,457    339,457
   revenue: raw = kept + removed duplicates             362,165    362,165
   orphans (sessions w/o user, txns w/o session)              0          0
   funnel: sessions skipping a step                           0          0
   funnel: bad device x channel segments                      0          0
   dim_date: 92 consecutive days, no gaps                    92         92

   INFO                                              unordered    ordered
   sessions with add_to_cart                             15,188     15,167
   sessions with begin_checkout                          11,106      5,416
   sessions with purchase                                 4,848      2,834
   revenue: correct vs summed after item join           339,457  1,641,077
   transactions with NULL revenue                                     450
   users new in window (cohort population)                        257,314

   KEY FINDING (follow-up diagnostic, see docs/data_model.md Issue #15):
   Of the 2,014 purchase sessions that fail the ordered funnel, 2,000 contain
   NO add_to_cart event at all, and only 257 had add_to_cart in an earlier
   session. Of the 5,690 checkout sessions that fail, 5,145 contain no
   add_to_cart. → add_to_cart tracking is incomplete; it is not mainly
   cross-session journeys. The strict funnel under-counts purchase sessions
   by ~42% (2,834 vs 4,848). Phase 4 reports a sensitivity funnel that
   skips the cart step.
----------------------------------------------------------------------------- */
