// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from "./dependencies/openzeppelin/contracts//SafeMath.sol";
import {IERC20} from "./dependencies/openzeppelin/contracts//IERC20.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {IStableDebtToken} from "./interfaces/IStableDebtToken.sol";
import {IVariableDebtToken} from "./interfaces/IVariableDebtToken.sol";
import {IPriceOracleGetter} from "./interfaces/IPriceOracleGetter.sol";
import {ILendingPoolCollateralManager} from "./interfaces/ILendingPoolCollateralManager.sol";
import {VersionedInitializable} from "./protocol/libraries/aave-upgradeability/VersionedInitializable.sol";
import {GenericLogic} from "./protocol/libraries/logic/GenericLogic.sol";
import {Helpers} from "./protocol/libraries/helpers/Helpers.sol";
import {WadRayMath} from "./protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "./protocol/libraries/math/PercentageMath.sol";
import {SafeERC20} from "./dependencies/openzeppelin/contracts/SafeERC20.sol";
import {Errors} from "./protocol/libraries/helpers/Errors.sol";
import {ValidationLogic} from "./protocol/libraries/logic/ValidationLogic.sol";
import {DataTypes} from "./protocol/libraries/types/DataTypes.sol";
import {LendingPoolStorage} from "./protocol/lendingpool/LendingPoolStorage.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

interface IAaveProtocolDataProvider {
    struct TokenData {
        string symbol;
        address tokenAddress;
    }

    function ADDRESSES_PROVIDER() external view returns (address);

    function getAllATokens() external view returns (TokenData[] memory);

    function getAllReservesTokens() external view returns (TokenData[] memory);

    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );

    function getReserveData(address asset)
        external
        view
        returns (
            uint256 availableLiquidity,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );

    function getReserveTokensAddresses(address asset)
        external
        view
        returns (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        );

    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );
}

/**
 * @title AAAVEV2: LendingPoolCollateralData contract
 * @author twitter: @nowonderer
 * @dev Replicates estimations involving management of collateral in the protocol, specifically, liquidations.
 * Created to simplify the leg-work of calculating liquidation calls, since it isn't succinctly defined in their documentation.
 * This contract will be verified if/when I opensource my liquidation bot(s).
 **/
