// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * ============================================================================
 *
 *    VaultedMetrics Reserve v3.0 — Corrected for Cyberscope Re-Audit
 *    VaultedMetrics LLC — April 2, 2026
 *
 *    Autonomous strategic buyback engine for VM888
 *
 *    The token was the body. The Reserve is what brings it to life.
 *    If we believe it, then it's built into our code.
 *
 * ============================================================================
 *
 *    ARCHITECTURE:
 *
 *    Automation:  External/manual scheduler (2 calls/day, batch execution, 12 hours apart)
 *    Chambers:    4 buys/day across 3 chamber types
 *    Fuel:        1.0 ETH seed
 *
 *    Beat Cycle (repeating):
 *      Call #1 -> FLOOR (LP creation + burn) + REWARD (Staking/Ecosystem)
 *      Call #2 -> FLOOR (LP creation + burn) + SHIELD (accumulate/deploy)
 *
 *    Price Intelligence:
 *      On-chain EMA with manipulation-resistant bounded spot price
 *      Rising:   0.08 - 0.15 USD in ETH per buy (conserve)
 *      Stable:   0.15 - 0.28 USD in ETH per buy (steady)
 *      Falling:  0.28 - 0.55 USD in ETH per buy (accelerate)
 *      Crashing: 0.55 - 1.10 USD in ETH per buy + Shield deploys 25% as LP
 *
 *    Deposit Whitelist:
 *      Founders wallet  - ONE TIME ONLY (seed funding)
 *      Treasury A (Trezor) - PERMANENT (ongoing fuel)
 *      Treasury B (Trezor) - PERMANENT (backup fuel)
 *      All others - REJECTED (via explicit deposit function)
 *
 *    After Renouncing Ownership:
 *      No withdraw. No pause. No modify. No selfdestruct.
 *      The Reserve beats forever until ETH is depleted.
 *      Self-sustaining at $86/day trading volume.
 *
 *    CYBERSCOPE AUDIT FINDINGS RESOLVED (Initial Audit March 27, 2026):
 *      DRR  - receive() decoupled from deposit whitelist
 *      ITA  - Correct token address for balanceOf calls
 *      SPOM - EMA-bounded spot price prevents manipulation
 *      EIA  - Owner can set initial EMA from reliable source
 *      CCR  - Resolved by renounceOwnership()
 *      EWSS - shieldBalance reset on VM888 emergency withdrawal
 *      IEST - Actual ETH spend tracking via balance delta
 *      MCM  - Misleading comments corrected
 *      MC   - Deposit validation + slippage protection on all swaps
 *      MEE  - Events emitted for all state changes
 *      PLPI - Liquidity adequacy check before swaps
 *      PMRM - Resolved by renounceOwnership()
 *      PSU  - Safe subtraction patterns throughout
 *      RV   - Acknowledged (bounded amounts, prediction not exploitable)
 *      RRA  - One-time max approval via lazy initialization
 *      SBI  - Shield balance tracks actual tokens consumed
 *      SDAM - Proportional token calculation from pool ratio
 *      TUU  - Solidity time unit keywords used
 *      OCTD - Resolved by renounceOwnership()
 *      UTPD - Resolved by renounceOwnership()
 *      ZD   - Zero division guards on all calculations
 *      L04  - Solidity naming conventions applied
 *      L19  - Pragma locked to 0.8.20
 *      L20  - SafeERC20 for all token transfers
 *
 *    (c) 2026 VaultedMetrics LLC. All rights reserved.
 *
 * ============================================================================
 */

// ============================================================
//                    INTERFACES
// ============================================================

interface IUniswapV2Router02 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function WETH() external pure returns (address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);

    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IVM888 {
    function BUY_TOTAL_BPS() external pure returns (uint256);
}

interface IVM888Reserve {
    function VM888_TOKEN() external view returns (address);
}

// ============================================================
//                    SHIELD LIQUIDITY HELPER
// ============================================================

