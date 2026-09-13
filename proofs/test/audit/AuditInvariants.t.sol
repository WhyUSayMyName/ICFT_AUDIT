// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";
import {LendingPool} from "../../src/core/ICFT/lending/LendingPool.sol";
import {PriceOracle} from "../../src/core/ICFT/oracle/PriceOracle.sol";
import {RiskEngine} from "../../src/core/ICFT/risk/RiskEngine.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Stateful handler that drives the protocol AND moves oracle prices,
/// which the project's own invariant handler never does. Ghost flags capture
/// per-action postcondition violations for the invariant assertions.
contract AuditHandler is Test {
    LendingPool internal pool;
    PriceOracle internal oracle;
    RiskEngine internal risk;
    MockChainlinkFeed internal ethFeed;
    IERC20 internal icft;
    address internal liquidator;
    address[] internal actors;
    address internal constant NATIVE = address(0);

    // ghosts
    uint256 public lastBorrowIndex;
    bool public userActionLeftUnhealthy;   // inv5
    bool public liquidationLeftAboveTarget; // inv6
    bool public interestWentBackwards;      // inv11
    bool public debtDroppedWithoutRepay;    // inv9
    mapping(address => uint256) public lastDebtNoRepay;

    constructor(
        LendingPool pool_,
        PriceOracle oracle_,
        RiskEngine risk_,
        MockChainlinkFeed ethFeed_,
        IERC20 icft_,
        address liquidator_,
        address[] memory actors_
    ) {
        pool = pool_; oracle = oracle_; risk = risk_; ethFeed = ethFeed_; icft = icft_;
        liquidator = liquidator_; actors = actors_;
        lastBorrowIndex = pool.borrowIndex();
    }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }

    function _ltv(address a) internal view returns (uint256) {
        return risk.calculateLTV(pool.getCollateralValueUSD(a), pool.getDebt(a));
    }

    function _syncIndexGhost() internal {
        uint256 bi = pool.borrowIndex();
        if (bi < lastBorrowIndex) interestWentBackwards = true;
        lastBorrowIndex = bi;
    }

    function deposit(uint256 s, uint96 amt) external {
        address a = _actor(s);
        // minimum economically-meaningful deposit; dust positions (wei-scale) break
        // liquidation health-restoration by integer rounding — that is finding P3-03
        // (no minimum position size), demonstrated separately in FindingsPoC.
        uint256 amount = bound(uint256(amt), 0.1 ether, 50 ether);
        vm.deal(a, a.balance + amount);
        vm.prank(a);
        try pool.depositCollateral{value: amount}() {} catch {}
        _syncIndexGhost();
    }

    function borrow(uint256 s, uint96 amt) external {
        address a = _actor(s);
        uint256 maxB = pool.getAvailableBorrow(a);
        if (maxB == 0) return;
        uint256 amount = bound(uint256(amt), 1 wei, maxB);
        vm.prank(a);
        try pool.borrow(amount) {
            // inv5: a successful user borrow must never leave LTV above maxLTV
            if (_ltv(a) > risk.getMaxLTVBps()) userActionLeftUnhealthy = true;
        } catch {}
        _syncIndexGhost();
    }

    function repay(uint256 s, uint96 amt) external {
        address a = _actor(s);
        uint256 amount = bound(uint256(amt), 1 wei, 200_000 ether);
        vm.prank(a);
        try pool.repay(amount) {} catch {}
        _syncIndexGhost();
    }

    function withdraw(uint256 s, uint96 amt) external {
        address a = _actor(s);
        (uint256 col,,,,) = pool.positions(a);
        if (col == 0) return;
        uint256 amount = bound(uint256(amt), 1 wei, col);
        vm.prank(a);
        try pool.withdrawCollateral(amount) {
            // inv5: withdraw must never leave LTV above maxLTV
            if (_ltv(a) > risk.getMaxLTVBps()) userActionLeftUnhealthy = true;
        } catch {}
        _syncIndexGhost();
    }

    function liquidate(uint256 s, uint96 maxIcft) external {
        address victim = _actor(s);
        if (!pool.isLiquidatable(victim)) return;
        uint256 amount = bound(uint256(maxIcft), 1 wei, 500_000 ether);
        vm.prank(liquidator);
        try pool.liquidate(victim, NATIVE, amount, liquidator) {
            // inv6/inv7 (true property): after a successful liquidation that LEAVES collateral,
            // the position must no longer be liquidatable (LTV < threshold) — i.e. it cannot be
            // immediately re-liquidated. Underwater positions with ALL collateral seized
            // (col==0, debt>0) are bad debt, captured separately in FindingsPoC.
            // MATERIAL collateral must remain for this to be an under-liquidation bug.
            // Near-zero remaining collateral with residual debt is bad debt (P3-LIQ3),
            // covered separately — a wei-dust remainder is economically the same as full seizure.
            if (pool.getDebt(victim) > 0
                && pool.getCollateralValueUSD(victim) > 1e15 // > $0.001 of collateral left
                && pool.isLiquidatable(victim)) {
                liquidationLeftAboveTarget = true;
            }
        } catch {}
        _syncIndexGhost();
    }

    function setEthPrice(uint256 s) external {
        int256 p = int256(bound(s, 300e8, 5_000e8));
        ethFeed.setRoundData(p, block.timestamp);
        _syncIndexGhost();
    }

    function setIcftPrice(uint256 s) external {
        uint256 p = bound(s, 0.2e18, 5e18);
        oracle.setManualICFTPrice(p, 18);
        _syncIndexGhost();
    }

    function warpTime(uint32 j) external {
        // snapshot debts to check monotonicity across a pure time jump (no repay)
        for (uint256 i; i < actors.length; ++i) lastDebtNoRepay[actors[i]] = pool.getDebt(actors[i]);
        vm.warp(block.timestamp + bound(uint256(j), 1 minutes, 30 days));
        (, int256 ans,,,) = ethFeed.latestRoundData();
        ethFeed.setRoundData(ans, block.timestamp); // keep feed fresh
        pool.accrueInterest();
        // inv9 + inv11: debt must not shrink over time absent a repayment
        for (uint256 i; i < actors.length; ++i) {
            if (pool.getDebt(actors[i]) + 1 < lastDebtNoRepay[actors[i]]) debtDroppedWithoutRepay = true;
        }
        _syncIndexGhost();
    }

    function actorsLength() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
}

