// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Token} from "../contracts/Token.sol";

contract TokenTest is Test {
    Token internal token;
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new Token("ClearSwap Unit", "CSU");
    }

    function test_Metadata() public view {
        assertEq(token.name(), "ClearSwap Unit");
        assertEq(token.symbol(), "CSU");
        assertEq(uint256(token.decimals()), 18);
        assertEq(token.owner(), address(this));
        assertTrue(token.mintable());
    }

    function test_MintByOwner() public {
        token.mint(1_000e18);
        assertEq(token.balanceOf(address(this)), 1_000e18);
        assertEq(token.totalSupply(), 1_000e18);
    }

    function testRevert_MintByNonOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        token.mint(1);
        assertEq(token.totalSupply(), 0);
    }

    function testRevert_MintAfterDisable() public {
        token.mint(5e18);
        token.disable_mint();
        assertFalse(token.mintable());
        vm.expectRevert(bytes("mint disabled"));
        token.mint(1);
        assertEq(token.totalSupply(), 5e18);
    }

    function testRevert_DisableMintByNonOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        token.disable_mint();
        assertTrue(token.mintable());
    }

    function test_DisableMintIsPermanent() public {
        token.disable_mint();
        token.disable_mint();
        assertFalse(token.mintable());
        vm.expectRevert(bytes("mint disabled"));
        token.mint(1);
    }

    function testFuzz_MintAccumulates(uint128 a, uint128 b) public {
        token.mint(a);
        token.mint(b);
        assertEq(token.balanceOf(address(this)), uint256(a) + uint256(b));
    }
}
