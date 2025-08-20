/*
 SPDX-License-Identifier: MIT
*/

pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "contracts/beanstalk/storage/System.sol";
import {BeanstalkERC20} from "contracts/tokens/ERC20/BeanstalkERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AppStorage} from "contracts/beanstalk/storage/AppStorage.sol";
import {LibTractor} from "contracts/libraries/LibTractor.sol";
import {LibCases} from "contracts/libraries/LibCases.sol";
import {Distribution} from "contracts/beanstalk/facets/sun/abstract/Distribution.sol";
import {C} from "contracts/C.sol";
import {LibDiamond} from "contracts/libraries/LibDiamond.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondCut} from "contracts/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "contracts/interfaces/IDiamondLoupe.sol";
import {ShipmentPlanner} from "contracts/ecosystem/ShipmentPlanner.sol";
import {LibGauge} from "contracts/libraries/LibGauge.sol";

/**
 * @title InitProtocol
 */
contract InitProtocol {
    using SafeERC20 for IERC20;

    // EVENTS:
    event BeanToMaxLpGpPerBdvRatioChange(uint256 indexed season, uint256 caseId, int80 absChange);

    AppStorage internal s;

    /**
     * @notice contains bean hyperparameters and initial system data.
     */
    struct SystemData {
        SeedGauge seedGauge;
        EvaluationParameters evalParams;
        ShipmentRoute[] shipmentRoutes;
    }

    /**
     * @notice contains the name, symbol and salt for the token to be deployed.
     */
    struct TokenData {
        string name;
        string symbol;
        address receiver;
        bytes32 salt;
        uint256 initSupply;
    }

    /**
     * @notice Initializes the Bean protocol deployment.
     */
    function init(SystemData calldata system, TokenData calldata token, address newOwner) external {
        // set supported diamond interfaces
        addInterfaces();
        // deploy new bean contract.
        deployToken(token);
        // initalize season
        initalizeSeason(system.evalParams);
        // init seed gauge
        initializeSeedGaugeSettings(system.seedGauge);
        // initalize field
        initalizeField();
        // initalize misc
        initalizeMisc();
        // initalize tractor:
        setTractor();
        // deploy shipment planner and set shipment routes.
        initShipping(system.shipmentRoutes);
        // propose ownership to a multisig address
        proposeNewOwner(newOwner);
    }

    /**
     * @notice Sets the supported interfaces by the diamond contract.
     */
    function addInterfaces() internal {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[0xd9b67a26] = true; // ERC1155
        ds.supportedInterfaces[0x0e89341c] = true; // ERC1155Metadata
    }

    /**
     * @notice Deploys the Bean ERC20 contract, mints the initial supply and sets the address in storage.
     */
    function deployToken(TokenData calldata token) internal {
        BeanstalkERC20 bean = new BeanstalkERC20{salt: token.salt}(
            address(this),
            token.name,
            token.symbol
        );
        s.sys.bean = address(bean);
        bean.mint(token.receiver, token.initSupply);
    }

    /**
     * @notice Initializes season parameters.
     */
    function initalizeSeason(EvaluationParameters calldata evalParams) internal {
        // set current season to 1.
        s.sys.season.current = 1;

        // initalize the duration of 1 season in seconds.
        s.sys.season.period = C.CURRENT_SEASON_PERIOD;

        // initalize current timestamp.
        s.sys.season.timestamp = block.timestamp;

        // initalize the start timestamp.
        // Rounds down to the nearest hour
        // if needed.
        s.sys.season.start = s.sys.season.period > 0
            ? (block.timestamp / s.sys.season.period) * s.sys.season.period
            : block.timestamp;

        // Cases
        LibCases.setCasesV2();

        // Evaluation Parameters
        s.sys.evaluationParameters = evalParams;
    }

    /**
     * @notice Initializes field parameters.
     */
    function initalizeField() internal {
        s.sys.activeField = 0;
        s.sys.fieldCount = 1;
        s.sys.weather.temp = 1e6;
        s.sys.weather.thisSowTime = type(uint32).max;
        s.sys.weather.lastSowTime = type(uint32).max;
    }

    function initializeSeedGaugeSettings(SeedGauge calldata seedGauge) internal {
        s.sys.seedGauge.averageGrownStalkPerBdvPerSeason = seedGauge
            .averageGrownStalkPerBdvPerSeason;
        s.sys.seedGauge.beanToMaxLpGpPerBdvRatio = seedGauge.beanToMaxLpGpPerBdvRatio;
        // emit events.
        emit BeanToMaxLpGpPerBdvRatioChange(
            s.sys.season.current,
            type(uint256).max,
            int80(int128(s.sys.seedGauge.beanToMaxLpGpPerBdvRatio))
        );
        emit LibGauge.UpdateAverageStalkPerBdvPerSeason(
            s.sys.seedGauge.averageGrownStalkPerBdvPerSeason
        );
    }

    /**
     * @notice Initializes misc parameters.
     */
    function initalizeMisc() internal {
        s.sys.reentrantStatus = 1;
        s.sys.farmingStatus = 1;
    }

    /**
     * @notice Proposes a new owner for the protocol. To be set to a multisig address.
     */
    function proposeNewOwner(address newOwner) internal {
        s.sys.ownerCandidate = newOwner;
    }

    /**
     * @notice Deploys the shipment planner and sets the shipment routes.
     */
    function initShipping(ShipmentRoute[] calldata routes) internal {
        // deploy the shipment planner
        address shipmentPlanner = address(new ShipmentPlanner(address(this), s.sys.bean));
        // set the shipment routes
        _setShipmentRoutes(shipmentPlanner, routes);
    }

    /**
     * @notice Sets the shipment routes to the field, silo and dev budget.
     * @dev Solidity does not support direct assignment of array structs to Storage.
     */
    function _setShipmentRoutes(address shipmentPlanner, ShipmentRoute[] calldata routes) internal {
        for (uint256 i; i < routes.length; i++) {
            ShipmentRoute memory route = routes[i];
            route.planContract = shipmentPlanner;
            s.sys.shipmentRoutes.push(route);
        }
        emit Distribution.ShipmentRoutesSet(routes);
    }

    /**
     * @notice Sets the tractor version and active publisher.
     */
    function setTractor() internal {
        LibTractor.TractorStorage storage ts = LibTractor._tractorStorage();
        ts.activePublisher = payable(address(1));
        ts.version = "1.0.0";
    }
}
