// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "../utils/Fixture.sol";

/// @notice One test per scenario so that `forge test --gas-report` lists every call. Each test also logs the
///         gas of the measured call (run with -vv to see the logs).
contract GasScenariosTest is Fixture {
    function setUp() public {
        _deploy(5_000 ether, 5_000e18);
        _fund(alice, 10_000 ether, 10_000e18);
        _fund(bob, 10_000 ether, 10_000e18);
        _fund(carol, 10_000 ether, 10_000e18);
    }

    function _logGas(string memory label, uint256 gasBefore) internal {
        emit log_named_uint(label, gasBefore - gasleft());
    }

    function test_GasAddIOUNoCycle() public {
        vm.prank(alice);
        uint256 g = gasleft();
        ledger.add_IOU(bob, 100, _noPath());
        _logGas("add_IOU, no cycle", g);
    }

    function test_GasAddIOUThreeNodeCycle() public {
        _iou(alice, bob, 100);
        _iou(bob, carol, 100);
        address[] memory path = _path(alice, bob, carol);
        vm.prank(carol);
        uint256 g = gasleft();
        ledger.add_IOU(alice, 60, path);
        _logGas("add_IOU, 3-node cycle", g);
        assertEq(ledger.lookup(carol, alice), 0);
    }

    function test_GasSettleWithTokens() public {
        _iou(alice, bob, 40);
        vm.prank(alice);
        uint256 g = gasleft();
        ledger.settleWithTokens(bob, 40);
        _logGas("settleWithTokens", g);
    }

    function test_GasSettleWithETH() public {
        _iou(alice, bob, 40);
        uint256 cap = exchange.quoteETHForExactTokens(40e18) * 105 / 100;
        vm.prank(alice);
        uint256 g = gasleft();
        ledger.settleWithETH{value: cap}(bob, 40);
        _logGas("settleWithETH (5% cap)", g);
    }

    function test_GasSwapETHForTokens() public {
        vm.prank(alice);
        uint256 g = gasleft();
        exchange.swapETHForTokens{value: 10 ether}(MAX);
        _logGas("swapETHForTokens", g);
    }

    function test_GasSwapTokensForETH() public {
        vm.prank(alice);
        uint256 g = gasleft();
        exchange.swapTokensForETH(10e18, MAX);
        _logGas("swapTokensForETH", g);
    }

    function test_GasAddLiquidity() public {
        vm.prank(bob);
        uint256 g = gasleft();
        exchange.addLiquidity{value: 100 ether}(MAX, 0);
        _logGas("addLiquidity (first deposit)", g);
    }

    function test_GasRemoveLiquidity() public {
        vm.prank(bob);
        exchange.addLiquidity{value: 100 ether}(MAX, 0);
        vm.prank(alice);
        exchange.swapETHForTokens{value: 10 ether}(MAX); // so that fees are paid on removal
        vm.prank(bob);
        uint256 g = gasleft();
        exchange.removeLiquidity(50 ether, MAX, 0);
        _logGas("removeLiquidity (with fee payout)", g);
    }

    function test_GasRemoveAllLiquidity() public {
        vm.prank(bob);
        exchange.addLiquidity{value: 100 ether}(MAX, 0);
        vm.prank(bob);
        uint256 g = gasleft();
        exchange.removeAllLiquidity(MAX, 0);
        _logGas("removeAllLiquidity", g);
    }
}
