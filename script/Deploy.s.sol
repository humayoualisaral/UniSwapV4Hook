// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {IPoolManager}    from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks}           from "v4-core/src/libraries/Hooks.sol";
import {HookMiner}       from "v4-hooks-public/src/utils/HookMiner.sol";
import {TreasuryFeeHook} from "../src/TreasuryFeeHook.sol";

contract Deploy is Script {

    // --- Pool Managers ----------------------------------------------------------
    address constant MAINNET_PM =
        0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant SEPOLIA_PM =
        0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    // --- Mainnet base currencies ------------------------------------------------
    address constant WETH_MAINNET  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC_MAINNET  = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT_MAINNET  = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // --- Sepolia base currencies (canonical testnet addresses) ------------------
    address constant WETH_SEPOLIA  = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant USDC_SEPOLIA  = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant USDT_SEPOLIA  = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;

    function run() external {
        bool isMainnet = block.chainid == 1;

        address pm = isMainnet ? MAINNET_PM : SEPOLIA_PM;

        address[] memory bases = new address[](3);
        if (isMainnet) {
            bases[0] = WETH_MAINNET;
            bases[1] = USDC_MAINNET;
            bases[2] = USDT_MAINNET;
        } else {
            bases[0] = WETH_SEPOLIA;
            bases[1] = USDC_SEPOLIA;
            bases[2] = USDT_SEPOLIA;
        }

        // --- Mine a CREATE2 salt whose address satisfies the hook flag bits ------
        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG               |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Note: We only encode (pm, bases) because Treasury and Fee are hardcoded inside the contract
        // CREATE2_FACTORY is inherited globally from forge-std/Script.sol
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(TreasuryFeeHook).creationCode,
            abi.encode(pm, bases)   
        );

        console.log("==============================================");
        console.log("Chain ID:      ", block.chainid);
        console.log("PoolManager:   ", pm);
        console.log("Fee (bps):     ", 9900, "(Hardcoded 99%)");
        console.log("Hook address:  ", hookAddr);
        console.log("==============================================");

        vm.startBroadcast();

        TreasuryFeeHook hook = new TreasuryFeeHook{salt: salt}(
            IPoolManager(pm),
            bases
        );

        require(address(hook) == hookAddr, "Address mismatch - re-run HookMiner");

        console.log("Deployed successfully:", address(hook));

        vm.stopBroadcast();
    }
}