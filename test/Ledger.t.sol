// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdError} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Ledger} from "../contracts/Ledger.sol";

contract LedgerTest is Fixture {
    function setUp() public {
        _deploy(5_000 ether, 5_000e18);
    }

    function test_LookupDefaultsToZero() public view {
        assertEq(ledger.lookup(alice, bob), 0);
    }

    function test_AddIOURecordsDebtAndEmits() public {
        vm.expectEmit(address(ledger));
        emit Ledger.IOUAdded(alice, bob, 100, 0);
        _iou(alice, bob, 100);
        assertEq(ledger.lookup(alice, bob), 100);
        assertEq(ledger.lookup(bob, alice), 0, "debts are directed");
    }

    function test_AddIOUAccumulates() public {
        _iou(alice, bob, 100);
        _iou(alice, bob, 50);
        assertEq(ledger.lookup(alice, bob), 150);
    }

    function test_NoCancellationWithoutProof() public {
        _iou(alice, bob, 50);
        _iou(bob, alice, 30);
        assertEq(ledger.lookup(alice, bob), 50);
        assertEq(ledger.lookup(bob, alice), 30);
    }

    /// Spec: A->B 50, then B owes A 30 with path [A, B]  =>  A->B 20, B->A 0.
    function test_TwoNodeCycle() public {
        _iou(alice, bob, 50);
        vm.expectEmit(address(ledger));
        emit Ledger.IOUAdded(bob, alice, 30, 30);
        vm.prank(bob);
        ledger.add_IOU(alice, 30, _path(alice, bob));
        assertEq(ledger.lookup(alice, bob), 20);
        assertEq(ledger.lookup(bob, alice), 0);
    }

    /// Spec: A->B 100, B->C 100, then C owes A 60 with path [A, B, C]  =>  A->B 40, B->C 40, C->A 0.
    function test_ThreeNodeCycle() public {
        _iou(alice, bob, 100);
        _iou(bob, carol, 100);
        vm.expectEmit(address(ledger));
        emit Ledger.IOUAdded(carol, alice, 60, 60);
        vm.prank(carol);
        ledger.add_IOU(alice, 60, _path(alice, bob, carol));
        assertEq(ledger.lookup(alice, bob), 40);
        assertEq(ledger.lookup(bob, carol), 40);
        assertEq(ledger.lookup(carol, alice), 0);
    }

    function test_CycleMinimumOnExistingEdge() public {
        _iou(alice, bob, 10);
        _iou(bob, carol, 20);
        vm.prank(carol);
        ledger.add_IOU(alice, 50, _path(alice, bob, carol));
        assertEq(ledger.lookup(alice, bob), 0, "the minimum edge is cleared");
        assertEq(ledger.lookup(bob, carol), 10);
        assertEq(ledger.lookup(carol, alice), 40);
    }

    function test_CycleIncludesExistingDebtOnNewEdge() public {
        _iou(carol, alice, 5);
        _iou(alice, bob, 100);
        _iou(bob, carol, 100);
        vm.prank(carol);
        ledger.add_IOU(alice, 60, _path(alice, bob, carol));
        assertEq(ledger.lookup(carol, alice), 0, "5 + 60 cancelled");
        assertEq(ledger.lookup(alice, bob), 35);
        assertEq(ledger.lookup(bob, carol), 35);
    }

    function test_EqualCycleClearsEverything() public {
        _iou(alice, bob, 30);
        _iou(bob, carol, 30);
        vm.prank(carol);
        ledger.add_IOU(alice, 30, _path(alice, bob, carol));
        assertEq(ledger.lookup(alice, bob), 0);
        assertEq(ledger.lookup(bob, carol), 0);
        assertEq(ledger.lookup(carol, alice), 0);
    }

    function testRevert_Uint32Overflow() public {
        _iou(alice, bob, type(uint32).max);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        ledger.add_IOU(bob, 1, _noPath());
        assertEq(ledger.lookup(alice, bob), type(uint32).max);
    }

    /// I1: after a valid cycle proof at least one edge is zero, every edge drops by the same m,
    /// and each member's net position (owed to them minus owed by them) is unchanged.
    function testFuzz_CycleZeroesAnEdgeAndKeepsNetPositions(uint32 ab, uint32 bc, uint32 ca) public {
        ab = uint32(bound(ab, 1, 1e9));
        bc = uint32(bound(bc, 1, 1e9));
        ca = uint32(bound(ca, 1, 1e9));
        _iou(alice, bob, ab);
        _iou(bob, carol, bc);
        vm.prank(carol);
        ledger.add_IOU(alice, ca, _path(alice, bob, carol));

        uint32 nab = ledger.lookup(alice, bob);
        uint32 nbc = ledger.lookup(bob, carol);
        uint32 nca = ledger.lookup(carol, alice);
        assertTrue(nab == 0 || nbc == 0 || nca == 0, "some edge cleared");
        uint256 m = ab - nab;
        assertEq(bc - nbc, m, "same m on every edge");
        assertEq(ca - nca, m, "same m on the new edge");
        assertEq(int256(uint256(nca)) - int256(uint256(nab)), int256(uint256(ca)) - int256(uint256(ab)), "net(A)");
        assertEq(int256(uint256(nab)) - int256(uint256(nbc)), int256(uint256(ab)) - int256(uint256(bc)), "net(B)");
    }
}
