// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {IUniswapV2Router02} from "./interfaces/uniswap.sol";
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";

import { IBalancerVault } from "./interfaces/Balancer/IBalancerVault.sol";
import { IBalancerPool } from "./interfaces/Balancer/IBalancerPool.sol";
import { IAsset } from "./interfaces/Balancer/IAsset.sol";
import {ITradeFactory} from "./interfaces/ySwaps/ITradeFactory.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

interface IOracle {
    function latestAnswer() external view returns (uint256);
}

interface IFeedRegistry {
    function getFeed(address, address) external view returns (address);
    function latestRoundData(address, address) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface IConvexRewards {
    // strategy's staked balance in the synthetix staking contract
    function balanceOf(address account) external view returns (uint256);

    // read how much claimable BAL a strategy has
    function earned(address account) external view returns (uint256);

    // stake a convex tokenized deposit
    function stake(uint256 _amount) external returns (bool);

    // withdraw to a convex tokenized deposit, probably never need to use this
    function withdraw(uint256 _amount, bool _claim) external returns (bool);

    // withdraw directly to curve LP token, this is what we primarily use
    function withdrawAndUnwrap(uint256 _amount, bool _claim)
        external
        returns (bool);

    // claim rewards, with an option to claim extra rewards or not
    function getReward(address _account, bool _claimExtras)
        external
        returns (bool);

    // check if we have rewards on a pool
    function extraRewardsLength() external view returns (uint256);

    // if we have rewards, see what the address is
    function extraRewards(uint256 _reward) external view returns (address);

    // read our rewards token
    function rewardToken() external view returns (address);

    // check our reward period finish
    function periodFinish() external view returns (uint256);
}

interface IConvexDeposit {
    // deposit into convex, receive a tokenized deposit.  parameter to stake immediately (we always do this).
    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _stake
    ) external returns (bool);

    // burn a tokenized deposit (Convex deposit tokens) to receive curve lp tokens back
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);

    // give us info about a pool based on its pid
    function poolInfo(uint256)
        external
        view
        returns (
            address,
            address,
            address,
            address,
            address,
            bool
        );
}

