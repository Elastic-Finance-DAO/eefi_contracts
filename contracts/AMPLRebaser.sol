// SPDX-License-Identifier: NONE
pragma solidity 0.7.6;

import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/IERC20.sol";

abstract contract AMPLRebaser {

    event Rebase(uint256 old_supply, uint256 new_supply);

    //
    // Check last AMPL total supply from AMPL contract.
    //
    uint256 public last_ampl_supply;

    uint256 public last_rebase_call;

    IERC20 public _ampl_token;

    constructor(IERC20 ampl_token) {
        require(address(ampl_token) != address(0), "AMPLRebaser: Invalid ampl token address");
        _ampl_token = ampl_token;
        last_ampl_supply = _ampl_token.totalSupply();
        last_rebase_call = block.timestamp;
    }

    function rebase() external {
        //require timestamp to exceed 24 hours in order to execute function; tested to ensure call is not manipulable by sending ampl
        require(block.timestamp - 24 hours > last_rebase_call, "AMPLRebaser: rebase can only be called once every 24 hours");
        last_rebase_call = block.timestamp;
        uint256 new_supply = _ampl_token.totalSupply();
        _rebase(last_ampl_supply, new_supply);
        emit Rebase(last_ampl_supply, new_supply);
        last_ampl_supply = new_supply;
    }

    function _rebase(uint256 old_supply, uint256 new_supply) internal virtual;
}
