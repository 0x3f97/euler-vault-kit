// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {IVault, IEVault, IERC4626} from "../IEVault.sol";
import {Base} from "../shared/Base.sol";
import {BalanceUtils} from "../shared/BalanceUtils.sol";
import {AssetTransfers} from "../shared/AssetTransfers.sol";
import {SafeERC20Lib} from "../shared/lib/SafeERC20Lib.sol";
import {ProxyUtils} from "../shared/lib/ProxyUtils.sol";

import "../shared/types/Types.sol";

/// @title VaultModule
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice An EVault module handling ERC4626 standard behaviour
abstract contract VaultModule is IVault, Base, AssetTransfers, BalanceUtils {
    using TypesLib for uint256;
    using SafeERC20Lib for IERC20;

    /// @inheritdoc IERC4626
    function asset() public view virtual reentrantOK returns (address) {
        (IERC20 _asset,,) = ProxyUtils.metadata();
        return address(_asset);
    }

    /// @inheritdoc IERC4626
    function totalAssets() public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();
        return totalAssetsInternal(vaultCache);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();
        return shares.toShares().toAssetsDown(vaultCache).toUint();
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();
        return assets.toAssets().toSharesDown(vaultCache).toUint();
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address account) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();

        return isOperationDisabled(vaultCache.hookedOps, OP_DEPOSIT) ? 0 : maxDepositInternal(vaultCache, account);
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) public view virtual nonReentrantView returns (uint256) {
        return convertToShares(assets);
    }

    /// @inheritdoc IERC4626
    function maxMint(address account) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();

        if (isOperationDisabled(vaultCache.hookedOps, OP_MINT)) return 0;

        // make sure to not revert on conversion
        uint256 shares = maxDepositInternal(vaultCache, account).toAssets().toSharesDownUint256(vaultCache);

        return shares < MAX_SANE_AMOUNT ? shares : MAX_SANE_AMOUNT;
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();
        return shares.toShares().toAssetsUp(vaultCache).toUint();
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();

        return isOperationDisabled(vaultCache.hookedOps, OP_WITHDRAW)
            ? 0
            : maxRedeemInternal(owner).toAssetsDown(vaultCache).toUint();
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();
        return assets.toAssets().toSharesUp(vaultCache).toUint();
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) public view virtual nonReentrantView returns (uint256) {
        return isOperationDisabled(vaultStorage.hookedOps, OP_REDEEM) ? 0 : maxRedeemInternal(owner).toUint();
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view virtual nonReentrantView returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc IVault
    function accumulatedFees() public view virtual nonReentrantView returns (uint256) {
        return loadVault().accumulatedFees.toUint();
    }

    /// @inheritdoc IVault
    function accumulatedFeesAssets() public view virtual nonReentrantView returns (uint256) {
        VaultCache memory vaultCache = loadVault();

        return vaultCache.accumulatedFees.toAssetsDown(vaultCache).toUint();
    }

    /// @inheritdoc IVault
    function creator() public view virtual reentrantOK returns (address) {
        return vaultStorage.creator;
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 amount, address receiver) public virtual nonReentrant returns (uint256) {
        (VaultCache memory vaultCache, address account) = initOperation(OP_DEPOSIT, CHECKACCOUNT_NONE);

        Assets assets = amount == type(uint256).max ? vaultCache.asset.balanceOf(account).toAssets() : amount.toAssets();
        if (assets.isZero()) return 0;

        Shares shares = assets.toSharesDown(vaultCache);
        if (shares.isZero()) revert E_ZeroShares();

        finalizeDeposit(vaultCache, assets, shares, account, receiver);

        return shares.toUint();
    }

    /// @inheritdoc IERC4626
    function mint(uint256 amount, address receiver) public virtual nonReentrant returns (uint256) {
        (VaultCache memory vaultCache, address account) = initOperation(OP_MINT, CHECKACCOUNT_NONE);

        Shares shares = amount.toShares();
        if (shares.isZero()) return 0;

        Assets assets = shares.toAssetsUp(vaultCache);

        finalizeDeposit(vaultCache, assets, shares, account, receiver);

        return assets.toUint();
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 amount, address receiver, address owner) public virtual nonReentrant returns (uint256) {
        (VaultCache memory vaultCache, address account) = initOperation(OP_WITHDRAW, owner);

        Assets assets = amount.toAssets();
        if (assets.isZero()) return 0;

        Shares shares = assets.toSharesUp(vaultCache);

        finalizeWithdraw(vaultCache, assets, shares, account, receiver, owner);

        return shares.toUint();
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 amount, address receiver, address owner) public virtual nonReentrant returns (uint256) {
        (VaultCache memory vaultCache, address account) = initOperation(OP_REDEEM, owner);

        Shares shares = amount == type(uint256).max ? vaultStorage.users[owner].getBalance() : amount.toShares();
        if (shares.isZero()) return 0;

        Assets assets = shares.toAssetsDown(vaultCache);
        if (assets.isZero()) revert E_ZeroAssets();

        finalizeWithdraw(vaultCache, assets, shares, account, receiver, owner);

        return assets.toUint();
    }

    /// @inheritdoc IVault
    function skim(uint256 amount, address receiver) public virtual nonReentrant returns (uint256) {
        (VaultCache memory vaultCache, address account) = initOperation(OP_SKIM, CHECKACCOUNT_NONE);

        Assets balance = vaultCache.asset.balanceOf(address(this)).toAssets();
        Assets available = balance <= vaultCache.cash ? Assets.wrap(0) : balance.subUnchecked(vaultCache.cash);

        Assets assets;
        if (amount == type(uint256).max) {
            assets = available;
        } else {
            assets = amount.toAssets();
            if (assets > available) revert E_InsufficientAssets();
        }
        if (assets.isZero()) return 0;

        Shares shares = assets.toSharesDown(vaultCache);
        if (shares.isZero()) revert E_ZeroShares();

        increaseBalance(vaultCache, receiver, account, shares, assets);
        vaultStorage.cash = vaultCache.cash = vaultCache.cash + assets;

        return shares.toUint();
    }

    function finalizeDeposit(
        VaultCache memory vaultCache,
        Assets assets,
        Shares shares,
        address sender,
        address receiver
    ) private {
        pullAssets(vaultCache, sender, assets);

        increaseBalance(vaultCache, receiver, sender, shares, assets);
    }

    function finalizeWithdraw(
        VaultCache memory vaultCache,
        Assets assets,
        Shares shares,
        address sender,
        address receiver,
        address owner
    ) private {
        if (vaultCache.cash < assets) revert E_InsufficientCash();

        decreaseAllowance(owner, sender, shares);
        decreaseBalance(vaultCache, owner, sender, receiver, shares, assets);

        pushAssets(vaultCache, receiver, assets);
    }

    function maxRedeemInternal(address owner) internal view returns (Shares) {
        Shares max = vaultStorage.users[owner].getBalance();
        if (max.isZero()) return Shares.wrap(0);

        // If account has borrows, withdrawal might be reverted by the controller during account status checks.
        // The collateral vault has no way to verify or enforce the behaviour of the controller, which the account owner
        // has enabled. It will therefore assume that all of the assets would be withheld by the controller and
        // under-estimate the return amount to zero.
        // Integrators who handle borrowing should implement custom logic to work with the particular controllers
        // they want to support.
        if (isCollateralEnabled(owner, address(this)) && hasControllerEnabled(owner)) return Shares.wrap(0);

        VaultCache memory vaultCache = loadVault();

        Shares cash = vaultCache.cash.toSharesDown(vaultCache);
        max = max > cash ? cash : max;

        return max;
    }

    function maxDepositInternal(VaultCache memory vaultCache, address) private pure returns (uint256) {
        uint256 supply = totalAssetsInternal(vaultCache);
        if (supply >= vaultCache.supplyCap) return 0;

        uint256 remainingSupply;
        unchecked {
            remainingSupply = vaultCache.supplyCap - supply;
        }

        uint256 remainingCash = MAX_SANE_AMOUNT - vaultCache.cash.toUint();

        return remainingCash < remainingSupply ? remainingCash : remainingSupply;
    }
}

/// @dev Deployable module contract
contract Vault is VaultModule {
    constructor(Integrations memory integrations) Base(integrations) {}
}
