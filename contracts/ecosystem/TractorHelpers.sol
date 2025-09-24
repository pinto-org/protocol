// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {Call, IWell, IERC20} from "../interfaces/basin/IWell.sol";
import {IBeanstalkWellFunction} from "contracts/interfaces/basin/IBeanstalkWellFunction.sol";
import {BeanstalkPrice, P} from "./price/BeanstalkPrice.sol";
import {ReservesType} from "./price/WellPrice.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {IOperatorWhitelist} from "contracts/ecosystem/OperatorWhitelist.sol";
import {LibSiloHelpers} from "contracts/libraries/Silo/LibSiloHelpers.sol";
import {console} from "forge-std/console.sol";

/**
 * @title TractorHelpers
 * @author FordPinto
 * @notice Helper contract for Silo operations. For use with Tractor.
 */
contract TractorHelpers {
    IBeanstalk immutable beanstalk;
    BeanstalkPrice immutable beanstalkPrice;

    enum RewardType {
        ERC20,
        ERC1155
    }

    enum TokenSort {
        ASC_SEEDS,
        ASC_PRICE
    }

    event OperatorReward(
        RewardType rewardType,
        address indexed publisher,
        address indexed operator,
        address token,
        int256 amount
    );

    constructor(address _beanstalk, address _beanstalkPrice) {
        beanstalk = IBeanstalk(_beanstalk);
        beanstalkPrice = BeanstalkPrice(_beanstalkPrice);
    }

    /**
     * @notice Returns the BeanstalkPrice contract address
     */
    function getBeanstalkPrice() external view returns (address) {
        return address(beanstalkPrice);
    }

    /**
     * @notice Returns all whitelisted assets and their seed values, sorted from highest to lowest seeds
     * @return tokens Array of token addresses
     * @return seeds Array of corresponding seed values
     */
    function getSortedWhitelistedTokensBySeeds()
        external
        view
        returns (address[] memory tokens, uint256[] memory seeds)
    {
        // Get whitelisted tokens
        tokens = getWhitelistStatusAddresses();
        seeds = new uint256[](tokens.length);

        // Get seed values for each token
        for (uint256 i = 0; i < tokens.length; i++) {
            seeds[i] = beanstalk.tokenSettings(tokens[i]).stalkEarnedPerSeason;
        }

        // Sort tokens and seeds arrays (bubble sort)
        (tokens, seeds) = sortTokens(tokens, seeds);

        return (tokens, seeds);
    }

    /**
     * @notice Returns the token with the highest seed value and its seed amount
     * @return highestSeedToken The token address with the highest seed value
     * @return seedAmount The seed value of the highest seed token
     */
    function getHighestSeedToken()
        external
        view
        returns (address highestSeedToken, uint256 seedAmount)
    {
        address[] memory tokens = getWhitelistStatusAddresses();
        require(tokens.length > 0, "No whitelisted tokens");

        highestSeedToken = tokens[0];
        seedAmount = beanstalk.tokenSettings(tokens[0]).stalkEarnedPerSeason;

        for (uint256 i = 1; i < tokens.length; i++) {
            uint256 currentSeed = beanstalk.tokenSettings(tokens[i]).stalkEarnedPerSeason;
            if (currentSeed > seedAmount) {
                seedAmount = currentSeed;
                highestSeedToken = tokens[i];
            }
        }

        return (highestSeedToken, seedAmount);
    }

    /**
     * @notice Returns the token with the lowest seed value and its seed amount
     * @return lowestSeedToken The token address with the lowest seed value
     * @return seedAmount The seed value of the lowest seed token
     */
    function getLowestSeedToken()
        external
        view
        returns (address lowestSeedToken, uint256 seedAmount)
    {
        address[] memory tokens = getWhitelistStatusAddresses();
        require(tokens.length > 0, "No whitelisted tokens");

        lowestSeedToken = tokens[0];
        seedAmount = beanstalk.tokenSettings(tokens[0]).stalkEarnedPerSeason;

        for (uint256 i = 1; i < tokens.length; i++) {
            uint256 currentSeed = beanstalk.tokenSettings(tokens[i]).stalkEarnedPerSeason;
            if (currentSeed < seedAmount) {
                seedAmount = currentSeed;
                lowestSeedToken = tokens[i];
            }
        }

        return (lowestSeedToken, seedAmount);
    }

    /**
     * @notice Helper function to get the address and stem from a deposit ID
     * @dev This is a copy of LibBytes.unpackAddressAndStem for gas purposes
     * @param depositId The ID of the deposit to get the address and stem for
     * @return token The address of the token
     * @return stem The stem value of the deposit
     */
    function getAddressAndStem(uint256 depositId) public pure returns (address token, int96 stem) {
        return (address(uint160(depositId >> 96)), int96(int256(depositId)));
    }

    /**
     * @notice Returns the index of a token in the whitelisted tokens array
     * @dev Returns 0 for the bean token, otherwise returns the index in the whitelisted tokens array
     * @param token The token to get the index for
     * @return index The index of the token (0 for bean token, otherwise index in whitelisted tokens array)
     */
    function getTokenIndex(address token) public view returns (uint8 index) {
        // This relies on the assumption that the Bean token is whitelisted first
        if (token == beanstalk.getBeanToken()) {
            return 0;
        }
        address[] memory whitelistedTokens = getWhitelistStatusAddresses();
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            if (whitelistedTokens[i] == token) {
                return uint8(i);
            }
        }
        revert("Token not found");
    }

    /**
     * @notice Returns arrays of stems and amounts for all deposits, sorted by stem in descending order
     * @dev This function could be made more gas efficient by using a more efficient sorting algorithm
     * @param account The address of the account that owns the deposits
     * @param token The token to get deposits for
     * @return stems Array of stems in descending order
     * @return amounts Array of corresponding amounts for each stem
     */
    function getSortedDeposits(
        address account,
        address token
    ) public view returns (int96[] memory stems, uint256[] memory amounts) {
        uint256[] memory depositIds = beanstalk.getTokenDepositIdsForAccount(account, token);
        if (depositIds.length == 0) revert("No deposits");

        // Initialize arrays with exact size since we know all deposits are valid
        stems = new int96[](depositIds.length);
        amounts = new uint256[](depositIds.length);

        // Collect all deposits
        for (uint256 i = 0; i < depositIds.length; i++) {
            (, int96 stem) = getAddressAndStem(depositIds[i]);
            (uint256 amount, ) = beanstalk.getDeposit(account, token, stem);
            stems[i] = stem;
            amounts[i] = amount;
        }

        // Sort deposits by stem in descending order using bubble sort
        for (uint256 i = 0; i < depositIds.length - 1; i++) {
            for (uint256 j = 0; j < depositIds.length - i - 1; j++) {
                if (stems[j] < stems[j + 1]) {
                    // Swap stems
                    int96 tempStem = stems[j];
                    stems[j] = stems[j + 1];
                    stems[j + 1] = tempStem;

                    // Swap corresponding amounts
                    uint256 tempAmount = amounts[j];
                    amounts[j] = amounts[j + 1];
                    amounts[j + 1] = tempAmount;
                }
            }
        }
    }

    /**
     * @notice Returns the amount of LP tokens that must be withdrawn to receive a specific amount of Beans
     * @param beanAmount The amount of Beans desired
     * @param well The Well LP token address
     * @return lpAmount The amount of LP tokens needed
     */
    function getLPTokensToWithdrawForBeans(
        uint256 beanAmount,
        address well
    ) public view returns (uint256 lpAmount) {
        // Get current reserves if not provided
        uint256[] memory reserves = IWell(well).getReserves();

        // Get bean index in the well
        uint256 beanIndex = beanstalk.getBeanIndex(IWell(well).tokens());

        // Get the well function
        Call memory wellFunction = IWell(well).wellFunction();

        // Calculate current LP supply
        uint256 lpSupplyNow = IBeanstalkWellFunction(wellFunction.target).calcLpTokenSupply(
            reserves,
            wellFunction.data
        );

        // Calculate reserves after removing beans

        reserves[beanIndex] = reserves[beanIndex] - beanAmount;

        // Calculate new LP supply after removing beans
        uint256 lpSupplyAfter = IBeanstalkWellFunction(wellFunction.target).calcLpTokenSupply(
            reserves,
            wellFunction.data
        );

        // The difference is how many LP tokens need to be removed in order to withdraw beanAmount
        return lpSupplyNow - lpSupplyAfter;
    }

    /**
     * @notice Returns all whitelisted tokens sorted by seed value (ascending)
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by seed value (ascending)
     * @return seeds Array of corresponding seed values
     */
    function getTokensAscendingSeeds()
        public
        view
        returns (uint8[] memory tokenIndices, uint256[] memory seeds)
    {
        return getTokensAscendingSeeds(false);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by seed value (ascending)
     * @param excludeBean If true, excludes the Bean token from the returned arrays
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by seed value (ascending)
     * @return seeds Array of corresponding seed values
     */
    function getTokensAscendingSeeds(
        bool excludeBean
    ) public view returns (uint8[] memory tokenIndices, uint256[] memory seeds) {
        return getTokens(TokenSort.ASC_SEEDS, excludeBean, 0);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by seed value (ascending), dependent on seedDifference
     * @param seedDifference if nonzero, checks whether the difference between the input token and pinto seeds exceed the difference.
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by seed value (ascending)
     * @return seeds Array of corresponding seed values
     */
    function getTokensAscendingSeedsWithDifference(
        bool excludeBean,
        int256 seedDifference
    ) public view returns (uint8[] memory tokenIndices, uint256[] memory seeds) {
        return getTokens(TokenSort.ASC_SEEDS, excludeBean, seedDifference);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by price (ascending)
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by price (ascending)
     * @return prices Array of corresponding prices
     */
    function getTokensAscendingPrice()
        public
        view
        returns (uint8[] memory tokenIndices, uint256[] memory prices)
    {
        return getTokensAscendingPrice(false);
    }

    /**
     * @notice Returns all whitelisted tokens sorted by price (ascending)
     * @param excludeBean If true, excludes the Bean token from the returned arrays
     * @return tokenIndices Array of token indices in the whitelisted tokens array, sorted by price (ascending)
     * @return prices Array of corresponding prices
     */
    function getTokensAscendingPrice(
        bool excludeBean
    ) public view returns (uint8[] memory tokenIndices, uint256[] memory prices) {
        return getTokens(TokenSort.ASC_PRICE, excludeBean, 0);
    }

    /**
     * @dev internal function that gets the tokens
     * given the sort type, whether we want to exclude beans, and the seed diff (if sort type is asc seeds)
     */
    function getTokens(
        TokenSort sort,
        bool excludeBean,
        int256 seedDifference
    ) internal view returns (uint8[] memory tokenIndices, uint256[] memory values) {
        // Get whitelisted tokens with their status
        IBeanstalk.WhitelistStatus[] memory ws = beanstalk.getWhitelistStatuses();
        require(ws.length > 0, "No whitelisted tokens");

        // Initialize arrays with the count of active whitelistStatus
        tokenIndices = new uint8[](ws.length);
        values = new uint256[](ws.length);

        (tokenIndices, values) = getIndicesAndValues(
            ws,
            excludeBean,
            seedDifference,
            sort,
            tokenIndices,
            values
        );

        // Sort values if length greater than 1.
        if (tokenIndices.length > 1) {
            (tokenIndices, values) = sortTokenIndices(tokenIndices, values);
        }
    }

    /**
     * @dev contains internal logic to getIndicesAndValues
     */
    function getIndicesAndValues(
        IBeanstalk.WhitelistStatus[] memory ws,
        bool excludeBean,
        int256 seedDifference, // only used if sort.ASC_SEEDS is enabled.
        TokenSort sort,
        uint8[] memory tokenIndices,
        uint256[] memory values
    ) internal view returns (uint8[] memory, uint256[] memory) {
        // initialize variables, set based on `sort` type.
        BeanstalkPrice.Prices memory p;
        uint256 beanSeeds;

        address beanToken = beanstalk.getBeanToken();

        if (sort == TokenSort.ASC_PRICE) {
            p = beanstalkPrice.price(ReservesType.INSTANTANEOUS_RESERVES);
        } else if (sort == TokenSort.ASC_SEEDS && seedDifference != 0) {
            beanSeeds = beanstalk.getSeedsForToken(beanToken);
        }
        // `tokenIndices` uses the original index from whitelistStatuses in order to
        // determine what token to use. Thus, `activeIndex` is used to set the entry in the array,
        // and `i` is used to denote the index of `whitelistStatuses`.
        uint256 activeIndex = 0;
        for (uint256 i; i < ws.length; i++) {
            if (ws[i].isWhitelisted) {
                // Skip Bean token if excludeBean is true
                if (excludeBean && ws[i].token == beanToken) {
                    continue;
                }

                if (sort == TokenSort.ASC_PRICE) {
                    tokenIndices[activeIndex] = uint8(i);
                    values[activeIndex] = getTokenPrice(ws[i].token, p);
                } else if (sort == TokenSort.ASC_SEEDS) {
                    uint256 tokenSeeds = beanstalk.getSeedsForToken(ws[i].token);
                    if (
                        seedDifference != 0 &&
                        !checkForSeedDifference(tokenSeeds, beanSeeds, seedDifference)
                    ) {
                        continue;
                    }
                    tokenIndices[activeIndex] = uint8(i);
                    values[activeIndex] = tokenSeeds;
                }

                activeIndex++;
            }
        }

        assembly {
            mstore(tokenIndices, activeIndex)
            mstore(values, activeIndex)
        }

        return (tokenIndices, values);
    }

    /**
     * @notice Helper function to get the price of a token from BeanstalkPrice
     * @param token The token to get the price for
     * @param p The Prices struct from BeanstalkPrice
     * @return price The price of the token
     */
    function getTokenPrice(
        address token,
        BeanstalkPrice.Prices memory p
    ) internal view returns (uint256 price) {
        address bean = beanstalk.getBeanToken();
        if (token == bean) {
            return p.price;
        }
        // Find the non-Bean token in the pool's tokens array
        for (uint256 j = 0; j < p.ps.length; j++) {
            if (p.ps[j].pool == token) {
                return p.ps[j].price;
            }
        }
        revert("Token price not found");
    }

    /**
     * @notice Sorts tokens in ascending order based on the index array
     * @param tokens The tokens to sort
     * @param index The index array
     * @return sortedTokens The sorted tokens
     * @return sortedIndex The sorted index
     */
    function sortTokens(
        address[] memory tokens,
        uint256[] memory index
    ) internal pure returns (address[] memory, uint256[] memory) {
        for (uint256 i = 0; i < tokens.length - 1; i++) {
            for (uint256 j = 0; j < tokens.length - i - 1; j++) {
                uint256 j1 = j + 1;
                if (index[j] < index[j1]) {
                    // Swap index
                    (index[j], index[j1]) = (index[j1], index[j]);

                    // Swap corresponding tokens
                    (tokens[j], tokens[j1]) = (tokens[j1], tokens[j]);
                }
            }
        }
        return (tokens, index);
    }

    function sortTokenIndices(
        uint8[] memory tokenIndices,
        uint256[] memory index
    ) internal pure returns (uint8[] memory, uint256[] memory) {
        for (uint256 i = 0; i < tokenIndices.length - 1; i++) {
            for (uint256 j = 0; j < tokenIndices.length - i - 1; j++) {
                uint256 j1 = j + 1;
                if (index[j] > index[j1]) {
                    // Swap index
                    (index[j], index[j1]) = (index[j1], index[j]);

                    // Swap token indices
                    (tokenIndices[j], tokenIndices[j1]) = (tokenIndices[j1], tokenIndices[j]);
                }
            }
        }
        return (tokenIndices, index);
    }

    /**
     * @notice helper function to tip the operator.
     * @dev if `tipAmount` is negative, the publisher is tipped instead.
     */
    function tip(
        address token,
        address publisher,
        address tipAddress,
        int256 tipAmount,
        LibTransfer.From from,
        LibTransfer.To to
    ) external {
        // Handle tip transfer based on whether it's positive or negative
        if (tipAmount > 0) {
            // Transfer tip to operator
            beanstalk.transferToken(IERC20(token), tipAddress, uint256(tipAmount), from, to);
        } else if (tipAmount < 0) {
            // Transfer tip from operator to user
            beanstalk.transferInternalTokenFrom(
                IERC20(token),
                tipAddress,
                publisher,
                uint256(-tipAmount),
                to
            );
        }

        emit OperatorReward(RewardType.ERC20, publisher, tipAddress, token, tipAmount);
    }

    /**
     * @notice Checks if the current operator is whitelisted
     * @param whitelistedOperators Array of whitelisted operator addresses
     * @return isWhitelisted Whether the current operator is whitelisted
     */
    function isOperatorWhitelisted(
        address[] calldata whitelistedOperators
    ) external view returns (bool) {
        // If there are no whitelisted operators, pass in, accept any operator
        if (whitelistedOperators.length == 0) {
            return true;
        }

        address currentOperator = beanstalk.operator();
        for (uint256 i = 0; i < whitelistedOperators.length; i++) {
            address checkAddress = whitelistedOperators[i];
            if (checkAddress == currentOperator) {
                return true;
            } else {
                // Skip if address is a precompiled contract (address < 0x20)
                if (uint160(checkAddress) <= 0x20) continue;

                // Check if the address is a contract before attempting staticcall
                uint256 size;
                assembly {
                    size := extcodesize(checkAddress)
                }

                if (size > 0) {
                    try
                        IOperatorWhitelist(checkAddress).checkOperatorWhitelist(currentOperator)
                    returns (bool success) {
                        if (success) {
                            return true;
                        }
                    } catch {
                        // If the call fails, continue to the next address
                        continue;
                    }
                }
            }
        }
        return false;
    }

    /**
     * @notice Combines multiple withdrawal plans into a single plan
     * @dev This function aggregates the amounts used from each deposit across all plans
     * @param plans Array of withdrawal plans to combine
     * @return combinedPlan A single withdrawal plan that represents the total usage across all input plans
     */
    function combineWithdrawalPlans(
        LibSiloHelpers.WithdrawalPlan[] memory plans
    ) external view returns (LibSiloHelpers.WithdrawalPlan memory) {
        // Call the library function directly
        return LibSiloHelpers.combineWithdrawalPlans(plans, beanstalk);
    }

    /**
     * @notice Returns the addresses of all whitelisted tokens, even those that have been Dewhitelisted
     * @return addresses The addresses of all whitelisted tokens
     */
    function getWhitelistStatusAddresses() public view returns (address[] memory) {
        IBeanstalk.WhitelistStatus[] memory whitelistStatuses = beanstalk.getWhitelistStatuses();
        address[] memory addresses = new address[](whitelistStatuses.length);
        for (uint256 i = 0; i < whitelistStatuses.length; i++) {
            addresses[i] = whitelistStatuses[i].token;
        }
        return addresses;
    }

    /**
     * @notice Verifies if the difference between the token seeds and the bean seeds exceeds the seed difference
     * @param tokenSeeds The seeds of the token
     * @param beanSeeds The seeds of the bean
     * @param seedDifference The seed difference
     * @return true if the difference exceeds the seed difference, false otherwise
     * @dev `checkForSeedDifference` should only be called when `seedDifference` is nonZero
     */
    function checkForSeedDifference(
        uint256 tokenSeeds,
        uint256 beanSeeds,
        int256 seedDifference
    ) public pure returns (bool) {
        if (seedDifference > 0) {
            // bean seeds needs to be greater than the token seeds + seed difference
            // to be valid
            if (beanSeeds < tokenSeeds + uint256(seedDifference)) {
                return false;
            }
        } else {
            // if the difference is negative, the bean seeds
            // can be UP TO `seedDifference` less than the token seeds.
            if (beanSeeds + uint256(-seedDifference) < tokenSeeds) {
                return false;
            }
        }
        return true;
    }
}
