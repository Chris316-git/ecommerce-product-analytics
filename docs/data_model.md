# Data Model & Data Quality

Source: `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` (GA4 export of the Google Merchandise Store, obfuscated by Google)
Window: 2020-11-01 to 2021-01-31 (92 daily shards) · All numbers below come from `sql/01_data_quality.sql`.

## 1. Raw data in one sentence

**One row = one event** (a page view, an add-to-cart, a purchase …). There are no separate user, session or order tables. Each of those has to be *derived* from events.

| Scale | Value |
|---|---|
| Events | 4,295,584 |
| Users (`user_pseudo_id`) | 270,154 |
| Sessions (`user_pseudo_id` + `ga_session_id`) | 360,129 |
| Purchase events | 5,692 |
| Distinct valid transaction IDs | 4,451 |

## 2. Entities, grain and keys

| Entity | Grain | Key | Where it comes from |
|---|---|---|---|
| Event | 1 tracked interaction | none (no event ID); unique by user + timestamp + name + params | each row |
| User | 1 browser/device cookie | `user_pseudo_id` | column |
| Session | 1 visit | `user_pseudo_id` + `ga_session_id` | `ga_session_id` is inside `event_params` (int_value) |
| Transaction | 1 order | `ecommerce.transaction_id` (when valid) | `purchase` events |
| Item line | 1 product inside an event | event + `items[]` position | `items` (REPEATED) |

Why the session key is composite: `ga_session_id` is the session start time in seconds, so different users collide. Using it alone gives 349,545 sessions instead of 360,129 (10,584 sessions wrongly merged).

## 3. Entity-relationship / data-flow diagram

```
                         events_YYYYMMDD   (grain: 1 event)
                                 │
       ┌─────────────────────────┼──────────────────────────┐
       │                         │                          │
 user_pseudo_id        event_params[] (REPEATED)       ecommerce / items[] (REPEATED)
       │               ga_session_id, page_location,   transaction_id, purchase_revenue,
       │               source/medium (partial)         item_id, item_name, price, quantity
       ▼                         ▼                          ▼
 ┌────────────┐  1 ─── N  ┌──────────────┐  1 ─── 0..N ┌────────────────┐  1 ─── N  ┌──────────┐
 │   USER     │──────────▶│   SESSION    │────────────▶│  TRANSACTION   │──────────▶│ ITEM LINE│
 │ user_      │           │ user_pseudo_ │             │ transaction_id │           │ item_id  │
 │ pseudo_id  │           │ id + ga_     │             │ revenue        │           │ price×qty│
 │ first-touch│           │ session_id   │             └────────────────┘           └──────────┘
 │ channel,   │           │ device,      │
 │ device,    │           │ country,     │      Funnel events live at the SESSION level:
 │ country,   │           │ funnel step  │      view_item → add_to_cart → begin_checkout → purchase
 │ cohort wk  │           │ timestamps   │
 └────────────┘           └──────────────┘
```

Plain-English version: a **user** has one or more **sessions**; a session contains many **events**; some sessions contain a **purchase**, which is one **transaction** with one or more **item lines**.

## 4. Field map

| Purpose | Field | Notes |
|---|---|---|
| User ID | `user_pseudo_id` | 0 nulls. Cookie-based: same person on two devices = two users |
| Session ID | `event_params.ga_session_id` (int) | on 100% of events, 0 nulls |
| Event type | `event_name` | 17 types (see below) |
| Timestamp | `event_timestamp` (micros, UTC); `event_date` (STRING `YYYYMMDD`) | 0 nulls |
| First touch time | `user_first_touch_timestamp` | null for 4,433 users |
| Acquisition | `traffic_source.source / medium / name` | not constant per user (see issues) |
| Session source | `event_params.source / medium / campaign` | partial coverage (see issues) |
| Transaction | `ecommerce.transaction_id` | null or `(not set)` on 906 purchases |
| Revenue | `ecommerce.purchase_revenue` (= `_in_usd`) | source of truth for revenue |
| Products | `items[]`: `item_id, item_name, item_category, price, quantity, item_revenue` | 2.81 items per purchase |
| Device | `device.category` | desktop / mobile / tablet |
| Geography | `geo.country`, `geo.region`, `geo.city` | US is 44% of users |

Funnel events present: `view_item` (386,068), `add_to_cart` (58,543), `begin_checkout` (38,757), `purchase` (5,692). Checkout sub-steps `add_shipping_info` and `add_payment_info` also exist.

## 5. Known data issues and decisions

| # | Issue | Evidence | Decision |
|---|---|---|---|
| 1 | `ga_session_id` is not unique across users | 349,545 vs 360,129 | Session key = `user_pseudo_id` + `ga_session_id` |
| 2 | Some sessions have no `session_start` event | 5,272 of 360,129 (1.5%); 105 have >1 | Define sessions by the session key, not by `session_start` |
| 3 | `traffic_source` is not constant per user | 42,263 users (15.6%) have >1 value; 25,974 vary within a single day | First-touch channel = `traffic_source` on the user's **earliest event** |
| 4 | Obfuscated channel values | `<Other>` 47,101 + `(data deleted)` 2,900 users = 18.5% | Keep as an explicit "Unknown" group; never silently drop |
| 5 | Session-level source/medium unreliable | present in 73.7% of sessions, usable in 67.1%, **varies inside 15.0% of sessions** | Excluded from MVP; all channel analysis is first-touch |
| 6 | Users acquired before the window | 8,417 first touched before 2020-11-01; 4,433 have null first touch | Cohorts include only the 257,304 users first touched inside the window |
| 7 | Duplicate transactions | 326 transaction IDs on >1 purchase event; 311 are same user + same revenue within 1 hour | One row per valid `transaction_id` (earliest event) |
| 8 | Missing transaction IDs | 23 null + 883 `(not set)` = 906 purchase events | Keep each as its own purchase, flagged `has_valid_txn_id = FALSE` |
| 9 | Missing revenue | 450 purchases (all in issue 8) | Keep NULL, not 0, so AOV is not understated |
| 10 | Order vs item revenue | 362,165 vs 362,110 in total (0.02% gap) | Use `ecommerce.purchase_revenue` |
| 11 | Item-join double counting | summing order revenue after `UNNEST(items)` gives 1,641,077 (4.5×) | Order metrics at transaction grain; item metrics at item grain only |
| 12 | Exact duplicate events | 0 found | No event-level dedup needed |
| 13 | Cookie-based identity | 4,182 users show >1 device category | Accept; state as a limitation (no cross-device stitching) |
| 14 | Holiday season window | Nov–Jan only | Interpret trends as seasonal; weekly cohorts are the main retention view |

## 6. What Phase 2 builds from this

| Table | Grain | Built from |
|---|---|---|
| `stg_events` | 1 event | raw events + extracted `session_key`, `event_ts`, `transaction_id` |
| `dim_users` | 1 user | earliest-event channel/device/country, `first_touch_ts`, `is_new_in_window` |
| `fct_sessions` | 1 session | session key, device, country, ordered funnel step timestamps, purchase flag, revenue |
| `fct_transactions` | 1 transaction | dedup rules from issues 7–9 |
| `dim_date` | 1 calendar day | `GENERATE_DATE_ARRAY` over the window |
