// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ClearSwap Unit (CSU)
/// @notice ERC-20 used as the debt unit of the Ledger: one debt unit is 1e18 CSU.
contract Token is ERC20, Ownable {
    bool public mintable = true;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    /// @notice Mints `amount` to the owner while minting is enabled.
    function mint(uint256 amount) external onlyOwner {
        require(mintable, "mint disabled");
        _mint(msg.sender, amount);
    }

    /// @notice Disables minting forever.
    function disable_mint() external onlyOwner {
        mintable = false;
    }
}
