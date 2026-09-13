// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";

/// @notice On-chain stress scenarios executed numerically (not by reasoning).
/// S3 & S4 are the mandatory oracle-timing PoCs; S7/S10/S12 exercise utilization
/// ceiling, frozen-but-fresh oracle, and the absent Fund B path.
contract StressScenarios is ProtocolFixture {
    function setUp() public {
        _setUpProtocol();
    }

    // ------------------------------------------------------------------
    // S3 — manipulate ICFT/USD DOWN at borrow time.
    // Borrower receives MORE tokens for the same USD debt; after the price
    // recovers, the debt (fixed in USD) is repaid with far fewer tokens,
    // leaving a risk-free ICFT profit extracted from Fund A.
    // ------------------------------------------------------------------
    function test_S3_manipulateDownAtBorrow_freeTokens() public {
        // baseline: at $1 the same collateral would allow ~1600 ICFT
        uint256 baseline;
        {
            uint256 snap = vm.snapshot();
            vm.prank(bob);
            lendingPool.depositCollateral{value: 1 ether}();
            baseline = lendingPool.getAvailableBorrow(bob); // ICFT at $1
            vm.revertTo(snap);
        }

        // attacker path: push ICFT to $0.50 right before borrowing
        oracle.setManualICFTPrice(0.5e18, 18);
        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 got = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(got);

        uint256 debtUsd = lendingPool.getDebt(alice);

        // price recovers to $1
        oracle.setManualICFTPrice(1e18, 18);
        uint256 icftToRepay = oracle.convertUSDToICFT(debtUsd, true);

        emit log_named_uint("ICFT receivable @ $1 (baseline)", baseline);
        emit log_named_uint("ICFT received @ $0.50 (manipulated)", got);
        emit log_named_uint("USD debt booked", debtUsd);
        emit log_named_uint("ICFT needed to repay after recovery", icftToRepay);

        // received ~2x the baseline, but only needs ~half of what was received to repay
        assertGt(got, baseline * 19 / 10, "got ~2x tokens for same USD cap");
        assertLt(icftToRepay, got, "repays with fewer tokens than received");
        uint256 profit = got - icftToRepay;
        emit log_named_uint("risk-free ICFT profit (drained from Fund A)", profit);
        assertGt(profit, baseline * 8 / 10, "keeps ~1x baseline as pure profit");
    }

    // ------------------------------------------------------------------
    // S4 — manipulate ICFT/USD UP at repay time.
    // A normal borrower closes a USD debt with far fewer tokens, then
    // withdraws all collateral — again a token profit vs what was borrowed.
    // ------------------------------------------------------------------
    function test_S4_manipulateUpAtRepay_cheapClose() public {
        // borrow normally at $1
        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 borrowed = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(borrowed);

        // ICFT pumped to $2 right before repay
        oracle.setManualICFTPrice(2e18, 18);
        uint256 debtUsd = lendingPool.getDebt(alice);
        uint256 icftToClose = oracle.convertUSDToICFT(debtUsd, true);

        vm.prank(alice);
        lendingPool.repay(icftToClose);
        assertEq(lendingPool.getDebt(alice), 0, "debt fully closed");

        // collateral is fully retrievable
        vm.prank(alice);
        lendingPool.withdrawCollateral(1 ether);

        emit log_named_uint("ICFT borrowed @ $1", borrowed);
        emit log_named_uint("ICFT needed to close @ $2", icftToClose);
        uint256 kept = borrowed - icftToClose;
        emit log_named_uint("ICFT kept after full close + collateral out", kept);
        assertLt(icftToClose, borrowed, "closes with fewer tokens than borrowed");
        assertGt(kept, borrowed * 4 / 10, "keeps ~half the borrowed tokens");
    }

    // ------------------------------------------------------------------
    // S7 — drive utilization toward 100%. The model caps new borrows at
    // maxBorrowUtilizationBps (90%); there is no Fund B top-up. Measure the
    // real ceiling numerically.
    // ------------------------------------------------------------------
    function test_S7_utilizationCeiling_noFundB() public {
        // whale posts enormous collateral so LTV never binds; only the util cap does
        address whale = address(0x7777);
        vm.deal(whale, 1_000_000 ether);
        vm.prank(whale);
        lendingPool.depositCollateral{value: 1_000_000 ether}(); // $2e9 collateral

        uint256 alloc = lendingPool.fundAAllocation();
        // borrow just under the 90% cap
        uint256 target = alloc * 89 / 100;
        vm.prank(whale);
        lendingPool.borrow(target);
        uint256 util = lendingPool.getUtilization();
        emit log_named_uint("utilization after 89% borrow (bps)", util);

        // any borrow that would push utilization to/over 90% reverts
        vm.prank(whale);
        vm.expectRevert(); // BorrowingDisabledAtUtilization
        lendingPool.borrow(alloc * 5 / 100); // would reach ~94%

        emit log_named_uint("max reachable utilization (bps) ~", lendingPool.getUtilization());
        emit log_string("no Fund B mechanism exists to extend liquidity beyond the cap");
    }

    // ------------------------------------------------------------------
    // S10 — ETH/USD oracle "frozen" at a stale value but with a FRESH
    // updatedAt (the staleness check only looks at updatedAt, not correctness).
    // The protocol lends against a wrong (inflated) valuation.
    // ------------------------------------------------------------------
    function test_S10_frozenButFreshOracle_lendsOnWrongPrice() public {
        // real market: ETH fell to $1000, but the feed keeps reporting $2000
        // with a current timestamp (frozen value, fresh heartbeat)
        ethFeed.setRoundData(2_000e8, block.timestamp);

        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 borrowable = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(borrowable); // borrows against $2000 valuation

        uint256 ltvReported = lendingPool.getLTV(alice);
        emit log_named_uint("LTV at reported $2000 (bps)", ltvReported);

        // had the feed shown the true $1000, the same position would be ~160% LTV
        // (i.e. already deeply liquidatable). The stale-value feed hides it.
        uint256 debt = lendingPool.getDebt(alice);
        uint256 trueCollateralUsd = 1000e18; // 1 ETH @ true $1000
        uint256 trueLtv = debt * 10_000 / trueCollateralUsd;
        emit log_named_uint("true LTV at real $1000 (bps)", trueLtv);
        assertLe(ltvReported, riskEngine.getMaxLTVBps(), "passes checks on stale value");
        assertGt(trueLtv, riskEngine.getLiquidationThresholdBps(), "would be liquidatable on true price");
    }

    // ------------------------------------------------------------------
    // S12 — Fund B exhausted / utilization above 95%. There is no Fund B in
    // code, and the util cap prevents even reaching 95% via borrow; confirm
    // there is no code path that injects liquidity in that regime.
    // ------------------------------------------------------------------
    function test_S12_noFundBAbove95() public {
        address whale = address(0x7778);
        vm.deal(whale, 1_000_000 ether);
        vm.prank(whale);
        lendingPool.depositCollateral{value: 1_000_000 ether}();

        uint256 alloc = lendingPool.fundAAllocation();
        vm.prank(whale);
        lendingPool.borrow(alloc * 89 / 100);

        // utilization cannot be pushed to 95% via borrow (capped at 90%)...
        vm.prank(whale);
        vm.expectRevert();
        lendingPool.borrow(alloc * 7 / 100);

        // ...and there is no Fund B allocation / trigger to supply more ICFT.
        // Available liquidity is strictly bounded by Fund A minus buffer.
        uint256 avail = lendingPool.getAvailableLiquidity();
        emit log_named_uint("remaining available liquidity (ICFT)", avail);
        assertLe(avail, alloc, "liquidity never exceeds Fund A; no Fund B backstop");
    }
}