contract AuditInvariantTest is StdInvariant, ProtocolFixture {
    AuditHandler internal h;

    function setUp() public {
        _setUpProtocol();
        address[] memory a = new address[](3);
        a[0] = alice; a[1] = bob; a[2] = carol;
        h = new AuditHandler(lendingPool, oracle, riskEngine, ethFeed, IERC20(address(icft)), liquidator, a);

        // grant the handler the powers it needs to exercise the whole surface
        oracle.grantRole(oracle.ORACLE_ADMIN_ROLE(), address(h));
        lendingPool.grantRole(lendingPool.LIQUIDATION_BOT_ROLE(), liquidator);
        // fund + approve the liquidator so the handler's liquidate() can pull ICFT
        vm.prank(liquidity);
        icft.transfer(liquidator, 5_000_000 ether);
        vm.prank(liquidator);
        icft.approve(address(lendingPool), type(uint256).max);

        targetContract(address(h));
    }

    // ---- 1. sum of per-position USD debt == aggregate tracked debt ----
    function invariant_01_debtSumMatchesAggregate() public view {
        uint256 sum;
        uint256 n = h.actorsLength();
        for (uint256 i; i < n; ++i) sum += lendingPool.getDebt(h.actorAt(i));
        uint256 agg = lendingPool.getDebt(address(0)); // 0 (no position) — use total via preview
        agg; // silence
        uint256 total = _totalDebtPreview();
        // per-position floor rounding: sum(floor) <= floor(total), gap <= n wei
        assertLe(sum, total + n);
        assertLe(total, sum + n);
    }

    // ---- 2 & 12. token/collateral backing: no shortfall ----
    function invariant_02_collateralFullyBacked() public view {
        uint256 sumEth;
        uint256 n = h.actorsLength();
        for (uint256 i; i < n; ++i) {
            (uint256 col,,,,) = lendingPool.positions(h.actorAt(i));
            sumEth += col;
        }
        // every wei of ETH collateral tracked is actually held by the pool
        assertGe(address(lendingPool).balance, sumEth);
    }

    function invariant_12_icftBalanceBacksRevenue() public view {
        // protocol revenue must be backed by real ICFT sitting in the pool
        assertGe(icft.balanceOf(address(lendingPool)), lendingPool.protocolRevenueICFT());
    }

    // ---- 3. total supply constant ----
    function invariant_03_supplyConstant() public view {
        assertEq(icft.totalSupply(), 1_000_000_000 ether);
    }

    // ---- 5. no user action leaves LTV > maxLTV ----
    function invariant_05_userActionNeverLeavesUnhealthy() public view {
        assertFalse(h.userActionLeftUnhealthy());
    }

    // ---- 6. partial liquidation ends at/below target ----
    function invariant_06_liquidationReachesTarget() public view {
        assertFalse(h.liquidationLeftAboveTarget());
    }

    // ---- 9 & 11. interest monotonic (index up, debt not shrinking w/o repay) ----
    function invariant_09_11_interestMonotonic() public view {
        assertFalse(h.interestWentBackwards());
        assertFalse(h.debtDroppedWithoutRepay());
    }

    function _totalDebtPreview() internal view returns (uint256) {
        // mirror LendingPool._debtFromScaled(totalScaledDebtUSD, previewIndex)
        uint256 scaled = lendingPool.totalScaledDebtUSD();
        // getDebt uses previewBorrowIndex internally; reconstruct via a zero-collateral proxy is hard,
        // so use borrowIndex (accrueInterest is called in warp) — bound check tolerates drift.
        uint256 idx = lendingPool.borrowIndex();
        return (scaled * idx) / 1e18;
    }
}
