//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {Price} from "@synthetixio/spot-market/contracts/storage/Price.sol";
import {DecimalMath} from "@synthetixio/core-contracts/contracts/utils/DecimalMath.sol";
import {SafeCastI256, SafeCastU256, SafeCastU128} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {ISpotMarketSystem} from "../interfaces/external/ISpotMarketSystem.sol";
import {Position} from "./Position.sol";
import {PerpsMarket} from "./PerpsMarket.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {PerpsPrice} from "./PerpsPrice.sol";
import {MarketUpdate} from "./MarketUpdate.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {PerpsMarketConfiguration} from "./PerpsMarketConfiguration.sol";
import {KeeperCosts} from "../storage/KeeperCosts.sol";
import {AsyncOrder} from "../storage/AsyncOrder.sol";

uint128 constant SNX_USD_MARKET_ID = 0;

/**
 * @title Data for a single perps market
 */
library PerpsAccount {
    using SetUtil for SetUtil.UintSet;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using SafeCastU256 for uint256;
    using Position for Position.Data;
    using PerpsPrice for PerpsPrice.Data;
    using PerpsMarket for PerpsMarket.Data;
    using PerpsMarketConfiguration for PerpsMarketConfiguration.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using GlobalPerpsMarket for GlobalPerpsMarket.Data;
    using GlobalPerpsMarketConfiguration for GlobalPerpsMarketConfiguration.Data;
    using DecimalMath for int256;
    using DecimalMath for uint256;
    using KeeperCosts for KeeperCosts.Data;
    using AsyncOrder for AsyncOrder.Data;

    struct Data {
        // @dev synth marketId => amount
        mapping(uint128 => uint256) collateralAmounts;
        // @dev account Id
        uint128 id;
        // @dev set of active collateral types. By active we mean collateral types that have a non-zero amount
        SetUtil.UintSet activeCollateralTypes;
        // @dev set of open position market ids
        SetUtil.UintSet openPositionMarketIds;
    }

    error InsufficientCollateralAvailableForWithdraw(
        uint availableUsdDenominated,
        uint requiredUsdDenominated
    );

    error InsufficientSynthCollateral(
        uint128 synthMarketId,
        uint collateralAmount,
        uint withdrawAmount
    );

    error InsufficientAccountMargin(uint leftover);

    error AccountLiquidatable(uint128 accountId);

    error MaxPositionsPerAccountReached(uint128 maxPositionsPerAccount);

    error MaxCollateralsPerAccountReached(uint128 maxCollateralsPerAccount);

    function load(uint128 id) internal pure returns (Data storage account) {
        bytes32 s = keccak256(abi.encode("io.synthetix.perps-market.Account", id));

        assembly {
            account.slot := s
        }
    }

    /**
        @notice allows us to update the account id in case it needs to be
     */
    function create(uint128 id) internal returns (Data storage account) {
        account = load(id);
        if (account.id == 0) {
            account.id = id;
        }
    }

    function validateMaxPositions(uint128 accountId, uint128 marketId) internal view {
        if (PerpsMarket.accountPosition(marketId, accountId).size == 0) {
            uint128 maxPositionsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxPositionsPerAccount;
            if (maxPositionsPerAccount <= load(accountId).openPositionMarketIds.length()) {
                revert MaxPositionsPerAccountReached(maxPositionsPerAccount);
            }
        }
    }

    function validateMaxCollaterals(uint128 accountId, uint128 synthMarketId) internal view {
        Data storage account = load(accountId);

        if (account.collateralAmounts[synthMarketId] == 0) {
            uint128 maxCollateralsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxCollateralsPerAccount;
            if (maxCollateralsPerAccount <= account.activeCollateralTypes.length()) {
                revert MaxCollateralsPerAccountReached(maxCollateralsPerAccount);
            }
        }
    }

    function isEligibleForLiquidation(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    )
        internal
        view
        returns (
            bool isEligible,
            int256 availableMargin,
            uint256 requiredInitialMargin,
            uint256 requiredMaintenanceMargin,
            uint256 liquidationReward
        )
    {
        availableMargin = getAvailableMargin(self, stalenessTolerance);
        if (self.openPositionMarketIds.length() == 0) {
            return (false, availableMargin, 0, 0, 0);
        }
        (
            requiredInitialMargin,
            requiredMaintenanceMargin,
            liquidationReward
        ) = getAccountRequiredMargins(self, stalenessTolerance);
        isEligible = (requiredMaintenanceMargin + liquidationReward).toInt() > availableMargin;
    }

    function flagForLiquidation(
        Data storage self
    ) internal returns (uint256 flagKeeperCost, uint256 marginCollected) {
        SetUtil.UintSet storage liquidatableAccounts = GlobalPerpsMarket
            .load()
            .liquidatableAccounts;

        if (!liquidatableAccounts.contains(self.id)) {
            flagKeeperCost = KeeperCosts.load().getFlagKeeperCosts(self.id);
            liquidatableAccounts.add(self.id);
            marginCollected = convertAllCollateralToUsd(self);
            AsyncOrder.load(self.id).reset();
        }
    }

    function updateOpenPositions(Data storage self, uint positionMarketId, int size) internal {
        if (size == 0 && self.openPositionMarketIds.contains(positionMarketId)) {
            self.openPositionMarketIds.remove(positionMarketId);
        } else if (!self.openPositionMarketIds.contains(positionMarketId)) {
            self.openPositionMarketIds.add(positionMarketId);
        }
    }

    function updateCollateralAmount(
        Data storage self,
        uint128 synthMarketId,
        int amountDelta
    ) internal returns (uint256 collateralAmount) {
        collateralAmount = (self.collateralAmounts[synthMarketId].toInt() + amountDelta).toUint();
        self.collateralAmounts[synthMarketId] = collateralAmount;

        bool isActiveCollateral = self.activeCollateralTypes.contains(synthMarketId);
        if (collateralAmount > 0 && !isActiveCollateral) {
            self.activeCollateralTypes.add(synthMarketId);
        } else if (collateralAmount == 0 && isActiveCollateral) {
            self.activeCollateralTypes.remove(synthMarketId);
        }

        // always update global values when account collateral is changed
        GlobalPerpsMarket.load().updateCollateralAmount(synthMarketId, amountDelta);
    }

    /**
     * @notice This function validates you have enough margin to withdraw without being liquidated.
     * @dev    This is done by checking your collateral value against your initial maintenance value.
     * @dev    It also checks the synth collateral for this account is enough to cover the withdrawal amount.
     * @dev    All price checks are not checking strict staleness tolerance.
     */
    function validateWithdrawableAmount(
        Data storage self,
        uint128 synthMarketId,
        uint256 amountToWithdraw,
        ISpotMarketSystem spotMarket
    ) internal view returns (uint256 availableWithdrawableCollateralUsd) {
        uint collateralAmount = self.collateralAmounts[synthMarketId];
        if (collateralAmount < amountToWithdraw) {
            revert InsufficientSynthCollateral(synthMarketId, collateralAmount, amountToWithdraw);
        }

        (
            bool isEligible,
            int256 availableMargin,
            uint256 initialRequiredMargin,
            ,
            uint256 liquidationReward
        ) = isEligibleForLiquidation(self, PerpsPrice.Tolerance.DEFAULT);

        if (isEligible) {
            revert AccountLiquidatable(self.id);
        }

        uint256 requiredMargin = initialRequiredMargin + liquidationReward;
        // availableMargin can be assumed to be positive since we check for isEligible for liquidation prior
        availableWithdrawableCollateralUsd = availableMargin.toUint() - requiredMargin;

        uint amountToWithdrawUsd;
        if (synthMarketId == SNX_USD_MARKET_ID) {
            amountToWithdrawUsd = amountToWithdraw;
        } else {
            (amountToWithdrawUsd, ) = spotMarket.quoteSellExactIn(
                synthMarketId,
                amountToWithdraw,
                Price.Tolerance.DEFAULT
            );
        }

        if (amountToWithdrawUsd > availableWithdrawableCollateralUsd) {
            revert InsufficientCollateralAvailableForWithdraw(
                availableWithdrawableCollateralUsd,
                amountToWithdrawUsd
            );
        }
    }

    function getTotalCollateralValue(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    ) internal view returns (uint) {
        uint totalCollateralValue;
        ISpotMarketSystem spotMarket = PerpsMarketFactory.load().spotMarket;
        for (uint i = 1; i <= self.activeCollateralTypes.length(); i++) {
            uint128 synthMarketId = self.activeCollateralTypes.valueAt(i).to128();
            uint amount = self.collateralAmounts[synthMarketId];

            uint amountToAdd;
            if (synthMarketId == SNX_USD_MARKET_ID) {
                amountToAdd = amount;
            } else {
                (amountToAdd, ) = spotMarket.quoteSellExactIn(
                    synthMarketId,
                    amount,
                    Price.Tolerance(uint(stalenessTolerance)) // solhint-disable-line numcast/safe-cast
                );
            }
            totalCollateralValue += amountToAdd;
        }
        return totalCollateralValue;
    }

    function getAccountPnl(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    ) internal view returns (int totalPnl) {
        for (uint i = 1; i <= self.openPositionMarketIds.length(); i++) {
            uint128 marketId = self.openPositionMarketIds.valueAt(i).to128();
            Position.Data storage position = PerpsMarket.load(marketId).positions[self.id];
            (int pnl, , , , ) = position.getPnl(
                PerpsPrice.getCurrentPrice(marketId, stalenessTolerance)
            );
            totalPnl += pnl;
        }
    }

    function getAvailableMargin(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    ) internal view returns (int256) {
        int256 totalCollateralValue = getTotalCollateralValue(self, stalenessTolerance).toInt();
        int256 accountPnl = getAccountPnl(self, stalenessTolerance);

        return totalCollateralValue + accountPnl;
    }

    function getTotalNotionalOpenInterest(
        Data storage self
    ) internal view returns (uint totalAccountOpenInterest) {
        for (uint i = 1; i <= self.openPositionMarketIds.length(); i++) {
            uint128 marketId = self.openPositionMarketIds.valueAt(i).to128();

            Position.Data storage position = PerpsMarket.load(marketId).positions[self.id];
            (uint openInterest, , , , , ) = position.getPositionData(
                PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
            );
            totalAccountOpenInterest += openInterest;
        }
    }

    /**
     * @notice  This function returns the required margins for an account
     * @dev The initial required margin is used to determine withdrawal amount and when opening positions
     * @dev The maintenance margin is used to determine when to liquidate a position
     */
    function getAccountRequiredMargins(
        Data storage self,
        PerpsPrice.Tolerance stalenessTolerance
    )
        internal
        view
        returns (uint initialMargin, uint maintenanceMargin, uint possibleLiquidationReward)
    {
        // use separate accounting for liquidation rewards so we can compare against global min/max liquidation reward values
        for (uint i = 1; i <= self.openPositionMarketIds.length(); i++) {
            uint128 marketId = self.openPositionMarketIds.valueAt(i).to128();
            Position.Data storage position = PerpsMarket.load(marketId).positions[self.id];
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                marketId
            );
            (, , uint256 positionInitialMargin, uint256 positionMaintenanceMargin) = marketConfig
                .calculateRequiredMargins(
                    position.size,
                    PerpsPrice.getCurrentPrice(marketId, stalenessTolerance)
                );

            maintenanceMargin += positionMaintenanceMargin;
            initialMargin += positionInitialMargin;
        }

        (uint accumulatedLiquidationRewards, uint maxNumberOfWindows) = getKeeperRewardsAndCosts(
            self,
            0
        );
        possibleLiquidationReward = getPossibleLiquidationReward(
            self,
            accumulatedLiquidationRewards,
            maxNumberOfWindows
        );

        return (initialMargin, maintenanceMargin, possibleLiquidationReward);
    }

    function getKeeperRewardsAndCosts(
        Data storage self,
        uint128 skipMarketId
    ) internal view returns (uint accumulatedLiquidationRewards, uint maxNumberOfWindows) {
        // use separate accounting for liquidation rewards so we can compare against global min/max liquidation reward values
        for (uint i = 1; i <= self.openPositionMarketIds.length(); i++) {
            uint128 marketId = self.openPositionMarketIds.valueAt(i).to128();
            if (marketId == skipMarketId) continue;
            Position.Data storage position = PerpsMarket.load(marketId).positions[self.id];
            PerpsMarketConfiguration.Data storage marketConfig = PerpsMarketConfiguration.load(
                marketId
            );

            uint numberOfWindows = marketConfig.numberOfLiquidationWindows(
                MathUtil.abs(position.size)
            );

            uint256 flagReward = marketConfig.calculateFlagReward(
                MathUtil.abs(position.size).mulDecimal(
                    PerpsPrice.getCurrentPrice(marketId, PerpsPrice.Tolerance.DEFAULT)
                )
            );
            accumulatedLiquidationRewards += flagReward;

            maxNumberOfWindows = MathUtil.max(numberOfWindows, maxNumberOfWindows);
        }
    }

    function getPossibleLiquidationReward(
        Data storage self,
        uint accumulatedLiquidationRewards,
        uint numOfWindows
    ) internal view returns (uint possibleLiquidationReward) {
        GlobalPerpsMarketConfiguration.Data storage globalConfig = GlobalPerpsMarketConfiguration
            .load();
        KeeperCosts.Data storage keeperCosts = KeeperCosts.load();
        uint costOfFlagging = keeperCosts.getFlagKeeperCosts(self.id);
        uint costOfLiquidation = keeperCosts.getLiquidateKeeperCosts();
        uint256 liquidateAndFlagCost = globalConfig.keeperReward(
            accumulatedLiquidationRewards,
            costOfFlagging,
            getTotalCollateralValue(self, PerpsPrice.Tolerance.DEFAULT)
        );
        uint256 liquidateWindowsCosts = numOfWindows == 0
            ? 0
            : globalConfig.keeperReward(0, costOfLiquidation, 0) * (numOfWindows - 1);

        possibleLiquidationReward = liquidateAndFlagCost + liquidateWindowsCosts;
    }

    function convertAllCollateralToUsd(
        Data storage self
    ) internal returns (uint256 totalConvertedCollateral) {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        uint[] memory activeCollateralTypes = self.activeCollateralTypes.values();

        // 1. withdraw all collateral from synthetix
        // 2. sell all collateral for snxUSD
        // 3. deposit snxUSD into synthetix
        for (uint256 i = 0; i < activeCollateralTypes.length; i++) {
            uint128 synthMarketId = activeCollateralTypes[i].to128();
            if (synthMarketId == SNX_USD_MARKET_ID) {
                totalConvertedCollateral += self.collateralAmounts[synthMarketId];
                updateCollateralAmount(
                    self,
                    synthMarketId,
                    -(self.collateralAmounts[synthMarketId].toInt())
                );
            } else {
                totalConvertedCollateral += _deductAllSynth(self, factory, synthMarketId);
            }
        }
    }

    /**
     * @notice  This function deducts snxUSD from an account
     * @dev It uses the synth deduction priority to determine which synth to deduct from first
     * @dev if the synth is not snxUSD it will sell the synth for snxUSD
     * @dev Returns two arrays with the synth ids and amounts deducted
     */
    function deductFromAccount(
        Data storage self,
        uint amount // snxUSD
    ) internal returns (uint128[] memory deductedSynthIds, uint256[] memory deductedAmount) {
        uint leftoverAmount = amount;
        uint128[] storage synthDeductionPriority = GlobalPerpsMarketConfiguration
            .load()
            .synthDeductionPriority;
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        ISpotMarketSystem spotMarket = factory.spotMarket;

        deductedSynthIds = new uint128[](synthDeductionPriority.length);
        deductedAmount = new uint256[](synthDeductionPriority.length);

        for (uint i = 0; i < synthDeductionPriority.length; i++) {
            uint128 synthMarketId = synthDeductionPriority[i];
            uint availableAmount = self.collateralAmounts[synthMarketId];
            if (availableAmount == 0) {
                continue;
            }
            deductedSynthIds[i] = synthMarketId;

            if (synthMarketId == SNX_USD_MARKET_ID) {
                // snxUSD
                if (availableAmount >= leftoverAmount) {
                    deductedAmount[i] = leftoverAmount;
                    updateCollateralAmount(self, synthMarketId, -(leftoverAmount.toInt()));
                    leftoverAmount = 0;
                    break;
                } else {
                    deductedAmount[i] = availableAmount;
                    updateCollateralAmount(self, synthMarketId, -(availableAmount.toInt()));
                    leftoverAmount -= availableAmount;
                }
            } else {
                (uint synthAmountRequired, ) = spotMarket.quoteSellExactOut(
                    synthMarketId,
                    leftoverAmount,
                    Price.Tolerance.STRICT
                );

                address synthToken = factory.spotMarket.getSynth(synthMarketId);

                if (availableAmount >= synthAmountRequired) {
                    factory.synthetix.withdrawMarketCollateral(
                        factory.perpsMarketId,
                        synthToken,
                        synthAmountRequired
                    );

                    (uint amountToDeduct, ) = spotMarket.sellExactOut(
                        synthMarketId,
                        leftoverAmount,
                        type(uint).max,
                        address(0)
                    );

                    factory.depositMarketUsd(leftoverAmount);

                    deductedAmount[i] = amountToDeduct;
                    updateCollateralAmount(self, synthMarketId, -(amountToDeduct.toInt()));
                    leftoverAmount = 0;
                    break;
                } else {
                    factory.synthetix.withdrawMarketCollateral(
                        factory.perpsMarketId,
                        synthToken,
                        availableAmount
                    );

                    (uint amountToDeductUsd, ) = spotMarket.sellExactIn(
                        synthMarketId,
                        availableAmount,
                        0,
                        address(0)
                    );

                    factory.depositMarketUsd(amountToDeductUsd);

                    deductedAmount[i] = availableAmount;
                    updateCollateralAmount(self, synthMarketId, -(availableAmount.toInt()));
                    leftoverAmount -= amountToDeductUsd;
                }
            }
        }

        if (leftoverAmount > 0) {
            revert InsufficientAccountMargin(leftoverAmount);
        }
    }

    function liquidatePosition(
        Data storage self,
        uint128 marketId,
        uint256 price
    )
        internal
        returns (
            uint128 amountToLiquidate,
            int128 newPositionSize,
            int128 sizeDelta,
            uint128 oldPositionAbsSize,
            MarketUpdate.Data memory marketUpdateData
        )
    {
        PerpsMarket.Data storage perpsMarket = PerpsMarket.load(marketId);
        Position.Data storage position = perpsMarket.positions[self.id];

        perpsMarket.recomputeFunding(price);

        int128 oldPositionSize = position.size;
        oldPositionAbsSize = MathUtil.abs128(oldPositionSize);
        amountToLiquidate = perpsMarket.maxLiquidatableAmount(oldPositionAbsSize);

        if (amountToLiquidate == 0) {
            return (0, oldPositionSize, 0, oldPositionAbsSize, marketUpdateData);
        }

        int128 amtToLiquidationInt = amountToLiquidate.toInt();
        // reduce position size
        newPositionSize = oldPositionSize > 0
            ? oldPositionSize - amtToLiquidationInt
            : oldPositionSize + amtToLiquidationInt;

        // create new position in case of partial liquidation
        Position.Data memory newPosition;
        if (newPositionSize != 0) {
            newPosition = Position.Data({
                marketId: marketId,
                latestInteractionPrice: price.to128(),
                latestInteractionFunding: perpsMarket.lastFundingValue.to128(),
                size: newPositionSize
            });
        }

        // update position markets
        updateOpenPositions(self, marketId, newPositionSize);

        // update market data
        marketUpdateData = perpsMarket.updatePositionData(self.id, newPosition);
        sizeDelta = newPositionSize - oldPositionSize;

        return (
            amountToLiquidate,
            newPositionSize,
            sizeDelta,
            oldPositionAbsSize,
            marketUpdateData
        );
    }

    function _deductAllSynth(
        Data storage self,
        PerpsMarketFactory.Data storage factory,
        uint128 synthMarketId
    ) private returns (uint256 amountUsd) {
        uint amount = self.collateralAmounts[synthMarketId];
        address synth = factory.spotMarket.getSynth(synthMarketId);

        // 1. withdraw collateral from market manager
        factory.synthetix.withdrawMarketCollateral(factory.perpsMarketId, synth, amount);

        // 2. sell collateral for snxUSD
        (amountUsd, ) = PerpsMarketFactory.load().spotMarket.sellExactIn(
            synthMarketId,
            amount,
            0,
            address(0)
        );

        // 3. deposit snxUSD into market manager
        factory.depositMarketUsd(amountUsd);

        // 4. update account collateral amount
        updateCollateralAmount(self, synthMarketId, -(amount.toInt()));
    }
}
