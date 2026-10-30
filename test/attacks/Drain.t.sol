// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "../utils/Fixture.sol";

/// @notice Every way of pushing the reserves below 1 ETH / 1 token must revert (I4).
contract DrainTest is Fixture {
    address internal whale = makeAddr("whale");

    function setUp() public {
        _deploy(5_000 ether, 5_000e18);
        _fund(whale, 40_000_000 ether, 40_000_000e18);
    }

    function testRevert_SwapETHBelowTokenMinimum() public {
        // 30M ETH would buy ~4,999.14 tokens and leave ~0.86 token in the pool
        vm.prank(whale);
        vm.expectRevert(bytes("drain"));
        exchange.swapETHForTokens{value: 30_000_000 ether}(MAX);
    }

    function testRevert_SwapTokensBelowEthMinimum() public {
        vm.prank(whale);
        vm.expectRevert(bytes("drain"));
        exchange.swapTokensForETH(30_000_000e18, MAX);
    }

    function testRevert_ExactOutQuoteBelowTokenMinimum() public {
        vm.expectRevert(bytes("drain"));
        exchange.quoteETHForExactTokens(4_999e18);
    }

    function testRevert_SettleWithETHCannotDrainPool() public {
        _iou(alice, bob, 4_999);
        vm.deal(alice, 1_000_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("drain"));
        ledger.settleWithETH{value: 1_000_000_000 ether}(bob, 4_999);
        assertEq(ledger.lookup(alice, bob), 4_999, "debt unchanged");
    }

    function testRevert_RemoveLiquidityBelowEthMinimum() public {
        _deploy(1 ether, 1e18);
        _fund(alice, 1_000 ether, 1_000e18);
        vm.prank(alice);
        exchange.addLiquidity{value: 1_000 ether}(MAX, 0); // x = 1,001 ETH
        vm.prank(alice);
        vm.expectRevert(bytes("drain"));
        exchange.removeLiquidity(1000.5 ether, MAX, 0);
    }

    function testRevert_RemoveAllLiquidityBelowEthMinimum() public {
        _deploy(1 ether, 1e18);
        _fund(alice, 1_000 ether, 1_000e18);
        _fund(whale, 0, 10e18);
        vm.prank(alice);
        exchange.addLiquidity{value: 1_000 ether}(MAX, 0);
        // a trade lowers x, so alice's 99.9% share of it is more than x - 1 ETH
        vm.prank(whale);
        exchange.swapTokensForETH(10e18, MAX);
        vm.prank(alice);
        vm.expectRevert(bytes("drain"));
        exchange.removeAllLiquidity(MAX, 0);
    }

    function test_DominantLPCanExitDownToTheMinimum() public {
        _deploy(1 ether, 1e18);
        _fund(alice, 1_000 ether, 1_000e18);
        vm.prank(alice);
        exchange.addLiquidity{value: 1_000 ether}(MAX, 0);
        vm.prank(alice);
        exchange.removeAllLiquidity(MAX, 0);
        (uint256 x, uint256 y, uint256 s) = exchange.getPoolState();
        assertEq(x, 1 ether, "unowned initial shares keep the minimum");
        assertEq(y, 1e18);
        assertEq(s, exchange.INITIAL_SHARES());
        assertEq(alice.balance, 1_000 ether);
    }

    function testRevert_DustWithdrawalWithoutShares() public {
        // burn = ceil(S * 1 wei / x) = 1 share, so a zero-share account cannot take even 1 wei
        vm.prank(whale);
        vm.expectRevert(bytes("insufficient shares"));
        exchange.removeLiquidity(1, MAX, 0);
    }

    function test_DustWithdrawalStillBurnsAShare() public {
        vm.prank(whale);
        exchange.addLiquidity{value: 1_000 ether}(MAX, 0);
        uint256 sharesBefore = exchange.shares(whale);
        vm.prank(whale);
        exchange.removeLiquidity(1, MAX, 0);
        assertEq(exchange.shares(whale), sharesBefore - 1, "rounding favours the pool");
        _assertExchangeSolvent();
    }

    /// I4: whatever single swap is attempted, the reserves never drop below the minimums.
    function testFuzz_SwapsNeverBreakMinimums(uint256 amount, bool sellEth) public {
        amount = bound(amount, 1, 40_000_000e18);
        vm.prank(whale);
        if (sellEth) {
            try exchange.swapETHForTokens{value: amount}(MAX) {} catch {}
        } else {
            try exchange.swapTokensForETH(amount, MAX) {} catch {}
        }
        (uint256 x, uint256 y,) = exchange.getPoolState();
        assertGe(x, exchange.MIN_ETH());
        assertGe(y, exchange.MIN_TOKEN());
        _assertExchangeSolvent();
    }
}
