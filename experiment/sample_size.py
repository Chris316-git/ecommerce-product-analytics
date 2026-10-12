"""
sample_size.py — Phase 8: sample size and duration for the checkout A/B test

Standard library only (statistics.NormalDist), so it runs anywhere:
    python experiment/sample_size.py

Inputs come from sql/07_experiment_baseline.sql (cart-tracked window,
2020-11-26 → 2021-01-31, new users who reached checkout):
    baseline completion rate  = 2,467 / 5,214 = 47.31 %
    eligible users            = 5,214 over 67 days  → ~545 per week
    revenue per checkout user = $33.03, SD $74.09
"""
from math import ceil, sqrt
from statistics import NormalDist

Z = NormalDist().inv_cdf

# ---- inputs from the data ---------------------------------------------------
P_BASELINE = 2467 / 5214            # primary metric: checkout completion (user level)
ELIGIBLE_PER_WEEK = 5214 / 67 * 7   # new users reaching checkout per week
REV_MEAN, REV_SD = 33.03, 74.09     # secondary metric: revenue per checkout user

# ---- design choices ---------------------------------------------------------
ALPHA = 0.05      # two-sided significance level (Type I error rate)
POWER = 0.80      # 1 - beta (beta = Type II error rate)
SPLIT = 0.5       # 50 / 50 control vs treatment


def n_per_arm_proportions(p1: float, rel_mde: float, alpha=ALPHA, power=POWER) -> int:
    """Users per arm to detect a relative lift `rel_mde` on a conversion rate p1
    (two-sided z-test for two proportions)."""
    p2 = p1 * (1 + rel_mde)
    p_bar = (p1 + p2) / 2
    z_a, z_b = Z(1 - alpha / 2), Z(power)
    num = (z_a * sqrt(2 * p_bar * (1 - p_bar)) + z_b * sqrt(p1 * (1 - p1) + p2 * (1 - p2))) ** 2
    return ceil(num / (p2 - p1) ** 2)


def mde_for_mean(sd: float, n_per_arm: int, alpha=ALPHA, power=POWER) -> float:
    """Smallest absolute difference in a mean detectable with n users per arm."""
    return (Z(1 - alpha / 2) + Z(power)) * sd * sqrt(2 / n_per_arm)


if __name__ == "__main__":
    print(f"Baseline completion rate : {P_BASELINE:.2%}")
    print(f"Eligible users per week  : {ELIGIBLE_PER_WEEK:,.0f}")
    print(f"alpha={ALPHA}, power={POWER}, split={SPLIT:.0%}/{1-SPLIT:.0%}\n")

    print(f"{'Relative MDE':>12} {'Abs. MDE':>9} {'Target rate':>11} {'Users/arm':>10} {'Total':>7} {'Weeks':>6}")
    for rel in (0.05, 0.08, 0.10, 0.15):
        n = n_per_arm_proportions(P_BASELINE, rel)
        total = 2 * n
        weeks = total / ELIGIBLE_PER_WEEK
        print(f"{rel:>12.0%} {P_BASELINE*rel*100:>8.2f}pp {P_BASELINE*(1+rel):>11.2%} "
              f"{n:>10,} {total:>7,} {weeks:>6.1f}")

    n10 = n_per_arm_proportions(P_BASELINE, 0.10)
    mde_rev = mde_for_mean(REV_SD, n10)
    print(f"\nSecondary metric (revenue per checkout user) at {n10:,} users/arm:")
    print(f"  detectable difference ≈ ${mde_rev:.2f} on a ${REV_MEAN:.2f} mean "
          f"({mde_rev/REV_MEAN:.0%} relative) → underpowered, so it is secondary, not primary.")
