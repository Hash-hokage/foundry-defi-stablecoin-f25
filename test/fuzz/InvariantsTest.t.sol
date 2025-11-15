//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract InvariantTest is Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;

    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dsc, dsce);
        targetContract(address(handler));
    }

    function invariant_ProtocolMustHaveMoreCollateralThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 WethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 WbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value:", WethValue);
        console.log("wbtc value:", WbtcValue);
        console.log("total supply:", totalSupply);
        console.log("Times mint is called:", handler.timesMintIsCalled());

        assert(WethValue + WbtcValue >= totalSupply);
    }
}

