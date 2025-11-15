//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {stdError} from "forge-std/Test.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig public config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public user = makeAddr("user");
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant MINT_AMOUNT = 10000 ether; // $10,000 DSC
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        deal(weth, user, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
    //                    CONSTUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    address[] public tokenAdresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAdresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector)
        );
        new DSCEngine(tokenAdresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
    //                       PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertApproxEqAbs(actualUsd, expectedUsd, 1e14, "USD value calculation incorrect");
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // 100 * 1e18 / (2000 * 1e10) = 0.05e18
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertApproxEqAbs(actualWeth, expectedWeth, 1e14, "Token amount calculation incorrect");
    }

    function testRevertsIfPriceIsInvalid() public {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__INVALID_PRICE.selector));
        dsce.getUsdValue(weth, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__INVALID_PRICE.selector));
        dsce.getTokenAmountFromUsd(weth, 1 ether);

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000e8);
    }

    /*//////////////////////////////////////////////////////////////
    //                 DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), 1e18);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__MustBeMoreThanZero.selector));
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        deal(address(ranToken), user, COLLATERAL_AMOUNT);

        vm.startPrank(user);
        ranToken.approve(address(dsce), COLLATERAL_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector));
        dsce.depositCollateral(address(ranToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
    //                      MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testMintDscRevertsIfAmountIsZero() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__MustBeMoreThanZero.selector));
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testMintDscRevertsIfHealthFactorBreaks() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateral(weth, COLLATERAL_AMOUNT);
        // 10 WETH * $2000 = $20,000. Threshold = 50%.
        // Max mint = 20000 * 50 / 100 = 10000
        // Max safe mint = 10,000 DSC, so mint slightly above
        uint256 unsafeMintAmount = 10_001 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreakHealthFactor.selector,
                999_900_009_999_000_099 // optional: only include if you know the exact arg
            )
        );
        dsce.mintDsc(unsafeMintAmount);
    }

    /*//////////////////////////////////////////////////////////////
    //           DEPOSIT COLLATERAL AND MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositCollateralAndMintDscRevertsIfHealthFactorBreaks() public {
        // Arrange
        ERC20Mock(weth).mint(user, COLLATERAL_AMOUNT);
        vm.startPrank(user);
        uint256 unsafeMintAmount = dsce.getUsdValue(weth, COLLATERAL_AMOUNT) * 10; // deliberately too high
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);

        // Act + Assert
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, uint256(5e16)));

        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, unsafeMintAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
    //                      BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testBurnDscRevertsIfAmountIsZero() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__MustBeMoreThanZero.selector));
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnDscRevertsIfAllowanceIsInsufficient() public {
        // Setup: Deposit and Mint
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_AMOUNT);

        // Test: User tries to burn without approving DSC token
        // This will revert at the transferFrom call
        vm.expectRevert();
        dsce.burnDsc(MINT_AMOUNT);

        vm.stopPrank();
    }

    function testBurnDscRevertsIfBurnAmountExceedsMinted() public {
        // Setup: User1 deposits and mints
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_AMOUNT);
        vm.stopPrank();

        // Setup: User2 deposits, mints, and transfers to User1
        address user2 = makeAddr("user2");
        deal(weth, user2, COLLATERAL_AMOUNT);
        vm.startPrank(user2);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, 1 ether);
        dsc.transfer(user, 1 ether); // User now has 10,001 DSC
        vm.stopPrank();

        assertEq(dsc.balanceOf(user), MINT_AMOUNT + 1 ether, "User DSC balance setup failed");

        // Test: User1 tries to burn more than they minted (but not more than balance)
        vm.startPrank(user);
        dsc.approve(address(dsce), MINT_AMOUNT + 1 ether);
        uint256 burnAmount = bound(MINT_AMOUNT + 1 ether, MINT_AMOUNT + 1, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError); // Reverts at sDscMinted[onBehalfOf] -= amountDsc
        dsce.burnDsc(burnAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
    //                 REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRedeemCollateralRevertsIfAmountIsZero() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__MustBeMoreThanZero.selector));
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfUserHasNoCollateral() public {
        vm.startPrank(user);
        uint256 redeemAmount = bound(1 ether, 1, type(uint256).max);
        vm.expectRevert(stdError.arithmeticError); // Reverts at sCollateralDeposited[from][token] -= amount
        dsce.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfHealthFactorBreaks() public {
        // Setup: Deposit and Mint to HF = 1
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_AMOUNT);
        // 10 WETH * $2000 = $20,000. Minted 10,000 DSC. HF = 1.

        // Burn 6000 DSC, Redeem 1 WETH.
        // Now 9 WETH ($18k), 4000 DSC. HF = (18k * 50/100) / 4000 = 2.25
        dsc.approve(address(dsce), 6000 ether);
        dsce.burnDsc(6000 ether);
        dsce.redeemCollateral(weth, 1 ether);

        // Max redeem = 5 WETH. ( (9-X) * 2000 * 50/100 >= 4000 -> (9-X) * 1000 >= 4000 -> 9000 - 1000X >= 4000 -> 5000 >= 1000X -> X <= 5)
        uint256 maxRedeemableWeth = 5 ether;
        uint256 expectedHealthFactor = 999750000000000000; // from trace (≈ 0.99975 * 1e18)
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateral(weth, maxRedeemableWeth + 1e15); // 5.001 WETH
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
    //           REDEEM COLLATERAL FOR DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testRedeemCollateralForDscRevertsIfHealthFactorBreaks() public {
        // Setup: Deposit and Mint to HF = 1
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_AMOUNT);
        // 10 WETH ($20,000), 10,000 DSC. HF = 1.

        // Try to redeem 1 WETH (leaving 9 WETH) and burn 1 wei DSC.
        // New HF = (9*2000 * 50/100) * 1e18 / (10000e18 - 1) = 0.9. Should fail.
        uint256 redeemAmount = 1 ether;
        uint256 burnAmount = 1;

        dsc.approve(address(dsce), burnAmount);
        uint256 expectedHealthFactor = 9e17; // approximate 0.9 * 1e18
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
        dsce.redeemCollateralForDsc(weth, redeemAmount, burnAmount);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
    //                    LIQUIDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function testLiquidateRevertsIfAmountIsZero() public {
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__MustBeMoreThanZero.selector));
        dsce.liquidate(weth, user, 0);
        vm.stopPrank();
    }

    function testLiquidateRevertsIfHealthFactorIsOk() public {
        // Setup: User deposits and mints
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_AMOUNT);
        vm.stopPrank();

        // Setup: Liquidator
        address liquidator = makeAddr("liquidator");
        deal(weth, liquidator, STARTING_ERC20_BALANCE);
        deal(address(dsc), liquidator, MINT_AMOUNT); // Give liquidator DSC to liquidate
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), MINT_AMOUNT);

        // Test: User HF is 1, which is OK.
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorOk.selector));
        dsce.liquidate(weth, user, 100 ether);
        vm.stopPrank();
    }

    function testLiquidateRevertsIfBonusExceedsCollateral() public {
        // Setup: User deposits and mints
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_AMOUNT);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, MINT_AMOUNT);
        vm.stopPrank();

        // Setup: Liquidator
        address liquidator = makeAddr("liquidator");
        deal(weth, liquidator, STARTING_ERC20_BALANCE);
        deal(address(dsc), liquidator, MINT_AMOUNT); // Give liquidator DSC to liquidate
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), MINT_AMOUNT);

        // Make user unhealthy
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1e8); // Drop price to $1
        // User has 10 WETH = $10. Minted 10,000 DSC. HF = (10 * 50/100) / 10000 = 0.0005.

        // What if liquidator covers 10 DSC debt?
        // $10 debt = 10 WETH.
        // 10% Bonus = 1 WETH.
        // Total = 11 WETH. User only has 10.
        uint256 debtToCover = bound(10 ether, 10 ether, type(uint256).max); // 10 DSC
        vm.expectRevert(stdError.arithmeticError); // Underflow in _redeemCollateral
        dsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000e8);
    }
}
