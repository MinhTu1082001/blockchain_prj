// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Token} from "../contracts/Token.sol";
import {Exchange} from "../contracts/Exchange.sol";
import {Ledger} from "../contracts/Ledger.sol";

/// @notice Deploys ClearSwap on Anvil: Token, Exchange(token), Ledger(token, exchange); mints 20,000 CSU,
///         creates a 5,000 ETH / 5,000 CSU pool, sends 1,000 CSU to Anvil accounts #1-#5 and writes the
///         addresses to deployments/anvil.json for the web app.
/// @dev forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil #0>
contract Deploy is Script {
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
    uint256 internal constant SUPPLY = 20_000e18;
    uint256 internal constant POOL_ETH = 5_000 ether;
    uint256 internal constant POOL_TOKENS = 5_000e18;
    uint256 internal constant PER_ACCOUNT = 1_000e18;

    function run() external {
        uint256 deployBlock = block.number;
        vm.startBroadcast();
        Token token = new Token("ClearSwap Unit", "CSU");
        Exchange exchange = new Exchange(address(token));
        Ledger ledger = new Ledger(address(token), address(exchange));
        token.mint(SUPPLY);
        token.approve(address(exchange), POOL_TOKENS);
        exchange.createPool{value: POOL_ETH}(POOL_TOKENS);
        for (uint32 i = 1; i <= 5; i++) {
            address account = vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i));
            require(token.transfer(account, PER_ACCOUNT), "transfer failed");
        }
        vm.stopBroadcast();

        string memory obj = "deployment";
        vm.serializeAddress(obj, "token", address(token));
        vm.serializeAddress(obj, "exchange", address(exchange));
        vm.serializeAddress(obj, "ledger", address(ledger));
        vm.serializeUint(obj, "deployBlock", deployBlock);
        string memory json = vm.serializeUint(obj, "chainId", block.chainid);
        vm.createDir("deployments", true);
        vm.writeJson(json, "deployments/anvil.json");
    }
}
