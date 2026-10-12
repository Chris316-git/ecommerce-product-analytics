# Business Recommendations

Five recommendations, in priority order (impact × confidence × effort).
Each one is labelled by evidence type:

- **Descriptive**: what happened in the data
- **Correlational**: two things move together; the cause is not established
- **Causal**: requires a randomized experiment. **No causal claim is made from this observational data**; the experiment in `experiment/ab_test_design.md` is how one would be earned.

---

## 1. Fix event tracking before trusting funnel metrics
*Evidence type: descriptive · Effort: low · Unblocks everything below*

- **Finding:** Key ecommerce events were missing for parts of the window.
- **Evidence:** add_to_cart had ~0 events before 2020-11-26. transaction_id was missing on every purchase Nov 1–11, and revenue plus ID were missing on most purchases Jan 26–31 (Issue #16). Even after Nov 26, 887 of 3,625 purchase sessions (24%) have no ordered add_to_cart.
- **Business implication:** Read naively, the funnel would show "users don't add to cart" in early November, and revenue would be overstated by $22,708 (duplicate purchases) or understated (missing revenue). Decisions made on those numbers would be wrong.
- **Recommended action:** Fire add_to_cart on every cart path (including any "buy now" flow), enforce a non-null transaction_id on purchase, and add a daily data-quality alert on event volumes (the checks in `sql/06_qa_checks.sql` are a starting point).
- **Metric to monitor:** Daily add_to_cart / view_item ratio; share of purchases with a valid transaction_id and revenue (target: 100%).

## 2. Test a simplified checkout for first-time visitors
*Evidence type: correlational → to be tested causally · Effort: medium*

- **Finding:** First-time visitors abandon checkout far more often than returning visitors.
- **Evidence:** In the cart-tracked window, new-user sessions complete checkout 42.2% vs 63.1% for returning sessions. The gap holds under the no-cart funnel definition (36.0% vs 62.0%) and on desktop and mobile. At user level, 47.3% of new users who reach checkout complete a purchase.
- **Business implication:** Checkout is the last step before revenue and is fully controlled by the product team. Closing even a quarter of the gap is material.
- **Recommended action:** Run the A/B test in `experiment/ab_test_design.md`: guest checkout by default, shipping cost and delivery date shown upfront, fewer fields. Sticky user-level randomization, 10% relative MDE, ~1,750 triggered users per arm, ~6–7 weeks outside the holiday window.
- **Metric to monitor:** Checkout completion rate (primary). AOV, payment errors and SRM as guardrails.

## 3. Build a re-engagement program for new users, starting with holiday cohorts
*Evidence type: descriptive + correlational · Effort: medium*

- **Finding:** Almost no new users come back, and holiday-acquired users come back least.
- **Evidence:** Week-1 retention is 2.14% and Week-4 retention is 0.82% (censoring-aware cohort analysis, 255k new users). Christmas/New Year cohorts retain at 1.35% vs 3.09% for early-November cohorts. Returning-user sessions are worth $2.40 vs $0.40 for new-user sessions.
- **Business implication:** The store's most valuable behaviour (coming back) is its rarest. The biggest holiday acquisition wave contributes little repeat traffic.
- **Recommended action:** Test lifecycle touchpoints (post-purchase email, wishlist / back-in-stock reminders, a January re-engagement offer to December visitors) **against a randomized holdout group**. Don't use before/after comparisons, because seasonality would confound them.
- **Metric to monitor:** Week-1 and Week-4 retention of treated vs holdout users; repeat purchase rate.

## 4. Don't reallocate acquisition budget on attributed channel performance; test incrementality instead
*Evidence type: correlational · Effort: low to medium*

- **Finding:** Acquisition channel barely predicts user quality.
- **Evidence:** Using a fair, fixed 14-day window per new user, purchase rates range only 1.20%–1.34% across channels, with overlapping 95% CIs. Week-1 retention ranges 2.04%–2.27%, also overlapping. The one signal is Paid Search's higher AOV ($83 vs ~$65), which comes entirely from desktop and rests on just 70 buyers.
- **Business implication:** Shifting budget between channels based on this data would mostly move noise. When a user was acquired matters more than how (a 1.7-point retention spread by period vs 0.2 points by channel).
- **Recommended action:** Keep the current mix. Validate the Paid Search desktop signal with a geo or budget-split test that measures **incremental** revenue, not attributed revenue.
- **Metric to monitor:** Incremental revenue per new user and per ad dollar in the test vs control regions.

## 5. Investigate why 79.5% of sessions never reach a product page
*Evidence type: descriptive · Effort: low (analysis first)*

- **Finding:** The largest absolute leak is at the top of the funnel.
- **Evidence:** 215,607 of 271,105 sessions (79.5%) in the clean window never view a product. New-user sessions reach a product page 18.8% of the time vs 25.3% for returning sessions.
- **Business implication:** Even a small improvement in product discovery affects the most users. But much of this traffic may be low-intent browsing, so the upside is uncertain.
- **Recommended action:** Run a landing-page analysis (entry page → product view rate) to find the pages that lose the most visitors, then design a targeted test. Don't launch a site-wide redesign without one.
- **Metric to monitor:** Product view rate by landing page; strict session conversion rate.

---

### Why this order
1 is cheap and makes every other metric trustworthy. 2 has the strongest evidence and the clearest owner. 3 addresses the biggest value gap but needs lifecycle tooling. 4 is mostly a "don't do" that prevents wasted spend. 5 needs more analysis before any action.
