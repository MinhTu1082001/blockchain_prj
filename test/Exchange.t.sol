// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {Exchange} from "../contracts/Exchange.sol";

contract ExchangeTest is Fixture {
    uint256 internal constant X0 = 5_000 ether;
    uint256 internal constant Y0 = 5_000e18;

    function setUp() public {
        _deploy(X0, Y0);
        _fund(alice, 100_000 ether, 100_000e18);
        _fund(bob, 100_000 ether, 100_000e18);
    }

    // ------------------------------------------------------------------ createPool

    function test_CreatePoolSetsState() public view {
        (uint256 x, uint256 y, uint256 s) = exchange.getPoolState();
        assertEq(x, X0);
        assertEq(y, Y0);
        assertEq(s, exchange.INITIAL_SHARES());
        assertEq(exchange.k(), X0 * Y0);
        assertEq(exchange.owner(), address(this));
        assertEq(exchange.shares(address(this)), 0, "initial shares belong to nobody");
        _assertExchangeSolvent();
    }

    function testRevert_CreatePoolTwice() public {
        token.mint(10e18);
        token.approve(address(exchange), 10e18);
        vm.expectRevert(bytes("pool exists"));
        exchange.createPool{value: 10 ether}(10e18);
    }

    function testRevert_CreatePoolNotOwner() public {
        Exchange fresh = new Exchange(address(token));
        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        fresh.createPool{value: 10 ether}(10e18);
    }

    function testRevert_CreatePoolBelowMinimum() public {
        Exchange fresh = new Exchange(address(token));
        token.mint(10e18);
        token.approve(address(fresh), 10e18);
        vm.expectRevert(bytes("below minimum"));
        fresh.createPool{value: 0.5 ether}(10e18);
    }

    // ------------------------------------------------------------------ swaps

    function test_SwapETHForTokensSpecExample() public {
        vm.prank(alice);
        uint256 out = exchange.swapETHForTokens{value: 100 ether}(MAX);
        assertEq(out, Y0 * 97 ether / (X0 + 97 ether), "y * net / (x + net)");
        assertApproxEqAbs(out, 95.15e18, 0.01e18, "~95.15 tokens");
        assertEq(token.balanceOf(alice), 100_000e18 + out);

        (uint256 x, uint256 y,) = exchange.getPoolState();
        assertEq(x, X0 + 97 ether, "only the net amount enters the reserve");
        assertEq(y, Y0 - out);
        assertEq(exchange.ethFeeReserve(), 3 ether, "3% fee goes to the fund");
        assertEq(exchange.accEthPerShare(), 3 ether * 1e18 / exchange.INITIAL_SHARES());
        assertEq(exchange.k(), X0 * Y0, "k is not reassigned by swaps");
        _assertExchangeSolvent();
    }

    function test_SwapTokensForETH() public {
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 out = exchange.swapTokensForETH(100e18, MAX);
        assertEq(out, X0 * 97e18 / (Y0 + 97e18));
        assertEq(alice.balance, ethBefore + out);
        assertEq(token.balanceOf(alice), 100_000e18 - 100e18);
        assertEq(exchange.tokenFeeReserve(), 3e18);
        assertEq(exchange.tokenReserve(), Y0 + 97e18);
        assertEq(exchange.k(), X0 * Y0);
        _assertExchangeSolvent();
    }

    function test_QuoteTokensForETHMatchesSwap() public {
        uint256 quote = exchange.quoteTokensForETH(42 ether);
        vm.prank(alice);
        uint256 out = exchange.swapETHForTokens{value: 42 ether}(MAX);
        assertEq(out, quote);
    }

    function test_QuoteETHForExactTokensSpecExample() public {
        uint256 ethIn = exchange.quoteETHForExactTokens(300e18);
        assertApproxEqAbs(ethIn, 329.02 ether, 0.01 ether, "~329.02 ETH");
        vm.prank(alice);
        uint256 out = exchange.swapETHForTokens{value: ethIn}(MAX);
        assertGe(out, 300e18, "the quote always buys at least the requested amount");
    }

    function testRevert_QuoteETHForExactTokensDrain() public {
        vm.expectRevert(bytes("drain"));
        exchange.quoteETHForExactTokens(Y0 - 1e18);
    }

    function test_SwapAtExactMaxRate() public {
        // 100 ETH buys 95.154... tokens: 100e18 * 1e5 / 95.154e18 = 105092
        vm.prank(alice);
        uint256 out = exchange.swapETHForTokens{value: 100 ether}(105_092);
        assertGt(out, 0);
    }

    function testRevert_SwapETHForTokensSlippage() public {
        vm.prank(alice);
        vm.expectRevert(bytes("slippage"));
        exchange.swapETHForTokens{value: 100 ether}(105_091);
    }

    function testRevert_SwapTokensForETHSlippage() public {
        vm.prank(alice);
        vm.expectRevert(bytes("slippage"));
        exchange.swapTokensForETH(100e18, 105_091);
    }

    function testRevert_SwapZeroOut() public {
        vm.prank(alice);
        vm.expectRevert(bytes("zero out"));
        exchange.swapETHForTokens{value: 1}(MAX);
    }

    /// I3: through any sequence of swaps x * y >= k, and swaps change neither k nor the shares.
    function testFuzz_SwapsKeepProductAboveK(uint256[6] memory amounts, bool[6] memory sellEth) public {
        uint256 k0 = exchange.k();
        uint256 s0 = exchange.totalShares();
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(amounts[i], 1e15, 2_000e18);
            vm.prank(alice);
            if (sellEth[i]) {
                exchange.swapETHForTokens{value: amount}(MAX);
            } else {
                exchange.swapTokensForETH(amount, MAX);
            }
            (uint256 x, uint256 y,) = exchange.getPoolState();
            assertGe(x * y, k0, "x * y >= k");
            assertEq(exchange.k(), k0, "k only changes on add/remove");
            assertEq(exchange.totalShares(), s0, "swaps do not change shares");
        }
        _assertExchangeSolvent();
    }

    // ------------------------------------------------------------------ liquidity

    function test_AddLiquidityGivesOneThird() public {
        _deploy(1_000 ether, 1_000e18);
        _fund(bob, 500 ether, 500e18);
        vm.prank(bob);
        exchange.addLiquidity{value: 500 ether}(MAX, 0);

        assertEq(exchange.shares(bob), 5e4);
        assertEq(exchange.totalShares(), 1.5e5);
        assertEq(exchange.shares(bob) * 3, exchange.totalShares(), "bob owns 1/3");
        assertEq(token.balanceOf(bob), 0, "exactly 500 tokens pulled");
        (uint256 x, uint256 y,) = exchange.getPoolState();
        assertEq(x, 1_500 ether);
        assertEq(y, 1_500e18);
        assertEq(exchange.k(), x * y, "k reset on add");
        _assertExchangeSolvent();
    }

    function test_AddLiquidityRoundsTokensUp() public {
        vm.prank(alice);
        exchange.swapETHForTokens{value: 7 ether}(MAX); // makes y / x non-integral
        (uint256 x, uint256 y,) = exchange.getPoolState();
        uint256 value = 3 ether + 1;
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        exchange.addLiquidity{value: value}(MAX, 0);
        uint256 pulled = before - token.balanceOf(bob);
        assertEq(pulled, (y * value + x - 1) / x, "ceilDiv(y * value, x)");
        assertGe(pulled * x, y * value, "the pool never gets less than its ratio");
    }

    function test_RemoveLiquidity() public {
        _deploy(1_000 ether, 1_000e18);
        _fund(bob, 500 ether, 500e18);
        vm.prank(bob);
        exchange.addLiquidity{value: 500 ether}(MAX, 0);

        vm.prank(bob);
        exchange.removeLiquidity(250 ether, MAX, 0);
        assertEq(exchange.shares(bob), 25_000, "burn = ceil(S * amount / x)");
        assertEq(exchange.totalShares(), 125_000);
        assertEq(bob.balance, 250 ether);
        assertEq(token.balanceOf(bob), 250e18);
        assertEq(exchange.k(), exchange.ethReserve() * exchange.tokenReserve(), "k reset on remove");
        _assertExchangeSolvent();
    }

    function test_RemoveAllLiquidityReturnsDeposit() public {
        _deploy(1_000 ether, 1_000e18);
        _fund(bob, 500 ether, 500e18);
        vm.prank(bob);
        exchange.addLiquidity{value: 500 ether}(MAX, 0);

        vm.prank(bob);
        exchange.removeAllLiquidity(MAX, 0);
        assertEq(exchange.shares(bob), 0);
        assertEq(exchange.totalShares(), exchange.INITIAL_SHARES());
        assertEq(bob.balance, 500 ether);
        assertEq(token.balanceOf(bob), 500e18);
        (uint256 x, uint256 y,) = exchange.getPoolState();
        assertEq(x, 1_000 ether);
        assertEq(y, 1_000e18);
    }

    function testRevert_AddLiquidityAboveMaxRate() public {
        vm.prank(alice);
        vm.expectRevert(bytes("rate"));
        exchange.addLiquidity{value: 10 ether}(99_999, 0); // pool rate is 1e5
    }

    function testRevert_AddLiquidityBelowMinRate() public {
        vm.prank(alice);
        vm.expectRevert(bytes("rate"));
        exchange.addLiquidity{value: 10 ether}(MAX, 100_001);
    }

    function testRevert_RemoveLiquidityOutsideRate() public {
        vm.prank(alice);
        exchange.addLiquidity{value: 10 ether}(MAX, 0);
        vm.prank(alice);
        vm.expectRevert(bytes("rate"));
        exchange.removeLiquidity(1 ether, 99_999, 0);
    }

    function testRevert_AddLiquidityTooSmall() public {
        vm.prank(alice);
        vm.expectRevert(bytes("too small"));
        exchange.addLiquidity{value: 0.01 ether}(MAX, 0); // 1e5 * 0.01 / 5000 rounds to 0 shares
    }

    function testRevert_RemoveMoreThanShares() public {
        vm.prank(alice);
        vm.expectRevert(bytes("insufficient shares"));
        exchange.removeLiquidity(1 ether, MAX, 0);
    }

    function testRevert_RemoveAllWithoutShares() public {
        vm.prank(alice);
        vm.expectRevert(bytes("no shares"));
        exchange.removeAllLiquidity(MAX, 0);
    }

    function testRevert_RemoveZero() public {
        vm.prank(alice);
        vm.expectRevert(bytes("zero amount"));
        exchange.removeLiquidity(0, MAX, 0);
    }
}
