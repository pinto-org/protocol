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

/**
 * @dev Fertilizer tailored implementation of the ERC-1155 standard.
 * We rewrite transfer and mint functions to allow the balance transfer function be overwritten as well.
 * Merged from multiple contracts: Fertilizer.sol, Internalizer.sol, Fertilizer1155.sol
 * All metadata-related functionality has been removed.
 */
contract BarnPayback is ERC1155Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using LibRedundantMath256 for uint256;
    using LibRedundantMath128 for uint128;

    event ClaimFertilizer(uint256[] ids, uint256 beans);

    struct Balance {
        uint128 amount;
        uint128 lastBpf;
    }

    /**
     * @notice contains data per account for Fertilizer.
     */
    struct AccountFertilizerData {
        address account;
        uint128 amount;
        uint128 lastBpf;
    }

    /**
     * @notice Fertilizers contains the ids, accounts, amounts, and lastBpf of each Fertilizer.
     * @dev fertilizerIds MUST be in ascending order.
     * for each fert id --> all accounts --> amount, lastBpf
     */
    struct Fertilizers {
        uint128 fertilizerId;
        AccountFertilizerData[] accountData;
    }

    /**
     * @notice contains data related to the system's fertilizer (static system).
     * @param fertilizerIds Array of fertilizer IDs in ascending order.
     * @param fertilizerAmounts Array of fertilizer amounts corresponding to each ID.
     * @param fertilizedIndex The total number of Fertilizer Beans that have been fertilized.
     * @param fertilizedPaidIndex The total number of Fertilizer Beans that have been sent out to users.
     * @param bpf The cumulative Beans Per Fertilizer (bfp) minted over all Seasons.
     * @param leftoverBeans Amount of Beans that have shipped to Fert but not yet reflected in bpf.
     */
    struct SystemFertilizer {
        uint128[] fertilizerIds;
        uint256[] fertilizerAmounts;
        uint256 fertilizedIndex;
        uint256 fertilizedPaidIndex;
        uint128 bpf;
        uint256 leftoverBeans;
    }

    // Storage
    mapping(uint256 => mapping(address => Balance)) internal _balances;
    SystemFertilizer internal fert;
    IERC20 public pinto;

    //////////////////////////// Initialization ////////////////////////////

    /**
     * @notice Initializes the contract, sets global fertilizer state, and batch mints all fertilizers.
     * @param _pinto The address of the Pinto ERC20 token.
     * @param systemFert The global fertilizer state data.
     * @param fertilizerIds Array of fertilizer account data to initialize.
     */
    function init(
        address _pinto,
        SystemFertilizer calldata systemFert,
        Fertilizers[] calldata fertilizerIds
    ) external initializer {
        // Inheritance Inits
        __ERC1155_init("");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        // State Inits
        pinto = IERC20(_pinto);
        setFertilizerState(systemFert);
        // Minting will happen after deployment due to potential gas limit issues
    }

    /**
     * @notice Sets the global fertilizer state.
     * @param systemFert The fertilizer state data.
     */
    function setFertilizerState(SystemFertilizer calldata systemFert) internal {
        fert.fertilizerIds = systemFert.fertilizerIds;
        fert.fertilizerAmounts = systemFert.fertilizerAmounts;
        fert.fertilizedIndex = systemFert.fertilizedIndex;
        fert.fertilizedPaidIndex = systemFert.fertilizedPaidIndex;
        fert.bpf = systemFert.bpf;
        fert.leftoverBeans = systemFert.leftoverBeans;
    }

    /**
     * @notice Batch mints fertilizers to all accounts and initializes balances.
     * @param fertilizerIds Array of fertilizer data containing ids, accounts, amounts, and lastBpf.
     */
    function mintFertilizers(Fertilizers[] calldata fertilizerIds) external onlyOwner {
        for (uint i; i < fertilizerIds.length; i++) {
            Fertilizers memory f = fertilizerIds[i];
            uint128 fid = f.fertilizerId;

            // Mint fertilizer to each holder
            for (uint j; j < f.accountData.length; j++) {
                if (!isContract(f.accountData[j].account)) {
                    _balances[fid][f.accountData[j].account].amount = f.accountData[j].amount;
                    _balances[fid][f.accountData[j].account].lastBpf = f.accountData[j].lastBpf;

                    // this used to call beanstalkMint but amounts and balances are set directly here
                    // we also do not need to perform any checks since we are only minting once
                    // after deployment, no more beanstalk fertilizers will be distributed
                    _safeMint(f.accountData[j].account, fid, f.accountData[j].amount, "");

                    emit TransferSingle(
                        msg.sender,
                        address(0),
                        f.accountData[j].account,
                        fid,
                        f.accountData[j].amount
                    );
                }
            }
        }
    }


    function _safeMint(address to, uint256 id, uint256 amount, bytes memory data) internal virtual {
        require(to != address(0), "ERC1155: mint to the zero address");

        address operator = _msgSender();

        _transfer(address(0), to, id, amount);

        emit TransferSingle(operator, address(0), to, id, amount);

        __doSafeTransferAcceptanceCheck(operator, address(0), to, id, amount, data);
    }

    //////////////////////////// Transfer Functions ////////////////////////////

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

    /// @dev copied from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC1155/ERC1155.sol)
    function __asSingletonArray(uint256 element) private pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = element;
        return array;
    }

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

    function _transfer(
        address from,
        address to,
        uint256 id,
        uint256 amount
    ) internal virtual {
        uint128 _amount = uint128(amount);
        if (from != address(0)) {
            uint128 fromBalance = _balances[id][from].amount;
            require(uint256(fromBalance) >= amount, "ERC1155: insufficient balance for transfer");
            _balances[id][from].amount = fromBalance - _amount;
        }
        _balances[id][to].amount = _balances[id][to].amount.add(_amount);
    }

    /// @dev copied from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC1155/ERC1155.sol)
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

    /// @dev copied from OpenZeppelin Contracts (last updated v4.6.0) (token/ERC1155/ERC1155.sol)
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
     * @notice handles state updates before a fertilizer transfer
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

    //////////////////////////// Claiming Functions (Update) ////////////////////////////

    /**
     * @notice Allows users to claim their fertilized beans directly.
     * @param ids - an array of fertilizer ids to claim
     * @param mode - the balance to transfer Beans to; see {LibTransfer.To}
     */
    function claimFertilized(uint256[] memory ids, LibTransfer.To mode) external {
        uint256 amount = __update(msg.sender, ids, uint256(fert.bpf));
        if (amount > 0) {
            fert.fertilizedPaidIndex += amount;
            LibTransfer.sendToken(pinto, amount, msg.sender, mode);
        }
    }

    /**
     * @notice Calculates and transfers the rewarded beans
     * from a set of fertilizer ids to an account's internal balance
     * @param account - the user to update
     * @param ids - an array of fertilizer ids
     * @param bpf - the beans per fertilizer
     */
    function _update(address account, uint256[] memory ids, uint256 bpf) internal {
        uint256 amount = __update(account, ids, bpf);
        if (amount > 0) {
            fert.fertilizedPaidIndex += amount;
            LibTransfer.sendToken(pinto, amount, account, LibTransfer.To.INTERNAL);
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

    //////////////////////////// Getters ////////////////////////////////

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
     @notice Returns the current beans per fertilizer
     */
    function beansPerFertilizer() external view returns (uint128) {
        return fert.bpf;
    }

    /**
     @notice Returns fertilizer amount for a given id
     */
    function getFertilizer(uint128 id) external view returns (uint256) {
        for (uint256 i = 0; i < fert.fertilizerIds.length; i++) {
            if (fert.fertilizerIds[i] == id) {
                return fert.fertilizerAmounts[i];
            }
        }
        return 0;
    }

    function totalFertilizedBeans() external view returns (uint256) {
        return fert.fertilizedIndex;
    }

    function totalUnfertilizedBeans() public view returns (uint256) {
        uint256 totalUnfertilized = 0;
        for (uint256 i = 0; i < fert.fertilizerIds.length; i++) {
            uint256 id = fert.fertilizerIds[i];
            uint256 amount = fert.fertilizerAmounts[i];
            if (id > fert.bpf) {
                totalUnfertilized += (id - fert.bpf) * amount;
            }
        }
        return totalUnfertilized;
    }

    function totalFertilizerBeans() external view returns (uint256) {
        return fert.fertilizedIndex + totalUnfertilizedBeans();
    }

    function rinsedSprouts() external view returns (uint256) {
        return fert.fertilizedPaidIndex;
    }

    function rinsableSprouts() external view returns (uint256) {
        return fert.fertilizedIndex - fert.fertilizedPaidIndex;
    }

    function leftoverBeans() external view returns (uint256) {
        return fert.leftoverBeans;
    }

    function name() external pure returns (string memory) {
        return "Beanstalk Payback Fertilizer";
    }

    function symbol() external pure returns (string memory) {
        return "bsFERT";
    }

    function balanceOf(address account, uint256 id) public view virtual override returns (uint256) {
        require(account != address(0), "ERC1155: balance query for the zero address");
        return _balances[id][account].amount;
    }

    function lastBalanceOf(address account, uint256 id) public view returns (Balance memory) {
        require(account != address(0), "ERC1155: balance query for the zero address");
        return _balances[id][account];
    }

    function lastBalanceOfBatch(
        address[] memory accounts,
        uint256[] memory ids
    ) external view returns (Balance[] memory balances) {
        balances = new Balance[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            balances[i] = lastBalanceOf(accounts[i], ids[i]);
        }
    }

    function uri(uint256) public view virtual override returns (string memory) {
        return "";
    }

    /// @notice Checks if an account is a contract.
    function isContract(address account) internal view returns (bool) {
        uint size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /// @dev called by the ShipmentPlanner contract to determine how many pinto to send to the barn payback contract
    function barnRemaining() external view returns (uint256) {
        return totalUnfertilizedBeans();
    }
}
