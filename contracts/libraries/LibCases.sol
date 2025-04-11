// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
import {LibAppStorage, AppStorage} from "./LibAppStorage.sol";

/**
 * @title LibCases handles the cases for beanstalk.
 *
 * @dev Cases are used to determine the change in
 * temperature and Bean to maxLP gaugePoint per BDV ratio.
 *
 *  Data format:
 *
 * mT: 4 Bytes (1% = 1e6)
 * bT: 4 Bytes (1% = 1e6)
 * mL: 10 Bytes (1% = 1e18)
 * bL: 10 Bytes (1% = 1e18)
 * 4 bytes are left for future use.
 *
 * mT: Relative Temperature change.
 * bT: Absolute Temperature change.
 * mL: Relative Grown Stalk to Liquidity change.
 * bL: Absolute Grown Stalk to Liquidity change.
 *
 * Temperature and Bean and maxLP gaugePoint per BDV ratio is updated as such:
 * T_n = mT * T_n-1 + bT
 * L_n = mL * L_n-1 + bL
 *
 * In total, there are 144 cases (4 * 3 * 3 * 4)
 *
 * Temperature is stored in AppStorage with 6 decimal precision (1% = 1e6),
 * which is why bT has 6 decimal precision.
 * The following bytes correspond to the current absolute temperature changes:
 *
 * +0.5%: 0007A120 = 0.5e6
 * +1%:   000F4240 = 1e6
 * +2%:   001E8480 = 2e6
 * +3%:   002DC6C0 = 3e6
 * -0.5%: FFF85EE0 = -0.5e6
 * -1%:   FFF0BDC0 = -1e6
 * -2%:   FFE17B80 = -2e6
 * -3%:   FFD23940 = -3e6
 * 
 * The following bytes correspond to the absolute Bean to maxLP gaugePoint per BDV ratio changes:
 * -50: FFFD4A1C50E94E780000 = -50e18
 * +1:  FFFA9438A1D29CF00000 = 1e18
 * +2:  FFF7DE54F2BBF1680000 = 2e18
 *
 * The following bytes correspond to the relative Bean to maxLP gaugePoint per BDV ratio changes:
 * 100%: 00056BC75E2D63100000 = 100e18
 * The following bytes correspond to the relative temperature changes:
 * 100%: 05F5E100 = 100e6
 */

