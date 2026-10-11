# Acquisition & Segment Quality

Source: `sql/04_acquisition_segments.sql` (B1–B3) · mart: `mart_acquisition_14d`
All findings are **correlations** between how a user arrived and what they did next. They are not causal effects of the channel.

## Design: a fair comparison

Comparing channels on "all-time" conversion is biased: a user acquired on Dec 1 has two months to buy, while one acquired on Jan 20 has ten days. So every new user gets the **same 14-day outcome window**.

| Choice | Value | Why |
|---|---|---|
| Population | 142,183 new users with first visit between **2020-11-26 and 2021-01-11** | Cart tracking is live from Nov 26; day 0 + 13 ends by Jan 24, before revenue tracking breaks (Jan 26) |
| Outcomes | purchase, orders, revenue, return visit on a later day, all within days 0–13 | Same observation time for everyone |
| Segment | first-touch channel, first device, first country (`dim_users`) | Each user counts in exactly one segment |
| Uncertainty | 95% CI = p ± 1.96·√(p(1−p)/n) | Separates real differences from noise |

## B1. Channels: volume differs, quality barely does

| First-touch channel | New users | Share of users | Share of 14-day revenue | 14-day purchase rate (95% CI) | Revenue / new user | AOV | 14-day return rate |
|---|---|---|---|---|---|---|---|
| Organic Search | 54,625 | 38.4% | 39.1% | 1.28% ± 0.09 | $0.95 | $65.63 | 7.80% |
| Direct | 33,822 | 23.8% | 23.0% | 1.26% ± 0.12 | $0.90 | $65.30 | 7.85% |
| Unknown (obfuscated) | 25,731 | 18.1% | 17.2% | 1.24% ± 0.14 | $0.88 | $63.62 | 7.71% |
| Referral | 20,212 | 14.2% | 13.7% | 1.20% ± 0.15 | $0.89 | $69.48 | 7.55% |
| Paid Search | 7,793 | 5.5% | 7.0% | 1.34% ± 0.26 | **$1.20** | **$83.14** | 7.88% |

- **All confidence intervals overlap.** No channel's purchase rate is distinguishable from the others with this data. Each channel's share of revenue roughly equals its share of users.
- **Paid Search is the only outlier, and the signal is AOV, not conversion.** It delivers 5.5% of new users but 7.0% of revenue because its buyers spend $83 vs ~$65 elsewhere.
- Return rates are flat (7.6%–7.9%). The channel doesn't predict whether a new user comes back within two weeks.

## B2. Device and country

| Segment | New users | 14-day purchase rate (95% CI) | Revenue / new user |
|---|---|---|---|
| Desktop | 82,652 | 1.26% ± 0.08 | $0.96 |
| Mobile | 56,320 | 1.27% ± 0.09 | $0.90 |
| United States | 62,434 | 1.31% ± 0.09 | $0.98 |
| India | 13,256 | 1.32% ± 0.19 | $0.96 |
| Canada | 10,749 | 1.22% ± 0.21 | $1.03 |
| United Kingdom | 4,476 | 1.52% ± 0.36 | $1.12 |
| Other (outside top 10) | 36,345 | 1.16% ± 0.11 | $0.82 |

- Device: no difference at user level either, which confirms the Phase 4 session-level result.
- Country: the long tail outside the top 10 converts lowest (1.16% vs 1.31% for the US, intervals barely overlap) and is worth $0.82 vs $0.98 per new user. It's plausible that international shipping costs revealed at checkout play a role, which links back to the Phase 4 priority. This is a hypothesis to check in the checkout drill-down, not a conclusion.

## B3. Simpson's-paradox check: channel × device

| Channel | Desktop: purchase rate / rev per user (buyers) | Mobile: purchase rate / rev per user (buyers) |
|---|---|---|
| Organic Search | 1.28% / $0.94 (405) | 1.30% / $0.99 (282) |
| Direct | 1.18% / $0.92 (232) | 1.39% / $0.91 (187) |
| Referral | 1.30% / $1.06 (155) | 1.08% / $0.69 (85) |
| **Paid Search** | **1.54% / $1.54 (70)** | 1.01% / $0.69 (31) |

- Paid Search's advantage comes **entirely from desktop** (AOV $90). On mobile it's the weakest channel.
- But it rests on 70 desktop buyers (95% CI for the rate: 1.18%–1.90%). Treat it as a **lead to test**, not a reason to move budget.

## What this means for the business

1. **Acquisition source is not the main lever.** Users from every channel and device convert and return at about the same rate. The 4.5× gap found in Phase 4 is between **new and returning** users, so the leverage is in what happens *after* arrival: checkout completion for first-time buyers, and bringing new users back.
2. **Don't reallocate budget on this data alone.** The one promising signal (Paid Search on desktop: higher AOV) should be validated with a geo or budget-split test that measures incremental revenue, not just attributed revenue.
3. **Watch the long-tail international segment.** Its lower conversion and value fit the shipping-cost hypothesis behind Priority #1.

## Limitations

- Google obfuscated this public sample, and 18% of users have an "Unknown" channel. Obfuscation may blur real segment differences, so "no difference" here means "no difference detectable in this data".
- First-touch channel uses the user's earliest event (Issue #3) and ignores later touches. That suits acquisition questions but not multi-touch attribution.
- Small segments (Paid Search mobile, single countries) have wide intervals. Rates based on fewer than ~100 buyers are flagged as noisy.
