// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Ledger} from "../contracts/Ledger.sol";

contract SettleTest is Fixture {
    function setUp() public {
        _deploy(5_000 ether, 5_000e18);
        _fund(alice, 10_000 ether, 1_000e18);
        _iou(alice, bob, 40);
    }

    // ------------------------------------------------------------------ settleWithTokens

    function test_SettleWithTokensPaysCreditor() public {
        vm.expectEmit(address(ledger));
        emit Ledger.Settled(alice, bob, 40, false, 0);
        vm.prank(alice);
        ledger.settleWithTokens(bob, 40);
        assertEq(token.balanceOf(bob), 40e18, "creditor + amount * UNIT");
        assertEq(token.balanceOf(alice), 960e18);
        assertEq(ledger.lookup(alice, bob), 0);
        _assertLedgerEmpty();
    }

    function test_SettleWithTokensPartially() public {
        vm.prank(alice);
        ledger.settleWithTokens(bob, 15);
        assertEq(ledger.lookup(alice, bob), 25);
        assertEq(token.balanceOf(bob), 15e18);
    }

    function testRevert_SettleWithTokensMoreThanDebt() public {
        vm.prank(alice);
        vm.expectRevert(bytes("no such debt"));
        ledger.settleWithTokens(bob, 41);
        assertEq(ledger.lookup(alice, bob), 40);
    }

    function testRevert_SettleWithTokensWithoutAllowance() public {
        vm.prank(alice);
        token.approve(address(ledger), 0);
        bytes4 selector = IERC20Errors.ERC20InsufficientAllowance.selector;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(selector, address(ledger), 0, 40e18));
        ledger.settleWithTokens(bob, 40);
        assertEq(ledger.lookup(alice, bob), 40, "debt unchanged");
    }

    // ------------------------------------------------------------------ settleWithETH

    function test_SettleWithETHPaysExactTokensAndRefunds() public {
        uint256 quote = exchange.quoteETHForExactTokens(40e18);
        uint256 ethBefore = alice.balance;
        uint256 tokBefore = token.balanceOf(alice);
        vm.prank(alice);
        ledger.settleWithETH{value: quote * 105 / 100}(bob, 40);
        assertEq(token.balanceOf(bob), 40e18, "creditor gets exactly amount * UNIT");
        assertEq(ledger.lookup(alice, bob), 0, "debt reduced");
        assertEq(ethBefore - alice.balance, quote, "debtor pays the quote; the rest is refunded");
        assertGe(token.balanceOf(alice), tokBefore, "surplus tokens go back to the debtor");
        _assertLedgerEmpty();
        _assertExchangeSolvent();
    }

    function test_SettleWithETHEmitsSettled() public {
        uint256 quote = exchange.quoteETHForExactTokens(40e18);
        vm.expectEmit(address(ledger));
        emit Ledger.Settled(alice, bob, 40, true, quote);
        vm.prank(alice);
        ledger.settleWithETH{value: quote}(bob, 40);
    }

    function testRevert_SettleWithETHOverCap() public {
        uint256 quote = exchange.quoteETHForExactTokens(40e18);
        vm.prank(alice);
        vm.expectRevert(bytes("over cap"));
        ledger.settleWithETH{value: quote - 1}(bob, 40);
        assertEq(ledger.lookup(alice, bob), 40, "debt unchanged");
        assertEq(token.balanceOf(bob), 0);
    }

    function testRevert_SettleWithETHWithoutDebt() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes("no such debt"));
        ledger.settleWithETH{value: 1 ether}(alice, 1);
    }

    function testRevert_SettleWithETHZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(bytes("no such debt"));
        ledger.settleWithETH{value: 1 ether}(bob, 0);
    }

    /// I2 + I6: for any amount and cap, the creditor receives exactly amount * UNIT and the Ledger ends empty.
    function testFuzz_SettleWithETHPaysExactly(uint32 amount, uint256 slippage) public {
        uint32 amt = uint32(bound(amount, 1, 1_000));
        _iou(alice, carol, amt);
        uint256 quote = exchange.quoteETHForExactTokens(uint256(amt) * 1e18);
        uint256 cap = quote + quote * bound(slippage, 0, 50) / 100;
        vm.deal(alice, cap);
        vm.prank(alice);
        ledger.settleWithETH{value: cap}(carol, amt);
        assertEq(token.balanceOf(carol), uint256(amt) * 1e18);
        assertEq(alice.balance, cap - quote, "refund");
        assertEq(ledger.lookup(alice, carol), 0);
        _assertLedgerEmpty();
    }

    /// Phase 6 scenario: A owes B 100, B owes C 100, C owes A 60 (cycle) => A->B 40, B->C 40;
    /// then A settles 40 with ETH and a 5% cap => B +40 CSU, Ledger empty.
    function test_ScenarioABC() public {
        _iou(alice, bob, 60); // 40 from setUp + 60 = 100
        _iou(bob, carol, 100);
        vm.prank(carol);
        ledger.add_IOU(alice, 60, _path(alice, bob, carol));
        assertEq(ledger.lookup(alice, bob), 40);
        assertEq(ledger.lookup(bob, carol), 40);
        assertEq(ledger.lookup(carol, alice), 0);

        uint256 cap = exchange.quoteETHForExactTokens(40e18) * 105 / 100;
        vm.prank(alice);
        ledger.settleWithETH{value: cap}(bob, 40);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(ledger.lookup(alice, bob), 0);
        _assertLedgerEmpty();
    }
}
