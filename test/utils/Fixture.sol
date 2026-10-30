// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../contracts/Token.sol";
import {Exchange} from "../../contracts/Exchange.sol";
import {Ledger} from "../../contracts/Ledger.sol";

/// @notice Shared deployment helpers. The test contract owns the token and creates the pool, so it holds
///         no LP shares (INITIAL_SHARES belong to nobody).
abstract contract Fixture is Test {
    uint256 internal constant MAX = type(uint256).max;

    Token internal token;
    Exchange internal exchange;
    Ledger internal ledger;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    receive() external payable {}

    /// @dev Deploys Token, Exchange and Ledger and seeds the pool with `eth` wei and `tokens` CSU.
    function _deploy(uint256 eth, uint256 tokens) internal {
        token = new Token("ClearSwap Unit", "CSU");
        exchange = new Exchange(address(token));
        ledger = new Ledger(address(token), address(exchange));
        token.mint(tokens);
        token.approve(address(exchange), tokens);
        exchange.createPool{value: eth}(tokens);
    }

    /// @dev Sets `who`'s ETH balance, mints `tokens` to it and approves the Exchange and the Ledger.
    function _fund(address who, uint256 eth, uint256 tokens) internal {
        vm.deal(who, eth);
        if (tokens > 0) {
            token.mint(tokens);
            require(token.transfer(who, tokens), "fund");
        }
        vm.startPrank(who);
        token.approve(address(exchange), MAX);
        token.approve(address(ledger), MAX);
        vm.stopPrank();
    }

    /// @dev `debtor` records an IOU to `creditor` without any cycle proof.
    function _iou(address debtor, address creditor, uint32 amount) internal {
        vm.prank(debtor);
        ledger.add_IOU(creditor, amount, _noPath());
    }

    function _noPath() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _path(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        p[0] = a;
        p[1] = b;
        p[2] = c;
    }

    /// @dev I6: the Ledger keeps neither ETH nor tokens.
    function _assertLedgerEmpty() internal view {
        assertEq(address(ledger).balance, 0, "ledger ETH");
        assertEq(token.balanceOf(address(ledger)), 0, "ledger tokens");
    }

    /// @dev I8: the Exchange balances equal reserves plus fee funds.
    function _assertExchangeSolvent() internal view {
        assertEq(address(exchange).balance, exchange.ethReserve() + exchange.ethFeeReserve(), "exchange ETH");
        uint256 books = exchange.tokenReserve() + exchange.tokenFeeReserve();
        assertEq(token.balanceOf(address(exchange)), books, "exchange tokens");
    }
}
