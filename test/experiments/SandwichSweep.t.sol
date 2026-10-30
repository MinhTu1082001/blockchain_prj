// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "../utils/Fixture.sol";

/// @notice Sandwich experiment on a fresh 5,000 ETH / 5,000 CSU pool for every (s, F):
///         Alice signs settleWithETH(300 CSU) with cap = quote * (100 + s) / 100, Sam front-runs with F ETH,
///         Alice's transaction runs, then Sam sells every token he bought (also when Alice reverted).
///         Writes out-experiments/sandwich.csv with columns s,F,alice_eth_paid,reverted,sam_profit_eth.
contract SandwichSweepTest is Fixture {
    string internal constant CSV = "out-experiments/sandwich.csv";
    uint32 internal constant DEBT = 300;

    address internal sam = makeAddr("sam");

    function test_SandwichSweep() public {
        uint256[6] memory caps = [uint256(0), 1, 2, 5, 10, 25];
        uint256[4] memory fronts = [uint256(50), 100, 200, 500];
        vm.createDir("out-experiments", true);
        vm.writeFile(CSV, "s,F,alice_eth_paid,reverted,sam_profit_eth\n");
        for (uint256 i = 0; i < caps.length; i++) {
            for (uint256 j = 0; j < fronts.length; j++) {
                _row(caps[i], fronts[j]);
            }
        }
    }

    /// Remark 2 from the other side: when the victim's trade is small (50 CSU = 1% of the pool), its price
    /// impact is below the ~6% round-trip fee, so the sandwich loses even when the cap lets Alice through.
    function test_SandwichOnSmallDebtLoses() public {
        uint256[4] memory fronts = [uint256(50), 100, 200, 500];
        for (uint256 j = 0; j < fronts.length; j++) {
            (, bool reverted, int256 profit) = _sandwich(50, 25, fronts[j] * 1 ether);
            assertFalse(reverted, "a 25% cap lets Alice through");
            assertLt(profit, 0, "the sandwich loses money");
        }
    }

    function _row(uint256 s, uint256 front) internal {
        (uint256 paid, bool reverted, int256 profit) = _sandwich(DEBT, s, front * 1 ether);
        string memory row = string.concat(vm.toString(s), ",", vm.toString(front), ",", _eth(int256(paid)));
        row = string.concat(row, ",", reverted ? string("1") : string("0"), ",", _eth(profit));
        vm.writeLine(CSV, row);

        if (reverted) {
            // Remark 2: a blocked sandwich costs Sam the round-trip fee, about 6% of F
            assertLt(profit, 0, "blocked sandwich loses");
            assertApproxEqRel(uint256(-profit), front * 0.06 ether, 0.1e18, "loss ~ 6% of F");
        } else {
            assertEq(token.balanceOf(bob), uint256(DEBT) * 1e18, "creditor paid in full");
        }
    }

    /// @dev Runs one sandwich on a fresh deployment. `s` is Alice's cap in percent, `front` Sam's ETH.
    function _sandwich(uint32 debt, uint256 s, uint256 front)
        internal
        returns (uint256 alicePaid, bool reverted, int256 samProfit)
    {
        _deploy(5_000 ether, 5_000e18);
        _fund(sam, front, 0);
        _iou(alice, bob, debt);
        // Alice signs before the attack: her cap comes from the honest quote
        uint256 cap = exchange.quoteETHForExactTokens(uint256(debt) * 1e18) * (100 + s) / 100;
        vm.deal(alice, cap);

        vm.prank(sam);
        uint256 samTokens = exchange.swapETHForTokens{value: front}(MAX);

        vm.prank(alice);
        try ledger.settleWithETH{value: cap}(bob, debt) {
            alicePaid = cap - alice.balance;
        } catch {
            reverted = true;
        }

        vm.prank(sam);
        samProfit = int256(exchange.swapTokensForETH(samTokens, MAX)) - int256(front);
        _assertLedgerEmpty();
    }

    /// @dev Formats wei as ETH with 6 decimals (truncated), e.g. -2.941437.
    function _eth(int256 v) internal pure returns (string memory) {
        uint256 a = uint256(v < 0 ? -v : v);
        string memory frac = vm.toString((a % 1 ether) / 1e12);
        while (bytes(frac).length < 6) {
            frac = string.concat("0", frac);
        }
        return string.concat(v < 0 ? string("-") : string(""), vm.toString(a / 1 ether), ".", frac);
    }
}
