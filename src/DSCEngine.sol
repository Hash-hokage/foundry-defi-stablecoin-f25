// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 *     @title DSCEngine
 *     @author omisade Olamiposi
 *
 *     The system is designed to be as minimal as possible, and have the token maintain a 1 token == $1 peg.
 *     This stablecoin has the properties:
 *     - Exogenous Collateral
 *     - Dollar pegged
 *     - Algorithmically stable
 *
 *     it is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC
 *     our DSC system should always be "overcollateralized". at no point should the value of all the collateral <= the $ backed value of DSC.
 *
 *     @notice This contract is the core of the DSC system. This is where all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral exists.
 *     @notice This contract is very loosely based on MakerDAO'S DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__INVALID_PRICE();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address => address) private sPriceFeeds;
    mapping(address => mapping(address => uint256)) private sCollateralDeposited;
    mapping(address => uint256) private sDscMinted;
    address[] private sCollateralTokens;

    DecentralizedStableCoin private immutable I_DSC;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event collateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (sPriceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(address[] memory tokenAddresses, address[] memory pricefeedAddresses, address dscAddress) {
        if (tokenAddresses.length != pricefeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            sPriceFeeds[tokenAddresses[i]] = pricefeedAddresses[i];
            sCollateralTokens.push(tokenAddresses[i]);
        }
        I_DSC = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of Decentralized Stable Coin to mint
     * @notice this function deposits collateral and mints DSC in a single transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        sCollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of Decentralized Stable Coin to burn
     * @notice this function burns DSC and redeems underlying collateral in a single transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of Decentralized Stable Coin to mint
     * @notice They must have more collateral value than the minimum threshold to mint
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        sDscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = I_DSC.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The address of the user who has broken _healthFactor. Their health factor is below the MIN_HEALTH_FACTOR
     * @param debtToCover The amount of debt to cover
     * @notice you can partially liquidate a user
     * @notice you will get a liquidation bonus for taking the users funds
     * @notice this function assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice a known bug is if the protocol were 100% or less collateralized, then we wont be able to incentivize liquidators.
     * for example: if the price of the collateral plummeted before anyone could liquidate.
     *
     * follows CEI
     */

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthBalance >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthBalance) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /*//////////////////////////////////////////////////////////////
                          PRIVATE & INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev this is a low-level internal function, do not call unless the function calling it is checking if the health factor is broken.
     */

    function _burnDsc(uint256 amountDsc, address onBehalfOf, address dscFrom) private {
        sDscMinted[onBehalfOf] -= amountDsc;
        bool success = I_DSC.transferFrom(dscFrom, address(this), amountDsc);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        I_DSC.burn(amountDsc);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        sCollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit collateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = sDscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * returns how close to liquidation a user is
     * if health factor < 1 , user can be liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);

        if (totalDscMinted == 0) {
            // If no DSC is minted, health factor is "infinite".
            // Return the max uint256 value.
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC & EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        if (price <= 0) revert DSCEngine__INVALID_PRICE();
        // casting to 'uint256' is safe because price is checked to be > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralDepositedInUsd) {
        for (uint256 i = 0; i < sCollateralTokens.length; i++) {
            address token = sCollateralTokens[i];
            uint256 amount = sCollateralDeposited[user][token];
            totalCollateralDepositedInUsd += getUsdValue(token, amount);
        }
        return totalCollateralDepositedInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        if (price <= 0) revert DSCEngine__INVALID_PRICE();
        // casting to 'uint256' is safe because price is checked to be > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return sCollateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return sCollateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return sPriceFeeds[token];
    }
}
