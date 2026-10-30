// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ClearSwap Exchange
/// @notice Constant-product AMM (x * y = k) between ETH and one ERC-20. A 3% fee is taken on the input,
///         kept outside the reserves in a fee fund and shared among LPs through per-swap accumulators.
/// @dev Rates are "input per output * MULT". What a user pays the pool rounds up, what the pool pays out
///      rounds down, so rounding dust always stays in the pool.
contract Exchange {
    IERC20 public immutable token;

    uint256 public constant MULT = 1e5;
    uint256 public constant FEE_NUM = 3;
    uint256 public constant FEE_DEN = 100;
    uint256 public constant MIN_ETH = 1 ether;
    uint256 public constant MIN_TOKEN = 1e18;
    uint256 public constant INITIAL_SHARES = 1e5;
    uint256 private constant ACC = 1e18; // accumulator precision

    uint256 public ethReserve;
    uint256 public tokenReserve;
    uint256 public k;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    uint256 public ethFeeReserve;
    uint256 public tokenFeeReserve;
    uint256 public accEthPerShare; // * ACC
    uint256 public accTokenPerShare; // * ACC
    mapping(address => uint256) public ethFeeDebt;
    mapping(address => uint256) public tokenFeeDebt;

    bool transient locked;
    address public owner; // pool creator

    modifier nonReentrant() {
        require(!locked, "reentrant");
        locked = true;
        _;
        locked = false;
    }

    constructor(address token_) {
        require(token_ != address(0), "zero token");
        token = IERC20(token_);
        owner = msg.sender;
    }

    /// @notice Seeds the pool once (owner only). The INITIAL_SHARES belong to nobody.
    function createPool(uint256 amountTokens) external payable nonReentrant {
        require(msg.sender == owner, "not owner");
        require(ethReserve == 0, "pool exists");
        require(msg.value >= MIN_ETH && amountTokens >= MIN_TOKEN, "below minimum");
        ethReserve = msg.value;
        tokenReserve = amountTokens;
        k = msg.value * amountTokens;
        totalShares = INITIAL_SHARES;
        require(token.transferFrom(msg.sender, address(this), amountTokens), "transfer failed");
    }

    /// @notice Reserves (fee fund excluded) and total shares.
    function getPoolState() external view returns (uint256 x, uint256 y, uint256 S) {
        return (ethReserve, tokenReserve, totalShares);
    }

    /// @notice Tokens a swap of `ethIn` wei would return at the current reserves.
    function quoteTokensForETH(uint256 ethIn) external view returns (uint256) {
        require(ethReserve > 0, "no pool");
        uint256 net = ethIn - ethIn * FEE_NUM / FEE_DEN;
        return tokenReserve * net / (ethReserve + net);
    }

    /// @notice ETH input that guarantees a swap returns at least `tokensOut` (both divisions round up).
    function quoteETHForExactTokens(uint256 tokensOut) external view returns (uint256 ethIn) {
        require(ethReserve > 0, "no pool");
        require(tokensOut < tokenReserve - MIN_TOKEN, "drain");
        uint256 ethNet = Math.ceilDiv(ethReserve * tokensOut, tokenReserve - tokensOut);
        ethIn = Math.ceilDiv(ethNet * FEE_DEN, FEE_DEN - FEE_NUM);
    }

    /// @notice Sells msg.value ETH for tokens. Reverts if the ETH paid per token * MULT exceeds `maxRate`.
    function swapETHForTokens(uint256 maxRate) external payable nonReentrant returns (uint256 tokensOut) {
        uint256 x = ethReserve;
        uint256 y = tokenReserve;
        require(x > 0, "no pool");
        uint256 fee = msg.value * FEE_NUM / FEE_DEN;
        uint256 net = msg.value - fee;
        tokensOut = y * net / (x + net);
        require(tokensOut > 0, "zero out");
        require(y - tokensOut >= MIN_TOKEN, "drain");
        require(msg.value * MULT / tokensOut <= maxRate, "slippage");
        ethReserve = x + net;
        tokenReserve = y - tokensOut;
        ethFeeReserve += fee;
        accEthPerShare += fee * ACC / totalShares;
        require(token.transfer(msg.sender, tokensOut), "transfer failed");
    }

    /// @notice Sells `amountTokens` for ETH. Reverts if the tokens paid per ETH * MULT exceed `maxRate`.
    function swapTokensForETH(uint256 amountTokens, uint256 maxRate) external nonReentrant returns (uint256 ethOut) {
        uint256 x = ethReserve;
        uint256 y = tokenReserve;
        require(x > 0, "no pool");
        uint256 fee = amountTokens * FEE_NUM / FEE_DEN;
        uint256 net = amountTokens - fee;
        ethOut = x * net / (y + net);
        require(ethOut > 0, "zero out");
        require(x - ethOut >= MIN_ETH, "drain");
        require(amountTokens * MULT / ethOut <= maxRate, "slippage");
        ethReserve = x - ethOut;
        tokenReserve = y + net;
        tokenFeeReserve += fee;
        accTokenPerShare += fee * ACC / totalShares;
        require(token.transferFrom(msg.sender, address(this), amountTokens), "transfer failed");
        (bool ok,) = payable(msg.sender).call{value: ethOut}("");
        require(ok, "eth send failed");
    }

    /// @notice Adds msg.value ETH plus the matching tokens (rounded up) and pays the caller's pending fees.
    /// @param maxRate Upper bound for the pool rate ethReserve * MULT / tokenReserve.
    /// @param minRate Lower bound for the same rate.
    function addLiquidity(uint256 maxRate, uint256 minRate) external payable nonReentrant {
        uint256 x = ethReserve;
        uint256 y = tokenReserve;
        _checkRate(x, y, maxRate, minRate);
        uint256 tokensNeeded = Math.ceilDiv(y * msg.value, x);
        uint256 newShares = totalShares * msg.value / x;
        require(newShares > 0, "too small");
        (uint256 ethFee, uint256 tokenFee) = _harvest(msg.sender);
        ethReserve = x + msg.value;
        tokenReserve = y + tokensNeeded;
        totalShares += newShares;
        shares[msg.sender] += newShares;
        k = ethReserve * tokenReserve;
        _resetFeeDebt(msg.sender);
        require(token.transferFrom(msg.sender, address(this), tokensNeeded), "transfer failed");
        _pay(msg.sender, ethFee, tokenFee);
    }

    /// @notice Withdraws `amountETH` plus the proportional tokens, burning shares rounded up.
    function removeLiquidity(uint256 amountETH, uint256 maxRate, uint256 minRate) external nonReentrant {
        _removeLiquidity(amountETH, false, maxRate, minRate);
    }

    /// @notice Withdraws the caller's whole position.
    function removeAllLiquidity(uint256 maxRate, uint256 minRate) external nonReentrant {
        uint256 s = shares[msg.sender];
        require(s > 0, "no shares");
        _removeLiquidity(ethReserve * s / totalShares, true, maxRate, minRate);
    }

    /// @notice Fees accrued to `lp` and not paid yet: shares * acc / 1e18 - debt, per asset.
    function pendingFees(address lp) public view returns (uint256 ethFee, uint256 tokenFee) {
        uint256 s = shares[lp];
        ethFee = s * accEthPerShare / ACC - ethFeeDebt[lp];
        tokenFee = s * accTokenPerShare / ACC - tokenFeeDebt[lp];
    }

    function _removeLiquidity(uint256 amountETH, bool all, uint256 maxRate, uint256 minRate) private {
        uint256 x = ethReserve;
        uint256 y = tokenReserve;
        _checkRate(x, y, maxRate, minRate);
        require(amountETH > 0, "zero amount");
        require(amountETH <= x - MIN_ETH, "drain");
        uint256 burn = all ? shares[msg.sender] : Math.ceilDiv(totalShares * amountETH, x);
        require(shares[msg.sender] >= burn, "insufficient shares");
        uint256 tokensOut = y * amountETH / x;
        require(tokensOut <= y - MIN_TOKEN, "drain");
        (uint256 ethFee, uint256 tokenFee) = _harvest(msg.sender);
        ethReserve = x - amountETH;
        tokenReserve = y - tokensOut;
        totalShares -= burn;
        shares[msg.sender] -= burn;
        k = ethReserve * tokenReserve;
        _resetFeeDebt(msg.sender);
        _pay(msg.sender, amountETH + ethFee, tokensOut + tokenFee);
    }

    function _checkRate(uint256 x, uint256 y, uint256 maxRate, uint256 minRate) private pure {
        require(x > 0, "no pool");
        uint256 rate = x * MULT / y;
        require(minRate <= rate && rate <= maxRate, "rate");
    }

    /// @dev Effects only: books the pending fees of `lp` as paid, capped by the fund against rounding dust.
    function _harvest(address lp) private returns (uint256 ethFee, uint256 tokenFee) {
        (ethFee, tokenFee) = pendingFees(lp);
        ethFee = Math.min(ethFee, ethFeeReserve);
        tokenFee = Math.min(tokenFee, tokenFeeReserve);
        ethFeeReserve -= ethFee;
        tokenFeeReserve -= tokenFee;
    }

    function _resetFeeDebt(address lp) private {
        ethFeeDebt[lp] = shares[lp] * accEthPerShare / ACC;
        tokenFeeDebt[lp] = shares[lp] * accTokenPerShare / ACC;
    }

    function _pay(address to, uint256 ethAmount, uint256 tokenAmount) private {
        if (tokenAmount > 0) require(token.transfer(to, tokenAmount), "transfer failed");
        if (ethAmount > 0) {
            (bool ok,) = payable(to).call{value: ethAmount}("");
            require(ok, "eth send failed");
        }
    }
}
