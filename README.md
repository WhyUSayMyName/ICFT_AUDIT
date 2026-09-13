# ICFT Protocol, Security Review

Independent security review of the ICFT lending protocol, with executable proofs for every finding of medium severity and above.

**Auditor:** WhyUSayMyName · [github](https://github.com/WhyUSayMyName) · [x.com/WhyUSayMyNamee](https://x.com/WhyUSayMyNamee)
**Date:** 12 September 2026 · **Commit reviewed:** `7135745` · **Scope:** 1,403 nSLOC across 13 files

> Published with the client's consent. The protocol was not deployed to mainnet at the time of review, and the team is addressing these findings before deployment. The `open` status reflects the state as of the review date.

## Results

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 4 |
| Medium | 5 |
| Low | 7 |
| Informational | 3 |

No critical findings: every path to a loss of funds requires a privileged key, and the centralised control model is recorded in the project specification as a deliberate MVP state.

### High severity

| ID | Finding |
|---|---|
| **H-01** | The ICFT price is set by a single role instantly and without limits, which allows value to be drained from Fund A |
| **H-02** | Uncovered debt survives after all collateral is seized, and nothing can write it off |
| **H-03** | A liquidator bonus that passes validation disables liquidation entirely |
| **H-04** | Any contract implementation can be replaced by one key in the same block, with no delay |

## Reports

- [ICFT-security-review-EN.pdf](report/ICFT-security-review-EN.pdf), 50 pages
- [ICFT-security-review-RU.pdf](report/ICFT-security-review-RU.pdf), 51 pages

Both contain the same content: executive summary, scope, methodology, system overview, trust model, code maturity assessment, all 19 findings, an invariant appendix and a static analysis appendix.

## Reproducing the findings

Every finding of medium severity and above is backed by an executable test rather than an argument. The proofs live in [`proofs/`](proofs/) and are written for Foundry.

```bash
forge test --match-path "test/audit/*"      # 37 tests
forge test --mt test_P3_05_badDebtSurvivesFullLiquidation -vv
```

The `-vv` flag prints the concrete numbers: residual debt, LTV, collateral seized.

### Finding to proof mapping

| Finding | Proof |
|---|---|
| **H-01** | `test_S3_manipulateDownAtBorrow_freeTokens`, `test_S4_manipulateUpAtRepay_cheapClose`, `test_PoC_ORA2_manualPrice_unbounded_and_drainsFundA` |
| **H-02** | `test_P3_05_badDebtSurvivesFullLiquidation`, `test_PoC_LIQ3_badDebtPersistsAfterFullSeizure` |
| **H-03** | `test_P3_AC3_highBonusBricksLiquidation`, `test_PoC_AC3_looseParameterBounds` |
| **H-04** | `test_P3_AC2_instantUpgradeNoTimelock`, `test_PoC_AC2_upgradeBreaksFixedSupply` |
| **M-01** | `test_F2_07_utilizationDistortedWithTwoBorrowers`, `test_PoC_F2_07_fundAConservationBreaksOnPriceDrop` |
| **M-02** | `test_P3_AC4_freezeLocksCollateralWhileInterestAccrues` |
| **M-03** | `test_P3_FUND2_revenueAccumulatesAndIsLocked` |
| **M-04** | `test_P3_03_dustBorrowAccepted` |
| **L-01** | `test_PoC_F2_03_staleFeedTrapsCollateral` |
| **L-02** | `test_P3_LIQ2_targetEqualsThreshold_stuckPosition` |
| **I-03** | `test_PoC_07_interestCompoundsVsSimple` |

The remaining findings are structural and are verified by reading the code or from static analysis output.

### Invariants

`AuditInvariants.t.sol` runs stateful fuzzing over the protocol. The handler also moves prices, which is what distinguishes it from the suite that already existed in the project.

Eight properties hold. Two fail and point at findings:

- **INV-08**, conservation of Fund A tokens, fails and corresponds to M-01
- **INV-09**, full closure of a position whose collateral is below its debt, fails and corresponds to H-02

Both are worth keeping in CI as regression guards: once M-01 and H-02 are fixed they should turn green and stay that way.

### Models

```bash
python proofs/models/economic_sim.py     # economic stress scenarios
python proofs/models/reference_model.py  # reference formulas for differential testing
```

`economic_sim.py` produces the numbers quoted in H-02, including the observation that a 40 percent drop in ETH makes roughly 94 percent of a maximally leveraged position book liquidatable. `reference_model.py` is an independent implementation of the LTV, interest accrual and partial liquidation formulas; `Differential.t.sol` compares the contract against it on random inputs.

## Method

The review ran for twelve days and combined line by line manual review, static analysis with Slither and solhint, stateful invariant fuzzing, differential testing against a reference model, and numerical economic scenarios.

Two points worth noting about the process.

**Findings were validated adversarially before publication.** A dedicated pass re-checked every finding against the source and against the project specification. Several were corrected, one was downgraded, and seven were reclassified as intended behaviour rather than defects. `ValidateFindings.t.sol` contains that work. The most useful correction: H-03 was originally written as "a 100 percent bonus lets a liquidator seize double", which turned out to be wrong. The real effect is an arithmetic overflow that disables liquidation protocol wide, and it triggers at a far more plausible value of around 17.6 percent.

**The governing document matters.** The review was conducted against `docs/MVP_SPEC.md`, the engineering specification in the repository. The external whitepaper describes the protocol differently in several places, and those divergences are collected in finding I-02 rather than being reported as code defects.

## Contents

```
report/     both language versions of the report
proofs/
  test/audit/     Foundry tests: invariants, per finding proofs, stress scenarios, differential
  test/helpers/   shared fixture that deploys the protocol behind proxies
  models/         Python reference model and economic scenarios
```

## Notes on running the proofs

The project does not build from a clean checkout, which is finding L-03 in the report. Two dependency files need to be present for the imports to resolve, and `script/` has to be excluded from compilation because an emoji sits inside an ordinary string literal. The report describes the proper fix; the tests themselves are unaffected once the project compiles.

## License

| Content | License |
|---|---|
| [`proofs/`](proofs/), tests and models | [MIT](LICENSE) |
| [`report/`](report/), the PDF documents | [CC BY-ND 4.0](LICENSE-REPORT.md) |

The code is free to reuse. The reports may be shared in full with attribution but
not redistributed in modified form, which matches the publication terms stated
inside the documents.

---

Findings are published as of the review date. This report is not an endorsement of the project, and a security review reduces risk without eliminating it.
