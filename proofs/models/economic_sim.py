#!/usr/bin/env python3
"""
ICFT economic stress simulation — market-dynamics scenarios run NUMERICALLY.

On-chain protocol scenarios (S3, S4, S7, S10, S12) are executed as Foundry PoCs in
test/audit/StressScenarios.t.sol. This script models the scenarios that depend on
off-protocol market structure (price crashes, gas, DEX depth, keeper throughput,
vesting sell pressure): S1, S2, S5, S6, S8, S9, S11.

All assumptions are stated inline and parametrised so the sensitivity is visible.
Run:  python audit/фаза5_экономика/economic_sim.py
"""
import random, math

BPS = 10_000
MAX_LTV = 0.80
LIQ_THRESHOLD = 0.90
TARGET_LTV = 0.85
BONUS = 0.05
LIQ_GAS = 300_000          # gas per liquidation (pool.liquidate + engine)
random.seed(51966)

def hr(t): print("\n" + "=" * 76 + f"\n{t}\n" + "=" * 76)

# ---- shared synthetic position book -----------------------------------------
def make_book(n=1000, eth_price=2000.0):
    """n positions; initial LTV skewed toward the 80% cap (borrowers maximise)."""
    book = []
    for _ in range(n):
        # collateral USD: log-uniform $50 .. $500k
        col_usd = 10 ** random.uniform(math.log10(50), math.log10(500_000))
        # initial LTV: beta skewed high (most borrowers near the 80% cap)
        ltv0 = min(MAX_LTV, random.betavariate(6, 2) * MAX_LTV / 0.75)
        debt_usd = col_usd * ltv0
        eth = col_usd / eth_price
        book.append({"eth": eth, "debt": debt_usd, "ltv0": ltv0})
    return book

# ===================================================================== S1
def s1_crash_40(book, eth0=2000.0):
    hr("S1  ETH -40% in ~1h (Mar-2020 / May-2021 / Nov-2022 style)")
    eth1 = eth0 * 0.60
    liq = under = 0
    bad_debt = 0.0
    for p in book:
        col1 = p["eth"] * eth1
        ltv1 = p["debt"] / col1 if col1 else float("inf")
        if ltv1 >= LIQ_THRESHOLD:
            liq += 1
        if ltv1 >= 1.0:  # debt >= collateral -> underwater -> bad debt on liquidation
            under += 1
            # residual uncovered debt after seizing all collateral
            bad_debt += max(0.0, p["debt"] - col1)
    n = len(book)
    print(f"assumption: {n} positions, LTV skewed to the 80% cap; instantaneous -40%")
    print(f"a -40% drop multiplies every LTV by 1/0.6 = {1/0.6:.3f}x")
    print(f"positions liquidatable (LTV>=90%):   {liq:4d} / {n}  ({100*liq/n:.1f}%)")
    print(f"positions UNDERWATER (LTV>=100%):     {under:4d} / {n}  ({100*under/n:.1f}%)")
    print(f"=> any borrower above ~54% initial LTV becomes liquidatable; above ~60% -> bad debt")
    print(f"immediate uncovered bad debt:         ${bad_debt:,.0f}")
    print(f"NOTE: single-keeper (P3-LIQ1) + ICFT-repay dependency (P3-LIQ3) cannot clear")
    print(f"      {liq} liquidations within the hour -> most underwater debt is unrecoverable")
    return {"liquidatable": liq, "underwater": under, "bad_debt": bad_debt, "n": n}

