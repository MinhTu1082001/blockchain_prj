// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The part of the Exchange the Ledger relies on.
interface IExchange {
    function quoteETHForExactTokens(uint256 tokensOut) external view returns (uint256 ethIn);
    function swapETHForTokens(uint256 maxRate) external payable returns (uint256 tokensOut);
}

/// @title ClearSwap Ledger
/// @notice Group IOU book. Debts are whole token units (uint32), cycles are cancelled with a path proven by
///         the client, and debts are settled either in tokens or in ETH swapped through the Exchange.
/// @dev The Ledger never holds ETH or tokens once a transaction ends (invariant I6).
contract Ledger {
    IERC20 public immutable token;
    IExchange public immutable exchange;

    uint256 public constant UNIT = 1e18;
    uint256 public constant MAX_PATH = 10;

    mapping(address => mapping(address => uint32)) private debts;
    bool transient locked;

    event IOUAdded(address indexed debtor, address indexed creditor, uint32 amount, uint32 cancelled);
    event Settled(address indexed debtor, address indexed creditor, uint32 amount, bool viaETH, uint256 ethSpent);

    modifier nonReentrant() {
        require(!locked, "reentrant");
        locked = true;
        _;
        locked = false;
    }

    constructor(address token_, address exchange_) {
        require(token_ != address(0) && exchange_ != address(0), "zero address");
        token = IERC20(token_);
        exchange = IExchange(exchange_);
    }

    /// @notice Units `debtor` currently owes `creditor`.
    function lookup(address debtor, address creditor) external view returns (uint32) {
        return debts[debtor][creditor];
    }

    /// @notice Records that msg.sender owes `creditor` `amount` more units.
    /// @param path Optional cycle proof [creditor, ..., msg.sender] along positive debts. The new IOU closes
    ///        the cycle and its minimum edge is cancelled on every edge. Pass [] to skip cancellation.
    function add_IOU(address creditor, uint32 amount, address[] calldata path) external {
        require(amount > 0, "zero amount");
        require(creditor != msg.sender && creditor != address(0), "bad creditor");
        debts[msg.sender][creditor] += amount;
        uint32 cancelled;
        if (path.length >= 2) cancelled = _cancelCycle(creditor, path);
        emit IOUAdded(msg.sender, creditor, amount, cancelled);
    }

    /// @notice Repays `amount` units in tokens; the Ledger needs an allowance of amount * UNIT.
    function settleWithTokens(address creditor, uint32 amount) external nonReentrant {
        require(amount > 0 && debts[msg.sender][creditor] >= amount, "no such debt");
        debts[msg.sender][creditor] -= amount;
        require(token.transferFrom(msg.sender, creditor, uint256(amount) * UNIT), "transfer failed");
        emit Settled(msg.sender, creditor, amount, false, 0);
    }

    /// @notice Repays `amount` units with ETH in one transaction: buys exactly amount * UNIT tokens on the
    ///         Exchange and forwards them to `creditor`. msg.value is the payer's cap (sandwich guard);
    ///         unused ETH and surplus tokens go back to the payer.
    function settleWithETH(address creditor, uint32 amount) external payable nonReentrant {
        require(amount > 0 && debts[msg.sender][creditor] >= amount, "no such debt"); // checks
        debts[msg.sender][creditor] -= amount; // effects
        uint256 want = uint256(amount) * UNIT;
        uint256 ethIn = exchange.quoteETHForExactTokens(want);
        require(ethIn <= msg.value, "over cap"); // the cap is the sandwich guard
        uint256 got = exchange.swapETHForTokens{value: ethIn}(type(uint256).max); // interactions
        require(got >= want, "short");
        require(token.transfer(creditor, want), "transfer failed");
        if (got > want) require(token.transfer(msg.sender, got - want), "transfer failed");
        if (msg.value > ethIn) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - ethIn}("");
            require(ok, "refund");
        }
        emit Settled(msg.sender, creditor, amount, true, ethIn);
    }

    /// @dev Verifies the client's cycle proof in O(n^2) with n <= MAX_PATH and cancels the cycle minimum on
    ///      every edge, including the new one, so at least one edge drops to zero (invariant I1).
    function _cancelCycle(address creditor, address[] calldata path) private returns (uint32 m) {
        uint256 n = path.length;
        require(n <= MAX_PATH, "path too long");
        require(path[0] == creditor && path[n - 1] == msg.sender, "bad endpoints");
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                require(path[i] != path[j], "repeated node");
            }
        }
        m = debts[msg.sender][creditor];
        for (uint256 i = 0; i + 1 < n; i++) {
            uint32 d = debts[path[i]][path[i + 1]];
            require(d > 0, "edge");
            if (d < m) m = d;
        }
        for (uint256 i = 0; i + 1 < n; i++) {
            debts[path[i]][path[i + 1]] -= m;
        }
        debts[msg.sender][creditor] -= m;
    }
}
