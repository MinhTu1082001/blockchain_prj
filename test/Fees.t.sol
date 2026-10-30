// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";

contract FeesTest is Fixture {
    /// @dev Swap sizes (whole ETH or tokens) used in each fee phase.
    uint256[10] internal amounts = [uint256(10), 25, 40, 15, 30, 5, 50, 20, 35, 45];

    function setUp() public {
        _deploy(1_000 ether, 1_000e18); // LP0 = this contract; its INITIAL_SHARES belong to nobody
        _fund(alice, 10_000 ether, 10_000e18);
        _fund(bob, 10_000 ether, 10_000e18);
        _fund(carol, 1_000_000 ether, 1_000_000e18); // the trader
    }

    /// @dev Ten swaps by carol alternating direction; `ethFirst` picks the direction of the first one.
    function _tenSwaps(bool ethFirst) internal {
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i] * 1e18;
            vm.prank(carol);
            if ((i % 2 == 0) == ethFirst) {
                exchange.swapETHForTokens{value: amount}(MAX);
            } else {
                exchange.swapTokensForETH(amount, MAX);
            }
        }
    }

    function test_AccumulatorTracksEachSwap() public {
        vm.prank(carol);
        exchange.swapETHForTokens{value: 10 ether}(MAX);
        uint256 fee = 10 ether * 3 / 100;
        assertEq(exchange.ethFeeReserve(), fee);
        assertEq(exchange.accEthPerShare(), fee * 1e18 / exchange.totalShares());

        vm.prank(carol);
        exchange.swapTokensForETH(10e18, MAX);
        assertEq(exchange.tokenFeeReserve(), fee);
        assertEq(exchange.accTokenPerShare(), fee * 1e18 / exchange.totalShares());
        _assertExchangeSolvent();
    }

    /// Spec scenario: LP0 creates the pool; 10 swaps; Bob adds 50%; 10 more swaps; Bob withdraws.
    /// Bob gets ~1/3 of the phase-2 fees (error <= 1 wei per rounding) and nothing from phase 1.
    function test_LateLPEarnsOnlyFeesAfterJoining() public {
        _tenSwaps(true);
        uint256 ethFees1 = exchange.ethFeeReserve();
        uint256 tokenFees1 = exchange.tokenFeeReserve();
        assertGt(ethFees1, 0);
        assertGt(tokenFees1, 0);

        uint256 x = exchange.ethReserve();
        vm.prank(bob);
        exchange.addLiquidity{value: (x + 1) / 2}(MAX, 0); // half of the pool, rounded up
        assertEq(exchange.shares(bob) * 3, exchange.totalShares(), "bob owns exactly 1/3");
        (uint256 pe, uint256 pt) = exchange.pendingFees(bob);
        assertEq(pe + pt, 0, "phase-1 fees are not bob's");

        _tenSwaps(false);
        uint256 ethFees2 = exchange.ethFeeReserve() - ethFees1;
        uint256 tokenFees2 = exchange.tokenFeeReserve() - tokenFees1;
        (pe, pt) = exchange.pendingFees(bob);
        assertApproxEqAbs(pe, ethFees2 / 3, 1, "1/3 of phase-2 ETH fees");
        assertApproxEqAbs(pt, tokenFees2 / 3, 1, "1/3 of phase-2 token fees");

        uint256 fundBefore = exchange.ethFeeReserve();
        _removeAllAndCheck(bob, pe, pt);
        assertEq(fundBefore - exchange.ethFeeReserve(), pe, "fees leave the fund exactly once");
        assertGe(exchange.ethFeeReserve(), ethFees1, "phase-1 ETH fees stay in the fund");
        assertGe(exchange.tokenFeeReserve(), tokenFees1, "phase-1 token fees stay in the fund");
        _assertExchangeSolvent();
    }

    function test_PendingFeesPaidOnAddLiquidity() public {
        vm.prank(bob);
        exchange.addLiquidity{value: 100 ether}(MAX, 0);
        _tenSwaps(true);
        (uint256 pe, uint256 pt) = exchange.pendingFees(bob);
        assertGt(pe, 0);
        assertGt(pt, 0);

        uint256 tokensNeeded = (exchange.tokenReserve() * 1 ether + exchange.ethReserve() - 1) / exchange.ethReserve();
        uint256 ethBefore = bob.balance;
        uint256 tokBefore = token.balanceOf(bob);
        vm.prank(bob);
        exchange.addLiquidity{value: 1 ether}(MAX, 0);
        assertEq(bob.balance, ethBefore - 1 ether + pe, "ETH fees paid out");
        assertEq(token.balanceOf(bob), tokBefore - tokensNeeded + pt, "token fees paid out");
        (pe, pt) = exchange.pendingFees(bob);
        assertEq(pe + pt, 0, "debt re-anchored after the payout");
        _assertExchangeSolvent();
    }

    function test_FeesSplitProRataBetweenLPs() public {
        vm.prank(alice);
        exchange.addLiquidity{value: 200 ether}(MAX, 0);
        vm.prank(bob);
        exchange.addLiquidity{value: 120 ether}(MAX, 0);
        assertEq(exchange.shares(alice) * 3, exchange.shares(bob) * 5, "alice : bob = 5 : 3");

        _tenSwaps(true); // the fee fund was empty before these swaps
        uint256 total = exchange.totalShares();
        uint256 feeEth = exchange.ethFeeReserve();
        uint256 feeTok = exchange.tokenFeeReserve();
        (uint256 ae, uint256 at) = exchange.pendingFees(alice);
        (uint256 be, uint256 bt) = exchange.pendingFees(bob);
        assertApproxEqAbs(ae, feeEth * exchange.shares(alice) / total, 1);
        assertApproxEqAbs(at, feeTok * exchange.shares(alice) / total, 1);
        assertApproxEqAbs(be, feeEth * exchange.shares(bob) / total, 1);
        assertApproxEqAbs(bt, feeTok * exchange.shares(bob) / total, 1);
        assertLe(ae + be, feeEth, "I7 for ETH");
        assertLe(at + bt, feeTok, "I7 for tokens");
    }

    /// Rounding lemma: swapping exactly quoteETHForExactTokens(t) always returns at least t.
    function testFuzz_ExactOutQuoteSuffices(uint256 x, uint256 y, uint256 t) public {
        x = bound(x, 100 ether, 1e8 ether);
        y = bound(y, 100e18, 1e26);
        _deploy(x, y);
        t = bound(t, 1, y - exchange.MIN_TOKEN() - 1);
        uint256 ethIn = exchange.quoteETHForExactTokens(t);
        vm.deal(alice, ethIn);
        vm.prank(alice);
        uint256 out = exchange.swapETHForTokens{value: ethIn}(MAX);
        assertGe(out, t);
    }

    function _removeAllAndCheck(address lp, uint256 pe, uint256 pt) internal {
        uint256 amountETH = exchange.ethReserve() * exchange.shares(lp) / exchange.totalShares();
        uint256 tokensOut = exchange.tokenReserve() * amountETH / exchange.ethReserve();
        uint256 ethBefore = lp.balance;
        uint256 tokBefore = token.balanceOf(lp);
        vm.prank(lp);
        exchange.removeAllLiquidity(MAX, 0);
        assertEq(lp.balance - ethBefore, amountETH + pe, "principal + ETH fees");
        assertEq(token.balanceOf(lp) - tokBefore, tokensOut + pt, "principal + token fees");
        assertEq(exchange.shares(lp), 0);
    }
}
