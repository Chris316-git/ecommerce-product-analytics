# A/B Test Design: Simplified Checkout for First-Time Visitors

**Status: design only.** No experiment was run, and no results are claimed. Every input below is either measured from the data (`sql/07_experiment_baseline.sql`) or an explicit, justified assumption.

## 1. Why this test (from the analysis)

| Evidence | Source |
|---|---|
| New-user sessions complete checkout 42.2% of the time vs 63.1% for returning sessions | Phase 4, A7/A8 |
| The gap holds under both funnel definitions and on desktop and mobile | Phase 4, A8 |
| begin_checkout and purchase are tracked for the whole window, so this is the most reliably measured step | Issue #16 |
| Long-tail international users convert lowest; shipping cost may only be revealed at checkout | Phase 5 |
| Channel and device don't explain the gap, so the lever is the on-site experience | Phases 5–6 |

The new vs returning gap is **correlational** (returning users already intend to buy). Only a randomized test can show whether changing checkout *causes* more first-time visitors to finish.

## 2. Hypothesis

> If first-time visitors see a simplified checkout (guest checkout as the default, shipping cost and delivery date shown before payment, fewer form fields), then more of them will complete their purchase, because less friction and fewer late surprises cut abandonment.

- **H0:** checkout completion is the same in control and treatment (p_T = p_C).
- **H1:** checkout completion differs between the two (p_T ≠ p_C). The test is two-sided, so a harmful change is detected too.

## 3. Design

| Element | Choice | Why |
|---|---|---|
| **Control** | Current checkout | Baseline |
| **Treatment** | Guest checkout by default + shipping cost and delivery estimate shown on the first checkout step + reduced form | Targets the friction points a first-time buyer hits |
| **Randomization unit** | **User** (`user_pseudo_id`), with **sticky assignment**: a returning user stays in the same variant on every session | Users can start checkout in one session and finish in another. Session-level randomization would let one person see both versions and contaminate the comparison |
| **Eligible population** | New users (first visit during the test) | The finding is about first-time visitors; returning users already complete 63% |
| **Trigger / analysis population** | Eligible users who **reach begin_checkout**, logged identically in both arms | Only users who see checkout can be affected. Including everyone else adds noise and dilutes the effect |
| **Split** | 50 / 50 | Maximizes power for a fixed sample |
| **Analysis unit** | User (matches the randomization unit) | Avoids the false precision of treating correlated sessions as independent |

## 4. Metrics

**Primary metric (matches the treatment scope):**
**Checkout completion rate** = triggered users who complete a purchase after begin_checkout ÷ triggered users.
The treatment only changes the checkout pages, so the primary metric starts at checkout. Overall site conversion would dilute the effect with 79% of sessions that never reach a product page.

**Secondary metrics:**
- Revenue per triggered user
- Shipping-info and payment-info step completion (shows *where* inside checkout the change works)
- Time from begin_checkout to purchase

**Guardrail metrics (must not get worse):**
- AOV: a simpler flow shouldn't shrink baskets (e.g. if upsells are removed)
- Payment error / failure rate and checkout page load time
- Sample ratio mismatch (SRM): the actual split must be close to 50/50 (chi-square check). A mismatch means a bug in assignment or logging, and the results are not trustworthy

## 5. Baseline and sample size

Baseline (new users, 2020-11-26 → 2021-01-31, user level, from `07_experiment_baseline.sql`):

| Input | Value |
|---|---|
| New users reaching checkout | 5,214 in 67 days → **~545 per week** |
| Baseline checkout completion | 2,467 / 5,214 = **47.3%** |
| Revenue per checkout user | $33.03 (SD $74.09) |

User-level completion (47.3%) is higher than the session-level rate (36.0%) because some users finish in a later session. That's one more reason to randomize and measure per user.

Design parameters: α = 0.05 (two-sided), power = 80%, 50/50 split. Calculated with `experiment/sample_size.py` (two-proportion z-test):

| Relative MDE | Absolute MDE | Target rate | Users per arm | Total | Weeks at ~545/week |
|---|---|---|---|---|---|
| 5% | 2.4 pp | 49.7% | 7,005 | 14,010 | 25.7 |
| 8% | 3.8 pp | 51.1% | 2,738 | 5,476 | 10.1 |
| **10%** | **4.7 pp** | **52.1%** | **1,752** | **3,504** | **6.4** |
| 15% | 7.1 pp | 54.4% | 778 | 1,556 | 2.9 |

**Recommendation: MDE = 10% relative (47.3% → 52.1%), ~1,750 triggered users per arm, about 6–7 weeks.**
- Smaller lifts (5%) need half a year of traffic, which is impractical for this store's volume.
- A 4.7-point lift recovers less than a quarter of the 21-point new vs returning gap, so it's a realistic target for a checkout redesign.
- If the business only cares about large wins, a 15% MDE runs in ~3 weeks. The cost is that real but smaller improvements would be missed (higher Type II risk).

Revenue per user can't be the primary metric: at 1,752 users per arm the smallest detectable difference is about $7 (21% of the mean), because revenue is highly skewed (SD > 2× the mean).

## 6. Duration and timing

- Run in **whole weeks** (at least 2), so weekday/weekend patterns are balanced.
- **Avoid Dec 20 – Jan 3.** Traffic and intent shift sharply around the holidays (Phase 4 trend, Phase 6 retention), and a result from that window may not generalize.
- Fix the sample size and end date **in advance**. Don't stop early because the p-value dips below 0.05 ("peeking" inflates false positives). If early stopping is needed, use a sequential testing method planned up front.

## 7. Analysis plan

1. Check SRM first. If it fails, stop and debug; don't read the results.
2. Primary: two-proportion z-test on checkout completion; report the difference with a 95% confidence interval.
3. Secondary and guardrail metrics with their own CIs. Treat them as supporting evidence; they don't decide the test.
4. Pre-planned segment reads (desktop vs mobile, US vs international) are hypothesis-generating only, because multiple comparisons raise the false-positive risk.

## 8. How to interpret the outcomes

| Result | Decision |
|---|---|
| Completion up, CI excludes 0, guardrails OK | Ship to all new users; then test whether returning users also benefit |
| Completion up, but AOV or payment errors worse | Don't ship as is; find which component caused the guardrail hit |
| No significant difference (CI includes 0) | Not "no effect". The effect is smaller than ~4.7 pp or absent. Use the shipping/payment sub-step metrics to decide whether to iterate |
| Completion down | Roll back. Two-sided testing exists to catch exactly this |
| SRM detected | Results invalid; fix assignment/logging and rerun |

## 9. Key statistics concepts (interview-ready)

- **p-value:** if H0 were true (no real difference), the probability of seeing a difference at least this large by chance. It is *not* the probability that H0 is true.
- **Confidence interval (95%):** a range of plausible values for the true difference. If we repeated the experiment many times, 95% of such intervals would contain the true effect. If it excludes 0, the result is significant at α = 0.05.
- **Type I error (α = 5%):** declaring a winner when there is no real effect (false positive). Peeking makes it larger.
- **Type II error (β = 20%):** missing a real effect (false negative).
- **Power (1 − β = 80%):** the probability of detecting the effect *if it is at least the MDE*.
- **MDE (minimum detectable effect):** the smallest true effect the test is designed to detect reliably. A smaller MDE needs a quadratically larger sample (halving the MDE ≈ 4× the users).
- **Sample size:** set by baseline rate, MDE, α and power. Here, 1,752 users per arm to detect 47.3% → 52.1%.