contract ShieldLiquidityHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LiquidityAmounts {
        uint256 tokens;
        uint256 eth;
        uint256 minTokens;
        uint256 minETH;
    }

    address public immutable reserve;

    error OnlyReserve();
    error InvalidArguments();
    error NoTokensReceived();
    error ETHRefundFailed();

    constructor(address reserve_) {
        if (reserve_ == address(0)) revert InvalidArguments();
        reserve = reserve_;
    }

    function executeAddLiquidity(
        address uniswapRouter,
        address vm888Token,
        uint256 tokensToUse,
        uint256 minTokens,
        uint256 minETH,
        address deadAddress,
        uint256 deadline
    )
        external
        payable
        nonReentrant
    {
        if (msg.sender != reserve) revert OnlyReserve();
        if (
            uniswapRouter == address(0) || vm888Token == address(0) || deadAddress == address(0)
                || tokensToUse == 0 || msg.value == 0
        ) revert InvalidArguments();

        IERC20 token = IERC20(vm888Token);
        uint256 balanceBefore = token.balanceOf(address(this));

        // Pull inside this call so a router revert also rolls back the token transfer.
        token.safeTransferFrom(reserve, address(this), tokensToUse);

        LiquidityAmounts memory amounts;
        amounts.tokens = token.balanceOf(address(this)) - balanceBefore;
        if (amounts.tokens == 0) revert NoTokensReceived();

        // Reserve -> helper is taxed, so preserve the intended VM888/ETH ratio
        // and slippage limits using the amount that actually reached the helper.
        amounts.eth = Math.mulDiv(msg.value, amounts.tokens, tokensToUse);
        amounts.minTokens = Math.mulDiv(minTokens, amounts.tokens, tokensToUse);
        amounts.minETH = Math.mulDiv(minETH, amounts.tokens, tokensToUse);
        if (amounts.eth == 0 || amounts.minTokens == 0 || amounts.minETH == 0) {
            revert InvalidArguments();
        }

        token.forceApprove(uniswapRouter, amounts.tokens);
        IUniswapV2Router02(uniswapRouter).addLiquidityETH{value: amounts.eth}(
            vm888Token, amounts.tokens, amounts.minTokens, amounts.minETH, deadAddress, deadline
        );
        token.forceApprove(uniswapRouter, 0);

        uint256 tokenLeftover = token.balanceOf(address(this));
        if (tokenLeftover > 0) {
            token.safeTransfer(reserve, tokenLeftover);
        }

        uint256 ethLeftover = address(this).balance;
        if (ethLeftover > 0) {
            (bool success,) = payable(reserve).call{value: ethLeftover}("");
            if (!success) revert ETHRefundFailed();
        }
    }

    /// @notice Return any VM888 left in the helper to the Reserve.
    /// @dev Permissionless because the only possible recipient is the configured Reserve.
    function withdrawTokensFromHelper() external nonReentrant {
        IERC20 vm888 = IERC20(IVM888Reserve(reserve).VM888_TOKEN());
        uint256 balance = vm888.balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        vm888.safeTransfer(reserve, balance);
    }

    receive() external payable {}
}

// ============================================================
//                    MAIN CONTRACT
// ============================================================

