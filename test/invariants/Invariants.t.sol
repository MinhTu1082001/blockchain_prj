// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Token} from "../../contracts/Token.sol";
import {Exchange} from "../../contracts/Exchange.sol";
import {Ledger} from "../../contracts/Ledger.sol";

/// @notice Drives random swaps, liquidity moves, IOUs and settlements from a fixed set of actors.
/// @dev Inputs are bounded to valid ranges; calls that still revert are discarded by the fuzzer.
///      Ghost variables record what the invariants cannot see from the contracts' state alone.
contract Handler is Test {
    Token internal immutable token;
    Exchange internal immutable exchange;
    Ledger internal immutable ledger;
    address[] internal actors;

    uint256 public ghostDebtTotal; // expected sum of all debts between actors
    bool public ghostSettleMismatch; // a creditor received something other than amount * UNIT
    bool public ghostCycleNotCancelled; // a cycle proof left every edge positive
    bool public ghostSwapChangedKOrShares; // a swap moved k or totalShares

    uint256 internal kBefore;
    uint256 internal sharesBefore;

    constructor(Token token_, Exchange exchange_, Ledger ledger_, address[] memory actors_) {
        token = token_;
        exchange = exchange_;
        ledger = ledger_;
        actors = actors_;
    }

    // ------------------------------------------------------------------ Exchange

    function swapETHForTokens(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        amount = bound(amount, 0.01 ether, 300 ether);
        vm.deal(a, a.balance + amount);
        _beforeSwap();
        vm.prank(a);
        exchange.swapETHForTokens{value: amount}(type(uint256).max);
        _afterSwap();
    }

    function swapTokensForETH(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        amount = bound(amount, 0.01e18, 300e18);
        if (token.balanceOf(a) < amount) return;
        _beforeSwap();
        vm.prank(a);
        exchange.swapTokensForETH(amount, type(uint256).max);
        _afterSwap();
    }

    function addLiquidity(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        amount = bound(amount, 1 ether, 500 ether);
        vm.deal(a, a.balance + amount);
        vm.prank(a);
        exchange.addLiquidity{value: amount}(type(uint256).max, 0);
    }

    function removeLiquidity(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        uint256 maxEth = exchange.ethReserve() * exchange.shares(a) / exchange.totalShares();
        if (maxEth == 0) return;
        amount = bound(amount, 1, maxEth);
        vm.prank(a);
        exchange.removeLiquidity(amount, type(uint256).max, 0);
    }

    function removeAllLiquidity(uint256 seed) external {
        address a = actors[seed % actors.length];
        if (exchange.shares(a) == 0) return;
        vm.prank(a);
        exchange.removeAllLiquidity(type(uint256).max, 0);
    }

    // ------------------------------------------------------------------ Ledger

    function addIOU(uint256 seed, uint256 amount, bool useCycle) external {
        (address debtor, address creditor) = _pair(seed);
        if (debtor == creditor) return;
        uint32 amt = uint32(bound(amount, 1, 1_000));
        address[] memory path = useCycle ? _findCycle(creditor, debtor) : new address[](0);
        uint256 before = ledger.lookup(debtor, creditor);
        vm.prank(debtor);
        ledger.add_IOU(creditor, amt, path);
        // every one of the path.length cycle edges dropped by the same cancelled amount
        uint256 cancelled = before + amt - ledger.lookup(debtor, creditor);
        ghostDebtTotal = ghostDebtTotal + amt - cancelled * path.length;
        if (path.length >= 2 && !_hasZeroEdge(path)) ghostCycleNotCancelled = true;
    }

    function settleWithTokens(uint256 seed, uint256 amount) external {
        (address debtor, address creditor) = _pair(seed);
        uint32 amt = ledger.lookup(debtor, creditor);
        if (amt == 0) return;
        amt = uint32(bound(amount, 1, amt));
        if (token.balanceOf(debtor) < uint256(amt) * 1e18) return;
        uint256 expected = token.balanceOf(creditor) + uint256(amt) * 1e18;
        vm.prank(debtor);
        ledger.settleWithTokens(creditor, amt);
        _afterSettle(creditor, expected, amt);
    }

    function settleWithETH(uint256 seed, uint256 amount, uint256 slippage) external {
        (address debtor, address creditor) = _pair(seed);
        uint32 amt = ledger.lookup(debtor, creditor);
        if (amt == 0) return;
        amt = uint32(bound(amount, 1, amt < 500 ? amt : 500));
        if (uint256(amt) * 1e18 + 1e18 >= exchange.tokenReserve()) return; // the quote would revert
        uint256 cap = exchange.quoteETHForExactTokens(uint256(amt) * 1e18);
        cap += cap * bound(slippage, 0, 25) / 100;
        vm.deal(debtor, debtor.balance + cap);
        uint256 expected = token.balanceOf(creditor) + uint256(amt) * 1e18;
        vm.prank(debtor);
        ledger.settleWithETH{value: cap}(creditor, amt);
        _afterSettle(creditor, expected, amt);
    }

    // ------------------------------------------------------------------ helpers

    function _pair(uint256 seed) internal view returns (address debtor, address creditor) {
        uint256 n = actors.length;
        debtor = actors[seed % n];
        creditor = actors[(seed / n) % n];
    }

    function _beforeSwap() internal {
        kBefore = exchange.k();
        sharesBefore = exchange.totalShares();
    }

    function _afterSwap() internal {
        if (exchange.k() != kBefore || exchange.totalShares() != sharesBefore) ghostSwapChangedKOrShares = true;
    }

    function _afterSettle(address creditor, uint256 expected, uint32 amt) internal {
        if (token.balanceOf(creditor) != expected) ghostSettleMismatch = true;
        ghostDebtTotal -= amt;
    }

    /// @dev Proof for the new edge debtor -> creditor: a 2-cycle if creditor owes debtor, else a 3-cycle.
    function _findCycle(address creditor, address debtor) internal view returns (address[] memory path) {
        if (ledger.lookup(creditor, debtor) > 0) {
            path = new address[](2);
            path[0] = creditor;
            path[1] = debtor;
            return path;
        }
        for (uint256 i = 0; i < actors.length; i++) {
            address mid = actors[i];
            if (mid == creditor || mid == debtor) continue;
            if (ledger.lookup(creditor, mid) > 0 && ledger.lookup(mid, debtor) > 0) {
                path = new address[](3);
                path[0] = creditor;
                path[1] = mid;
                path[2] = debtor;
                return path;
            }
        }
    }

    function _hasZeroEdge(address[] memory path) internal view returns (bool) {
        uint256 n = path.length;
        if (ledger.lookup(path[n - 1], path[0]) == 0) return true; // the new edge
        for (uint256 i = 0; i + 1 < n; i++) {
            if (ledger.lookup(path[i], path[i + 1]) == 0) return true;
        }
        return false;
    }
}