abstract contract StrategyAuraBase is BaseStrategy {
    using Address for address;

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    // convex stuff
    address internal constant depositContract =
        0x7818A1DA7BD1E64c199029E86Ba244a9798eEE10; // this is the deposit contract that all pools use, aka booster
    IConvexRewards public rewardsContract; // This is unique to each curve pool
    uint256 public pid; // this is unique to each pool

    // keepBAL stuff
    uint256 public keepBAL; // the percentage of BAL we re-lock for boost (in basis points)
    address internal constant voter =
        0xc999dE72BFAFB936Cb399B94A8048D24a27eD1Ff; // Yearn's veBAL voter, we send some extra BAL here
    uint256 internal constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in basis points

    // Swap stuff
    IERC20 internal constant bal =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20 internal constant auraToken =
        IERC20(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);
    IERC20 internal constant weth =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // keeper stuff
    uint256 public harvestProfitMin; // minimum size in USD (6 decimals) that we want to harvest
    uint256 public harvestProfitMax; // maximum size in USD (6 decimals) that we want to harvest
    uint256 public creditThreshold; // amount of credit in underlying tokens that will automatically trigger a harvest
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    string internal stratName;

    // convex-specific variables
    bool public claimRewards; // boolean if we should always claim rewards when withdrawing, usually via withdrawAndUnwrap (generally this should be false)

    /* ========== CONSTRUCTOR ========== */

    constructor(address _vault) public BaseStrategy(_vault) {}

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    /// @notice How much want we have staked in Convex
    function stakedBalance() public view returns (uint256) {
        return rewardsContract.balanceOf(address(this));
    }

    /// @notice Balance of want sitting in our strategy
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    /// @notice How much bal we can claim from the staking contract
    function claimableBalance() public view returns (uint256) {
        return rewardsContract.earned(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Send all of our Curve pool tokens to be deposited
        uint256 _toInvest = balanceOfWant();
        // deposit into convex and stake immediately (but only if we have something to invest)
        if (_toInvest > 0) {
            IConvexDeposit(depositContract).deposit(pid, _toInvest, true);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                rewardsContract.withdrawAndUnwrap(
                    Math.min(_stakedBal, _amountNeeded.sub(_wantBal)),
                    claimRewards
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // don't bother withdrawing zero
            rewardsContract.withdrawAndUnwrap(_stakedBal, claimRewards);
        }
        return balanceOfWant();
    }

    // in case we need to exit into the convex deposit token, this will allow us to do that
    // make sure to check claimRewards before this step if needed
    // plan to have gov sweep convex deposit tokens from strategy after this
    function withdrawToConvexDepositTokens() external onlyVaultManagers {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            rewardsContract.withdraw(_stakedBal, claimRewards);
        }
    }

    // we don't want for these tokens to be swept out. We allow gov to sweep out AURA vault tokens; we would only be holding these if things were really, really rekt.
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Set the amount of bal to be locked in Yearn's vebal voter from each harvest. Default is 10%.
    function setKeepBAL(uint256 _keepBAL) external onlyVaultManagers {
        require(_keepBAL <= 10_000);
        keepBAL = _keepBAL;
    }

    // We usually don't need to claim rewards on withdrawals, but might change our mind for migrations etc
    function setClaimRewards(bool _claimRewards) external onlyVaultManagers {
        claimRewards = _claimRewards;
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyVaultManagers
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }
}

contract StrategyAuraUSDClonable is StrategyAuraBase {
    /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.

    bool public checkEarmark; // this determines if we should check if we need to earmark rewards before harvesting

     // Balancer stuff
    //The main Balancer vault
    IBalancerVault internal constant balancerVault = 
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    //Pools we use for swapping rewards
    bytes32 internal constant balEthPoolId = 
        bytes32(0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014);
    bytes32 internal constant auraEthPoolId = 
        bytes32(0xc29562b045d80fd77c69bec09541f5c16fe20d9d000200000000000000000251);
    bytes32 internal constant ethUsdcPoolId =
        bytes32(0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019);
        //The want Balancer Pool Id
    bytes32 internal poolId;

    IERC20 internal constant usdc =
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    //address of the trade factory to be used for extra rewards
    address public tradeFactory;

    // check for cloning
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        uint256 _pid,
        string memory _name
    ) public StrategyAuraBase(_vault) {
        _initializeStrat(_pid, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // we use this to clone our original strategy to other vaults
    function cloneStrategyAuraUSD(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _pid,
        string memory _name
    ) external returns (address newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyAuraUSDClonable(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _pid,
            _name
        );

        emit Cloned(newStrategy);
    }

    // this will only be called by the clone function above
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _pid,
        string memory _name
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_pid, _name);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(
        uint256 _pid,
        string memory _name
    ) internal {
        // make sure that we haven't initialized this before
        require(address(rewardsContract) == address(0)); // already initialized.

        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 21 days; // 21 days in seconds, if we hit this then harvestTrigger = True
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012; // health.ychad.eth
        harvestProfitMin = 60000e6;
        harvestProfitMax = 120000e6;
        creditThreshold = 1e6 * 1e18;

        // want = Balancer LP
        want.approve(address(depositContract), type(uint256).max);
        auraToken.approve(address(balancerVault), type(uint256).max);
        bal.approve(address(balancerVault), type(uint256).max);

        // this is the pool specific to this vault, but we only use it as an address
        poolId = IBalancerPool(address(want)).getPoolId();

        // setup our rewards contract
        pid = _pid; // this is the pool ID on convex, we use this to determine what the reweardsContract address is
        (address lptoken, , , address _rewardsContract, , ) =
            IConvexDeposit(depositContract).poolInfo(_pid);

        // set up our rewardsContract
        rewardsContract = IConvexRewards(_rewardsContract);

        // check that our LP token based on our pid matches our want
        require(address(lptoken) == address(want));

        // set our strategy's name
        stratName = _name;

        // these are our approvals and path specific to this contract
        usdc.approve(address(balancerVault), type(uint256).max);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // this claims our BAL, AURA, and any extra tokens like SNX or ANKR. no harm leaving this true even if no extra rewards currently.
        rewardsContract.getReward(address(this), true);

        uint256 balBalance = bal.balanceOf(address(this));
        uint256 auraBalance = auraToken.balanceOf(address(this));

        uint256 _sendToVoter = balBalance.mul(keepBAL).div(FEE_DENOMINATOR);
        if (_sendToVoter > 0) {
            bal.safeTransfer(voter, _sendToVoter);
        }

        // check our balance again after transferring some BAL to our voter
        balBalance = bal.balanceOf(address(this));

        if (balBalance > 0 && auraBalance > 0) {
            _sellBalAndAura(balBalance, auraBalance);
        }

        createUSDCLP();

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                rewardsContract.withdrawAndUnwrap(
                    Math.min(_stakedBal, _debtOutstanding),
                    claimRewards
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            uint256 _wantBal = balanceOfWant();
            if (_profit.add(_debtPayment) > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    // migrate our want token to a new strategy if needed, make sure to check claimRewards first
    // also send over any BAL or AURA that is claimed; for migrations we definitely want to claim
    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            rewardsContract.withdrawAndUnwrap(_stakedBal, claimRewards);
        }
        uint256 balBalance = bal.balanceOf(address(this));
        uint256 auraBalance = auraToken.balanceOf(address(this));

        if (balBalance > 0){
            bal.transfer(_newStrategy, balBalance);
        }
        if (auraBalance > 0){
            auraToken.transfer(_newStrategy, auraBalance);
        }
    }

    // Sells both BAL and AURA -> WETH -> USDC
    function _sellBalAndAura(uint256 _balAmount, uint256 _auraAmount)
        internal
    {
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](4);

        //Sell bal -> weth
        swaps[0] = IBalancerVault.BatchSwapStep(
            balEthPoolId,
            0,
            2,
            _balAmount,
            abi.encode(0)
        );
        
        //Sell WETH -> USDC due to higher liquidity
        swaps[1] = IBalancerVault.BatchSwapStep(
            ethUsdcPoolId,
            2,
            3,
            0,
            abi.encode(0)
        );

        //Sell Aura -> Weth
        swaps[2] = IBalancerVault.BatchSwapStep(
            auraEthPoolId,
            1,
            2,
            _auraAmount,
            abi.encode(0)
        );

        //Sell WETH -> USDC due to higher liquidity
        swaps[3] = IBalancerVault.BatchSwapStep(
            ethUsdcPoolId,
            2,
            3,
            0,
            abi.encode(0)
        );

        //Match the token address with the desired index for this trade
        IAsset[] memory assets = new IAsset[](4);
        assets[0] = IAsset(address(bal));
        assets[1] = IAsset(address(auraToken));
        assets[2] = IAsset(address(weth));
        assets[3] = IAsset(address(usdc));
        
        //Only min we need to set is for the balances going in
        int[] memory limits = new int[](4);
        limits[0] = int(_balAmount);
        limits[1] = int(_auraAmount);
            
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );
    }

    /*
    * @notice
    *   Function available internally to create an lp during harvests
    *   Will only use USDC since that is what is swapped to during harvests
    */
    function createUSDCLP() internal {
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        if(balance == 0) return;

        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);
        IAsset[] memory assets = new IAsset[](3);
        int[] memory limits = new int[](3);

        swaps[0] = IBalancerVault.BatchSwapStep(
            bytes32(0x9210f1204b5a24742eba12f710636d76240df3d00000000000000000000000fc),
            0,
            1,
            balance,
            abi.encode(0)
        );

        swaps[1] = IBalancerVault.BatchSwapStep(
            poolId,
            1,
            2,
            0,
            abi.encode(0)
        );

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(0x9210F1204b5a24742Eba12f710636D76240dF3d0);
        assets[2] = IAsset(address(want));

        limits[0] = int(balance);
        
        balancerVault.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, 
            swaps, 
            assets, 
            getFundManagement(), 
            limits, 
            block.timestamp
        );
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        // only check if we need to earmark on vaults we know are problematic
        if (checkEarmark) {
            // don't harvest if we need to earmark convex rewards
            if (needsEarmarkReward()) {
                return false;
            }
        }

        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = claimableProfitInUsdt();
        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // only checks bal rewards. 
    //Returns the expected value of the rewards in USDT, 1e6
    function claimableProfitInUsdt() public view returns (uint256) {
        (, int256 balPrice,,,) = IFeedRegistry(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf).latestRoundData(
            address(bal),
            address(0x0000000000000000000000000000000000000348) // USD
        );

        //Get the latest oracle price for bal * amount of bal / (1e18 + 1e2) to adjust oracle price that is 1e8
        return uint256(balPrice).mul(claimableBalance()).div(1e20);
    }

    // convert our keeper's eth cost into want, we don't need this anymore since we don't use baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {}

    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    /// @notice True if someone needs to earmark rewards on Convex before keepers harvest again
    // check if someone needs to earmark rewards on convex before keepers harvest again
    function needsEarmarkReward() public view returns (bool needsEarmark) {
        // check if there is any CRV we need to earmark
        uint256 balExpiry = rewardsContract.periodFinish();
        if (balExpiry < block.timestamp) {
            return true;
        }
    }

   // ---------------------- YSWAPS FUNCTIONS ----------------------\\

   //Only use the yswaps for any "extra" tokens
   //If there are none, tradeFactory can stay set to address(0)

    function updateTradeFactory(address _newTradeFactory)
        external
        onlyGovernance
    {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        tradeFactory = _newTradeFactory;
        if (_newTradeFactory != address(0)) {
            _setUpTradeFactory();
        }
    }

    // once this is called setupTradefactory must be called to get things working again
    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        address _tradeFactory = tradeFactory;
        if (_tradeFactory == address(0)) {
            return;
        }
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        uint256 extraRewards = rewardsContract.extraRewardsLength();

        for(uint256 i; i < extraRewards; i ++) {
            address virtualRewardsPool = rewardsContract.extraRewards(i);
            address _rewardsToken =
                IConvexRewards(virtualRewardsPool).rewardToken();
            IERC20(_rewardsToken).safeApprove(tradeFactory, 0);
            tf.disable(_rewardsToken, address(want));
        }

        tradeFactory = address(0);
    }

    function _setUpTradeFactory() internal {
        //approve and set up trade factory
        address _tradeFactory = tradeFactory;
        
        uint256 extraRewards = rewardsContract.extraRewardsLength();

        //enable for all rewards tokens too
        for(uint256 i; i < extraRewards; i ++) {
            address virtualRewardsPool = rewardsContract.extraRewards(i);
            address _rewardsToken =
                IConvexRewards(virtualRewardsPool).rewardToken();
            IERC20(_rewardsToken).safeApprove(_tradeFactory, type(uint256).max);
            ITradeFactory(_tradeFactory).enable(_rewardsToken, address(want));
        }
    }

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.


    // Min profit to start checking for harvests if gas is good, max will harvest no matter gas (both in USDT, 6 decimals). Credit threshold is in want token, and will trigger a harvest if credit is large enough. check earmark to look at convex's booster.
    function setHarvestTriggerParams(
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax,
        uint256 _creditThreshold,
        bool _checkEarmark
    ) external onlyVaultManagers {
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;
        creditThreshold = _creditThreshold;
        checkEarmark = _checkEarmark;
    }

    function getFundManagement() 
        internal 
        view 
        returns (IBalancerVault.FundManagement memory fundManagement) 
    {
        fundManagement = IBalancerVault.FundManagement(
                address(this),
                false,
                payable(address(this)),
                false
            );
    }
}
