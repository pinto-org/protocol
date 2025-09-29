/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity ^0.8.20;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {LibRedundantMath128} from "contracts/libraries/Math/LibRedundantMath128.sol";
import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {LibTransfer} from "contracts/libraries/Token/LibTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBeanstalk} from "contracts/interfaces/IBeanstalk.sol";
import {LibBytes64} from "contracts/libraries/LibBytes64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {TractorEnabled} from "contracts/ecosystem/TractorEnabled.sol";

/**
 * @dev Fertilizer tailored implementation of the ERC-1155 standard.
 * We rewrite transfer and mint functions to allow the balance transfer function be overwritten as well.
 * Merged from multiple contracts: Fertilizer.sol, Internalizer.sol, Fertilizer1155.sol from the beanstalk protocol.
 */
abstract contract BeanstalkFertilizer is
    ERC1155Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    TractorEnabled
{
    using LibRedundantMath256 for uint256;
    using LibRedundantMath128 for uint128;
    using Strings for uint256;

    event ClaimFertilizer(uint256[] ids, uint256 beans);

    struct Balance {
        uint128 amount;
        uint128 lastBpf;
    }

    /**
     * @dev Data for initialization of the fertilizer state
     * note: the fertilizerIds and fertilizerAmounts should be the same length and in ascending order
     */
    struct InitSystemFertilizer {
        uint128[] fertilizerIds;
        uint256[] fertilizerAmounts;
        uint256 activeFertilizer;
        uint256 fertilizedIndex;
        uint256 unfertilizedIndex;
        uint256 fertilizedPaidIndex;
        uint128 fertFirst;
        uint128 fertLast;
        uint128 bpf;
        uint256 leftoverBeans;
    }

    /**
     * @notice Fertilizer state.
     * @param fertilizer A mapping from Fertilizer Id to the supply of Fertilizer for each Id.
     * @param nextFid A linked list of Fertilizer Ids ordered by Id number.
     * - Fertilizer Id is the Beans Per Fertilzer level at which the Fertilizer no longer receives Beans.
     * - Sort in order by which Fertilizer Id expires next.
     * @param activeFertilizer The number of active Fertilizer.
     * @param fertilizedIndex The total number of Fertilizer Beans (paid out).
     * @param unfertilizedIndex The total number of Unfertilized Beans ever (total debt).
     * @param fertilizedPaidIndex The total number of Fertilizer Beans that have been sent out to users.
     * @param fertFirst The lowest active Fertilizer Id (start of linked list that is stored by nextFid).
     * @param fertLast The highest active Fertilizer Id (end of linked list that is stored by nextFid).
     * @param bpf The cumulative Beans Per Fertilizer (bfp) minted over all Seasons.
     * @param leftoverBeans Amount of Beans that have shipped to Fert but not yet reflected in bpf.
     */
    struct SystemFertilizer {
        mapping(uint128 id => uint256 amount) fertilizer;
        mapping(uint128 id => uint128 nextId) nextFid;
        uint256 activeFertilizer;
        uint256 fertilizedIndex;
        uint256 unfertilizedIndex;
        uint256 fertilizedPaidIndex;
        uint128 fertFirst;
        uint128 fertLast;
        uint128 bpf;
        uint256 leftoverBeans;
    }

    // Storage
    mapping(uint256 id => mapping(address account => Balance)) internal _balances;
    SystemFertilizer public fert;
    IERC20 public pintoToken;
    address public contractDistributor;

    /// @dev gap for future upgrades
    uint256[50] private __gap;

    /**
     * @notice Initializes the contract, sets global fertilizer state, and batch mints all fertilizers.
     * @param _pintoToken The address of the Pinto ERC20 token.
     * @param initSystemFert The initialglobal fertilizer state data.
     */
    function initialize(
        address _pintoToken,
        address _pintoProtocol,
        address _contractDistributor,
        InitSystemFertilizer calldata initSystemFert
    ) public virtual onlyInitializing {
        // Inheritance Inits
        __ERC1155_init("");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        // State Inits
        pintoToken = IERC20(_pintoToken);
        pintoProtocol = IBeanstalk(_pintoProtocol);
        contractDistributor = _contractDistributor;
        setFertilizerState(initSystemFert);
        // approve the pinto protocol to spend the incoming pintoToken tokens for claims
        pintoToken.approve(address(pintoProtocol), type(uint256).max);
        // Minting will happen after deployment due to potential gas limit issues
    }

    /**
     * @notice Sets the global fertilizer state.
     * @param systemFert The fertilizer state data.
     */
    function setFertilizerState(InitSystemFertilizer calldata systemFert) internal {
        // init mappings
        for (uint256 i; i < systemFert.fertilizerIds.length; i++) {
            fert.fertilizer[systemFert.fertilizerIds[i]] = systemFert.fertilizerAmounts[i];
            if (i != 0) fert.nextFid[systemFert.fertilizerIds[i - 1]] = systemFert.fertilizerIds[i];
        }
        // init state
        fert.activeFertilizer = systemFert.activeFertilizer;
        fert.fertilizedIndex = systemFert.fertilizedIndex;
        fert.unfertilizedIndex = systemFert.unfertilizedIndex;
        fert.fertilizedPaidIndex = systemFert.fertilizedPaidIndex;
        fert.fertFirst = systemFert.fertFirst;
        fert.fertLast = systemFert.fertLast;
        fert.bpf = systemFert.bpf;
        fert.leftoverBeans = systemFert.leftoverBeans;
    }

    //////////////////////////// ERC-1155 Functions ////////////////////////////

    function _safeMint(address to, uint256 id, uint256 amount, bytes memory data) internal virtual {
        require(to != address(0), "ERC1155: mint to the zero address");

        address operator = _msgSender();

        _transfer(address(0), to, id, amount);

        emit TransferSingle(operator, address(0), to, id, amount);

        __doSafeTransferAcceptanceCheck(operator, address(0), to, id, amount, data);
    }

    //////////////////////////// Transfer Functions ////////////////////////////

    /**
     * @notice Transfers a fertilizer id from one account to another
     * @param from - the account to transfer from
     * @param to - the account to transfer to
     * @param id - the fertilizer id
     * @param amount - the amount of fertilizer to transfer
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public virtual override {
        require(to != address(0), "ERC1155: transfer to the zero address");
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not owner nor approved"
        );

        address operator = _msgSender();

        _beforeTokenTransfer(
            operator,
            from,
            to,
            __asSingletonArray(id),
            __asSingletonArray(amount),
            data
        );

        _transfer(from, to, id, amount);

        emit TransferSingle(operator, from, to, id, amount);

        __doSafeTransferAcceptanceCheck(operator, from, to, id, amount, data);
    }

    /**
     * @notice Transfers a batch of fertilizers from one account to another
     * @param from - the account to transfer from
     * @param to - the account to transfer to
     * @param ids - the fertilizer ids
     * @param amounts - the amounts of fertilizer to transfer
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public virtual override {
        require(ids.length == amounts.length, "ERC1155: ids and amounts length mismatch");
        require(to != address(0), "ERC1155: transfer to the zero address");
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: transfer caller is not owner nor approved"
        );

        address operator = _msgSender();

        _beforeTokenTransfer(operator, from, to, ids, amounts, data);

        for (uint256 i; i < ids.length; ++i) {
            _transfer(from, to, ids[i], amounts[i]);
        }

        emit TransferBatch(operator, from, to, ids, amounts);

        __doSafeBatchTransferAcceptanceCheck(operator, from, to, ids, amounts, data);
    }

    /**
     * @notice Transfers a fertilizer from one account to another by changing the internal balances mapping
     * @param from - the account to transfer from
     * @param to - the account to transfer to
     * @param id - the fertilizer id
     * @param amount - the amount of fertilizer to transfer
     */
    function _transfer(address from, address to, uint256 id, uint256 amount) internal virtual {
        uint128 _amount = uint128(amount);
        if (from != address(0)) {
            uint128 fromBalance = _balances[id][from].amount;
            require(uint256(fromBalance) >= amount, "ERC1155: insufficient balance for transfer");
            _balances[id][from].amount = fromBalance - _amount;
        }
        _balances[id][to].amount = _balances[id][to].amount.add(_amount);
    }

    /**
     * @notice Checks if a fertilizer transfer is accepted by the recipient in case of a contract
     * @dev copied from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC1155/ERC1155.sol)
     */
    function __doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private {
        if (isContract(to)) {
            try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (
                bytes4 response
            ) {
                if (response != IERC1155Receiver.onERC1155Received.selector) {
                    revert("ERC1155: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non ERC1155Receiver implementer");
            }
        }
    }

    /**
     * @notice Checks if a batch of fertilizer transfers are accepted by the recipient in case of a contract
     * @dev copied from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC1155/ERC1155.sol)
     */
    function __doSafeBatchTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) private {
        if (isContract(to)) {
            try
                IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data)
            returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155BatchReceived.selector) {
                    revert("ERC1155: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non ERC1155Receiver implementer");
            }
        }
    }

    /**
     * @notice Updates the reward state for both the sender and recipient and transfers pinto token rewards.
     * Following the 1155 design from OpenZeppelin Contracts < 5.x.
     * @param from - the account to transfer from
     * @param to - the account to transfer to
     * @param ids - an array of fertilizer ids
     */
    function _beforeTokenTransfer(
        address, // operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory, // amounts
        bytes memory // data
    ) internal virtual {
        uint256 bpf = uint256(fert.bpf);
        if (from != address(0)) _update(from, ids, bpf);
        _update(to, ids, bpf);
    }

    //////////////////////////// Internal State Updates ////////////////////////////

    /**
     * @notice Calculates and transfers the rewarded beans
     * from a set of fertilizer ids to an account's internal balance
     * @dev _update is called as a hook before token transfers so the user does not specify the transfer mode
     * In this case, we use internal balance to transfer the pintos to the user by default.
     * @param account - the user to update
     * @param ids - an array of fertilizer ids
     * @param bpf - the beans per fertilizer
     */
    function _update(address account, uint256[] memory ids, uint256 bpf) internal {
        uint256 amount = __update(account, ids, bpf);
        if (amount > 0) {
            fert.fertilizedPaidIndex += amount;
            // Transfer the rewards to the caller,
            // note: pintos are streamed to the contract's external balance during the gm call
            pintoProtocol.transferToken(
                pintoToken,
                account,
                amount,
                LibTransfer.From.EXTERNAL,
                LibTransfer.To.INTERNAL
            );
        }
    }

    /**
     * @notice Calculates and updates the amount of beans a user should receive
     * given a set of fertilizer ids and the current outstanding total beans per fertilizer
     * @param account - the user to update
     * @param ids - the fertilizer ids
     * @param bpf - the current beans per fertilizer
     * @return beans - the amount of beans to reward the fertilizer owner
     */
    function __update(
        address account,
        uint256[] memory ids,
        uint256 bpf
    ) internal returns (uint256 beans) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 stopBpf = bpf < ids[i] ? bpf : ids[i];
            uint256 deltaBpf = stopBpf - _balances[ids[i]][account].lastBpf;
            if (deltaBpf > 0) {
                beans = beans.add(deltaBpf.mul(_balances[ids[i]][account].amount));
                _balances[ids[i]][account].lastBpf = uint128(stopBpf);
            }
        }
        emit ClaimFertilizer(ids, beans);
    }

    /**
     * @dev Removes the first fertilizer id in the queue.
     * fFirst is the lowest active Fertilizer Id (see SystemFertilizer struct)
     * (start of linked list that is stored by nextFid).
     * @return bool Whether the queue is empty.
     */
    function fertilizerPop() internal returns (bool) {
        uint128 first = fert.fertFirst;
        fert.activeFertilizer = fert.activeFertilizer.sub(getAmount(first));
        uint128 next = getNext(first);
        if (next == 0) {
            // If all Unfertilized Beans have been fertilized, delete line.
            require(fert.activeFertilizer == 0, "Still active fertilizer");
            fert.fertFirst = 0;
            fert.fertLast = 0;
            return false;
        }
        fert.fertFirst = getNext(first);
        return true;
    }

    /**
     * @notice Returns a singleton array with the given element
     * @dev copied from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC1155/ERC1155.sol)
     */
    function __asSingletonArray(uint256 element) private pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = element;
        return array;
    }

    //////////////////////////// Getters ////////////////////////////////

    /**
     * @dev Returns the next fertilizer id in the linked list.
     * @param id The id of the fertilizer.
     */
    function getNext(uint128 id) internal view returns (uint128) {
        return fert.nextFid[id];
    }

    /**
     * @dev Returns the amount (supply) of fertilizer for a given id.
     * @param id The id of the fertilizer.
     */
    function getAmount(uint128 id) internal view returns (uint256) {
        return fert.fertilizer[id];
    }

    /**
     * @notice Returns the balance of fertilized beans of a fertilizer owner given
      a set of fertilizer ids
     * @param account - the fertilizer owner
     * @param ids - the fertilizer ids 
     * @return beans - the amount of fertilized beans the fertilizer owner has
     */
    function balanceOfFertilized(
        address account,
        uint256[] memory ids
    ) external view returns (uint256 beans) {
        uint256 bpf = uint256(fert.bpf);
        for (uint256 i; i < ids.length; ++i) {
            uint256 stopBpf = bpf < ids[i] ? bpf : ids[i];
            uint256 deltaBpf = stopBpf - _balances[ids[i]][account].lastBpf;
            beans = beans.add(deltaBpf.mul(_balances[ids[i]][account].amount));
        }
    }

    /**
     * @notice Returns the balance of unfertilized beans of a fertilizer owner given
      a set of fertilizer ids
     * @param account - the fertilizer owner
     * @param ids - the fertilizer ids 
     * @return beans - the amount of unfertilized beans the fertilizer owner has
     */
    function balanceOfUnfertilized(
        address account,
        uint256[] memory ids
    ) external view returns (uint256 beans) {
        uint256 bpf = uint256(fert.bpf);
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] > bpf)
                beans = beans.add(ids[i].sub(bpf).mul(_balances[ids[i]][account].amount));
        }
    }

    /**
     * @notice Returns the total pinto tokens needed to repay the barn
     */
    function totalUnfertilizedBeans() public view returns (uint256 beans) {
        return fert.unfertilizedIndex - fert.fertilizedIndex;
    }

    /**
     * @notice Returns the balance of a fertilizer owner given a fertilizer id
     * @param account - the fertilizer owner
     * @param id - the fertilizer id
     * @return balance - the balance of the fertilizer owner
     */
    function balanceOf(address account, uint256 id) public view virtual override returns (uint256) {
        require(account != address(0), "ERC1155: balance query for the zero address");
        return _balances[id][account].amount;
    }

    /**
     * @notice Returns the balance of a fertilizer owner given a set of fertilizer ids
     * @param account - the fertilizer owner
     * @param id - the fertilizer id
     * @return balance - the balance of the fertilizer owner
     */
    function lastBalanceOf(address account, uint256 id) public view returns (Balance memory) {
        require(account != address(0), "ERC1155: balance query for the zero address");
        return _balances[id][account];
    }

    /**
     * @notice Returns the balance of a fertilizer owner given a set of fertilizer ids
     * @param accounts - the fertilizer owners
     * @param ids - the fertilizer ids
     * @return balances - the balances of the fertilizer owners
     */
    function lastBalanceOfBatch(
        address[] memory accounts,
        uint256[] memory ids
    ) external view returns (Balance[] memory balances) {
        balances = new Balance[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            balances[i] = lastBalanceOf(accounts[i], ids[i]);
        }
    }

    /////////////////////// Metadata ///////////////////////////

    /**
     * @notice Assembles and returns a base64 encoded json metadata
     * URI for a given fertilizer ID.
     * @param _id - the id of the fertilizer
     * @return - the json metadata URI
     */
    function uri(uint256 _id) public view virtual override returns (string memory) {
        // get the remaining bpf (id - fert.bpf)
        uint128 bpfRemaining = uint128(_id) >= fert.bpf ? uint128(_id) - fert.bpf : 0;

        // get the image URI
        string memory imageUri = imageURI(_id, bpfRemaining);

        // assemble and return the json URI
        return (
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    LibBytes64.encode(
                        bytes(
                            abi.encodePacked(
                                '{"name": "Beanstalk Payback Fertilizer", ',
                                '"description": "The Beanstalk Payback Barn fertilizer pays back Beanstalk fertilizer holders with Pinto after the 1 billion supply threshold is reached.", "image": "',
                                imageUri,
                                '", "attributes": [{ "trait_type": "BPF Remaining","display_type": "boost_number","value": ',
                                formatBpRemaining(bpfRemaining),
                                " }]}"
                            )
                        )
                    )
                )
            )
        );
    }

    /**
     * @dev imageURI returns the base64 encoded image URI representation of the Fertilizer
     * @param _id - the id of the Fertilizer
     * @param bpfRemaining - the bpfRemaining of the Fertilizer
     * @return imageUri - the image URI representation of the Fertilizer
     */
    function imageURI(uint256 _id, uint128 bpfRemaining) public view returns (string memory) {
        return "";
    }

    function name() external pure returns (string memory) {
        return "Beanstalk Payback Fertilizer";
    }

    function symbol() external pure returns (string memory) {
        return "bsFERT";
    }

    /**
     * @notice Formats a the bpf remaining value with 6 decimals to a string with 2 decimals.
     * @param number - The bpf value to format.
     */
    function formatBpRemaining(uint256 number) internal pure returns (string memory) {
        // 6 to 2 decimal places
        uint256 scaled = number / 10000;
        // Separate the integer and decimal parts
        uint256 integerPart = scaled / 100;
        uint256 decimalPart = scaled % 100;
        string memory result = integerPart.toString();
        // Add decimal point
        result = string(abi.encodePacked(result, "."));
        // Add leading zero if necessary
        if (decimalPart < 10) {
            result = string(abi.encodePacked(result, "0"));
        }
        // Add decimal part
        result = string(abi.encodePacked(result, decimalPart.toString()));
        return result;
    }

    /**
     * @notice Checks if an account is a contract.
     */
    function isContract(address account) internal view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