/// @notice Invariants I1-I8 of docs/DESIGN.md checked after every random call.
contract InvariantsTest is Test {
    Token internal token;
    Exchange internal exchange;
    Ledger internal ledger;
    Handler internal handler;
    address[] internal actors;

    function setUp() public {
        token = new Token("ClearSwap Unit", "CSU");
        exchange = new Exchange(address(token));
        ledger = new Ledger(address(token), address(exchange));
        token.mint(10_000_000e18);
        token.approve(address(exchange), 5_000e18);
        exchange.createPool{value: 5_000 ether}(5_000e18);

        for (uint256 i = 0; i < 5; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.deal(a, 100_000 ether);
            require(token.transfer(a, 1_000_000e18), "fund");
            vm.startPrank(a);
            token.approve(address(exchange), type(uint256).max);
            token.approve(address(ledger), type(uint256).max);
            vm.stopPrank();
        }
        handler = new Handler(token, exchange, ledger, actors);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = Handler.swapETHForTokens.selector;
        selectors[1] = Handler.swapTokensForETH.selector;
        selectors[2] = Handler.addLiquidity.selector;
        selectors[3] = Handler.removeLiquidity.selector;
        selectors[4] = Handler.removeAllLiquidity.selector;
        selectors[5] = Handler.addIOU.selector;
        selectors[6] = Handler.settleWithTokens.selector;
        selectors[7] = Handler.settleWithETH.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// I1: a valid cycle proof always clears at least one edge.
    function invariant_I1_CycleClearsAnEdge() public view {
        assertFalse(handler.ghostCycleNotCancelled());
    }

    /// I2: debts move only through IOUs, cycle cancellation and settlement; creditors get amount * UNIT.
    function invariant_I2_DebtsMatchHistory() public view {
        uint256 total;
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                total += ledger.lookup(actors[i], actors[j]);
            }
        }
        assertEq(total, handler.ghostDebtTotal(), "sum of debts");
        assertFalse(handler.ghostSettleMismatch(), "creditor got amount * UNIT");
    }

    /// I3: x * y >= k; swaps never move k (or the shares).
    function invariant_I3_ProductNeverBelowK() public view {
        (uint256 x, uint256 y,) = exchange.getPoolState();
        assertGe(x * y, exchange.k());
        assertFalse(handler.ghostSwapChangedKOrShares(), "swap moved k or shares");
    }

    /// I4: reserves stay at or above 1 ETH / 1 token.
    function invariant_I4_ReservesAboveMinimum() public view {
        assertGe(exchange.ethReserve(), exchange.MIN_ETH());
        assertGe(exchange.tokenReserve(), exchange.MIN_TOKEN());
    }

    /// I5: sum of LP shares + INITIAL_SHARES == totalShares.
    function invariant_I5_SharesAddUp() public view {
        uint256 sum = exchange.INITIAL_SHARES();
        for (uint256 i = 0; i < actors.length; i++) {
            sum += exchange.shares(actors[i]);
        }
        assertEq(sum, exchange.totalShares());
    }

    /// I6: the Ledger never keeps ETH or tokens.
    function invariant_I6_LedgerHoldsNothing() public view {
        assertEq(address(ledger).balance, 0);
        assertEq(token.balanceOf(address(ledger)), 0);
    }

    /// I7: the pending fees of all LPs are covered by the fee funds.
    function invariant_I7_PendingFeesBacked() public view {
        uint256 ethFees;
        uint256 tokenFees;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 e, uint256 t) = exchange.pendingFees(actors[i]);
            ethFees += e;
            tokenFees += t;
        }
        assertLe(ethFees, exchange.ethFeeReserve());
        assertLe(tokenFees, exchange.tokenFeeReserve());
    }

    /// I8: Exchange balances equal reserves plus fee funds.
    function invariant_I8_BalancesMatchBooks() public view {
        assertEq(address(exchange).balance, exchange.ethReserve() + exchange.ethFeeReserve());
        assertEq(token.balanceOf(address(exchange)), exchange.tokenReserve() + exchange.tokenFeeReserve());
    }
}
