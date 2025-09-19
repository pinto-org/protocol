//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibRedundantMath256} from "contracts/libraries/Math/LibRedundantMath256.sol";
import {WellPrice, P, C, ReservesType} from "./WellPrice.sol";

contract BeanstalkPrice is WellPrice {
    using LibRedundantMath256 for uint256;

    constructor(address beanstalk) WellPrice(beanstalk) {}

    struct Prices {
        uint256 price;
        uint256 liquidity;
        int deltaB;
        P.Pool[] ps;
    }

    /**
     * @notice Returns the manipulation or non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean in all whitelisted liquidity pools.
     **/
    function price(ReservesType reservesType) external view returns (Prices memory p) {
        address[] memory wells = beanstalk.getSiloTokens();
        return priceForWells(wells, reservesType);
    }

    /**
     * @notice Returns the non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean in all whitelisted liquidity pools.
     **/
    function price() external view returns (Prices memory p) {
        address[] memory wells = beanstalk.getSiloTokens();
        return priceForWells(wells, ReservesType.CURRENT_RESERVES);
    }

    /**
     * @notice Returns the manipulation or non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean for the passed in wells.
     **/
    function priceForWells(
        address[] memory wells,
        ReservesType reservesType
    ) public view returns (Prices memory p) {
        address bean = beanstalk.getBeanToken();
        p.ps = new P.Pool[](wells.length);
        for (uint256 i = 0; i < wells.length; i++) {
            if (wells[i] == bean) continue;
            p.ps[i] = getWell(wells[i], reservesType);
        }
        for (uint256 i = 0; i < p.ps.length; i++) {
            p.price += p.ps[i].price.mul(p.ps[i].liquidity);
            p.liquidity += p.ps[i].liquidity;
            p.deltaB += p.ps[i].deltaB;
        }
        p.price = p.price.div(p.liquidity);
    }

    /**
     * @notice Returns the non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean for the passed in wells.
     **/
    function priceForWells(address[] memory wells) public view returns (Prices memory p) {
        return priceForWells(wells, ReservesType.CURRENT_RESERVES);
    }

    /**
     * @notice Returns the manipulation or non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean in the specified liquidity pools.
     **/
    function poolPrice(
        address pool,
        ReservesType reservesType
    ) public view returns (P.Pool memory p) {
        return getWell(pool, reservesType);
    }

    /**
     * @notice Returns the non-manipulation resistant on-chain liquidity, deltaB and price data for
     * Bean in the specified liquidity pools.
     **/
    function poolPrice(address pool) public view returns (P.Pool memory p) {
        return poolPrice(pool, ReservesType.CURRENT_RESERVES);
    }
}