library LibCases {
    struct CaseData {
        uint32 mT;
        int32 bT;
        uint80 mL;
        int80 bL;
    }

    // constants are used for reability purposes,
    // given that multiple cases use the same values.
    //
    // Naming Convention:
    // PLUS: increment by X (y_i = y_1 + X)
    // MINUS decrement by X (y_i = y_1 - X)
    // INCR: scale up by X (y_i = y_1 * X)
    // DECR: scale down by X (y_i = y_1 * (1-X))
    // T: Temperature, L: Bean to max LP gauge point per BDV ratio
    // Example: T_PLUS_2_L_MINUS_FIFTY-> Temperature is incremented 2%,
    // BeantoMaxLPGaugePointPerBdvRatio is decrement by 50%.

    //////////////////////////////////////////////////////////     [  mT  ][  bT  ][       mL         ][       BL         ][ null ]
    bytes32 internal constant T_PLUS_2_L_MINUS_FIFTY =   bytes32(0x05F5E100001E848000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature increased by 2%,   Bean2maxLpGpPerBdv decreased by 50.
    bytes32 internal constant T_PLUS_1_L_MINUS_FIFTY =   bytes32(0x05F5E100000F424000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature increased by 1%,   Bean2maxLpGpPerBdv decreased by 50.
    bytes32 internal constant T_PLUS_05_L_MINUS_FIFTY =  bytes32(0x05F5E1000007A12000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature increased by 0.5%, Bean2maxLpGpPerBdv decreased by 50.
    bytes32 internal constant T_PLUS_0_L_MINUS_FIFTY =   bytes32(0x05F5E1000000000000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature increased by 0%,   Bean2maxLpGpPerBdv decreased by 50.
    bytes32 internal constant T_MINUS_05_L_MINUS_FIFTY = bytes32(0x05F5E100FFF85EE000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature decreased by 0.5%, Bean2maxLpGpPerBdv decreased by 50.
    bytes32 internal constant T_MINUS_1_L_MINUS_FIFTY =  bytes32(0x05F5E100FFF0BDC000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature decreased by 1%,   Bean2maxLpGpPerBdv decreased by 50.
    bytes32 internal constant T_MINUS_3_L_MINUS_FIFTY =  bytes32(0x05F5E100FFD2394000056BC75E2D63100000FFFD4A1C50E94E78000000000000); // temperature decreased by 3%,   Bean2maxLpGpPerBdv decreased by 50.
    //////////////////////////////////////////////////////////  [  mT  ][  bT  ][       mL         ][       BL         ][ null ]
    bytes32 internal constant T_PLUS_2_L_PLUS_ONE =   bytes32(0x05F5E100001E848000056BC75E2D6310000000000DE0B6B3A764000000000000); // temperature increased by 2%, Bean2maxLpGpPerBdv increased by 1.
    bytes32 internal constant T_PLUS_1_L_PLUS_ONE =   bytes32(0x05F5E100000F424000056BC75E2D6310000000000DE0B6B3A764000000000000); // temperature increased by 1%, Bean2maxLpGpPerBdv increased by 1.
    bytes32 internal constant T_PLUS_05_L_PLUS_ONE =  bytes32(0x05F5E1000007A12000056BC75E2D6310000000000DE0B6B3A764000000000000); // temperature increased by 0.5%, Bean2maxLpGpPerBdv increased by 1.
    bytes32 internal constant T_PLUS_0_L_PLUS_ONE =   bytes32(0x05F5E1000000000000056BC75E2D6310000000000DE0B6B3A764000000000000); // temperature increased by 0%, Bean2maxLpGpPerBdv increased by 1.
    bytes32 internal constant T_MINUS_05_L_PLUS_ONE = bytes32(0x05F5E100FFF85EE000056BC75E2D6310000000000DE0B6B3A764000000000000); // temperature decreased by 0.5%, Bean2maxLpGpPerBdv increased by 1.
    //////////////////////////////////////////////////////////  [  mT  ][  bT  ][       mL         ][       BL         ][ null ]
    bytes32 internal constant T_PLUS_1_L_PLUS_TWO =   bytes32(0x05F5E100000F424000056BC75E2D6310000000001BC16D674EC8000000000000); // temperature increased by 1%, Bean2maxLpGpPerBdv increased by 2.
    bytes32 internal constant T_PLUS_05_L_PLUS_TWO =  bytes32(0x05F5E1000007A12000056BC75E2D6310000000001BC16D674EC8000000000000); // temperature increased by 0.5%, Bean2maxLpGpPerBdv increased by 2.
    bytes32 internal constant T_MINUS_05_L_PLUS_TWO = bytes32(0x05F5E100FFF85EE000056BC75E2D6310000000001BC16D674EC8000000000000); // temperature decreased by 0.5%, Bean2maxLpGpPerBdv increased by 2.
    //////////////////////////////////////////////////////////  [  mT  ][  bT  ][       mL         ][       BL         ][ null ]
    bytes32 internal constant T_PLUS_0_L_MINUS_ONE =  bytes32(0x05F5E1000000000000056BC75E2D63100000FFFFF21F494C589C000000000000); // temperature increased by 0%, Bean2maxLpGpPerBdv decreased by 1.
    bytes32 internal constant T_MINUS_1_L_MINUS_ONE = bytes32(0x05F5E100FFF0BDC000056BC75E2D63100000FFFFF21F494C589C000000000000); // temperature decreased by 1%, Bean2maxLpGpPerBdv decreased by 1.
    bytes32 internal constant T_MINUS_3_L_MINUS_ONE = bytes32(0x05F5E100FFD2394000056BC75E2D63100000FFFFF21F494C589C000000000000); // temperature decreased by 3%, Bean2maxLpGpPerBdv decreased by 1.
    //////////////////////////////////////////////////////////  [  mT  ][  bT  ][       mL         ][       BL         ][ null ]
    bytes32 internal constant T_PLUS_0_L_MINUS_TWO =  bytes32(0x05F5E1000000000000056BC75E2D63100000FFFFE43E9298B138000000000000); // temperature increased by 0%,   Bean2maxLpGpPerBdv decreased by 2.
    bytes32 internal constant T_MINUS_1_L_MINUS_TWO = bytes32(0x05F5E100FFF0BDC000056BC75E2D63100000FFFFE43E9298B138000000000000); // temperature decreased by 1%,   Bean2maxLpGpPerBdv decreased by 2.
    bytes32 internal constant T_MINUS_3_L_MINUS_TWO = bytes32(0x05F5E100FFD2394000056BC75E2D63100000FFFFE43E9298B138000000000000); // temperature decreased by 3%,   Bean2maxLpGpPerBdv decreased by 2.

    /**
     * @notice given a caseID (0-144), return the caseData.
     *
     * CaseV2 allows developers to change both the absolute
     * and relative change in temperature and bean to maxLP gaugePoint to BDV ratio,
     * with greater precision than CaseV1.
     *
     */
    function getDataFromCase(uint256 caseId) internal view returns (bytes32 caseData) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.sys.casesV2[caseId];
    }


    /**
     * @notice given a caseID (0-144), return the data associated.
     * @dev * Each case outputs 4 variables:
     * mT: Relative Temperature change. (1% = 1e6)
     * bT: Absolute Temperature change. (1% = 1e6)
     * mL: Relative Grown Stalk to Liquidity change. (1% = 1e18)
     * bL: Absolute Grown Stalk to Liquidity change. (1% = 1e18)
     */
    function decodeCaseData(uint256 caseId) internal view returns (CaseData memory cd) {
        bytes32 _caseData = getDataFromCase(caseId);
        // cd.mT = uint32(bytes4(_caseData)); Uncomment if you want to use mT
        cd.bT = int32(uint32(bytes4(_caseData << 32)));
        // cd.mL = uint80(bytes10(_caseData << 64)); Uncomment if you want to use mL
        cd.bL = int80(uint80(bytes10(_caseData << 144)));
    }

    function setCasesV2() internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.sys.casesV2 = [
            //               Dsc soil demand,       Steady soil demand,         Inc soil demand,      Debt level
                    /////////////////////// Extremely Low L2SR ///////////////////////
            bytes32(T_PLUS_2_L_MINUS_FIFTY),    T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_1_L_MINUS_FIFTY, // Exs Low: P < 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                     T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_0_L_MINUS_FIFTY, // Rea Low: P < 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                     T_PLUS_1_L_MINUS_FIFTY,   T_PLUS_05_L_MINUS_FIFTY,  T_MINUS_05_L_MINUS_FIFTY, // Rea Hgh: P < 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                     T_PLUS_1_L_MINUS_FIFTY,   T_PLUS_05_L_MINUS_FIFTY,  T_MINUS_05_L_MINUS_FIFTY, // Exs Hgh: P < 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                    /////////////////////// Reasonably Low L2SR ///////////////////////
                     T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_1_L_MINUS_FIFTY, // Exs Low: P < 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                     T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_2_L_MINUS_FIFTY,    T_PLUS_0_L_MINUS_FIFTY, // Rea Low: P < 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_1_L_PLUS_ONE,      T_PLUS_05_L_PLUS_ONE,     T_MINUS_05_L_PLUS_ONE, // Rea Hgh: P < 1
                       T_PLUS_0_L_MINUS_TWO,     T_MINUS_1_L_MINUS_TWO,     T_MINUS_3_L_MINUS_TWO, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_1_L_PLUS_ONE,      T_PLUS_05_L_PLUS_ONE,     T_MINUS_05_L_PLUS_ONE, // Exs Hgh: P < 1
                       T_PLUS_0_L_MINUS_TWO,     T_MINUS_1_L_MINUS_TWO,     T_MINUS_3_L_MINUS_TWO, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                    /////////////////////// Reasonably High L2SR ///////////////////////
                        T_PLUS_2_L_PLUS_ONE,       T_PLUS_2_L_PLUS_ONE,       T_PLUS_1_L_PLUS_ONE, // Exs Low: P < 1
                      T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_2_L_PLUS_ONE,       T_PLUS_2_L_PLUS_ONE,       T_PLUS_0_L_PLUS_ONE, // Rea Low: P < 1
                      T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_1_L_PLUS_ONE,      T_PLUS_05_L_PLUS_ONE,     T_MINUS_05_L_PLUS_ONE, // Rea Hgh: P < 1
                       T_PLUS_0_L_MINUS_ONE,     T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_1_L_PLUS_ONE,      T_PLUS_05_L_PLUS_ONE,     T_MINUS_05_L_PLUS_ONE, // Exs Hgh: P < 1
                       T_PLUS_0_L_MINUS_ONE,     T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                    /////////////////////// Extremely High L2SR ///////////////////////
                        T_PLUS_2_L_PLUS_ONE,       T_PLUS_2_L_PLUS_ONE,       T_PLUS_1_L_PLUS_ONE, // Exs Low: P < 1
                      T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_2_L_PLUS_ONE,       T_PLUS_2_L_PLUS_ONE,       T_PLUS_0_L_PLUS_ONE, // Rea Low: P < 1
                      T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                    T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_1_L_PLUS_TWO,      T_PLUS_05_L_PLUS_TWO,     T_MINUS_05_L_PLUS_TWO, // Rea Hgh: P < 1
                       T_PLUS_0_L_MINUS_ONE,     T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY, //          P > Q
                        T_PLUS_1_L_PLUS_TWO,      T_PLUS_05_L_PLUS_TWO,     T_MINUS_05_L_PLUS_TWO, // Exs Hgh: P < 1
                       T_PLUS_0_L_MINUS_ONE,     T_MINUS_1_L_MINUS_ONE,     T_MINUS_3_L_MINUS_ONE, //          P > 1
                     T_PLUS_0_L_MINUS_FIFTY,   T_MINUS_1_L_MINUS_FIFTY,   T_MINUS_3_L_MINUS_FIFTY  //          P > Q
        ];
    }
}
