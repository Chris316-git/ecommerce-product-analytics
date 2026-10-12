# Cohort Retention Findings

Source: `sql/05_cohort_retention.sql` (C1–C4) · mart: `mart_cohort_retention`
All findings are descriptive. Differences between cohorts or segments are correlations, not causal effects.

## Definitions (and why they matter)

| Choice | Definition | Why |
|---|---|---|
| Cohort | Week (Sunday start) of the user's `first_visit`; new users only | Users first seen before Nov 1 are not new (Issue #6). The 1-day partial week of Jan 31 is dropped |
| Week N | Days 7N … 7N+6 after the user's **own** first visit | Calendar weeks would give a Tuesday visitor a shorter "week 0" than a Sunday visitor |
| Retained | ≥1 session in Week N | Activity retention. Purchase retention is too sparse (~1% of new users buy at all) |
| **Right censoring** | Week N is shown for a cohort only if `cohort_week + 6 + 7N + 6 ≤ 2021-01-31` | The data ends on Jan 31. A Jan 17 cohort can't be observed for a full Week 3, so that cell is **NULL**, not 0 |
| Segments | First-touch channel and first-touch device | Each user stays in one segment for every week |

Why censoring matters: showing unobservable cells as 0 would make the newest cohorts look as if they stop returning, and it would drag the average curve down. Each week of the average curve only uses cohorts that are fully observable at that week.

Sessions are tracked for the whole window, so retention is **not** affected by the cart and transaction tracking gaps (Issue #16).

## C2. Average retention curve (255,189 new users, 13 cohorts)

| Week N | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 |
|---|---|---|---|---|---|---|---|---|
| Retention | **2.14%** | 1.27% | 1.01% | 0.82% | 0.54% | 0.38% | 0.26% | 0.23% |
| Cohorts observable | 11 | 10 | 9 | 8 | 7 | 6 | 4 | 2 |

- **About 98% of new users never come back in the week after their first visit.** Only 2.1% return in Week 1, and by Week 4 fewer than 1 in 100 are still active.
- The curve flattens after Week 6 at ~0.25%: a small core of repeat visitors.
- Context: Phase 4 showed returning-user sessions convert 4.5× better ($2.40 vs $0.40 per session). The store's highest-value behaviour is also its rarest.

## C1. Cohort matrix (Week-N retention %)

| Cohort | Size | W1 | W2 | W3 | W4 | W6 | W8 |
|---|---|---|---|---|---|---|---|
| Nov 1 | 16,926 | 2.37 | 1.65 | 1.21 | 1.00 | 0.52 | 0.14 |
| Nov 8 | 14,544 | 3.53 | 1.99 | 1.77 | 1.40 | 0.32 | 0.28 |
| Nov 15 | 16,585 | 3.43 | 2.27 | 1.92 | 1.08 | 0.33 | 0.30 |
| Nov 22 | 18,301 | 2.82 | 1.75 | 1.08 | 0.52 | 0.39 | 0.32 |
| Nov 29 | 21,112 | 2.88 | 1.54 | 0.63 | 0.55 | 0.35 | — |
| Dec 6 | 27,094 | 1.68 | 0.70 | 0.60 | 0.92 | 0.37 | — |
| Dec 13 | 24,526 | 1.30 | 0.91 | 0.97 | 0.73 | — | — |
| Dec 20 | 17,397 | 1.37 | 1.00 | 0.79 | 0.49 | — | — |
| Dec 27 | 16,224 | 1.34 | 0.62 | 0.57 | — | — | — |
| Jan 3 | 22,320 | 1.68 | 0.91 | — | — | — | — |
| Jan 10 | 21,026 | 1.98 | — | — | — | — | — |
| Jan 17 | 20,319 | — | — | — | — | — | — |
| Jan 24 | 18,815 | — | — | — | — | — | — |

"—" = censored (not yet observable), not zero.

## C4. Seasonality: holiday shoppers are the least sticky

| Acquisition period | New users | W1 | W2 |
|---|---|---|---|
| Early Nov (Nov 1–21) | 48,055 | **3.09%** | 1.97% |
| Holiday peak (Nov 22 – Dec 19) | 91,033 | 2.09% | 1.16% |
| Christmas / New Year (Dec 20 – Jan 2) | 33,621 | **1.35%** | 0.81% |
| January (Jan 3+)* | 82,480 | 1.82% | 0.91% |

\*W1 for January uses the Jan 3 and Jan 10 cohorts only; later cohorts are censored.

- Users acquired over Christmas return **less than half as often** as early-November users (1.35% vs 3.09%). The largest acquisition wave (the holiday peak, 91k users) retains below average.
- Plausible reading: holiday traffic is gift buying with one-off intent, while early-November visitors are more often fans of the brand. This is a hypothesis; the data can't show intent.
- Implication: judge holiday acquisition campaigns on first-purchase value, not on expected repeat visits. And post-holiday re-engagement (e.g. January emails to December buyers) has the lowest natural baseline, so it's where an intervention has the most room to help.

## C3. Channel and device: no meaningful difference

| Segment | New users | W1 (95% CI) | W2 | W4 | W8 |
|---|---|---|---|---|---|
| Organic Search | 97,897 | 2.20% ± 0.10 | 1.27% | 0.83% | 0.28% |
| Direct | 60,850 | 2.10% ± 0.12 | 1.34% | 0.85% | 0.30% |
| Unknown | 46,116 | 2.12% ± 0.14 | 1.14% | 0.67% | 0.19% |
| Referral | 36,372 | 2.04% ± 0.16 | 1.32% | 0.89% | 0.23% |
| Paid Search | 13,954 | 2.27% ± 0.27 | 1.27% | 0.88% | 0.22% |
| Desktop | 148,252 | 2.10% ± 0.08 | 1.28% | 0.81% | 0.28% |
| Mobile | 101,208 | 2.22% ± 0.10 | 1.28% | 0.82% | 0.24% |

- All W1 confidence intervals overlap. **When** users were acquired matters far more than **how**: there's a 1.7-point spread across acquisition periods vs a 0.2-point spread across channels. This is consistent with Phase 5.

## What a Product / Growth Analyst would recommend investigating

1. **Lifecycle re-engagement for first-time visitors and buyers**, especially holiday cohorts: a post-purchase email, a "back in stock" alert, or a wishlist reminder. Measure with a holdout group, not before/after.
2. **Link retention to first-session behaviour**: do users who view products, add to cart or buy in their first session return more? That's a stretch analysis. It would point to an "activation" event worth optimizing.
3. **Treat retention numbers as a lower bound**: identity is cookie-based, so a returning user on a new device or with cleared cookies counts as a new user.

## Limitations

- Only 13 weekly cohorts and at most 11 weeks of follow-up. Long-term retention (quarterly, yearly) can't be measured.
- Cookie-based identity understates true retention (Issue #13).
- Obfuscation in the public sample may blur segment differences.