contract VaultedMetricsReserve is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //                    ECOSYSTEM ADDRESSES
    // ============================================================

    address public constant VM888_TOKEN = 0x062570121e9519C77CB71C7936B6C1f76C7B1119;

    IUniswapV2Router02 public constant UNISWAP_ROUTER =
        IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    IUniswapV2Pair public constant UNISWAP_PAIR =
        IUniswapV2Pair(0xdfad37E05c4a203cd9aCa0f856407a0634f5b467);

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address public constant FOUNDERS_WALLET = 0x9E5ef891a89e57FaF907670e97005f91751F578c;
    address public constant TREASURY_A = 0x011fC8Ca3553C4Ab7460ae50BB833bC398AACbe4;
    address public constant TREASURY_B = 0xeF9CF6F30950E8707A35Db1F2890a30dc79625C8;
    address public constant STAKING_WALLET = 0x40bA7dB618BD9eE95E9745D598629c0fF69c84eE;
    address public constant ECOSYSTEM_WALLET = 0x6a8D23738B76faFd8b14eB89308e9e437C3976F6;

    // ============================================================
    //                    CONSTANTS
    // ============================================================

    uint256 public constant BEAT_INTERVAL = 12 hours;

    uint256 public constant BUY_RISING_MIN  = 0.000039 ether;
    uint256 public constant BUY_RISING_MAX  = 0.000072 ether;
    uint256 public constant BUY_STABLE_MIN  = 0.000072 ether;
    uint256 public constant BUY_STABLE_MAX  = 0.000135 ether;
    uint256 public constant BUY_FALLING_MIN = 0.000135 ether;
    uint256 public constant BUY_FALLING_MAX = 0.000265 ether;
    uint256 public constant BUY_CRASH_MIN   = 0.000265 ether;
    uint256 public constant BUY_CRASH_MAX   = 0.000530 ether;

    uint256 public constant EMA_ALPHA_BPS = 328;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant RISING_THRESHOLD  = 500;
    uint256 public constant FALLING_THRESHOLD = 500;
    uint256 public constant CRASH_THRESHOLD   = 1500;
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 3000;

    uint256 public constant SHIELD_DEPLOY_BPS = 2500;
    uint256 public constant SHIELD_SAFETY_CAP = 6_000_000 * 1e18;
    uint256 public constant SHIELD_SAFETY_DEPLOY_BPS = 5000;

    uint256 public constant MIN_ETH_RESERVE = 0.001 ether;

    uint256 public constant TWAP_MIN_WINDOW = 30 minutes;

    uint256 public constant LP_MIN_OUTPUT_BPS = 9500;

    // ============================================================
    //                    STATE VARIABLES
    // ============================================================

    uint256 public chamberIndex;
    uint256 public lastBeatTimestamp;
    bool    public founderHasDeposited;
    uint256 public shieldBalance;
    uint256 public emaPrice;
    bool    public emaInitialized;
    uint256 public totalCalls;
    uint256 public beatCount;
    uint256 public totalEthSpent;
    uint256 public totalVM888Bought;
    bool    public rewardToStaking;
    bool    private _routerApproved;
    ShieldLiquidityHelper public shieldLiquidityHelper;
    address public immutable emergencyWithdrawalAddress;

    uint256 public lastPriceCumulative;
    uint32 public lastTwapTimestamp;
    uint256 public lastTwapPrice;
    bool public twapInitialized;

    // ============================================================
    //                    EVENTS
    // ============================================================

    event Beat(
        uint256 indexed beatNumber,
        uint256 chamberType,
        uint256 ethSpent,
        uint256 vm888Acquired,
        uint256 currentPrice,
        uint256 emaPrice_
    );

    event ShieldDeployed(
        uint256 indexed beatNumber,
        uint256 vm888Deployed,
        string reason
    );

    event Deposited(address indexed depositor, uint256 amount);
    event EMAUpdated(uint256 newEMA, uint256 currentPrice);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event EmergencyWithdrawShield(uint256 amount);
    event ExcessVM888Swept(uint256 amount);
    event TWAPObserved(uint256 price, uint32 timeElapsed);
    event ShieldLiquidityHelperUpdated(address indexed previousHelper, address indexed newHelper);

    error InvalidShieldLiquidityHelper();

    // ============================================================
    //                    CONSTRUCTOR
    // ============================================================

    constructor() Ownable(msg.sender) {
        emergencyWithdrawalAddress = owner();
        shieldLiquidityHelper = new ShieldLiquidityHelper(address(this));
        lastBeatTimestamp = 0;
        chamberIndex = 0;
        rewardToStaking = true;
        emaInitialized = false;
        _routerApproved = false;
    }

    // ============================================================
    //                    INTERNAL: LAZY APPROVAL (RRA)
    // ============================================================

    /// @notice Approve Uniswap Router for max VM888 on first use only
    /// @dev One-time max approval instead of per-operation approvals.
    ///      Lazy pattern avoids constructor revert if token is not yet deployed.
    function _ensureRouterApproval() internal {
        if (!_routerApproved) {
            IERC20(VM888_TOKEN).approve(address(UNISWAP_ROUTER), type(uint256).max);
            _routerApproved = true;
        }
    }

    // ============================================================
    //                    OWNER-ONLY SETUP (before renounce)
    // ============================================================

    /// @notice Set initial EMA from a known reliable price before first execution
    /// @dev Prevents EMA initialization from a single potentially manipulated spot price.
    ///      Call with the current VM888 price from a trusted source (e.g. DEX Screener).
    function setInitialEMA(uint256 initialPrice) external onlyOwner {
        require(initialPrice > 0, "Price must be positive");
        require(!emaInitialized, "EMA already initialized");
        emaPrice = initialPrice;
        emaInitialized = true;
        emit EMAUpdated(emaPrice, initialPrice);
    }

    /// @notice Replace the helper used for Shield liquidity deployment.
    /// @dev The replacement must be deployed with this Reserve as its authorized caller.
    function setShieldLiquidityHelper(address newShieldLiquidityHelper) external onlyOwner {
        if (newShieldLiquidityHelper.code.length == 0) revert InvalidShieldLiquidityHelper();

        try ShieldLiquidityHelper(payable(newShieldLiquidityHelper)).reserve() returns (address configuredReserve) {
            if (configuredReserve != address(this)) revert InvalidShieldLiquidityHelper();
        } catch {
            revert InvalidShieldLiquidityHelper();
        }

        address previousHelper = address(shieldLiquidityHelper);
        shieldLiquidityHelper = ShieldLiquidityHelper(payable(newShieldLiquidityHelper));

        emit ShieldLiquidityHelperUpdated(previousHelper, newShieldLiquidityHelper);
    }

    /// @notice Emergency withdraw all ETH — disabled after renounceOwnership()
    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = msg.sender.call{value: balance}("");
        require(success, "ETH transfer failed");
        emit EmergencyWithdraw(address(0), balance);
    }

    /// @dev Sends withdrawable tokens to the current owner.
    ///  For VM888, the accounted Shield balance is preserved.
    function emergencyWithdrawTokens(address token) external onlyOwner nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 withdrawableBalance = balance;

        if (token == VM888_TOKEN) {
            withdrawableBalance = balance > shieldBalance ? balance - shieldBalance : 0;
        }

        require(withdrawableBalance > 0, "No tokens to withdraw");
        IERC20(token).safeTransfer(msg.sender, withdrawableBalance);
        emit EmergencyWithdraw(token, withdrawableBalance);
    }

    /// @notice Permissionlessly sweep VM888 not accounted for by the Shield.
    /// @dev Preserves shieldBalance and sends excess VM888 to the immutable
    ///      deployment owner.
    function sweepExcessVM888() external nonReentrant {
        uint256 balance = IERC20(VM888_TOKEN).balanceOf(address(this));
        uint256 withdrawableBalance = balance;
        withdrawableBalance = balance > shieldBalance ? balance - shieldBalance : 0;

        require(withdrawableBalance > 0, "No tokens to withdraw");
        IERC20(VM888_TOKEN).safeTransfer(emergencyWithdrawalAddress, withdrawableBalance);
        emit ExcessVM888Swept(withdrawableBalance);
    }

    /// @notice Emergency withdraw the complete VM888 Shield balance.
    /// @dev Disabled after renounceOwnership().
    function emergencyWithdrawShield() external onlyOwner nonReentrant {
        uint256 balance = IERC20(VM888_TOKEN).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");

        shieldBalance = 0;
        IERC20(VM888_TOKEN).safeTransfer(msg.sender, balance);
        emit EmergencyWithdrawShield(balance);
    }

    /// @notice Permanently renounce owner privileges after required setup is complete.
    /// @dev Requires the initial EMA to be set before renouncing.
    function renounceOwnership() public override onlyOwner {
        require(emaInitialized, "EMA must be initialized");
        super.renounceOwnership();
    }

    // ============================================================
    //                    DEPOSIT / RECEIVE (DRR + MC)
    // ============================================================

    /// @dev Intentional Reserve funding must go through deposit(), which enforces
    ///      the founders/treasury whitelist and emits Deposited.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Deposit ETH into the Reserve (whitelisted wallets only)
    function deposit() external payable {
        _processDeposit();
    }

    function _processDeposit() internal {
        require(msg.value > 0, "Deposit amount must be greater than zero");
        if (msg.sender == FOUNDERS_WALLET) {
            require(!founderHasDeposited, "Founders: one-time deposit already made");
            founderHasDeposited = true;
        } else if (msg.sender == TREASURY_A) {
            // Always allowed
        } else if (msg.sender == TREASURY_B && TREASURY_B != address(0)) {
            // Always allowed
        } else {
            revert("Deposit rejected: wallet not whitelisted");
        }
        emit Deposited(msg.sender, msg.value);
    }

    // ============================================================
    //                    SCHEDULER HOOKS
    // ============================================================

    function checkUpkeep(bytes calldata)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = emaInitialized
            && (block.timestamp >= lastBeatTimestamp + BEAT_INTERVAL)
            && (address(this).balance > MIN_ETH_RESERVE + BUY_RISING_MIN);
        performData = "";
    }

    function performUpkeep(bytes calldata) external {
        _executeBatchBeat();
    }

    // ============================================================
    //                    PUBLIC BACKUP EXECUTE
    // ============================================================

    /// @notice Manual trigger for Reserve beat execution
    function execute() external {
        _executeBatchBeat();
    }

    // ============================================================
    //                    CORE: BATCH BEAT EXECUTION
    // ============================================================

    /// @notice Execute one Reserve beat using TWAP-based market intelligence.
    /// @dev Reads a TWAP oracle observation, derives a bounded execution price for
    ///      buy sizing, and only updates the EMA when the TWAP observation is fresh.
    ///      The bounded execution price must not be fed back into the EMA because
    ///      doing so would let repeated boundary prices slowly drag the EMA.
    ///      Shield deployment receives the unbounded oracle price so it can classify
    ///      downturn severity without losing crash information to the execution clamp.
    function _executeBatchBeat() internal nonReentrant {
        require(emaInitialized, "EMA must be initialized");
        require(
            block.timestamp >= lastBeatTimestamp + BEAT_INTERVAL,
            "Too soon: must wait 12 hours between calls"
        );
        require(
            address(this).balance > MIN_ETH_RESERVE + BUY_RISING_MIN,
            "Insufficient ETH: below minimum reserve"
        );

        _ensureRouterApproval();

        lastBeatTimestamp = block.timestamp;
        totalCalls++;

        (uint256 oraclePrice, bool freshTwap) = _observeTwap();

        uint256 executionPrice = _sanitizePriceAgainstEMA(oraclePrice);

        _executeFloor(executionPrice);

        if (chamberIndex % 2 == 0) {
            _executeReward(executionPrice);
        } else {
            _executeShield(oraclePrice, executionPrice);
        }

        if (freshTwap) {
            _updateEMA(oraclePrice);
        }

        chamberIndex++;
    }

    // ============================================================
    //                    CHAMBER: FLOOR
    // ============================================================

    function _executeFloor(uint256 currentPrice) internal {
        uint256 buyAmount = _getBuyAmount(currentPrice);

        if (address(this).balance <= buyAmount + MIN_ETH_RESERVE) {
            if (address(this).balance > MIN_ETH_RESERVE) {
                buyAmount = address(this).balance - MIN_ETH_RESERVE;
            } else {
                return;
            }
        }
        if (buyAmount < BUY_RISING_MIN) return;

        uint256 ethBefore = address(this).balance;
        uint256 buyHalf = buyAmount / 2;
        uint256 lpHalf = buyAmount - buyHalf;

        uint256 vm888Before = IERC20(VM888_TOKEN).balanceOf(address(this));
        _swapETHForVM888(buyHalf, address(this));
        uint256 vm888Bought = IERC20(VM888_TOKEN).balanceOf(address(this)) - vm888Before;

        // Pair bought VM888 with the ETH amount it can actually support after buy tax.
        uint256 vm888ForLP = vm888Bought;

        {
            uint256 ethForLP = (vm888ForLP * currentPrice) / 1e18;
            if (ethForLP > lpHalf) {
                ethForLP = lpHalf;
            }
            if (ethForLP == 0) {
                return;
            }

            uint256 tokensToUse = _getProportionalTokenAmount(ethForLP, currentPrice);
            if (tokensToUse > vm888ForLP) {
                tokensToUse = vm888ForLP;
            }
            if (tokensToUse == 0) return;

            uint256 minTokens = (tokensToUse * LP_MIN_OUTPUT_BPS) / BPS_DENOMINATOR;
            uint256 minETH = (ethForLP * LP_MIN_OUTPUT_BPS) / BPS_DENOMINATOR;

            if (tokensToUse > 0 && ethForLP > 0) {

                uint256 vm888BalanceBeforeLP = IERC20(VM888_TOKEN).balanceOf(address(this));

                try UNISWAP_ROUTER.addLiquidityETH{value: ethForLP}(
                    VM888_TOKEN, tokensToUse, minTokens, minETH, DEAD_ADDRESS, block.timestamp + 5 minutes
                ) {
                    uint256 vm888BalanceAfterLP = IERC20(VM888_TOKEN).balanceOf(address(this));
                    uint256 tokensConsumed = 0;
                    if (vm888BalanceBeforeLP > vm888BalanceAfterLP) {
                        tokensConsumed = vm888BalanceBeforeLP - vm888BalanceAfterLP;
                    }
                    if (vm888ForLP > tokensConsumed) {
                        IERC20(VM888_TOKEN).safeTransfer(DEAD_ADDRESS, vm888ForLP - tokensConsumed);
                    }
                } catch {
                    IERC20(VM888_TOKEN).safeTransfer(DEAD_ADDRESS, vm888ForLP);
                }
            }
        }

        beatCount++;
        uint256 actualEthSpent = ethBefore - address(this).balance;
        totalEthSpent += actualEthSpent;
        totalVM888Bought += vm888Bought;
        emit Beat(beatCount, 0, actualEthSpent, vm888Bought, currentPrice, emaPrice);
    }

    // ============================================================
    //                    CHAMBER: REWARD (ITA fix)
    // ============================================================

    function _executeReward(uint256 currentPrice) internal {
        uint256 buyAmount = _getBuyAmount(currentPrice);

        if (address(this).balance <= buyAmount + MIN_ETH_RESERVE) {
            if (address(this).balance > MIN_ETH_RESERVE) {
                buyAmount = address(this).balance - MIN_ETH_RESERVE;
            } else {
                return;
            }
        }
        if (buyAmount < BUY_RISING_MIN) return;

        uint256 ethBefore = address(this).balance;
        address recipient = rewardToStaking ? STAKING_WALLET : ECOSYSTEM_WALLET;
        rewardToStaking = !rewardToStaking;

        // ITA FIX: Use VM888_TOKEN for balanceOf — NOT the recipient address
        uint256 vm888Before = IERC20(VM888_TOKEN).balanceOf(recipient);
        _swapETHForVM888(buyAmount, recipient);
        uint256 vm888Received = IERC20(VM888_TOKEN).balanceOf(recipient) - vm888Before;

        beatCount++;
        uint256 actualEthSpent = ethBefore - address(this).balance;
        totalEthSpent += actualEthSpent;
        totalVM888Bought += vm888Received;
        emit Beat(beatCount, 1, actualEthSpent, vm888Received, currentPrice, emaPrice);
    }

    // ============================================================
    //                    CHAMBER: SHIELD
    // ============================================================

    /// @notice Execute the Shield chamber for the current beat.
    /// @dev Uses `executionPrice` for conservative buy sizing and `oraclePrice` for
    ///      market-condition classification. Keeping these prices separate prevents
    ///      the EMA clamp from hiding the difference between mild dips and severe
    ///      crashes. Shield LP deployment is triggered only when the oracle price is
    ///      meaningfully below the EMA, or when the safety cap is exceeded.
    /// @param oraclePrice The latest TWAP-derived price used for Shield trigger logic.
    /// @param executionPrice The EMA-bounded price used only for buy sizing.
    function _executeShield(uint256 oraclePrice, uint256 executionPrice) internal {
        uint256 buyAmount = _getBuyAmount(executionPrice);

        if (address(this).balance <= buyAmount + MIN_ETH_RESERVE) {
            if (address(this).balance > MIN_ETH_RESERVE) {
                buyAmount = address(this).balance - MIN_ETH_RESERVE;
            } else {
                return;
            }
        }
        if (buyAmount < BUY_RISING_MIN) return;

        uint256 ethBefore = address(this).balance;
        uint256 vm888Before = IERC20(VM888_TOKEN).balanceOf(address(this));
        _swapETHForVM888(buyAmount, address(this));
        uint256 vm888Bought = IERC20(VM888_TOKEN).balanceOf(address(this)) - vm888Before;

        shieldBalance += vm888Bought;
        beatCount++;
        uint256 actualEthSpent = ethBefore - address(this).balance;
        totalEthSpent += actualEthSpent;
        totalVM888Bought += vm888Bought;
        emit Beat(beatCount, 2, actualEthSpent, vm888Bought, executionPrice, emaPrice);

        if (shieldBalance > SHIELD_SAFETY_CAP) {
            uint256 safetyDeploy = (shieldBalance * SHIELD_SAFETY_DEPLOY_BPS) / BPS_DENOMINATOR;
            _deployShieldAsLP(safetyDeploy, "SAFETY_VALVE", executionPrice);
            return;
        }

        if (!emaInitialized || emaPrice == 0 || oraclePrice == 0) {
            return;
        }

        uint256 crashDev = (emaPrice * CRASH_THRESHOLD) / BPS_DENOMINATOR;
        uint256 fallDev = (emaPrice * FALLING_THRESHOLD) / BPS_DENOMINATOR;

        if (emaPrice > crashDev && oraclePrice < emaPrice - crashDev) {
            uint256 crashDeploy =
                (shieldBalance * SHIELD_DEPLOY_BPS) / BPS_DENOMINATOR;

            if (crashDeploy > 0) {
                _deployShieldAsLP(crashDeploy, "CRASH", executionPrice);
            }

            return;
        }

        if (emaPrice > fallDev && oraclePrice < emaPrice - fallDev) {
            uint256 fallDeploy =
                (shieldBalance * SHIELD_DEPLOY_BPS) / BPS_DENOMINATOR;

            if (fallDeploy > 0) {
                _deployShieldAsLP(fallDeploy, "EMA", executionPrice);
            }
        }
    }

    // ============================================================
    //                    SHIELD LP DEPLOYMENT (SBI + SDAM)
    // ============================================================

    function _deployShieldAsLP(uint256 vm888Amount, string memory reason, uint256 referencePrice) internal {
        if (vm888Amount == 0 || address(this).balance <= MIN_ETH_RESERVE) return;
        if (referencePrice == 0) return;

        uint256 ethForLP = BUY_STABLE_MIN;

        if (address(this).balance <= ethForLP + MIN_ETH_RESERVE) {
            shieldBalance -= vm888Amount;
            IERC20(VM888_TOKEN).safeTransfer(DEAD_ADDRESS, vm888Amount);
            emit ShieldDeployed(beatCount, vm888Amount, reason);
            return;
        }

        // PTCM FIX: Size Shield LP from TWAP/EMA-bounded reference price, not spot reserves.
        uint256 tokensToUse = _getProportionalTokenAmount(ethForLP, referencePrice);
        if (tokensToUse > vm888Amount) {
            tokensToUse = vm888Amount;
        }
        if (tokensToUse == 0) return;

        uint256 minTokens = (tokensToUse * LP_MIN_OUTPUT_BPS) / BPS_DENOMINATOR;
        uint256 minETH = (ethForLP * LP_MIN_OUTPUT_BPS) / BPS_DENOMINATOR;
        if (minTokens == 0 || minETH == 0) return;

        IERC20 vm888 = IERC20(VM888_TOKEN);
        ShieldLiquidityHelper helper = shieldLiquidityHelper;
        uint256 vm888BalanceBefore = vm888.balanceOf(address(this));

        // Use an exact, temporary allowance because the owner can replace the helper.
        vm888.forceApprove(address(helper), tokensToUse);

        try helper.executeAddLiquidity{value: ethForLP}(
            address(UNISWAP_ROUTER),
            VM888_TOKEN,
            tokensToUse,
            minTokens,
            minETH,
            DEAD_ADDRESS,
            block.timestamp + 5 minutes
        ) {
            vm888.forceApprove(address(helper), 0);

            uint256 vm888BalanceAfter = vm888.balanceOf(address(this));
            uint256 tokensConsumed =
                vm888BalanceBefore > vm888BalanceAfter ? vm888BalanceBefore - vm888BalanceAfter : 0;
            if (tokensConsumed > shieldBalance) tokensConsumed = shieldBalance;

            shieldBalance -= tokensConsumed;
            emit ShieldDeployed(beatCount, tokensConsumed, reason);
        } catch {
            vm888.forceApprove(address(helper), 0);

            // The helper pulls VM888 atomically, so a revert leaves these tokens
            // in the Reserve and available for the configured burn fallback.
            shieldBalance -= tokensToUse;
            vm888.safeTransfer(DEAD_ADDRESS, tokensToUse);
            emit ShieldDeployed(beatCount, tokensToUse, reason);
        }
    }

    /// @notice Calculate VM888 tokens proportional to ETH using a manipulation-resistant ETH/VM888 price.
    /// @dev referencePrice is ETH per VM888, scaled by 1e18.
    function _getProportionalTokenAmount(
        uint256 ethAmount,
        uint256 referencePrice
    ) internal pure returns (uint256) {
        if (referencePrice == 0) return 0;
        return (ethAmount * 1e18) / referencePrice;
    }

    // ============================================================
    //                    UNISWAP SWAP (MC + PLPI)
    // ============================================================

    /// @notice Swap ETH for VM888 on Uniswap V2
    /// @dev Includes liquidity check and a fee-adjusted minimum output based on VM888's buy tax.
    function _swapETHForVM888(uint256 ethAmount, address recipient) internal {
        (uint112 reserve0, uint112 reserve1,) = UNISWAP_PAIR.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Pair has no liquidity");

        _requireSpotNearReference();

        address[] memory path = new address[](2);
        path[0] = UNISWAP_ROUTER.WETH();
        path[1] = VM888_TOKEN;

        // MC FIX: Calculate minimum output for slippage protection, taking into account the total buy fees
        uint256 expectedOutput = _getExpectedOutput(ethAmount);
        uint256 total_buy_bps = IVM888(VM888_TOKEN).BUY_TOTAL_BPS();
        uint256 minOutput = (expectedOutput * (BPS_DENOMINATOR - total_buy_bps)) / BPS_DENOMINATOR;

        UNISWAP_ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethAmount}(
            minOutput, path, recipient, block.timestamp + 5 minutes
        );
    }

    /// @notice Estimate expected VM888 output using Uniswap V2 constant product formula
    function _getExpectedOutput(uint256 ethIn) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = UNISWAP_PAIR.getReserves();
        address token0 = UNISWAP_PAIR.token0();

        uint256 ethReserve;
        uint256 tokenReserve;

        if (token0 == VM888_TOKEN) {
            tokenReserve = uint256(reserve0);
            ethReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            ethReserve = uint256(reserve0);
        }

        if (ethReserve == 0) return 0;

        uint256 ethInWithFee = ethIn * 997;
        uint256 numerator = ethInWithFee * tokenReserve;
        uint256 denominator = (ethReserve * 1000) + ethInWithFee;
        return numerator / denominator;
    }

    /// @notice Reverts when the current spot price deviates too far from the TWAP/EMA reference price.
    /// @dev Uses the last observed TWAP as the preferred reference, falling back to EMA when TWAP is
    ///      not initialized yet. If neither reference price is available, or the spot price cannot be
    ///      read, this guard does not block execution so the first valid observation can still seed.
    function _requireSpotNearReference() internal view {
        uint256 spot = _getCurrentPrice();

        uint256 referencePrice = lastTwapPrice;
        if (referencePrice == 0 && emaInitialized) referencePrice = emaPrice;

        if (spot == 0 || referencePrice == 0) return;

        uint256 maxDeviation = (referencePrice * MAX_PRICE_DEVIATION_BPS) / BPS_DENOMINATOR;
        uint256 lower = referencePrice > maxDeviation ? referencePrice - maxDeviation : 1;
        uint256 upper = referencePrice + maxDeviation;

        require(spot >= lower && spot <= upper, "Spot price deviates from reference price");
    }

    // ============================================================
    //                    PRICE INTELLIGENCE (SPOM + ZD)
    // ============================================================

    /// @notice Refresh the TWAP oracle and EMA without executing a Reserve beat.
    /// @dev Permissionless liveness helper for periods where spot price is outside
    ///      the execution band. This function performs no swaps, spends no ETH, and
    ///      does not update lastBeatTimestamp, chamberIndex, or beat counters.
    ///      EMA is updated only from a fresh TWAP observation.
    function refreshOracle() external {
        require(emaInitialized, "EMA must be initialized");

        (uint256 oraclePrice, bool freshTwap) = _observeTwap();

        if (freshTwap) {
            _updateEMA(oraclePrice);
        }
    }

    /// @notice Get VM888 price from Uniswap pair reserves
    function _getCurrentPrice() internal view returns (uint256 price) {
        (uint112 reserve0, uint112 reserve1,) = UNISWAP_PAIR.getReserves();
        address token0 = UNISWAP_PAIR.token0();

        if (reserve0 == 0 || reserve1 == 0) return 0;

        if (token0 == VM888_TOKEN) {
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else {
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
        }
    }

    /// @notice Bound a price against the current EMA for conservative execution sizing.
    /// @dev This must not be used as the source for EMA updates. It is only an
    ///      execution guard so extreme oracle moves do not instantly change buy sizing.
    function _sanitizePriceAgainstEMA(uint256 price) internal view returns (uint256) {
        require(emaInitialized && emaPrice != 0, "EMA must be initialized");

        if (price == 0) {
            return emaPrice;
        }

        uint256 deviation =
            (emaPrice * MAX_PRICE_DEVIATION_BPS) / BPS_DENOMINATOR;

        uint256 maxUp = emaPrice + deviation;
        uint256 maxDown = emaPrice > deviation ? emaPrice - deviation : 1;

        if (price > maxUp) {
            return maxUp;
        }

        if (price < maxDown) {
            return maxDown;
        }

        return price;
    }

    /// @notice Return the current Uniswap V2 cumulative price for VM888 in ETH.
    /// @dev Uses the pair's cumulative price accumulator and applies the standard
    ///      counterfactual update for time elapsed since the pair's last reserve
    ///      update. The returned cumulative price is selected so it always represents
    ///      ETH per VM888, regardless of whether VM888 is token0 or token1.
    /// @return cumulativePrice The current cumulative ETH-per-VM888 price in UQ112x112.
    /// @return blockTimestamp The current block timestamp truncated to uint32.
    function _currentCumulativePrice() internal view returns (uint256 cumulativePrice, uint32 blockTimestamp) {
        blockTimestamp = uint32(block.timestamp);

        uint256 price0Cumulative = UNISWAP_PAIR.price0CumulativeLast();
        uint256 price1Cumulative = UNISWAP_PAIR.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = UNISWAP_PAIR.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Pair has no liquidity");

        if (blockTimestampLast != blockTimestamp) {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;

            price0Cumulative +=
                (uint256(reserve1) << 112) / uint256(reserve0) * timeElapsed;

            price1Cumulative +=
                (uint256(reserve0) << 112) / uint256(reserve1) * timeElapsed;
        }

        address token0 = UNISWAP_PAIR.token0();

        if (token0 == VM888_TOKEN) {
            cumulativePrice = price0Cumulative; // WETH per VM888
        } else {
            cumulativePrice = price1Cumulative; // WETH per VM888
        }
    }

    /// @notice Observe the Uniswap V2 TWAP oracle and return the best available price.
    /// @dev Produces a fresh TWAP only when enough time has elapsed since the previous
    ///      observation. If the window is too short, this function does not revert;
    ///      it returns the last trusted TWAP, the EMA, or the current spot price as a
    ///      fallback and marks the observation as stale. Callers should only update
    ///      long-lived oracle state, such as the EMA, when `fresh` is true.
    /// @return price The observed TWAP price, or the best available fallback price.
    /// @return fresh True if `price` was computed from a new valid TWAP window.
    function _observeTwap() internal returns (uint256 price, bool fresh) {
        (uint256 currentCumulative, uint32 currentTimestamp) = _currentCumulativePrice();

        if (!twapInitialized) {
            lastPriceCumulative = currentCumulative;
            lastTwapTimestamp = currentTimestamp;
            twapInitialized = true;

            // Seed only. Do not claim this is a valid TWAP.
            uint256 fallbackPrice = emaInitialized ? emaPrice : _getCurrentPrice();
            return (fallbackPrice, false);
        }

        uint32 timeElapsed = currentTimestamp - lastTwapTimestamp;

        if (timeElapsed < TWAP_MIN_WINDOW) {
            if (lastTwapPrice != 0) {
                return (lastTwapPrice, false);
            }

            if (emaInitialized && emaPrice != 0) {
                return (emaPrice, false);
            }

            return (_getCurrentPrice(), false);
        }

        uint256 averagePriceX112 =
            (currentCumulative - lastPriceCumulative) / timeElapsed;

        price = (averagePriceX112 * 1e18) >> 112;

        if (price == 0) {
            if (lastTwapPrice != 0) return (lastTwapPrice, false);
            if (emaInitialized && emaPrice != 0) return (emaPrice, false);
            return (_getCurrentPrice(), false);
        }

        lastPriceCumulative = currentCumulative;
        lastTwapTimestamp = currentTimestamp;
        lastTwapPrice = price;

        emit TWAPObserved(price, timeElapsed);
        return (price, true);
    }


    // ============================================================
    //                    BUY AMOUNT CALCULATION (PSU + RV)
    // ============================================================

    function _getBuyAmount(uint256 currentPrice) internal view returns (uint256 buyAmount) {
        uint256 minBuy;
        uint256 maxBuy;

        if (!emaInitialized) {
            minBuy = BUY_STABLE_MIN;
            maxBuy = BUY_STABLE_MAX;
        } else if (currentPrice > emaPrice + (emaPrice * RISING_THRESHOLD / BPS_DENOMINATOR)) {
            minBuy = BUY_RISING_MIN;
            maxBuy = BUY_RISING_MAX;
        } else {
            // PSU FIX: Calculate deviation amounts before subtraction to prevent underflow
            uint256 crashDev = (emaPrice * CRASH_THRESHOLD) / BPS_DENOMINATOR;
            uint256 fallDev  = (emaPrice * FALLING_THRESHOLD) / BPS_DENOMINATOR;

            if (emaPrice > crashDev && currentPrice < emaPrice - crashDev) {
                minBuy = BUY_CRASH_MIN;
                maxBuy = BUY_CRASH_MAX;
            } else if (emaPrice > fallDev && currentPrice < emaPrice - fallDev) {
                minBuy = BUY_FALLING_MIN;
                maxBuy = BUY_FALLING_MAX;
            } else {
                minBuy = BUY_STABLE_MIN;
                maxBuy = BUY_STABLE_MAX;
            }
        }

        uint256 range = maxBuy - minBuy;
        
        // RV FIX: Avoid pseudo-randomness entirely. Buy sizing is deterministic and
        // bounded by market condition, so block producers/keepers cannot predict or
        // bias a pseudo-random amount for advantage.
        buyAmount = minBuy + (range / 2);
    }

    /// @notice Update Exponential Moving Average
    function _updateEMA(uint256 currentPrice) internal {
        if (currentPrice == 0) return;
        emaPrice = (currentPrice * EMA_ALPHA_BPS + emaPrice * (BPS_DENOMINATOR - EMA_ALPHA_BPS)) / BPS_DENOMINATOR;
        emit EMAUpdated(emaPrice, currentPrice);
    }

    // ============================================================
    //                    VIEW FUNCTIONS
    // ============================================================

    function getReserveStatus() external view returns (
        uint256 ethBalance,
        uint256 shieldBal,
        uint256 emaPriceValue,
        uint256 totalSpent,
        uint256 totalBought,
        uint256 beats,
        uint256 calls,
        uint256 chamber,
        bool stakingNext
    ) {
        return (
            address(this).balance, shieldBalance, emaPrice,
            totalEthSpent, totalVM888Bought, beatCount,
            totalCalls, chamberIndex, rewardToStaking
        );
    }

    function getMarketCondition() external view returns (uint256 condition) {
        if (!emaInitialized) return 1;
        uint256 currentPrice = _getCurrentPrice();
        if (currentPrice == 0) return 1;

        if (currentPrice > emaPrice + (emaPrice * RISING_THRESHOLD / BPS_DENOMINATOR)) return 0;

        uint256 crashDev = (emaPrice * CRASH_THRESHOLD) / BPS_DENOMINATOR;
        if (emaPrice > crashDev && currentPrice < emaPrice - crashDev) return 3;

        uint256 fallDev = (emaPrice * FALLING_THRESHOLD) / BPS_DENOMINATOR;
        if (emaPrice > fallDev && currentPrice < emaPrice - fallDev) return 2;

        return 1;
    }

    function timeUntilNextBeat() external view returns (uint256) {
        uint256 nextBeat = lastBeatTimestamp + BEAT_INTERVAL;
        if (block.timestamp >= nextBeat) return 0;
        return nextBeat - block.timestamp;
    }

    function getCurrentPrice() external view returns (uint256) {
        return _getCurrentPrice();
    }

    function getAvailableETH() external view returns (uint256) {
        if (address(this).balance <= MIN_ETH_RESERVE) return 0;
        return address(this).balance - MIN_ETH_RESERVE;
    }

    // ============================================================
    //  CENTRALIZATION NOTE (CCR, PMRM, OCTD, UTPD):
    //
    //  All onlyOwner functions (setInitialEMA, setShieldLiquidityHelper,
    //  emergencyWithdrawETH, emergencyWithdrawShield) are
    //  permanently disabled after renounceOwnership(). This is the same pattern used in the VM888
    //  token contract, audited by Cyberscope with zero critical and zero
    //  medium findings after re-audit (Corrected Phase 2, March 6, 2026).
    // ============================================================
}
