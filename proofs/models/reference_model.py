#!/usr/bin/env python3
"""
ICFT differential reference model.

Independent Python re-implementation of the protocol's LTV and partial-liquidation
math (integer arithmetic, matching the Solidity exactly). Emits random-input vectors
to test/audit/fixtures/diff_vectors.json; the Foundry test Differential.t.sol feeds
the same inputs to RiskEngine and asserts the on-chain result equals this model.

Run:  python audit/фаза4_тесты/reference_model.py
"""
import json, random, os

BPS = 10_000
TARGET = 8_500          # targetLtvBps
THRESH = 9_000          # liquidationThresholdBps
BONUS = 500             # liquidationBonusBps
UINT_MAX = (1 << 256) - 1

def calc_ltv(collateral: int, debt: int) -> int:
    if debt == 0:
        return 0
    if collateral == 0:
        return UINT_MAX
    return (debt * BPS) // collateral

def is_already_at_target(collateral: int, debt: int) -> bool:
    # debt*BPS*BPS <= target*collateral*BPS
    return debt * BPS * BPS <= TARGET * collateral * BPS

def calc_liquidation(collateral: int, debt: int):
    """Mirror RiskEngine.calculateLiquidation -> (debtToCoverUSD, collateralValueSeizedUSD)."""
    ltv = calc_ltv(collateral, debt)
    if collateral == 0 or debt == 0 or ltv < THRESH:
        return (0, 0)
    if is_already_at_target(collateral, debt):
        return (0, 0)
    denominator = (BPS * BPS) - (TARGET * (BPS + BONUS))
    assert denominator != 0
    numerator = (debt * BPS * BPS) - (TARGET * collateral * BPS)
    debt_to_cover = numerator // denominator
    if numerator % denominator != 0:
        debt_to_cover += 1
    if debt_to_cover > debt:
        debt_to_cover = debt
    seize = (debt_to_cover * (BPS + BONUS)) // BPS
    if seize > collateral:
        seize = collateral
    return (debt_to_cover, seize)

def main():
    random.seed(51966)  # deterministic
    collateral, debt, exp_ltv, exp_cover, exp_seize = [], [], [], [], []

    def add(c, d):
        collateral.append(str(c)); debt.append(str(d))
        exp_ltv.append(str(calc_ltv(c, d)))
        cover, seize = calc_liquidation(c, d)
        exp_cover.append(str(cover)); exp_seize.append(str(seize))

    # broad random spread (healthy, near-threshold, deeply underwater)
    for _ in range(300):
        c = random.randint(1 * 10**18, 5_000_000 * 10**18)
        d = random.randint(1 * 10**18, int(c * 1.5))  # up to 150% LTV
        add(c, d)

    # targeted near-boundary cases around 90% threshold
    for pct in (8999, 9000, 9001, 9500, 10000, 12000, 20000):
        c = 1000 * 10**18
        d = c * pct // BPS
        add(c, d)

    out = {
        "collateral": collateral, "debt": debt,
        "expLtv": exp_ltv, "expCover": exp_cover, "expSeize": exp_seize,
        "params": {"BPS": BPS, "TARGET": TARGET, "THRESH": THRESH, "BONUS": BONUS},
        "count": len(collateral),
    }
    dst = os.path.join(os.path.dirname(__file__), "..", "..", "test", "audit", "fixtures")
    dst = os.path.abspath(dst)
    os.makedirs(dst, exist_ok=True)
    path = os.path.join(dst, "diff_vectors.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print(f"wrote {out['count']} vectors -> {path}")

if __name__ == "__main__":
    main()
