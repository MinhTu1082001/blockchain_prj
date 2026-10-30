// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "../utils/Fixture.sol";

/// @notice Forged cycle proofs must revert and leave every debt untouched.
contract FakePathTest is Fixture {
    address internal dave = makeAddr("dave");

    function setUp() public {
        _deploy(5_000 ether, 5_000e18);
        _iou(alice, bob, 100);
        _iou(bob, carol, 100);
    }

    /// @dev `sender` adds an IOU to `creditor` with `path`; expects `reason` and unchanged debts.
    function _expectRejected(
        address sender,
        address creditor,
        uint32 amount,
        address[] memory path,
        bytes memory reason
    ) internal {
        vm.prank(sender);
        vm.expectRevert(reason);
        ledger.add_IOU(creditor, amount, path);
        assertEq(ledger.lookup(alice, bob), 100, "A->B unchanged");
        assertEq(ledger.lookup(bob, carol), 100, "B->C unchanged");
        assertEq(ledger.lookup(sender, creditor), 0, "no new debt");
    }

    function test_ValidPathIsAccepted() public {
        vm.prank(carol);
        ledger.add_IOU(alice, 60, _path(alice, bob, carol));
        assertEq(ledger.lookup(alice, bob), 40);
    }

    function testRevert_PathNotStartingAtCreditor() public {
        _expectRejected(carol, alice, 60, _path(bob, carol), bytes("bad endpoints"));
    }

    function testRevert_PathNotEndingAtSender() public {
        _expectRejected(carol, alice, 60, _path(alice, bob), bytes("bad endpoints"));
    }

    function testRevert_PathWithZeroEdge() public {
        _expectRejected(carol, alice, 60, _path(alice, carol), bytes("edge"));
    }

    function testRevert_PathThroughStranger() public {
        _expectRejected(carol, alice, 60, _path(alice, dave, carol), bytes("edge"));
    }

    function testRevert_PathAgainstDebtDirection() public {
        // alice owes bob and bob owes carol, so carol -> bob -> alice follows no debt
        _expectRejected(alice, carol, 60, _path(carol, bob, alice), bytes("edge"));
    }

    function testRevert_ForgedCycleCannotCancelThirdPartyDebt() public {
        address[] memory path = new address[](4);
        path[0] = alice;
        path[1] = bob;
        path[2] = carol;
        path[3] = dave; // carol does not owe dave
        _expectRejected(dave, alice, 1, path, bytes("edge"));
    }

    function testRevert_PathWithRepeatedNode() public {
        address[] memory path = new address[](5);
        path[0] = alice;
        path[1] = bob;
        path[2] = alice;
        path[3] = bob;
        path[4] = carol;
        _expectRejected(carol, alice, 60, path, bytes("repeated node"));
    }

    function testRevert_PathWithAdjacentDuplicate() public {
        address[] memory path = new address[](4);
        path[0] = alice;
        path[1] = bob;
        path[2] = bob;
        path[3] = carol;
        _expectRejected(carol, alice, 60, path, bytes("repeated node"));
    }

    function testRevert_PathTooLong() public {
        address[] memory path = new address[](11);
        path[0] = alice;
        for (uint256 i = 1; i < 10; i++) {
            path[i] = makeAddr(string.concat("node", vm.toString(i)));
        }
        path[10] = carol;
        _expectRejected(carol, alice, 60, path, bytes("path too long"));
    }

    function testRevert_ZeroAmount() public {
        _expectRejected(carol, alice, 0, _path(alice, bob, carol), bytes("zero amount"));
    }

    function testRevert_SelfAsCreditor() public {
        _expectRejected(carol, carol, 10, _noPath(), bytes("bad creditor"));
    }

    function testRevert_ZeroAddressCreditor() public {
        _expectRejected(carol, address(0), 10, _noPath(), bytes("bad creditor"));
    }
}
