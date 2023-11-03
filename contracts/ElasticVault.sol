// SPDX-License-Identifier: NONE
pragma solidity 0.7.6;

// Contract requirements 
import './Distribute.sol';
import './interfaces/IStakingDoubleERC20.sol';
import './AMPLRebaser.sol';
import './Wrapper.sol';
import './interfaces/ITrader.sol';

import '@balancer-labs/v2-solidity-utils/contracts/math/Math.sol';

contract TokenStorage is Ownable {
    using SafeERC20 for IERC20;

    constructor() Ownable() {
    }

    function claim(address token) external onlyOwner() {
        IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }
}

contract ElasticVault is AMPLRebaser, Wrapper, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    TokenStorage public token_storage;
    IStakingDoubleERC20 public staking_pool;
    ITrader public trader;
    IERC20 public eefi_token;
    Distribute immutable public rewards_eefi;
    Distribute immutable public rewards_ohm;
    address payable public treasury;
    uint256 public last_positive = block.timestamp;
    uint256 public rebase_caller_reward = 0; // The amount of EEFI to be minted to the rebase caller as a reward
    IERC20 public constant ohm_token = IERC20(0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5);
    
    /* 

    Parameter Definitions: //Parameters updated from v1 vault

    - EEFI Deposit Rate: Depositors receive reward of .0001 EEFI * Amount of AMPL user deposited into vault 
    - EEFI Negative Rebase Rate: When AMPL supply declines mint EEFI at rate of .00001 EEFI * total AMPL deposited into vault 
    - EEFI Equilibrium Rebase Rate: When AMPL supply is does not change (is at equilibrium) mint EEFI at a rate of .0001 EEFI * total AMPL deposited into vault 
    - Deposit FEE_10000: .65% of EEFI minted to user upon initial deposit is delivered to Treasury 
    - Lock Time: AMPL deposited into vault is locked for 90 days; lock time applies to each new AMPL deposit
    - Trade Posiitve EEFI_100: Upon positive rebase 45% of new AMPL supply (based on total AMPL in vault) is sold and used to buy EEFI 
    - Trade Positive OHM_100: Upon positive rebase 22% of the new AMPL supply (based on total AMPL in vault) is sold for OHM 
    - Trade Positive Treasury_100: Upon positive rebase 3% of new AMPL supply (based on total AMPL in vault) is sent to Treasury 
    - Trade Positive Rewards_100: Upon positive rebase, send 55% of OHM rewards to users staking AMPL in vault 
    - Trade Positive LP Staking_100: Upon positive rebase, send 35% of OHM rewards to users staking LP tokens (EEFI/OHM)
    - Trade Neutral/Negative Rewards: Upon neutral/negative rebase, send 55% of EEFI rewards to users staking AMPL in vault
    - Trade Neutral/Negative LP Staking: Upon neutral/negative rebase, send 35% of EEFI rewards to users staking LP tokens (EEFI/OHM)
    - Minting Decay: If AMPL does not experience a positive rebase (increase in AMPL supply) for 45 days, do not mint EEFI, distribute rewards to stakers
    - Treasury EEFI_100: Amount of EEFI distributed to DAO Treasury after EEFI buy and burn; 10% of purchased EEFI distributed to Treasury
    */

    uint256 constant public EEFI_DEPOSIT_RATE = 10000;
    uint256 constant public EEFI_NEGATIVE_REBASE_RATE = 100000;
    uint256 constant public EEFI_EQULIBRIUM_REBASE_RATE = 10000;
    uint256 constant public DEPOSIT_FEE_10000 = 65;
    uint256 constant public LOCK_TIME = 90 days;
    uint256 constant public TRADE_POSITIVE_EEFI_100 = 45;
    uint256 constant public TRADE_POSITIVE_OHM_100 = 22;
    uint256 constant public TRADE_POSITIVE_TREASURY_100 = 3;
    uint256 constant public TRADE_POSITIVE_OHM_REWARDS_100 = 55;
    uint256 constant public TRADE_NEUTRAL_NEG_EEFI_REWARDS_100 = 55;
    uint256 constant public TRADE_POSITIVE_LPSTAKING_100 = 35; 
    uint256 constant public TRADE_NEUTRAL_NEG_LPSTAKING_100 = 35;
    uint256 constant public TREASURY_EEFI_100 = 10;
    uint256 constant public MINTING_DECAY = 45 days;
    uint256 constant public MAX_REBASE_REWARD = 2 ether; // 2 EEFI is the maximum reward for a rebase caller

    /* 
    Event Definitions:

    - Burn: EEFI burned (EEFI purchased using AMPL is burned)
    - Claimed: Rewards claimed by address 
    - Deposit: AMPL deposited by address 
    - Withdrawal: AMPL withdrawn by address 
    - StakeChanged: AMPL staked in contract; calculated as shares of total AMPL deposited 
    */

    event Burn(uint256 amount);
    event Claimed(address indexed account, uint256 ohm, uint256 eefi);
    event Deposit(address indexed account, uint256 amount, uint256 length);
    event Withdrawal(address indexed account, uint256 amount, uint256 length);
    event StakeChanged(uint256 total, uint256 timestamp);
    event RebaseRewardChanged(uint256 rebaseCallerReward);

    struct DepositChunk {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(address => DepositChunk[]) private _deposits;
    
// Only contract can mint new EEFI, and distribute OHM and EEFI rewards     
    constructor(IERC20 _eefi_token, IERC20 ampl_token)
    AMPLRebaser(ampl_token)
    Wrapper(ampl_token)
    Ownable() {
        eefi_token = _eefi_token;
        rewards_eefi = new Distribute(9, IERC20(eefi_token));
        rewards_ohm = new Distribute(9, IERC20(ohm_token));
        token_storage = new TokenStorage();
    }

    receive() external payable { }

    /**
     * @param account User address
     * @return total amount of shares owned by account
     */

    function totalStakedFor(address account) public view returns (uint256 total) {
        for(uint i = 0; i < _deposits[account].length; i++) {
            total += _deposits[account][i].amount;
        }
        return total;
    }

    /**
        @return total The total amount of AMPL claimable by a user
    */
    function totalClaimableBy(address account) public view returns (uint256 total) {
        if(rewards_eefi.totalStaked() == 0) return 0;
        for(uint i = 0; i < _deposits[account].length; i++) {
            if(_deposits[account][i].timestamp < block.timestamp.sub(LOCK_TIME)) {
                total += _deposits[account][i].amount;
            }
        }
        total = _convertToAMPL(total);
    }

    /**
        @dev Current amount of AMPL owned by the user
        @param account Account to check the balance of
    */
    function balanceOf(address account) public view returns(uint256 ampl) {
        if(rewards_eefi.totalStaked() == 0) return 0;
        ampl = _convertToAMPL(rewards_eefi.totalStakedFor(account));
    }

    /**
        @dev Called only once by the owner; this function sets up the vaults
        @param _staking_pool Address of the LP staking pool (EEFI/OHM LP token staking pool)
        @param _treasury Address of the treasury (Address of Elastic Finance DAO Treasury)
    */
    function initialize(IStakingDoubleERC20 _staking_pool, address payable _treasury) external
    onlyOwner() 
    {
        require(address(treasury) == address(0), "ElasticVault: contract already initialized");
        staking_pool = _staking_pool;
        treasury = _treasury;
    }

    /**
        @dev Contract owner can set and replace the contract used
        for trading AMPL, OHM and EEFI - Note: this is the only admin permission on the vault and is included to account for changes in future AMPL liqudity distribution and does not impact EEFI minting or provide access to user funds or rewards)
        @param _trader Address of the trader contract
    */
    function setTrader(ITrader _trader) external onlyOwner() {
        require(address(_trader) != address(0), "ElasticVault: invalid trader");
        trader = _trader;
    }

    /**
        @dev Deposits AMPL into the contract
        @param amount Amount of AMPL to take from the user
    */
    function makeDeposit(uint256 amount) _rebaseSynced() external {
        ampl_token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 waampl = _ampleTowaample(amount);
        _deposits[msg.sender].push(DepositChunk(waampl, block.timestamp));

        uint256 to_mint = amount.mul(10**9).divDown(EEFI_DEPOSIT_RATE);
        uint256 deposit_fee = to_mint.mul(DEPOSIT_FEE_10000).divDown(10000);
        // send some EEFI to Treasury upon initial mint 
        if(last_positive + MINTING_DECAY > block.timestamp) { // if 45 days without positive rebase do not mint EEFI
            (bool success1,) = address(eefi_token).call(abi.encodeWithSignature("mint(address,uint256)", treasury, deposit_fee));
            (bool success2,) = address(eefi_token).call(abi.encodeWithSignature("mint(address,uint256)", msg.sender, to_mint.sub(deposit_fee)));
            require(success1 && success2, "ElasticVault: mint failed");
        }
        
        // stake the shares also in the rewards pool
        rewards_eefi.stakeFor(msg.sender, waampl);
        rewards_ohm.stakeFor(msg.sender, waampl);
        emit Deposit(msg.sender, amount, _deposits[msg.sender].length);
        emit StakeChanged(rewards_ohm.totalStaked(), block.timestamp);
    }

    /**
        @dev Withdraw an amount of shares
        @param amount Amount of shares to withdraw
        !!! This isnt the amount of AMPL the user will get as we are using wrapped ampl to represent shares
    */
    function withdraw(uint256 amount) _rebaseSynced() public {
        uint256 total_staked_user = rewards_eefi.totalStakedFor(msg.sender);
        require(amount <= total_staked_user, "ElasticVault: Not enough balance");
        uint256 to_withdraw = amount;
        uint256 next_pop = 0; // keeps track of the amount of deposits to pop and the index of the next deposit to liquidate
        // make sure the assets aren't time locked - all AMPL deposits into are locked for 90 days and withdrawal request will fail if timestamp of deposit < 90 days
        while(to_withdraw > 0) {
            // either liquidate the deposit, or reduce it
            DepositChunk storage deposit = _deposits[msg.sender][next_pop];
            require(deposit.timestamp < block.timestamp.sub(LOCK_TIME), "ElasticVault: No unlocked deposits found");
            if(deposit.amount > to_withdraw) {
                deposit.amount = deposit.amount.sub(to_withdraw);
                to_withdraw = 0;
            } else {
                to_withdraw = to_withdraw.sub(deposit.amount);
                next_pop++;
            }
        }
        // remove the deposits that were fully liquidated
        _popDeposits(next_pop);
        // compute the current ampl count representing user shares
        uint256 ampl_to_withdraw = _convertToAMPL(amount);
        ampl_token.safeTransfer(msg.sender, ampl_to_withdraw);
        
        // unstake the shares also from the rewards pool
        rewards_eefi.unstakeFrom(msg.sender, amount);
        rewards_ohm.unstakeFrom(msg.sender, amount);
        emit Withdrawal(msg.sender, ampl_to_withdraw,_deposits[msg.sender].length);
        emit StakeChanged(totalStaked(), block.timestamp);
    }

    /**
    * AMPL share of the user based on the current stake
    * @param stake Amount of shares to convert to AMPL
    * @return Amount of AMPL the stake is worth
    */
    function _convertToAMPL(uint256 stake) internal view returns(uint256) {
        return ampl_token.balanceOf(address(this)).mul(stake).divDown(totalStaked());
    }

    /**
    * Change the rebase reward
    * @param new_rebase_reward New rebase reward
    !!!!!!!! This function is only callable by the owner
    */
    function setRebaseReward(uint256 new_rebase_reward) external onlyOwner() {
        require(new_rebase_reward <= MAX_REBASE_REWARD, "ElasticVault: invalid rebase reward"); //Max Rebase reward can't go above maximum 
        rebase_caller_reward = new_rebase_reward;
        emit RebaseRewardChanged(new_rebase_reward);
    }

    //Functions called depending on AMPL rebase status
    function _rebase(uint256 old_supply, uint256 new_supply) internal override {
        uint256 new_balance = ampl_token.balanceOf(address(this));

        if(new_supply > old_supply) {
            // This is a positive AMPL rebase and initates trading and distribuition of AMPL according to parameters (see parameters definitions)
            last_positive = block.timestamp;
            require(address(trader) != address(0), "ElasticVault: trader not set");

            uint256 changeRatio18Digits = old_supply.mul(10**18).divDown(new_supply);
            uint256 surplus = new_balance.sub(new_balance.mul(changeRatio18Digits).divDown(10**18));

            // transfer surplus to sell pool
            ampl_token.transfer(address(token_storage), surplus);
        } else {
            // If AMPL supply is negative (lower) or equal (at eqilibrium/neutral), distribute EEFI rewards as follows; only if the minting_decay condition is not triggered
            if(last_positive + MINTING_DECAY > block.timestamp) { //if 45 days without positive rebase do not mint
                uint256 to_mint = new_balance.mul(10**9).divDown(new_supply < last_ampl_supply ? EEFI_NEGATIVE_REBASE_RATE : EEFI_EQULIBRIUM_REBASE_RATE); /*multiplying by 10^9 because EEFI is 18 digits and not 9*/
                (bool success,) = address(eefi_token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), to_mint));
                require(success, "ElasticVault: mint failed");
                /* 
                EEFI Reward Distribution Overview: 

                - TRADE_Neutral_Neg_Rewards_100: Upon neutral/negative rebase, send 55% of EEFI rewards to users staking AMPL in vault 
                - Trade_Neutral_Neg_LPStaking_100: Upon neutral/negative rebase, send 35% of EEFI rewards to uses staking LP tokens (EEFI/OHM)  
                */


                uint256 to_rewards = to_mint.mul(TRADE_NEUTRAL_NEG_EEFI_REWARDS_100).divDown(100);
                uint256 to_lp_staking = to_mint.mul(TRADE_NEUTRAL_NEG_LPSTAKING_100).divDown(100);

                eefi_token.approve(address(rewards_eefi), to_rewards);
                eefi_token.transfer(address(staking_pool), to_lp_staking); 

                rewards_eefi.distribute(to_rewards, address(this));
                staking_pool.forward(); 

                // distribute the remainder of EEFI to the treasury
                IERC20(eefi_token).safeTransfer(treasury, eefi_token.balanceOf(address(this)));
            }
        }

        (bool success,) = address(eefi_token).call(abi.encodeWithSignature("mint(address,uint256)", msg.sender, rebase_caller_reward));
        require(success, "ElasticVault: mint failed");
    }

    /**
     * @param minimalExpectedEEFI Minimal amount of EEFI to be received from the trade
     * @param minimalExpectedOHM Minimal amount of OHM to be received from the trade
     !!!!!!!! This function is only callable by the owner
    */
    function sell(uint256 minimalExpectedEEFI, uint256 minimalExpectedOHM) external onlyOwner() {
        uint256 balance = ampl_token.balanceOf(address(token_storage));
        uint256 for_eefi = balance.mul(TRADE_POSITIVE_EEFI_100).divDown(100);
        uint256 for_ohm = balance.mul(TRADE_POSITIVE_OHM_100).divDown(100);
        uint256 for_treasury = balance.mul(TRADE_POSITIVE_TREASURY_100).divDown(100);

        token_storage.claim(address(ampl_token));

        ampl_token.approve(address(trader), for_eefi.add(for_ohm));
        // buy EEFI
        uint256 eefi_purchased = trader.sellAMPLForEEFI(for_eefi, minimalExpectedEEFI);
        // buy OHM
        uint256 ohm_purchased = trader.sellAMPLForOHM(for_ohm, minimalExpectedOHM);

        // 10% of purchased EEFI is sent to the DAO Treasury.
        IERC20(address(eefi_token)).safeTransfer(treasury, eefi_purchased.mul(TREASURY_EEFI_100).divDown(100));
        // burn the rest
        uint256 to_burn = eefi_token.balanceOf(address(this));
        emit Burn(to_burn);
        (bool success,) = address(eefi_token).call(abi.encodeWithSignature("burn(uint256)", to_burn));
        require(success, "ElasticVault: mint failed");
        
        // distribute ohm to vaults
        uint256 to_rewards = ohm_purchased.mul(TRADE_POSITIVE_OHM_REWARDS_100).divDown(100);
        uint256 to_lp_staking = ohm_purchased.mul(TRADE_POSITIVE_LPSTAKING_100).divDown(100);
        ohm_token.approve(address(rewards_ohm), to_rewards);
        rewards_ohm.distribute(to_rewards, address(this));
        ohm_token.transfer(address(staking_pool), to_lp_staking);
        staking_pool.forward();

        // distribute the remainder of OHM to the DAO treasury
        ohm_token.safeTransfer(treasury, ohm_token.balanceOf(address(this)));
        // distribute the remainder of AMPL to the DAO treasury
        ampl_token.safeTransfer(treasury, for_treasury);
    }

    /**
     * Claims OHM and EEFI rewards for the user
    */
    function claim() external { 
        (uint256 ohm, uint256 eefi) = getReward(msg.sender);
        rewards_ohm.withdrawFrom(msg.sender, rewards_ohm.totalStakedFor(msg.sender));
        rewards_eefi.withdrawFrom(msg.sender, rewards_eefi.totalStakedFor(msg.sender));
        emit Claimed(msg.sender, ohm, eefi);
    }

    /**
        @dev Returns how much OHM and EEFI the user can withdraw currently
        @param account Address of the user to check reward for
        @return ohm the amount of OHM the account will perceive if he unstakes now
        @return eefi the amount of tokens the account will perceive if he unstakes now
    */
    function getReward(address account) public view returns (uint256 ohm, uint256 eefi) { 
        ohm = rewards_ohm.getReward(account); 
        eefi = rewards_eefi.getReward(account);
    }

    /**
        @return current total amount of stakes
    */
    function totalStaked() public view returns (uint256) {
        return rewards_eefi.totalStaked();
    }

    /**
        @dev returns the total rewards stored for eefi and ohm
    */
    function totalReward() external view returns (uint256 ohm, uint256 eefi) {
        ohm = rewards_ohm.getTotalReward(); 
        eefi = rewards_eefi.getTotalReward();
    }

    /**
        @dev removes the first N elements of the deposit array
    */
    function _popDeposits(uint256 n) internal {
        uint256 length = _deposits[msg.sender].length;
        for (uint256 i = 0; i < length - n; i++) {
            _deposits[msg.sender][i] = _deposits[msg.sender][i + n];
        }

        for (uint256 i = 0; i < n; i++) {
            _deposits[msg.sender].pop();
        }
    }

}
