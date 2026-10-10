# Funnel Findings & Problem Prioritization

Source: `sql/03_funnel_analysis.sql` (queries A1–A8) · Clean tables from `sql/02_build_tables.sql`
All findings are **descriptive / correlational**. Nothing here proves causation; that is what the experiment in Phase 8 is for.

## 0. Before reading the funnel: tracking windows (Issue #16)

The weekly trend (A5) showed view → cart conversion of **0.02%** and **0%** in the first two weeks of November. Daily event counts explain why:

| Event / field | Problem | Reliable from |
|---|---|---|
| `add_to_cart` | ~0 events Nov 1–15, a short test Nov 16–20, 0 again Nov 21–24 | **2020-11-26** |
| `transaction_id` | missing on every purchase Nov 1–11 | 2020-11-12 |
| `purchase_revenue` + `transaction_id` | missing on most purchases Jan 26–31 | until 2021-01-25 |

**Decision:** every strict-funnel number below uses sessions from **2020-11-26 to 2021-01-31** (`dim_date.is_cart_tracked`). Read on all 92 days, the funnel would make it look as if users never add to cart in early November. That was a tracking gap, not user behaviour.

## 1. Overall funnel (clean window)

| Step | Sessions | Step rate | Sessions lost |
|---|---|---|---|
| Sessions | 271,105 | | |
| → product view | 55,498 | 20.47% of sessions | **215,607** |
| → add to cart | 14,559 | 26.23% of views | 40,939 |
| → begin checkout | 5,179 | 35.57% of carts | 9,380 |
| → purchase | 2,738 | 52.87% of checkouts | 2,441 |

- **Strict session conversion: 1.01%.** Broad check (any purchase in session): 1.34%. The strict funnel now captures 75.5% of purchase sessions (vs 58% when the untracked weeks were included). The remaining 887 purchase sessions have no ordered add_to_cart, so cart tracking is still not complete.
- No-cart sensitivity funnel (view → checkout → purchase): 1.29% conversion.
- **79.5% of sessions never open a product page.** That's the largest leak in absolute terms.

## 2. Who converts? Segment cuts (clean window)

| Segment | Sessions | View rate | View → cart | Cart → checkout | Checkout → purchase | Strict CVR | Rev / session |
|---|---|---|---|---|---|---|---|
| Desktop | 157,310 | 20.59% | 26.04% | 35.27% | 52.08% | 0.985% | $0.92 |
| Mobile | 107,746 | 20.31% | 26.58% | 36.00% | 53.87% | 1.047% | $0.91 |
| Organic Search | 101,775 | 20.09% | 25.22% | 35.58% | 52.51% | 0.946% | $0.86 |
| Direct | 64,697 | 20.60% | 27.09% | 35.17% | 52.05% | 1.022% | $0.91 |
| Referral | 40,168 | 21.25% | 26.86% | 35.51% | 54.67% | 1.108% | $0.94 |
| Paid Search | 14,275 | 19.36% | 24.97% | 35.36% | 55.33% | 0.946% | $0.93 |
| **New-user sessions** | **201,922** | 18.80% | 22.30% | 30.00% | **42.24%** | **0.531%** | **$0.40** |
| **Returning-user sessions** | **69,183** | 25.34% | 34.76% | 43.31% | **63.09%** | **2.407%** | **$2.40** |

What this says:
1. **Device and channel barely matter.** Strict CVR ranges only 0.95%–1.11% across devices and channels. Mobile is not the problem, which goes against a common assumption.
2. **New vs returning is the real split.** New-user sessions are 74.5% of traffic but convert **4.5× worse** (0.53% vs 2.41%) and are worth $0.40 vs $2.40 per session. They're worse at **every** step.
3. Part of that gap is self-selection: people who come back already intend to buy. So the returning-user rate is a ceiling for new users, not a target.

## 3. Trends (A5, all weeks)

- Broad conversion peaked in the week of Dec 6 (1.96%) and bottomed in the week of Jan 3 (0.56%), consistent with the holiday shipping cutoff. Product view rate also dropped from ~25% to ~15% in late December and early January.
- Implication: compare periods only like-for-like (holiday vs holiday). Any experiment should avoid the late-December window or run long enough to cover a full weekly cycle outside it.

## 4. Prioritization (A7 + A8)

Each leak is scored on **size**, **segment gap**, **measurement confidence** and **actionability**. Size is the number of extra purchases if new-user sessions matched the returning-user rate at that one step, holding the other steps at new-user rates. It's an upper bound in the clean window, not a forecast.

| Leak (new-user sessions) | New vs returning rate | Extra purchases (upper bound) | Measurement confidence | Actionability |
|---|---|---|---|---|
| Landing → product view | 18.8% vs 25.3% | ~373 | High | Low–medium: many visits have no shopping intent |
| Product view → add to cart | 22.3% vs 34.8% | ~600 | **Medium**: add_to_cart still incomplete (887 purchase sessions lack it) | Medium: product page content |
| Cart → begin checkout | 30.0% vs 43.3% | ~476 | Medium: depends on cart tracking | Medium |
| **Begin checkout → purchase** | **42.2% vs 63.1%** | **~530** | **High**: both events tracked all window | **High**: checkout flow is fully owned by product |

### Priority #1: new-user checkout completion

- **Evidence:** new-user sessions complete checkout 42.2% of the time vs 63.1% for returning sessions. That's 1,467 abandoned checkouts in 67 days.
- **Robust:** the gap holds under the no-cart definition (36.0% vs 62.0%) and on both devices (new desktop 41.0%, new mobile 44.1%; returning 62.8% / 63.2%).
- **Why it wins:** it's measured on the most reliable events, it sits closest to revenue, and the product team controls the checkout flow directly. "View → cart" has a slightly larger upper bound, but it rests on a partially tracked event.
- **What a Product Analyst would investigate next:**
  1. Drill into checkout sub-steps (`add_shipping_info`, `add_payment_info`) for new users to find *where* inside checkout they leave.
  2. Check whether drop-off concentrates in countries where shipping cost or delivery time is only revealed at checkout.
  3. Check whether checkout forces account creation, which is a known friction point for first-time buyers.
  4. Watch session recordings or run usability tests on the new-user checkout path.

This is the problem the A/B test in Phase 8 targets. It is still a **hypothesis**: the gap is correlational until tested.

### Priority #2: fix add_to_cart tracking, then re-check product page → cart

Before investing in product-page changes, make add_to_cart fire on every cart path, including any "buy now" flow. Until then, cart-based metrics carry a known undercount.

### Priority #3: landing → product view

This is the biggest absolute leak (215,607 sessions), but it also contains the most low-intent traffic. The next step is a landing-page analysis (which entry pages lead to product views) rather than an experiment.