# ===================================================================== S2
def s2_small_position_economics(eth_after=1600.0):
    hr("S2  ETH -20% + network congestion: is liquidating small positions economic?")
    print(f"liquidator profit = {BONUS:.0%} x debt_covered ; cost = gas x gasprice x ETH")
    print(f"ETH after -20% = ${eth_after:,.0f}; liquidation gas = {LIQ_GAS:,}")
    print(f"{'gas price':>12} | {'liq cost USD':>12} | {'min profitable debt (breakeven)':>32}")
    for gwei in (15, 50, 100, 200, 400):
        cost = LIQ_GAS * gwei * 1e-9 * eth_after
        breakeven = cost / BONUS
        print(f"{gwei:>9} gwei | ${cost:>10,.2f} | positions with debt < ${breakeven:>13,.0f} are UNPROFITABLE")
    print("=> at 200 gwei a position must owe > ~$2k to be worth liquidating;")
    print("   with no minimum borrow (P3-03) sub-$2k positions accrue as bad debt.")

# ===================================================================== S5
def s5_icft_pool_drained():
    hr("S5  ICFT/USDT pool drained: can anyone repay or liquidate?")
    print("repay(): borrower already holds borrowed ICFT -> can always repay (no DEX needed).")
    print("liquidate(): liquidator must SOURCE ICFT to pass to the pool.")
    print("model: constant-product pool (x ICFT, y USDT); liquidator buys R ICFT.")
    for depth_usdt in (2_000_000, 500_000, 100_000):
        x = depth_usdt        # assume ICFT ~ $1 => equal nominal depth
        y = depth_usdt
        for R in (50_000, 200_000):
            # cost to buy R ICFT out of pool (no fee): dy = y*R/(x-R) if R<x
            if R >= x:
                print(f"  depth ${depth_usdt:>9,} | buy {R:>7,} ICFT -> IMPOSSIBLE (R >= pool ICFT)")
                continue
            dy = y * R / (x - R)
            avg_price = dy / R
            print(f"  depth ${depth_usdt:>9,} | buy {R:>7,} ICFT -> pay ${dy:>10,.0f} USDT, avg ${avg_price:,.2f}/ICFT ({avg_price:.0%} of peg)")
    print("=> shallow pool: sourcing ICFT for large liquidations is prohibitively expensive")
    print("   or impossible -> liquidations stall -> bad debt (compounds P3-LIQ3).")

# ===================================================================== S6
def s6_all_borrowers_sell(borrowed_icft=170_000_000):
    hr("S6  All borrowers dump received ICFT into the pool")
    print("constant-product ICFT/USDT; sell `borrowed_icft` into pool of depth D (ICFT-side).")
    print(f"borrowed/at-risk ICFT dumped: {borrowed_icft:,}")
    for D in (5_000_000, 20_000_000, 100_000_000):
        # price after selling S into pool with reserves (D, D) at $1 peg
        # x*y=k; x'=D+S ; y'=k/x' ; price=y'/x'
        S = borrowed_icft
        k = D * D
        x2 = D + S
        y2 = k / x2
        price2 = y2 / x2
        print(f"  pool ICFT depth {D:>12,} | price ${1.0:>4.2f} -> ${price2:>7.4f}  ({price2-1:+.0%})")
    print("=> unless pool depth >> borrowable ICFT, a coordinated exit collapses the ICFT")
    print("   price. Because debt is USD-denominated, a low ICFT price then feeds S3-style")
    print("   over-borrowing and starves liquidators of affordable ICFT (S5).")

# ===================================================================== S8
def s8_dust_accumulation():
    hr("S8  Mass accumulation of dust positions")
    print("this codebase does NOT iterate positions on-chain (only a bounded loop over")
    print("supportedCollateralAssets) -> no gas/DoS from many positions. The real damage is")
    print("economic: dust below the liquidation-profit threshold is never closed.")
    breakeven_200gwei = LIQ_GAS * 200 * 1e-9 * 1600 / BONUS
    print(f"unprofitable-debt threshold @200 gwei, ETH $1600: ${breakeven_200gwei:,.0f}")
    for n_dust, avg_debt in ((10_000, 50), (50_000, 100), (200_000, 30)):
        stuck = n_dust * avg_debt
        print(f"  {n_dust:>7,} dust positions x ${avg_debt:>4} avg debt = ${stuck:>12,.0f} permanently uncoverable")
    print("=> no minimum position size (P3-03) lets an attacker seed cheap dust that can")
    print("   never be profitably liquidated, slowly converting Fund A into bad debt.")

