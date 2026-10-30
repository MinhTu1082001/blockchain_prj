// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "../utils/Fixture.sol";
import {Token} from "../../contracts/Token.sol";
import {Exchange} from "../../contracts/Exchange.sol";
import {Ledger} from "../../contracts/Ledger.sol";

/// @notice Debtor whose receive() re-enters settleWithETH when the Ledger refunds unused ETH.
/// @dev With `bubble` the blocked re-entry is re-thrown, so the refund fails and the whole tx reverts.
contract EvilDebtor {
    Ledger internal immutable ledger;
    address internal immutable creditor;
    bool internal immutable bubble;
    bool internal entered;
    bool public reentrySucceeded;
    bool public reentryBlocked;
    string public reentryReason;

    constructor(Ledger ledger_, address creditor_, bool bubble_) {
        ledger = ledger_;
        creditor = creditor_;
        bubble = bubble_;
    }

    function borrow(uint32 amount) external {
        ledger.add_IOU(creditor, amount, new address[](0));
    }

    function attack(uint32 amount) external payable {
        ledger.settleWithETH{value: msg.value}(creditor, amount);
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        // the remaining debt would pass the "no such debt" check, so only the guard can stop this call
        try ledger.settleWithETH{value: msg.value}(creditor, 1) {
            reentrySucceeded = true;
        } catch Error(string memory reason) {
            if (bubble) revert(reason);
            reentryBlocked = true;
            reentryReason = reason;
        }
    }
}

/// @notice LP whose receive() re-enters the Exchange while it is paying out ETH.
contract EvilLP {
    Exchange internal immutable exchange;
    Token internal immutable token;
    bool internal immutable bubble;
    bool internal armed;
    bool internal viaSwap;
    uint256 internal reentryAmount;
    bool public reentrySucceeded;
    bool public reentryBlocked;
    string public reentryReason;

    constructor(Exchange exchange_, Token token_, bool bubble_) {
        exchange = exchange_;
        token = token_;
        bubble = bubble_;
    }

    function provide() external payable {
        token.approve(address(exchange), type(uint256).max);
        exchange.addLiquidity{value: msg.value}(type(uint256).max, 0);
    }

    /// @dev Removes liquidity; receive() then calls removeLiquidity again, or swapETHForTokens if `viaSwap_`.
    function attackRemove(uint256 amountETH, bool viaSwap_) external {
        armed = true;
        viaSwap = viaSwap_;
        reentryAmount = amountETH;
        exchange.removeLiquidity(amountETH, type(uint256).max, 0);
    }

    /// @dev Sells tokens; receive() then tries to remove 1 ETH of liquidity.
    function attackSell(uint256 amountTokens) external {
        armed = true;
        viaSwap = false;
        reentryAmount = 1 ether;
        exchange.swapTokensForETH(amountTokens, type(uint256).max);
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        if (viaSwap) {
            try exchange.swapETHForTokens{value: 1 ether}(type(uint256).max) {
                reentrySucceeded = true;
            } catch Error(string memory reason) {
                _blocked(reason);
            }
        } else {
            try exchange.removeLiquidity(reentryAmount, type(uint256).max, 0) {
                reentrySucceeded = true;
            } catch Error(string memory reason) {
                _blocked(reason);
            }
        }
    }

    function _blocked(string memory reason) internal {
        if (bubble) revert(reason);
        reentryBlocked = true;
        reentryReason = reason;
    }
}

contract ReentrancyTest is Fixture {
    function setUp() public {
        _deploy(5_000 ether, 5_000e18);
    }

    // ------------------------------------------------------------------ Ledger.settleWithETH

    function test_ReentrantSettleIsBlocked() public {
        EvilDebtor evil = new EvilDebtor(ledger, bob, false);
        evil.borrow(20);
        uint256 quote = exchange.quoteETHForExactTokens(10e18);
        evil.attack{value: 2 * quote}(10);

        assertTrue(evil.reentryBlocked(), "re-entry must fail");
        assertFalse(evil.reentrySucceeded());
        assertEq(evil.reentryReason(), "reentrant");
        assertEq(ledger.lookup(address(evil), bob), 10, "settled exactly once");
        assertEq(token.balanceOf(bob), 10e18, "creditor paid exactly once");
        assertEq(address(evil).balance, quote, "the refund is kept");
        _assertLedgerEmpty();
    }

    /// Design choice (DESIGN.md): a refund the debtor refuses reverts the whole settlement.
    function testRevert_ReentrantSettleRevertsWholeTx() public {
        EvilDebtor evil = new EvilDebtor(ledger, bob, true);
        evil.borrow(20);
        uint256 quote = exchange.quoteETHForExactTokens(10e18);
        vm.expectRevert(bytes("refund"));
        evil.attack{value: 2 * quote}(10);
        assertEq(ledger.lookup(address(evil), bob), 20, "debt unchanged");
        assertEq(token.balanceOf(bob), 0, "nothing paid");
    }

    // ------------------------------------------------------------------ Exchange payouts

    function _evilLP(bool bubble) internal returns (EvilLP evil) {
        evil = new EvilLP(exchange, token, bubble);
        token.mint(2_000e18);
        require(token.transfer(address(evil), 2_000e18), "fund");
        evil.provide{value: 1_000 ether}(); // 20,000 shares; pool becomes 6,000 / 6,000
    }

    function test_ReentrantRemoveLiquidityIsBlocked() public {
        EvilLP evil = _evilLP(false);
        uint256 sharesBefore = exchange.shares(address(evil));
        evil.attackRemove(100 ether, false);

        assertTrue(evil.reentryBlocked(), "re-entry must fail");
        assertFalse(evil.reentrySucceeded());
        assertEq(evil.reentryReason(), "reentrant");
        assertEq(address(evil).balance, 100 ether, "paid exactly once");
        assertEq(sharesBefore - exchange.shares(address(evil)), 2_000, "burned exactly once");
        _assertExchangeSolvent();
    }

    function testRevert_ReentrantRemoveLiquidityRevertsWholeTx() public {
        EvilLP evil = _evilLP(true);
        uint256 sharesBefore = exchange.shares(address(evil));
        vm.expectRevert(bytes("eth send failed"));
        evil.attackRemove(100 ether, false);
        assertEq(exchange.shares(address(evil)), sharesBefore, "nothing burned");
        assertEq(address(evil).balance, 0, "nothing paid");
    }

    function test_CrossFunctionReentryIsBlocked() public {
        EvilLP evil = _evilLP(false);
        evil.attackRemove(100 ether, true);
        assertTrue(evil.reentryBlocked(), "swap during a payout must fail");
        assertEq(evil.reentryReason(), "reentrant");
        assertEq(address(evil).balance, 100 ether, "the 1 ETH re-entry swap never happened");
        _assertExchangeSolvent();
    }

    function test_ReentryDuringSwapTokensForETHIsBlocked() public {
        EvilLP evil = _evilLP(false);
        uint256 sharesBefore = exchange.shares(address(evil));
        evil.attackSell(100e18);
        assertTrue(evil.reentryBlocked(), "removeLiquidity during a swap payout must fail");
        assertEq(evil.reentryReason(), "reentrant");
        assertEq(exchange.shares(address(evil)), sharesBefore);
        _assertExchangeSolvent();
    }
}