contract LiqData {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    uint256 internal constant LIQUIDATION_CLOSE_FACTOR_PERCENT = 5000;
    ILendingPool private immutable AAVE =
        ILendingPool(0x4F01AeD16D97E3aB5ab2B501154DC9bb0F1A5A2C);

    IAaveProtocolDataProvider private immutable DATA =
        IAaveProtocolDataProvider(0x65285E9dfab318f57051ab2b139ccCf232945451);

    IPriceOracle oracle =
        IPriceOracle(0xdC336Cd4769f4cC7E9d726DA53e6d3fC710cEB89);

    struct LiquidationCallLocalVars {
        uint256 userCollateralBalance;
        uint256 userStableDebt;
        uint256 userVariableDebt;
        uint256 maxLiquidatableDebt;
        uint256 actualDebtToLiquidate;
        uint256 liquidationRatio;
        uint256 maxAmountCollateralToLiquidate;
        uint256 userStableRate;
        uint256 maxCollateralToLiquidate;
        uint256 debtAmountNeeded;
        uint256 healthFactor;
        uint256 liquidatorPreviousATokenBalance;
        IAToken collateralAtoken;
        bool isCollateralEnabled;
        DataTypes.InterestRateMode borrowRateMode;
        uint256 errorCode;
        string errorMsg;
    }

    /**
     * @dev Function to liquidate a position if its Health Factor drops below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCallData(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover, // In calls, set this to max_uint for simplicity
        bool receiveAToken
    )
        public
        view
        returns (
            uint256,
            uint256,
            string memory
        )
    {
        DataTypes.ReserveData memory collateralReserve = AAVE.getReserveData(
            collateralAsset
        );
        DataTypes.ReserveData memory debtReserve = AAVE.getReserveData(
            debtAsset
        );
        DataTypes.UserConfigurationMap memory userConfig = AAVE
            .getUserConfiguration(user);

        LiquidationCallLocalVars memory vars;

        (, , , , , vars.healthFactor) = AAVE.getUserAccountData(user);

        (vars.userStableDebt, vars.userVariableDebt) = Helpers
            .getUserCurrentDebtMemory(user, debtReserve);

        vars.collateralAtoken = IAToken(collateralReserve.aTokenAddress);

        vars.userCollateralBalance = vars.collateralAtoken.balanceOf(user);

        vars.maxLiquidatableDebt = vars
            .userStableDebt
            .add(vars.userVariableDebt)
            .percentMul(LIQUIDATION_CLOSE_FACTOR_PERCENT);

        vars.actualDebtToLiquidate = debtToCover > vars.maxLiquidatableDebt
            ? vars.maxLiquidatableDebt
            : debtToCover;

        (
            vars.maxCollateralToLiquidate,
            vars.debtAmountNeeded
        ) = _calculateAvailableCollateralToLiquidate(
            collateralAsset,
            debtAsset,
            vars.actualDebtToLiquidate,
            vars.userCollateralBalance
        );

        // If debtAmountNeeded < actualDebtToLiquidate, liquidate a smaller amount by necessity.
        if (vars.debtAmountNeeded < vars.actualDebtToLiquidate) {
            vars.actualDebtToLiquidate = vars.debtAmountNeeded;
        }

        string memory errCheck;

        // If the liquidator reclaims the underlying asset, we make sure there is enough available liquidity
        if (!receiveAToken) {
            uint256 currentAvailableCollateral = IERC20(collateralAsset)
                .balanceOf(address(vars.collateralAtoken));
            if (currentAvailableCollateral < vars.maxCollateralToLiquidate) {
                // LPCM_NOT_ENOUGH_LIQUIDITY_TO_LIQUIDATE = '45' || There isn't enough liquidity available to liquidate"
                errCheck = Errors.LPCM_NOT_ENOUGH_LIQUIDITY_TO_LIQUIDATE;
            } else {
                // LPCM_NO_ERRORS = '46' || 'No errors'
                errCheck = Errors.LPCM_NO_ERRORS;
            }
        }

        return (
            vars.actualDebtToLiquidate,
            vars.maxCollateralToLiquidate,
            errCheck
        );
    }

    struct AvailableCollateralToLiquidateLocalVars {
        uint256 userCompoundedBorrowBalance;
        uint256 liquidationBonus;
        uint256 collateralPrice;
        uint256 debtAssetPrice;
        uint256 maxAmountCollateralToLiquidate;
        uint256 debtAssetDecimals;
        uint256 collateralDecimals;
    }

    /**
     * @dev Calculates how much of a specific collateral can be liquidated, given
     * a certain amount of debt asset.
     * - This function needs to be called after all the checks to validate the liquidation have been performed,
     *   otherwise it might fail.
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param userCollateralBalance The collateral balance for the specific `collateralAsset` of the user being liquidated
     * @return collateralAmount: The maximum amount that is possible to liquidate given all the liquidation constraints
     *                           (user balance, close factor)
     *         debtAmountNeeded: The amount to repay with the liquidation
     **/
    function _calculateAvailableCollateralToLiquidate(
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover,
        uint256 userCollateralBalance
    ) internal view returns (uint256, uint256) {
        uint256 collateralAmount = 0;
        uint256 debtAmountNeeded = 0;

        AvailableCollateralToLiquidateLocalVars memory vars;

        vars.collateralPrice = oracle.getAssetPrice(collateralAsset);
        vars.debtAssetPrice = oracle.getAssetPrice(debtAsset);

        //prettier-ignore
        (
            vars.collateralDecimals,
            ,
            ,
            vars.liquidationBonus,
            ,
            ,
            ,
            ,
            ,
        ) = DATA.getReserveConfigurationData(collateralAsset);

        //prettier-ignore
        (
            vars.debtAssetDecimals,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = DATA.getReserveConfigurationData(debtAsset);

        // This is the maximum possible amount of the selected collateral that can be liquidated
        vars.maxAmountCollateralToLiquidate = vars
            .debtAssetPrice
            .mul(debtToCover)
            .mul(10**vars.collateralDecimals)
            .percentMul(vars.liquidationBonus)
            .div(vars.collateralPrice.mul(10**vars.debtAssetDecimals));

        if (vars.maxAmountCollateralToLiquidate > userCollateralBalance) {
            collateralAmount = userCollateralBalance;
            debtAmountNeeded = vars
                .collateralPrice
                .mul(collateralAmount)
                .mul(10**vars.debtAssetDecimals)
                .div(vars.debtAssetPrice.mul(10**vars.collateralDecimals))
                .percentDiv(vars.liquidationBonus);
        } else {
            collateralAmount = vars.maxAmountCollateralToLiquidate;
            debtAmountNeeded = debtToCover;
        }
        return (collateralAmount, debtAmountNeeded);
    }
}
