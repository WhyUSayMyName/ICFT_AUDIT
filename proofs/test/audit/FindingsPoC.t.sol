// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";
import {ICFT} from "../../src/core/ICFT/token/ICFT.sol";
import {IInterestRateModel} from "../../src/core/interfaces/IInterestRateModel.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Malicious upgrade target used by the AC2 PoC: proves an upgrade can add mint
/// to the "fixed-supply" token.
contract MaliciousICFT is ICFT {
    function evilMint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice One PoC per audit finding rated MEDIUM or higher. Each test PASSES by
/// demonstrating the flagged behaviour (a revert that should not happen, an accounting
/// break, an unguarded privileged action, etc.).
contract FindingsPoC is ProtocolFixture {
    bytes32 internal constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    receive() external payable {} // so this contract can receive seized ETH as a liquidator

    function setUp() public {
        _setUpProtocol();
    }

    // helper: give the test contract (admin) ICFT + approval so it can liquidate directly
    function _fundSelfWithIcft(uint256 amount) internal {
        vm.prank(liquidity);
        icft.transfer(address(this), amount);
        icft.approve(address(lendingPool), type(uint256).max);
    }

    function _aliceBorrow(uint256 ethAmount, uint256 borrowIcft) internal {
        vm.prank(alice);
        lendingPool.depositCollateral{value: ethAmount}();
        if (borrowIcft == 0) return;
        vm.prank(alice);
        lendingPool.borrow(borrowIcft);
    }

    // =====================================================================
    // HIGH — P3-ORA2 / БАГ #3 : setManualICFTPrice unguarded (no bounds/timelock)
    //        + P3-ORA1 (no integrity controls) + Fund A drain vector
    // =====================================================================
    function test_PoC_ORA2_manualPrice_unbounded_and_drainsFundA() public {
        // (a) no bounds: admin can set price to 1 wei or absurdly high, instantly, one tx
        oracle.setManualICFTPrice(1, 18); // ~$1e-18
        assertEq(oracle.getICFTUSDPrice(), 1);
        oracle.setManualICFTPrice(1_000_000 ether, 18); // ~$1e6
        assertEq(oracle.getICFTUSDPrice(), 1_000_000 ether);

        // (b) drain: at a near-zero ICFT price, a tiny collateral lets you borrow a huge
        // ICFT quantity because USD debt is priced off the manipulated ICFT price.
        oracle.setManualICFTPrice(1e6, 18); // ICFT = $0.000000000001
        uint256 fundABefore = lendingPool.fundALiquidityICFT();

        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}(); // $2000 collateral
        // borrow up to just under the 90% utilization cap: 170M of the 200M Fund A
        uint256 drain = 170_000_000 ether;
        vm.prank(alice);
        lendingPool.borrow(drain);

        // alice walked away with 85% of Fund A for ~1 ETH of collateral (LTV stays ~0)
        assertGt(drain, fundABefore / 2, "drained >50% of Fund A for 1 ETH");
        assertGe(icft.balanceOf(alice), drain);
        assertLe(lendingPool.getLTV(alice), riskEngine.getMaxLTVBps());
        emit log_named_uint("ICFT drained for 1 ETH collateral", drain);
    }

    // =====================================================================
    // HIGH — P3-AC4 : Emergency Freeze locks collateral while interest accrues.
    //        + P3-06 : liquidation blocked while paused.
    // =====================================================================
    function test_PoC_AC4_freezeTrapsCollateralAndAccruesInterest() public {
        _aliceBorrow(2 ether, 1_000 ether);
        uint256 debtBefore = lendingPool.getDebt(alice);

        lendingPool.pause();

        // repay is allowed during pause...
        vm.prank(alice);
        lendingPool.repay(100 ether);

        // ...but withdrawing collateral is blocked, trapping the user
        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        lendingPool.withdrawCollateral(1 ether);

        // liquidation is also blocked during pause (bad positions can't be closed)
        _fundSelfWithIcft(1_000_000 ether);
        vm.expectRevert();
        lendingPool.liquidate(alice, NATIVE_ASSET, 1_000 ether, address(this));

        // and interest keeps accruing while frozen
        vm.warp(block.timestamp + 30 days);
        ethFeed.setRoundData(2_000e8, block.timestamp);
        lendingPool.accrueInterest();
        assertGt(lendingPool.getDebt(alice), debtBefore - 100 ether, "interest accrues during pause");
        emit log_string("collateral withdrawal reverts while paused; debt still grows");
    }

    // =====================================================================
    // HIGH — P3-LIQ3 / P3-FUND1 : underwater liquidation leaves bad debt, no coverage
    // =====================================================================
    function test_PoC_LIQ3_badDebtPersistsAfterFullSeizure() public {
        _aliceBorrow(1 ether, 0); // deposit only
        uint256 maxBorrow = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(maxBorrow); // borrow to ~80% LTV

        // ETH crashes 85%: position goes deeply underwater
        ethFeed.setRoundData(300e8, block.timestamp);
        assertTrue(lendingPool.isLiquidatable(alice));

        _fundSelfWithIcft(2_000_000 ether);
        lendingPool.liquidate(alice, NATIVE_ASSET, 2_000_000 ether, address(this));

        (uint256 colAfter,,,,) = lendingPool.positions(alice);
        uint256 debtAfter = lendingPool.getDebt(alice);

        // all collateral seized, yet debt remains — bad debt with no write-off / Fund B
        assertEq(colAfter, 0, "all collateral seized");
        assertGt(debtAfter, 0, "residual bad debt remains");
        assertGt(lendingPool.totalScaledDebtUSD(), 0, "bad debt still counted in aggregate, uncovered");
        emit log_named_uint("residual bad debt USD (uncovered)", debtAfter);
    }

    // =====================================================================
    // HIGH — P3-AC1 : one address holds every privileged role across all modules
    // =====================================================================
    function test_PoC_AC1_singleAdminHoldsAllRoles() public view {
        assertTrue(lendingPool.hasRole(lendingPool.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(lendingPool.hasRole(lendingPool.PAUSER_ROLE(), admin));
        assertTrue(lendingPool.hasRole(lendingPool.CONFIG_ADMIN_ROLE(), admin));
        assertTrue(lendingPool.hasRole(lendingPool.LIQUIDATION_BOT_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.ORACLE_ADMIN_ROLE(), admin));
        assertTrue(riskEngine.hasRole(riskEngine.RISK_ADMIN_ROLE(), admin));
        assertTrue(rateModel.hasRole(rateModel.RATE_ADMIN_ROLE(), admin));
        assertTrue(liquidationEngine.hasRole(liquidationEngine.ENGINE_ADMIN_ROLE(), admin));
        assertTrue(liquidationEngine.hasRole(liquidationEngine.OPERATOR_ROLE(), admin));
        // single key = full protocol control
    }

    // =====================================================================
    // HIGH — P3-AC2 : instant upgrade can break "fixed supply" (mint via new impl)
    // =====================================================================
    function test_PoC_AC2_upgradeBreaksFixedSupply() public {
        assertEq(icft.totalSupply(), 1_000_000_000 ether);

        // resolve the auto-deployed ProxyAdmin for the token proxy
        address adminAddr = address(uint160(uint256(vm.load(address(icft), ERC1967_ADMIN_SLOT))));
        ProxyAdmin pAdmin = ProxyAdmin(adminAddr);

        MaliciousICFT evil = new MaliciousICFT();
        // upgradeAdmin (= address(this)) upgrades instantly, no timelock
        pAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(icft)), address(evil), "");

        MaliciousICFT(address(icft)).evilMint(admin, 500_000_000 ether);
        assertEq(icft.totalSupply(), 1_500_000_000 ether, "supply inflated via upgrade");
        emit log_string("fixed-supply token minted 500M extra after instant proxy upgrade");
    }

    // =====================================================================
    // MEDIUM — F2-07 : utilization accounting drifts; Fund A conservation breaks on price drop
    // =====================================================================
    function test_PoC_F2_07_fundAConservationBreaksOnPriceDrop() public {
        uint256 alloc = lendingPool.fundAAllocation();

        _aliceBorrow(100 ether, 0);
        vm.prank(alice);
        lendingPool.borrow(100_000 ether); // borrow 100k ICFT @ $1

        // invariant holds right after borrow
        assertEq(lendingPool.fundALiquidityICFT() + lendingPool.totalBorrowedICFT(), alloc);

        // ICFT price halves -> full repay needs ~2x tokens
        oracle.setManualICFTPrice(0.5e18, 18);

        uint256 debtUsd = lendingPool.getDebt(alice);
        uint256 needed = oracle.convertUSDToICFT(debtUsd, true); // ~200k ICFT
        // give alice enough ICFT to fully repay
        vm.prank(liquidity);
        icft.transfer(alice, needed);
        vm.prank(alice);
        lendingPool.repay(needed);

        // conservation now BROKEN: fundALiquidity overshoots the fixed allocation
        uint256 lhs = lendingPool.fundALiquidityICFT() + lendingPool.totalBorrowedICFT();
        emit log_named_uint("fundALiquidity+borrowed", lhs);
        emit log_named_uint("fundAAllocation", alloc);
        assertGt(lendingPool.fundALiquidityICFT(), alloc, "Fund A liquidity exceeds allocation (F2-07)");
    }

    // =====================================================================
    // MEDIUM — P3-07 : interest compounds per-interaction (WP claims simple/non-compounding)
    // =====================================================================
    function test_PoC_07_interestCompoundsVsSimple() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 100 ether}();
        vm.prank(alice);
        lendingPool.borrow(100_000 ether); // 50% LTV; rate1 = 5% APR

        // Signature of compounding: each equal-length accrual step adds MORE than the
        // previous one, because the increment is proportional to the CURRENT index.
        // Simple (non-compounding) interest would add a CONSTANT amount each step.
        uint256 start = block.timestamp;
        uint256 i0 = lendingPool.borrowIndex();

        vm.warp(start + 180 days);
        ethFeed.setRoundData(2_000e8, block.timestamp);
        lendingPool.accrueInterest();
        uint256 i1 = lendingPool.borrowIndex();

        vm.warp(start + 360 days);
        ethFeed.setRoundData(2_000e8, block.timestamp);
        lendingPool.accrueInterest();
        uint256 i2 = lendingPool.borrowIndex();

        uint256 inc1 = i1 - i0;
        uint256 inc2 = i2 - i1;
        emit log_named_uint("index increment, period 1", inc1);
        emit log_named_uint("index increment, period 2", inc2);
        // strictly increasing increment => compounding, not the WP's simple interest
        assertGt(inc2, inc1, "equal periods add growing interest => compounding");
    }

    // =====================================================================
    // MEDIUM — F2-03 / БАГ #4 : stale ETH feed traps collateral (can't withdraw)
    // =====================================================================
    function test_PoC_F2_03_staleFeedTrapsCollateral() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 5 ether}(); // no debt

        // feed goes stale (no update for > maxPriceAge = 1h)
        vm.warp(block.timestamp + 2 hours);

        // even a debt-free user cannot retrieve collateral while the oracle is stale
        vm.prank(alice);
        vm.expectRevert();
        lendingPool.withdrawCollateral(1 ether);
        emit log_string("debt-free withdrawal reverts on stale oracle -> collateral trapped");
    }

    // =====================================================================
    // MEDIUM — P3-LIQ1 / БАГ #6 : liquidation is NOT permissionless
    // =====================================================================
    function test_PoC_LIQ1_liquidationNotPermissionless() public {
        _aliceBorrow(1 ether, 0);
        uint256 maxBorrow = lendingPool.getAvailableBorrow(alice);
        vm.prank(alice);
        lendingPool.borrow(maxBorrow);
        ethFeed.setRoundData(300e8, block.timestamp); // make liquidatable
        assertTrue(lendingPool.isLiquidatable(alice));

        address randomLiquidator = address(0xBEEF);
        vm.prank(liquidity);
        icft.transfer(randomLiquidator, 2_000_000 ether);
        vm.prank(randomLiquidator);
        icft.approve(address(lendingPool), type(uint256).max);

        // an ordinary account cannot liquidate, even though the position is unhealthy
        vm.prank(randomLiquidator);
        vm.expectRevert();
        lendingPool.liquidate(alice, NATIVE_ASSET, 2_000_000 ether, randomLiquidator);
        emit log_string("permissionless liquidation reverts -> single-keeper dependency (WP mismatch)");
    }

    // =====================================================================
    // MEDIUM — P3-LIQ2 / re БАГ #5 : zero-buffer risk params accepted (target == threshold)
    // =====================================================================
    function test_PoC_LIQ2_zeroBufferParamsAccepted() public {
        // target == threshold is allowed (no minimum health gap enforced)
        riskEngine.setRiskParameters(8_000, 9_000, 9_000, 500);
        assertEq(riskEngine.getTargetLTVBps(), 9_000);
        assertEq(riskEngine.getLiquidationThresholdBps(), 9_000);
        emit log_string("targetLtv == liquidationThreshold accepted (no health buffer)");
    }

    // =====================================================================
    // MEDIUM — P3-AC3 : parameter bounds too loose (bonus 100%, uncapped APR)
    // =====================================================================
    function test_PoC_AC3_looseParameterBounds() public {
        // liquidation bonus of 100% is accepted
        riskEngine.setRiskParameters(8_000, 9_000, 8_500, 10_000);
        assertEq(riskEngine.getLiquidationBonusBps(), 10_000);

        // an APR of 1,000,000 bps (10,000%) is accepted — no upper cap
        IInterestRateModel.RateConfig memory c = IInterestRateModel.RateConfig({
            kink1Bps: 5_000, kink2Bps: 8_000, kink3Bps: 9_000,
            rate1Bps: 0, rate2Bps: 0, rate3Bps: 0, rate4Bps: 1_000_000,
            maxBorrowUtilizationBps: 9_000
        });
        rateModel.setRateConfig(c);
        emit log_string("bonus=100% and APR=10000% accepted -> bounds too loose");
    }

    // =====================================================================
    // MEDIUM — P3-FUND2 : protocol revenue has no withdrawal path (locked)
    // =====================================================================
    function test_PoC_FUND2_revenueLockedNoWithdrawal() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 100 ether}();
        vm.prank(alice);
        lendingPool.borrow(100_000 ether); // 50% LTV; rate1 = 5% APR

        vm.warp(block.timestamp + 365 days);
        ethFeed.setRoundData(2_000e8, block.timestamp);
        lendingPool.accrueInterest();

        uint256 debt = lendingPool.getDebt(alice);
        vm.prank(liquidity);
        icft.transfer(alice, debt);
        vm.prank(alice);
        lendingPool.repay(debt); // repay in full -> interest portion becomes protocol revenue

        uint256 revenue = lendingPool.protocolRevenueICFT();
        assertGt(revenue, 0, "protocol accrued ICFT revenue");
        // There is NO function on LendingPool to withdraw/distribute protocolRevenueICFT.
        // It is excluded from spendable balance and cannot be reclaimed by anyone.
        assertLe(lendingPool.getSpendablePrincipalBalance(), icft.balanceOf(address(lendingPool)) - revenue);
        emit log_named_uint("protocol revenue locked in pool (no withdraw fn)", revenue);
    }

    // =====================================================================
    // MEDIUM — P3-VEST1 : no vesting; founder allocation is immediately transferable
    // =====================================================================
    function test_PoC_VEST1_founderCanDumpImmediately() public {
        uint256 bal = icft.balanceOf(founder);
        assertEq(bal, 80_000_000 ether, "founder holds full allocation at t=0");

        // no cliff, no lock: founder transfers the entire allocation on day zero
        vm.prank(founder);
        icft.transfer(address(0xDEAD), bal);
        assertEq(icft.balanceOf(address(0xDEAD)), bal, "founder dumped 80M with no vesting");
    }

    // =====================================================================
    // LOW->MED — P3-03 : no minimum borrow size (dust positions)
    // =====================================================================
    function test_PoC_P303_noMinimumBorrow_dust() public {
        vm.prank(alice);
        lendingPool.depositCollateral{value: 1 ether}();
        vm.prank(alice);
        lendingPool.borrow(1); // 1 wei of ICFT
        assertGt(lendingPool.getDebt(alice), 0);
        emit log_string("dust borrow of 1 wei accepted (no minimum position size)");
    }
}
