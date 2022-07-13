//SPDX-License-Identifier: CC-BY-NC-ND-4.0
pragma solidity 0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/ILeveragedPool.sol";
import "./interfaces/IPoolCommitter.sol";
import "./interfaces/IPoolKeeper.sol";
import "./interfaces/IOracleWrapper.sol";
import "./libraries/PoolSwapLibrary.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Extended interfaces
interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint256);
}

interface IPoolCommitter2 is IPoolCommitter {
    function totalPoolCommitments(uint256 _updateIntervalId)
        external
        view
        returns (IPoolCommitter.TotalCommitment memory);

    function burningFee() external view returns (bytes16);

    function mintingFee() external view returns (bytes16);
}

interface ILeveragedPool2 is ILeveragedPool {
    function fee() external view returns (bytes16);

    function keeper() external view returns (address);

    function leverageAmount() external view override returns (bytes16);
}

interface IPoolKeeper2 is IPoolKeeper {
    function executionPrice(address _poolAddress)
        external
        view
        returns (int256 _lastExecutionPrice);
}

interface ISMAOracle is IOracleWrapper {
    function numPeriods() external view returns (int256);

    function prices(int256 _numPeriod) external view returns (int256 price);

    function periodCount() external view returns (int256);
}

interface IPoolStateHelper {
    error INVALID_PERIOD();

    struct SideInfo {
        uint256 supply; // poolToken.totalSupply()
        uint256 settlementBalance; // balance of settlementTokens associated with supply
        uint256 pendingBurnPoolTokens;
    }

    struct PoolInfo {
        SideInfo long;
        SideInfo short;
    }

    struct SMAInfo {
        int256[] prices;
        uint256 numPeriods;
    }

    struct ExpectedPoolState {
        //in settlementToken decimals
        uint256 cumulativePendingMintSettlement;
        uint256 remainingPendingShortBurnTokens;
        uint256 remainingPendingLongBurnTokens;
        uint256 longSupply;
        uint256 longBalance;
        uint256 shortSupply;
        uint256 shortBalance;
        int256 oraclePrice;
    }

    struct ReadOnlyPoolProps {
        bytes16 burningFee;
        bytes16 mintingFee;
        bytes16 poolManagementFee;
        bytes16 leverageAmount;
    }

    struct PriceInfo {
        int256 indexPrice;
        int256 spotPrice;
        int256 lastExecutedPrice;
        bool isSMAOracle;
        SMAInfo smaInfo;
    }

    function getCommitQueue(IPoolCommitter2 committer, uint256 periods)
        external
        view
        returns (IPoolCommitter2.TotalCommitment[] memory commitQueue);

    function getPoolInfo(ILeveragedPool2 pool, IPoolCommitter2 committer)
        external
        view
        returns (PoolInfo memory poolInfo);

    function getExpectedState(ILeveragedPool2 pool, uint256 periods)
        external
        view
        returns (ExpectedPoolState memory finalExpectedPoolState);

    function fullCommitPeriod(ILeveragedPool2 pool)
        external
        view
        returns (uint256);
}

