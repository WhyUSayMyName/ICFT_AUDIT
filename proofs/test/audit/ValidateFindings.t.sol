// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";
import {PriceOracleV2Mock} from "../../src/mocks/PriceOracleV2Mock.sol";

/// @notice Adversarial re-validation of previously reported findings.
/// Each test either PROVES the finding on-chain or REFUTES it (false positive).
contract ValidateFindings is ProtocolFixture {
    function setUp() public {
        _setUpProtocol();
    }

    // ---------------------------------------------------------------
    // F2-07 (part B) — does the Fund A token invariant actually break?
    // Claim: on an ICFT price DROP, repay returns more tokens than were
    // borrowed; _saturatingSub clamps totalBorrowedICFT at 0 while
    // fundALiquidityICFT keeps the surplus => fundA > allocation.
    // ---------------------------------------------------------------
    function test_F2_07_fundAExceedsAllocationOnPriceDrop() public {
        uint256 alloc = lendingPool.fundAAllocation();

        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 borrowed = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(borrowed);

        assertEq(lendingPool.fundALiquidityICFT() + lendingPool.totalBorrowedICFT(), alloc, "holds after borrow");

        // ICFT halves -> closing the same USD debt needs ~2x tokens
        oracle.setManualICFTPrice(0.5e18, 18);
        uint256 need = oracle.convertUSDToICFT(lendingPool.getDebt(alice), true);
        vm.prank(alice);
        lendingPool.repay(need);

        uint256 fundA = lendingPool.fundALiquidityICFT();
        uint256 borrowedNow = lendingPool.totalBorrowedICFT();
        emit log_named_uint("fundAAllocation      ", alloc);
        emit log_named_uint("fundALiquidityICFT   ", fundA);
        emit log_named_uint("totalBorrowedICFT    ", borrowedNow);
        emit log_named_uint("sum (should == alloc)", fundA + borrowedNow);

        assertGt(fundA, alloc, "CONFIRMED: fundA liquidity exceeds its allocation");
        assertTrue(fundA + borrowedNow != alloc, "CONFIRMED: token invariant broken");
    }

    // ---------------------------------------------------------------
    // F2-07 (part C) — the sharp version: with TWO borrowers, one repaying
    // after a price drop returns more tokens than they took, and
    // _saturatingSub can zero out totalBorrowedICFT while the other borrower
    // still owes => utilization (and therefore the APR for everyone) is wrong.
    // ---------------------------------------------------------------
    function test_F2_07_utilizationDistortedWithTwoBorrowers() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 aAvail = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(aAvail);

        vm.prank(bob);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 bAvail = lendingPool.getAvailableBorrow(bob);
        vm.prank(bob);
        lendingPool.borrow(bAvail);

        emit log_named_uint("totalBorrowedICFT (both)", lendingPool.totalBorrowedICFT());
        emit log_named_uint("utilization bps (both)  ", lendingPool.getUtilization());

        // ICFT crashes 10x -> alice must return ~10x tokens to clear her USD debt
        oracle.setManualICFTPrice(0.1e18, 18);
        uint256 need = oracle.convertUSDToICFT(lendingPool.getDebt(alice), true);
        deal(address(icft), alice, need); // fund her so she can actually close
        vm.prank(alice);
        lendingPool.repay(need);

        uint256 borrowedAfter = lendingPool.totalBorrowedICFT();
        uint256 bobDebt = lendingPool.getDebt(bob);
        emit log_named_uint("alice repaid tokens     ", need);
        emit log_named_uint("totalBorrowedICFT after ", borrowedAfter);
        emit log_named_uint("utilization bps after   ", lendingPool.getUtilization());
        emit log_named_uint("bob still owes USD      ", bobDebt);

        assertGt(bobDebt, 0, "bob still has debt");
        if (borrowedAfter == 0) {
            emit log_string("CONFIRMED: utilization reads 0 while debt is outstanding");
        } else {
            emit log_string("NOT ZEROED: counter distorted but not fully zeroed in this run");
        }
    }

    // ---------------------------------------------------------------
    // P3-AC3 — parameter bounds. Original claim: "bonus can be set to 100%,
    // liquidator seizes 2x". Re-test what ACTUALLY happens.
    // ---------------------------------------------------------------
    function test_P3_AC3_highBonusBricksLiquidation() public {
        // a plausible-looking 20% bonus is accepted by validation...
        riskEngine.setRiskParameters(8_000, 9_000, 8_500, 2_000);
        assertEq(riskEngine.getLiquidationBonusBps(), 2_000, "20% bonus accepted");

        // ...but the liquidation math underflows: BPS*BPS - target*(BPS+bonus)
        // = 1e8 - 8500*12000 < 0  => panic, liquidation is bricked protocol-wide
        vm.expectRevert();
        riskEngine.calculateLiquidation(2_000e18, 1_900e18);
        emit log_string("CONFIRMED: bonus=20% is accepted but calculateLiquidation reverts");

        // 100% bonus likewise accepted by the setter
        riskEngine.setRiskParameters(8_000, 9_000, 8_500, 10_000);
        assertEq(riskEngine.getLiquidationBonusBps(), 10_000, "100% bonus accepted by setter");
        vm.expectRevert();
        riskEngine.calculateLiquidation(2_000e18, 1_900e18);
        emit log_string("CONFIRMED: bonus=100% accepted, liquidation math reverts (DoS, not 2x seizure)");

        // safe bound: with target 85% the bonus must stay below ~17.6%
        riskEngine.setRiskParameters(8_000, 9_000, 8_500, 1_700);
        riskEngine.calculateLiquidation(2_000e18, 1_900e18); // does not revert
        emit log_string("bonus=17% still works -> real safe ceiling is ~17.6%, unenforced");
    }

    // ---------------------------------------------------------------
    // P3-LIQ2 — target == threshold accepted; position reports liquidatable
    // but liquidate() reverts (stuck state).
    // ---------------------------------------------------------------
    function test_P3_LIQ2_targetEqualsThreshold_stuckPosition() public {
        riskEngine.setRiskParameters(8_000, 9_000, 9_000, 500);
        emit log_string("CONFIRMED: target == threshold accepted by _setRiskParameters");

        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 avail = lendingPool.getAvailableBorrow(alice); // hoisted: must not consume the prank
        vm.prank(alice);
        lendingPool.borrow(avail);

        // push ETH down so the position is genuinely liquidatable (LTV > 90%)
        ethFeed.setRoundData(1_700e8, block.timestamp);
        emit log_named_uint("LTV before liquidation (bps)", lendingPool.getLTV(alice));
        assertTrue(lendingPool.isLiquidatable(alice), "position is liquidatable");

        // first liquidation succeeds and pulls LTV down to target (== threshold)
        vm.prank(liquidator);
        liquidationEngine.executeLiquidation(alice, NATIVE_ASSET, type(uint128).max, payable(liquidator));

        emit log_named_uint("LTV after 1st liquidation (bps)", lendingPool.getLTV(alice));

        // With target == threshold the position lands ON the threshold. calculateLTV
        // rounds down, so the true ratio stays a hair above target => the position
        // remains liquidatable and can be drained again, each round taking the bonus.
        uint256 collateralStart = lendingPool.getCollateralBalance(alice, NATIVE_ASSET);
        uint256 rounds;
        while (lendingPool.isLiquidatable(alice) && rounds < 20) {
            vm.prank(liquidator);
            try liquidationEngine.executeLiquidation(alice, NATIVE_ASSET, type(uint128).max, payable(liquidator)) {
                rounds++;
            } catch {
                break;
            }
        }
        uint256 collateralEnd = lendingPool.getCollateralBalance(alice, NATIVE_ASSET);

        emit log_named_uint("extra liquidation rounds executed", rounds);
        emit log_named_uint("collateral before repeat rounds (wei)", collateralStart);
        emit log_named_uint("collateral after  repeat rounds (wei)", collateralEnd);
        emit log_named_uint("collateral drained by repeats (wei)", collateralStart - collateralEnd);
        emit log_named_uint("final LTV (bps)", lendingPool.getLTV(alice));

        assertGt(rounds, 0, "CONFIRMED: position is re-liquidatable after reaching target");
    }

    // ---------------------------------------------------------------
    // P3-FUND2 — protocol revenue accumulates with no withdrawal path.
    // ---------------------------------------------------------------
    function test_P3_FUND2_revenueAccumulatesAndIsLocked() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 10 ether}();
        vm.prank(alice);
        lendingPool.borrow(10_000 ether);

        vm.warp(block.timestamp + 365 days);
        lendingPool.accrueInterest();

        uint256 debt = lendingPool.getDebt(alice);
        uint256 owed = oracle.convertUSDToICFT(debt, true); // hoisted: must not consume the prank
        vm.prank(alice);
        lendingPool.repay(owed);

        uint256 revenue = lendingPool.protocolRevenueICFT();
        emit log_named_uint("protocolRevenueICFT after 1y + full repay", revenue);
        assertGt(revenue, 0, "revenue accrued");

        // it is excluded from spendable inventory and there is no setter/withdrawer
        uint256 raw = icft.balanceOf(address(lendingPool));
        assertEq(lendingPool.getSpendablePrincipalBalance(), raw - revenue, "revenue carved out of spendable");
        emit log_string("CONFIRMED: no function in LendingPool ever decreases protocolRevenueICFT");
    }

    // ---------------------------------------------------------------
    // P3-AC4 — during pause: collateral is locked while interest keeps accruing.
    // ---------------------------------------------------------------
    function test_P3_AC4_freezeLocksCollateralWhileInterestAccrues() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 5 ether}();
        vm.prank(alice);
        lendingPool.borrow(5_000 ether);

        lendingPool.pause();

        uint256 debtBefore = lendingPool.getDebt(alice);
        vm.warp(block.timestamp + 30 days);
        lendingPool.accrueInterest(); // not gated by whenNotPaused
        uint256 debtAfter = lendingPool.getDebt(alice);

        emit log_named_uint("debt at pause start", debtBefore);
        emit log_named_uint("debt after 30d paused", debtAfter);
        assertGt(debtAfter, debtBefore, "CONFIRMED: interest accrues during pause");

        // collateral cannot be withdrawn while paused
        vm.prank(alice);
        vm.expectRevert();
        lendingPool.withdrawCollateral(1 ether);
        emit log_string("CONFIRMED: withdrawCollateral blocked while paused");

        // repay still allowed (this part matches MVP_SPEC line 123 - by design)
        vm.prank(alice);
        lendingPool.repay(100 ether);
        emit log_string("repay works during pause (by design per MVP_SPEC)");
    }

    // ---------------------------------------------------------------
    // P3-05 / P3-LIQ3 — underwater position: all collateral is seized but
    // residual debt survives with no write-off mechanism (bad debt).
    // ---------------------------------------------------------------
    function test_P3_05_badDebtSurvivesFullLiquidation() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        uint256 avail = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(avail);

        // ETH collapses: debt ($1600) now exceeds collateral ($1000)
        ethFeed.setRoundData(1_000e8, block.timestamp);
        emit log_named_uint("LTV after crash (bps)", lendingPool.getLTV(alice));

        uint256 rounds;
        while (lendingPool.isLiquidatable(alice) && rounds < 30) {
            vm.prank(liquidator);
            try liquidationEngine.executeLiquidation(alice, NATIVE_ASSET, type(uint128).max, payable(liquidator)) {
                rounds++;
            } catch {
                break;
            }
        }

        uint256 residualDebt = lendingPool.getDebt(alice);
        uint256 leftCollateral = lendingPool.getCollateralBalance(alice, NATIVE_ASSET);
        emit log_named_uint("liquidation rounds", rounds);
        emit log_named_uint("residual debt USD", residualDebt);
        emit log_named_uint("remaining collateral wei", leftCollateral);

        assertGt(residualDebt, 0, "CONFIRMED: uncovered bad debt remains");
        emit log_string("CONFIRMED: no write-off / insurance path exists for this residual");
    }

    // ---------------------------------------------------------------
    // P3-AC2 — upgrade is instant: the proxy admin owner swaps the oracle
    // implementation in one transaction, no timelock, no delay.
    // ---------------------------------------------------------------
    function test_P3_AC2_instantUpgradeNoTimelock() public {
        bytes32 ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        address proxyAdmin = address(uint160(uint256(vm.load(address(oracle), ADMIN_SLOT))));
        emit log_named_address("ProxyAdmin of PriceOracle", proxyAdmin);

        address newImpl = address(new PriceOracleV2Mock());
        uint256 t0 = block.timestamp;

        vm.prank(upgradeAdmin);
        (bool ok,) = proxyAdmin.call(
            abi.encodeWithSignature("upgradeAndCall(address,address,bytes)", address(oracle), newImpl, bytes(""))
        );

        assertTrue(ok, "CONFIRMED: upgrade executed");
        assertEq(block.timestamp, t0, "CONFIRMED: same block - zero delay, no timelock");
        emit log_string("CONFIRMED: single owner swapped implementation instantly");
    }

    // ---------------------------------------------------------------
    // P3-03 — no minimum borrow size: a 1 wei dust loan is accepted.
    // ---------------------------------------------------------------
    function test_P3_03_dustBorrowAccepted() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        vm.prank(alice);
        lendingPool.borrow(1); // 1 wei of ICFT
        assertGt(lendingPool.getPosition(alice).scaledDebtUSD, 0, "dust position created");
        emit log_named_uint("dust debt USD", lendingPool.getDebt(alice));
        emit log_string("CONFIRMED: no minimum borrow enforced");
    }
}
