// SPDX-License-Identifier: NONE
pragma solidity ^0.7.0;

import 'uFragments/contracts/UFragments.sol';

contract FakeAMPL is UFragments {
    constructor() UFragments() {
        initialize(msg.sender);
    }
}