// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
	// StateLibrary is new here and we haven't seen that before
	// It's used to add helper functions to the PoolManager to read
	// storage values.
	// In this case, we use it for accessing `currentTick` values
	// from the pool manager
	using StateLibrary for IPoolManager;

	// PoolIdLibrary used to convert PoolKeys to IDs
	using PoolIdLibrary for PoolKey;
	// Used to represent Currency types and helper functions like `.isNative()`
    using CurrencyLibrary for Currency;
	// Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

	// Errors
	error InvalidOrder();
	error NothingToClaim();
	error NotEnoughToClaim();
	
    // TakeProfitsHook.sol
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;
    mapping(PoolId poolId => mapping(int24 tickToSellAt =>  mapping(bool zeroForOne => uint256 inputAmount))) public pendingOrders;

    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;
	// Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

	// BaseHook Functions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

	function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }


    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120
    
        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;
    
        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity
    
        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }

    function redeem(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);
    
        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();
    
        // they must have claim tokens >= inputAmountToClaimFor
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();
    
        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];
    
        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );
    
        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);
    
        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;
    
        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");
    
        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);
    
        // Return the tick at which the order was actually placed
        return tick;
    }

    function cancelOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne
    ) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);
    
        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens == 0) revert InvalidOrder();
    
        // Remove their `positionTokens` worth of position from pending orders
        // NOTE: We don't want to zero this out directly because other users may have the same position
        pendingOrders[key.toId()][tick][zeroForOne] -= positionTokens;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= positionTokens;
        _burn(msg.sender, positionId, positionTokens);
    
        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, positionTokens);
    }
    function getPositionId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }



    function tryExecutingOrders(
        PoolKey calldata key,
        bool executeZeroForOne
    ) internal returns (bool tryMore, int24 newTick) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
    
        // Given `currentTick` and `lastTick`, 2 cases are possible:
    
        // Case (1) - Tick has increased, i.e. `currentTick > lastTick`
        // or, Case (2) - Tick has decreased, i.e. `currentTick < lastTick`
    
        // If tick increases => Token 0 price has increased
        // => We should check if we have orders looking to sell Token 0
        // i.e. orders with zeroForOne = true
    
        // TODO Case (1)
    
        // If tick decreases => Token 1 price has increased
        // => We should check if we have orders looking to sell Token 1
        // i.e. orders with zeroForOne = false
    
         // TODO Case (2)
    
        // ------
    
        // If no orders were found to be executed, we don't need to try
        // executing any more - return `false` and `currentTick`
        return (false, currentTick);
    }



    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4, int128) {
        // `sender` is the address which initiated the swap
        // if `sender` is the hook, we don't want to go down the `afterSwap`
        // rabbit hole again
        if (sender == address(this)) return (this.afterSwap.selector, 0);
    
        // Should we try to find and execute orders? True initially
        bool tryMore = true;
        int24 currentTick;
    
        while (tryMore) {
            // Try executing pending orders for this pool
    
            // `tryMore` is true if we successfully found and executed an order
            // which shifted the tick value
            // and therefore we need to look again if there are any pending orders
            // within the new tick range
    
            // `tickAfterExecutingOrder` is the tick value of the pool
            // after executing an order
            // if no order was executed, `tickAfterExecutingOrder` will be
            // the same as current tick, and `tryMore` will be false
            (tryMore, currentTick) = tryExecutingOrders(
                key,
                !params.zeroForOne
            );
        }
    
        // New last known tick for this pool is the tick value
        // after our orders are executed
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }


    function swapAndSettleBalances(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");
    
        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
    
            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
    
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }
    
        return delta;
    }
    
    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }
    
    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }


    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    
        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
    
        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
    }
    
}