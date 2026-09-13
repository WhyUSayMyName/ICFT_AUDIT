// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";
import {IRiskEngine} from "../../src/core/interfaces/IRiskEngine.sol";

/// @notice Differential test: the Python reference model (audit/фаза4_тесты/reference_model.py)
/// computes LTV and partial-liquidation math on random inputs and writes diff_vectors.json.
/// Here we feed the SAME inputs to the on-chain RiskEngine and assert exact agreement.
/// Any divergence is a finding. Regenerate vectors with the Python script before running.
contract DifferentialTest is ProtocolFixture {
    string internal json;
    string[] internal collateral;
    string[] internal debt;
    string[] internal expLtv;
    string[] internal expCover;
    string[] internal expSeize;

    function setUp() public {
        _setUpProtocol();
        json = vm.readFile("test/audit/fixtures/diff_vectors.json");
        collateral = vm.parseJsonStringArray(json, ".collateral");
        debt = vm.parseJsonStringArray(json, ".debt");
        expLtv = vm.parseJsonStringArray(json, ".expLtv");
        expCover = vm.parseJsonStringArray(json, ".expCover");
        expSeize = vm.parseJsonStringArray(json, ".expSeize");
    }

    function test_Differential_LTV_matchesReference() public view {
        uint256 n = collateral.length;
        for (uint256 i; i < n; ++i) {
            uint256 c = vm.parseUint(collateral[i]);
            uint256 d = vm.parseUint(debt[i]);
            uint256 got = riskEngine.calculateLTV(c, d);
            assertEq(got, vm.parseUint(expLtv[i]), "LTV divergence vs Python model");
        }
    }

    function test_Differential_Liquidation_matchesReference() public view {
        uint256 n = collateral.length;
        for (uint256 i; i < n; ++i) {
            uint256 c = vm.parseUint(collateral[i]);
            uint256 d = vm.parseUint(debt[i]);
            IRiskEngine.LiquidationOutcome memory o = riskEngine.calculateLiquidation(c, d);
            assertEq(o.debtToCoverUSD, vm.parseUint(expCover[i]), "debtToCover divergence vs Python model");
            assertEq(o.collateralValueSeizedUSD, vm.parseUint(expSeize[i]), "seized divergence vs Python model");
        }
    }
}