# ===================================================================== S9
def s9_keeper_offline_24h(book, eth0=2000.0):
    hr("S9  Keeper offline for 24h (no external permissionless liquidators, P3-LIQ1)")
    # a plausible bad day during the outage: ETH drifts -25% over 24h with no liquidations
    eth1 = eth0 * 0.75
    with_keeper_bad = 0.0   # keeper liquidates each position exactly when it crosses 90%
    without_keeper_bad = 0.0
    liq_missed = 0
    for p in book:
        col1 = p["eth"] * eth1
        ltv1 = p["debt"] / col1 if col1 else float("inf")
        if ltv1 >= LIQ_THRESHOLD:
            liq_missed += 1
            if ltv1 >= 1.0:
                # with a live keeper, liquidation triggers at ~90% -> negligible bad debt;
                # offline for 24h, the position free-falls to ltv1 -> uncovered remainder
                without_keeper_bad += max(0.0, p["debt"] - col1)
    n = len(book)
    print(f"assumption: ETH -25% over 24h, liquidation is role-gated (no fallback liquidators)")
    print(f"positions that should have been liquidated in the window: {liq_missed}/{n}")
    print(f"bad debt WITH a live keeper (liquidate at 90%):     ~$0 (closed before underwater)")
    print(f"bad debt WITHOUT keeper for 24h:                    ${without_keeper_bad:,.0f}")
    print("=> because liquidation is not permissionless, a 24h keeper outage converts every")
    print("   position that crosses 100% into unrecoverable bad debt with no market backstop.")
    return {"missed": liq_missed, "bad_debt": without_keeper_bad}

# ===================================================================== S11
def s11_vesting_unlocks():
    hr("S11  Vesting unlocks (WP months 6/12/18/24/30) vs code reality")
    print("CODE REALITY: no vesting (P3-VEST1). 100% of insider/reserve tokens are liquid at")
    print("TGE -> the entire schedule collapses to a single day-0 unlock.")
    alloc = {"Founder": 80e6, "Developers": 100e6, "FutureInvestors": 160e6, "Strategic/FundB": 280e6}
    total = sum(alloc.values())
    print(f"immediately-liquid insider/reserve supply: {total/1e6:.0f}M ICFT ({total/1e9*100:.0f}% of 1B)")
    for name, amt in alloc.items():
        print(f"  {name:<16} {amt/1e6:>5.0f}M")
    print(f"\nprice impact of dumping X% of the {total/1e6:.0f}M into an ICFT/USDT pool (depth 20M ICFT):")
    D = 20_000_000
    for pct in (5, 10, 25):
        S = total * pct / 100
        k = D * D
        price2 = (k / (D + S)) / (D + S)
        print(f"  dump {pct:>2}% = {S/1e6:>5.1f}M ICFT -> price ${1.0:.2f} -> ${price2:.4f}  ({price2-1:+.0%})")
    print("=> WP's 6m cliff + 24m linear is absent; worst-case sell pressure is unbounded and")
    print("   immediate, amplifying S3/S4/S6.")

def main():
    print("ICFT ECONOMIC STRESS SIMULATION (numerical) — market-dynamics scenarios")
    print("on-chain scenarios S3/S4/S7/S10/S12 are Foundry PoCs in StressScenarios.t.sol")
    book = make_book()
    s1_crash_40(book)
    s2_small_position_economics()
    s5_icft_pool_drained()
    s6_all_borrowers_sell()
    s8_dust_accumulation()
    s9_keeper_offline_24h(book)
    s11_vesting_unlocks()
    hr("DONE")

if __name__ == "__main__":
    main()