contract PoolStateHelper is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IPoolStateHelper
{
    // From LeveragedPool.sol
    uint128 public constant LONG_INDEX = 0;
    uint128 public constant SHORT_INDEX = 1;

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    /**
     * @notice Get an array of TotalCommitment in ascending order for a given period.
     * @return commitQueue
     * @param committer The PoolCommitter contract.
     * @param periods The number of commits to get.
     */
    function getCommitQueue(IPoolCommitter2 committer, uint256 periods)
        public
        view
        override
        returns (IPoolCommitter2.TotalCommitment[] memory commitQueue)
    {
        uint256 currentUpdateIntervalId = committer.updateIntervalId();
        commitQueue = new IPoolCommitter2.TotalCommitment[](periods);

        unchecked {
            for (uint256 i; i < periods; i++) {
                commitQueue[i] = committer.totalPoolCommitments(
                    currentUpdateIntervalId + i
                );
            }
        }
    }

    ///@dev Get latest SMA prices. The oldest price is omitted if the SMA is fully "ramped up", i.e. smaOracle.periodCount() >= smaOracle.numPeriods().
    function getSMAPrices(ISMAOracle smaOracle)
        public
        view
        returns (SMAInfo memory smaInfo)
    {
        uint256 _periodCount = uint256(smaOracle.periodCount());
        uint256 _numPeriods = uint256(smaOracle.numPeriods());
        uint256 _i;

        smaInfo.numPeriods = _numPeriods;

        unchecked {
            if (_periodCount < _numPeriods) {
                _i = 0;
                smaInfo.prices = new int256[](_periodCount);
            } else {
                // Exclude price at index[0] because prices are FIFO up to numPeriods, so -1.
                _i = _periodCount - (_numPeriods - 1);
                smaInfo.prices = new int256[](_numPeriods - 1);
            }

            for (uint256 i = _i; i < _periodCount; i++) {
                smaInfo.prices[
                    _periodCount < _numPeriods
                        ? i
                        : i + _numPeriods - _periodCount - 1
                ] = smaOracle.prices(int256(i));
            }
        }
    }

    /**
     * @notice Get relevant information from pool.
     * @return poolInfo
     * @param pool The LeveragedPool contract.
     * @param committer The PoolCommiter contract.
     */
    function getPoolInfo(ILeveragedPool2 pool, IPoolCommitter2 committer)
        public
        view
        override
        returns (PoolInfo memory poolInfo)
    {
        address[2] memory tokens = pool.poolTokens();

        poolInfo = PoolInfo({
            long: SideInfo({
                supply: IERC20(tokens[LONG_INDEX]).totalSupply(),
                settlementBalance: pool.longBalance(),
                pendingBurnPoolTokens: committer.pendingLongBurnPoolTokens()
            }),
            short: SideInfo({
                supply: IERC20(tokens[SHORT_INDEX]).totalSupply(),
                settlementBalance: pool.shortBalance(),
                pendingBurnPoolTokens: committer.pendingShortBurnPoolTokens()
            })
        });
    }

    /**
     * @notice The number of TotalCommitments that will be executed at the end of the frontrunning interval.
     * @return fullCommitPeriod
     * @param pool The LeveragedPool contract.
     */
    function fullCommitPeriod(ILeveragedPool2 pool)
        public
        view
        override
        returns (uint256)
    {
        uint256 currentUpdateIntervalId = IPoolCommitter2(pool.poolCommitter())
            .updateIntervalId();

        uint256 newUpdateIntervalId = PoolSwapLibrary
            .appropriateUpdateIntervalId(
                block.timestamp,
                pool.lastPriceTimestamp(),
                pool.frontRunningInterval(),
                pool.updateInterval(),
                currentUpdateIntervalId
            );

        return newUpdateIntervalId - currentUpdateIntervalId + 1;
    }

    function currentPoolState(ILeveragedPool2 pool)
        private
        view
        returns (ExpectedPoolState memory)
    {
        address[2] memory tokens = pool.poolTokens();
        address oracleWrapper = pool.oracleWrapper();

        IPoolCommitter2 committer = IPoolCommitter2(pool.poolCommitter());

        return
            ExpectedPoolState({
                cumulativePendingMintSettlement: 0, // There are no pending settlements, since we're getting the most recent state
                remainingPendingShortBurnTokens: committer
                    .pendingShortBurnPoolTokens(),
                remainingPendingLongBurnTokens: committer
                    .pendingLongBurnPoolTokens(),
                longSupply: IERC20(tokens[LONG_INDEX]).totalSupply(),
                longBalance: pool.longBalance(),
                shortSupply: IERC20(tokens[SHORT_INDEX]).totalSupply(),
                shortBalance: pool.shortBalance(),
                oraclePrice: IOracleWrapper(oracleWrapper).getPrice()
            });
    }

    function isSMAOracle(address oracle) public view returns (bool result) {
        try ISMAOracle(oracle).numPeriods() returns (int256) {
            result = true;
        } catch (bytes memory) {
            result = false;
        }
    }

    /// @dev Exclusive of keeper fee, and dynamic minting fees
    function getExpectedState(ILeveragedPool2 pool, uint256 periods)
        external
        view
        override
        returns (ExpectedPoolState memory)
    {
        if (periods > fullCommitPeriod(pool)) revert INVALID_PERIOD();

        if (periods == 0) {
            return currentPoolState(pool);
        }

        // PoolCommitter dependencies
        IPoolCommitter2.TotalCommitment[] memory commitQueue;
        PoolInfo memory poolInfo;
        ReadOnlyPoolProps memory readonlyPoolProps;

        {
            IPoolCommitter2 committer = IPoolCommitter2(pool.poolCommitter());

            commitQueue = getCommitQueue(committer, periods);
            poolInfo = getPoolInfo(pool, committer);

            //only assigned once
            readonlyPoolProps = ReadOnlyPoolProps({
                burningFee: committer.burningFee(),
                mintingFee: committer.mintingFee(),
                leverageAmount: pool.leverageAmount(),
                poolManagementFee: pool.fee()
            });
        }

        // Oracle dependencies
        PriceInfo memory priceInfo;
        priceInfo.lastExecutedPrice = IPoolKeeper2(pool.keeper())
            .executionPrice(address(pool));

        {
            address priceOracle = pool.oracleWrapper();

            if (isSMAOracle(priceOracle)) {
                // SMA -> spot -> chainlink
                priceInfo.isSMAOracle = true;
                priceInfo.indexPrice = IOracleWrapper(priceOracle).getPrice();
                priceInfo.spotPrice = IOracleWrapper(
                    IOracleWrapper(priceOracle).oracle()
                ).getPrice();
                priceInfo.smaInfo = getSMAPrices(ISMAOracle(priceOracle));
            } else {
                // spot -> chainlink
                priceInfo.spotPrice = IOracleWrapper(priceOracle).getPrice();
                priceInfo.indexPrice = priceInfo.spotPrice;
            }
        }

        uint256 cumulativePendingMintSettlement;

        for (uint256 i; i < periods; i++) {
            // Price update
            if (priceInfo.isSMAOracle) {
                (int256 newPrice, SMAInfo memory updatedSmaInfo) = getNewPrice(
                    priceInfo.smaInfo,
                    priceInfo.spotPrice
                );

                // Update price info
                priceInfo.indexPrice = newPrice;
                priceInfo.smaInfo = updatedSmaInfo;
            } else {
                /** NO OP because the assumption is a constant spot price
                 * E.g.
                 * priceInfo.indexPrice = priceInfo.indexPrice;
                 * priceInfo.smaInfo = priceInfo.smaInfo;
                 */
            }

            // Execute TotalCommitments in that period
            poolInfo = executeGivenCommit(
                commitQueue[i],
                calculateValueTransfer(
                    priceInfo.lastExecutedPrice,
                    priceInfo.indexPrice,
                    poolInfo,
                    readonlyPoolProps.leverageAmount,
                    readonlyPoolProps.poolManagementFee
                ),
                readonlyPoolProps.burningFee,
                readonlyPoolProps.mintingFee
            );

            // Update lastExecutedPrice
            priceInfo.lastExecutedPrice = priceInfo.indexPrice;

            // Update pendingSettlement
            cumulativePendingMintSettlement =
                cumulativePendingMintSettlement +
                commitQueue[i].longMintSettlement +
                commitQueue[i].shortMintSettlement;
        }

        return
            ExpectedPoolState({
                cumulativePendingMintSettlement: cumulativePendingMintSettlement,
                remainingPendingShortBurnTokens: poolInfo
                    .short
                    .pendingBurnPoolTokens,
                remainingPendingLongBurnTokens: poolInfo
                    .long
                    .pendingBurnPoolTokens,
                longBalance: poolInfo.long.settlementBalance,
                longSupply: poolInfo.long.supply,
                shortBalance: poolInfo.short.settlementBalance,
                shortSupply: poolInfo.short.supply,
                oraclePrice: priceInfo.indexPrice
            });
    }

    /** PURE FUNCTIONS */

    function getNewPrice(SMAInfo memory smaInfo, int256 spotPrice)
        public
        pure
        returns (int256, SMAInfo memory updatedSmaInfo)
    {
        unchecked {
            uint256 len = smaInfo.prices.length;
            int256 sum;

            // if len < numperiods; len + 1 : numPeriods - 1;
            uint256 updatedLen = len < smaInfo.numPeriods - 1
                ? len + 1
                : smaInfo.numPeriods - 1;
            updatedSmaInfo.prices = new int256[](updatedLen);

            for (uint256 i; i < len; i++) {
                sum += smaInfo.prices[i];

                if (i < len - 1) {
                    updatedSmaInfo.prices[i] = smaInfo.prices[i + 1];
                }
            }

            sum += spotPrice;
            updatedSmaInfo.prices[updatedLen - 1] = spotPrice;
            updatedSmaInfo.numPeriods = smaInfo.numPeriods;
            return (sum / int256(len + 1), updatedSmaInfo);
        }
    }

    /**
     * @notice Returns updated PoolInfo after value transfer.
     * @return newPoolInfo
     * @param oldPrice last executed price.
     * @param newPrice new price.
     * @param poolInfo pool info snapshot.
     * @param leverageAmount leverage.
     * @param poolManagementFee fee.
     */
    function calculateValueTransfer(
        int256 oldPrice,
        int256 newPrice,
        PoolInfo memory poolInfo,
        bytes16 leverageAmount,
        bytes16 poolManagementFee
    ) public pure returns (PoolInfo memory newPoolInfo) {
        (
            uint256 postXferLongBalance,
            uint256 postXferShortBalance,
            ,

        ) = PoolSwapLibrary.calculateValueTransfer(
                poolInfo.long.settlementBalance,
                poolInfo.short.settlementBalance,
                leverageAmount,
                oldPrice,
                newPrice,
                poolManagementFee
            );

        newPoolInfo = poolInfo;
        newPoolInfo.long.settlementBalance = postXferLongBalance;
        newPoolInfo.short.settlementBalance = postXferShortBalance;
    }

    /**
     * @notice Returns price of token given sideInfo.
     * @return price bytes16
     * @param sideInfo Information on the side to get price of.
     */
    function getPrice(SideInfo memory sideInfo) public pure returns (bytes16) {
        return
            PoolSwapLibrary.getPrice(
                sideInfo.settlementBalance,
                sideInfo.supply + sideInfo.pendingBurnPoolTokens
            );
    }

    function executeInstantSettlements(
        IPoolCommitter2.TotalCommitment memory totalCommitment,
        PoolInfo memory poolInfo,
        bytes16 burningFee,
        bytes16 mintingFee
    )
        public
        pure
        returns (
            uint256 longBurnInstantMintSettlement,
            uint256 shortBurnInstantMintSettlement
        )
    {
        // Amount of collateral tokens that are generated from burns into instant mints

        (longBurnInstantMintSettlement, , ) = PoolSwapLibrary
            .processBurnInstantMintCommit(
                totalCommitment.longBurnShortMintPoolTokens,
                getPrice(poolInfo.long),
                burningFee,
                mintingFee
            );

        (shortBurnInstantMintSettlement, , ) = PoolSwapLibrary
            .processBurnInstantMintCommit(
                totalCommitment.shortBurnLongMintPoolTokens,
                getPrice(poolInfo.short),
                burningFee,
                mintingFee
            );
    }

    function executeCommitsForSide(
        uint256 sideMintSettlement,
        SideInfo memory side,
        uint256 sideBurnInstantMintSettlement,
        uint256 totalBurnPoolTokens
    ) public pure returns (uint256 mintedPoolTokens, uint256 burnedPooltokens) {
        // Mints
        mintedPoolTokens = PoolSwapLibrary.getMintAmount(
            side.supply, // long token total supply,
            sideMintSettlement + sideBurnInstantMintSettlement, // Add the settlement tokens that will be generated from burning side for instant otherSide mint
            side.settlementBalance, // total quote tokens in the long pool
            side.pendingBurnPoolTokens // total pool tokens commited to be burned
        );

        // Burns
        burnedPooltokens = PoolSwapLibrary.getWithdrawAmountOnBurn(
            side.supply,
            totalBurnPoolTokens,
            side.settlementBalance,
            side.pendingBurnPoolTokens
        );
    }

    function executeGivenCommit(
        IPoolCommitter2.TotalCommitment memory totalCommitment,
        PoolInfo memory poolInfo,
        bytes16 burningFee,
        bytes16 mintingFee
    ) public pure returns (PoolInfo memory newPoolInfo) {
        newPoolInfo = PoolInfo({
            long: SideInfo({
                supply: poolInfo.long.supply,
                settlementBalance: totalCommitment.longMintSettlement +
                    poolInfo.long.settlementBalance,
                pendingBurnPoolTokens: poolInfo.long.pendingBurnPoolTokens
            }),
            short: SideInfo({
                supply: poolInfo.short.supply,
                settlementBalance: totalCommitment.shortMintSettlement +
                    poolInfo.short.settlementBalance,
                pendingBurnPoolTokens: poolInfo.short.pendingBurnPoolTokens
            })
        });

        // Flips
        (
            uint256 longBurnInstantMintSettlement,
            uint256 shortBurnInstantMintSettlement
        ) = executeInstantSettlements(
                totalCommitment,
                poolInfo,
                burningFee,
                mintingFee
            );

        newPoolInfo.short.settlementBalance += longBurnInstantMintSettlement;
        newPoolInfo.long.settlementBalance += shortBurnInstantMintSettlement;

        // Long mints & burns
        {
            uint256 totalLongBurnPoolTokens = totalCommitment
                .longBurnPoolTokens +
                totalCommitment.longBurnShortMintPoolTokens;

            (
                uint256 longMintPoolTokens,
                uint256 longBurnPoolTokens
            ) = executeCommitsForSide(
                    totalCommitment.longMintSettlement,
                    poolInfo.long,
                    shortBurnInstantMintSettlement,
                    totalLongBurnPoolTokens
                );

            newPoolInfo.long.settlementBalance -= longBurnPoolTokens;
            newPoolInfo.long.supply += longMintPoolTokens;
            newPoolInfo.long.pendingBurnPoolTokens -= totalLongBurnPoolTokens;
        }

        // Short mints & burns
        {
            uint256 totalShortBurnPoolTokens = totalCommitment
                .shortBurnPoolTokens +
                totalCommitment.shortBurnLongMintPoolTokens;

            (
                uint256 shortMintPoolTokens,
                uint256 shortBurnPoolTokens
            ) = executeCommitsForSide(
                    totalCommitment.shortMintSettlement,
                    poolInfo.short,
                    longBurnInstantMintSettlement,
                    totalShortBurnPoolTokens
                );

            newPoolInfo.short.settlementBalance -= shortBurnPoolTokens;
            newPoolInfo.short.supply += shortMintPoolTokens;
            newPoolInfo.short.pendingBurnPoolTokens -= totalShortBurnPoolTokens;
        }
    }
}
