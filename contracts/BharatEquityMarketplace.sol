// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BharatEquityToken} from "./BharatEquityToken.sol";
import {BharatEquityTokenFactory} from "./BharatEquityTokenFactory.sol";

/// @title BharatEquityMarketplace
/// @notice Buys and sells simulated stock-exposure tokens for native MON at prices signed by an authorised
///         off-chain oracle (EIP-712). Tokens are minted on buy and burned on sell. Sells are paid only from
///         the tracked reserve, never from accrued fees.
/// @dev Accounting invariant: address(this).balance >= reserveBalance + accruedFees.
///      Anything above that (e.g. forced sends) is `surplus()` and is never paid out to sellers.
///
///      Privileged functions:
///        DEFAULT_ADMIN_ROLE: withdrawReserve, withdrawFees, setFeeBps, setMaxFeeBps, setMaxQuoteAge,
///                            setTokenEnabled, unpause, grant/revoke every role (incl. oracle signer rotation)
///        PAUSER_ROLE:        pause
///        ORACLE_SIGNER_ROLE: holds no on-chain function; its signatures authorise quotes
contract BharatEquityMarketplace is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using Math for uint256;

    bytes32 public constant ORACLE_SIGNER_ROLE = keccak256("ORACLE_SIGNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev EIP-712 schema. chainId and this contract's address are bound through the domain separator.
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address user,address token,uint8 side,uint256 amount,uint256 price,uint256 nonce,uint256 marketTimestamp,uint256 expiry)"
    );

    uint8 public constant SIDE_BUY = 0;
    uint8 public constant SIDE_SELL = 1;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_HARD_CAP_BPS = 1_000; // 10%: maxFeeBps can never exceed this
    uint256 public constant MIN_QUOTE_AGE = 10;
    uint256 public constant MAX_QUOTE_AGE = 1 hours;

    /// @param user            Wallet that must submit the trade (msg.sender).
    /// @param token           Registered BharatEquityToken address.
    /// @param side            0 = BUY, 1 = SELL.
    /// @param amount          Token amount, 18 decimals.
    /// @param price           Wei of MON per 1e18 token units (one whole token).
    /// @param nonce           Unique per quote; random 256-bit recommended. Global replay protection.
    /// @param marketTimestamp Unix seconds of the market data used for `price`.
    /// @param expiry          Unix seconds after which the quote is invalid.
    struct Quote {
        address user;
        address token;
        uint8 side;
        uint256 amount;
        uint256 price;
        uint256 nonce;
        uint256 marketTimestamp;
        uint256 expiry;
    }

    BharatEquityTokenFactory public immutable factory;

    uint256 public feeBps = 50; // 0.5%
    uint256 public maxFeeBps = 300; // 3%
    uint256 public maxQuoteAge = 120; // seconds since marketTimestamp

    /// @notice MON available to pay sellers. Grows with buy principal and treasury funding.
    uint256 public reserveBalance;
    /// @notice Fees owed to the protocol; withdrawable by admin, never used for sell payouts.
    uint256 public accruedFees;

    mapping(uint256 nonce => bool) public usedNonces;
    mapping(address token => bool) public tokenDisabled;

    event StockPurchased(
        address indexed user,
        address indexed token,
        uint256 indexed nonce,
        uint256 amount,
        uint256 price,
        uint256 grossCost,
        uint256 fee,
        uint256 marketTimestamp
    );
    event StockSold(
        address indexed user,
        address indexed token,
        uint256 indexed nonce,
        uint256 amount,
        uint256 price,
        uint256 grossValue,
        uint256 fee,
        uint256 marketTimestamp
    );
    event TreasuryFunded(address indexed from, uint256 amount, uint256 reserveBalance);
    event ReserveWithdrawn(address indexed to, uint256 amount, uint256 reserveBalance);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 previousBps, uint256 newBps);
    event MaxFeeUpdated(uint256 previousBps, uint256 newBps);
    event MaxQuoteAgeUpdated(uint256 previous, uint256 current);
    event TokenStatusUpdated(address indexed token, bool enabled);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroValue();
    error WrongUser();
    error WrongSide();
    error TokenNotRegistered(address token);
    error TokenIsDisabled(address token);
    error QuoteExpired();
    error StaleMarketData();
    error NonceAlreadyUsed(uint256 nonce);
    error InvalidSignature();
    error UnauthorizedSigner(address signer);
    error SlippageExceeded(uint256 actual, uint256 limit);
    error InsufficientPayment(uint256 sent, uint256 required);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error ExceedsBalance(uint256 requested, uint256 available);
    error FeeTooHigh(uint256 bps, uint256 cap);
    error InvalidQuoteAge(uint256 age);

    constructor(address admin, BharatEquityTokenFactory factory_) EIP712("BharatEquityMarketplace", "1") {
        if (admin == address(0) || address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    // ================================================================ trading

    /// @notice Buy `q.amount` tokens at the signed price. Pays gross + fee; any excess msg.value is refunded.
    /// @param maxPayment Slippage guard: revert if gross + fee would exceed this many wei.
    /// @return total Wei actually charged (gross + fee).
    function buyStock(Quote calldata q, bytes calldata signature, uint256 maxPayment)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 total)
    {
        _consumeQuote(q, signature, SIDE_BUY);
        (uint256 gross, uint256 fee, uint256 cost) = quoteBuy(q.amount, q.price);
        if (cost > maxPayment) revert SlippageExceeded(cost, maxPayment);
        if (msg.value < cost) revert InsufficientPayment(msg.value, cost);

        reserveBalance += gross;
        accruedFees += fee;
        BharatEquityToken(q.token).mint(msg.sender, q.amount);

        emit StockPurchased(msg.sender, q.token, q.nonce, q.amount, q.price, gross, fee, q.marketTimestamp);

        uint256 refund = msg.value - cost;
        if (refund != 0) Address.sendValue(payable(msg.sender), refund);
        return cost;
    }

    /// @notice Sell `q.amount` tokens at the signed price. Requires prior ERC-20 approval to this contract.
    /// @param minPayout Slippage guard: revert if the net payout (gross - fee) is below this many wei.
    /// @return payout Wei sent to the seller.
    function sellStock(Quote calldata q, bytes calldata signature, uint256 minPayout)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 payout)
    {
        _consumeQuote(q, signature, SIDE_SELL);
        uint256 gross;
        uint256 fee;
        (gross, fee, payout) = quoteSell(q.amount, q.price);
        if (gross == 0) revert ZeroValue();
        if (payout < minPayout) revert SlippageExceeded(payout, minPayout);
        if (gross > reserveBalance) revert InsufficientLiquidity(gross, reserveBalance);

        reserveBalance -= gross;
        accruedFees += fee;

        BharatEquityToken token = BharatEquityToken(q.token);
        token.transferFrom(msg.sender, address(this), q.amount); // reverts on insufficient balance/allowance
        token.burn(q.amount);

        emit StockSold(msg.sender, q.token, q.nonce, q.amount, q.price, gross, fee, q.marketTimestamp);
        Address.sendValue(payable(msg.sender), payout);
    }

    // ================================================================ treasury

    /// @notice Add MON to the sell reserve. Open to anyone (donations can only increase liquidity).
    function fundTreasury() external payable {
        if (msg.value == 0) revert ZeroAmount();
        reserveBalance += msg.value;
        emit TreasuryFunded(msg.sender, msg.value, reserveBalance);
    }

    /// @notice Privileged (admin). Withdraw from the sell reserve. Reduces liquidity available to sellers.
    function withdrawReserve(address payable to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > reserveBalance) revert ExceedsBalance(amount, reserveBalance);
        reserveBalance -= amount;
        emit ReserveWithdrawn(to, amount, reserveBalance);
        Address.sendValue(to, amount);
    }

    /// @notice Privileged (admin). Withdraw accrued trading fees.
    function withdrawFees(address payable to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > accruedFees) revert ExceedsBalance(amount, accruedFees);
        accruedFees -= amount;
        emit FeesWithdrawn(to, amount);
        Address.sendValue(to, amount);
    }

    // ================================================================ admin config

    /// @notice Privileged (admin). Trading fee in basis points, <= maxFeeBps.
    function setFeeBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > maxFeeBps) revert FeeTooHigh(bps, maxFeeBps);
        emit FeeUpdated(feeBps, bps);
        feeBps = bps;
    }

    /// @notice Privileged (admin). Configurable fee ceiling, itself bounded by FEE_HARD_CAP_BPS and >= feeBps.
    function setMaxFeeBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > FEE_HARD_CAP_BPS) revert FeeTooHigh(bps, FEE_HARD_CAP_BPS);
        if (bps < feeBps) revert FeeTooHigh(feeBps, bps);
        emit MaxFeeUpdated(maxFeeBps, bps);
        maxFeeBps = bps;
    }

    /// @notice Privileged (admin). Max seconds between quote market data and execution.
    function setMaxQuoteAge(uint256 age) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (age < MIN_QUOTE_AGE || age > MAX_QUOTE_AGE) revert InvalidQuoteAge(age);
        emit MaxQuoteAgeUpdated(maxQuoteAge, age);
        maxQuoteAge = age;
    }

    /// @notice Privileged (admin). Halt or resume trading in one token. Registered tokens start enabled.
    function setTokenEnabled(address token, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!factory.isRegistered(token)) revert TokenNotRegistered(token);
        tokenDisabled[token] = !enabled;
        emit TokenStatusUpdated(token, enabled);
    }

    /// @notice Privileged (pauser). Emergency stop for buys and sells. Treasury/fee withdrawals stay available.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Privileged (admin). Resume trading.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ================================================================ views

    /// @notice Buy cost. Rounds UP (against the buyer) so dust can never be minted for free.
    function quoteBuy(uint256 amount, uint256 price) public view returns (uint256 gross, uint256 fee, uint256 total) {
        gross = amount.mulDiv(price, 1e18, Math.Rounding.Ceil);
        fee = gross.mulDiv(feeBps, BPS, Math.Rounding.Ceil);
        total = gross + fee;
    }

    /// @notice Sell proceeds. Gross rounds DOWN, fee rounds UP (both against the seller).
    function quoteSell(uint256 amount, uint256 price) public view returns (uint256 gross, uint256 fee, uint256 payout) {
        gross = amount.mulDiv(price, 1e18, Math.Rounding.Floor);
        fee = gross.mulDiv(feeBps, BPS, Math.Rounding.Ceil);
        payout = gross - fee; // fee <= gross because feeBps <= 10%
    }

    /// @notice MON currently available to pay sellers (gross, before fees).
    function availableLiquidity() external view returns (uint256) {
        return reserveBalance;
    }

    /// @notice Untracked MON (e.g. forced sends). Never used for payouts.
    function surplus() external view returns (uint256) {
        return address(this).balance - reserveBalance - accruedFees;
    }

    function isTokenTradable(address token) public view returns (bool) {
        return factory.isRegistered(token) && !tokenDisabled[token];
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The EIP-712 digest the oracle signs. Useful for debugging backend signatures.
    function hashQuote(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH, q.user, q.token, q.side, q.amount, q.price, q.nonce, q.marketTimestamp, q.expiry
                )
            )
        );
    }

    // ================================================================ internal

    function _consumeQuote(Quote calldata q, bytes calldata signature, uint8 side) internal {
        if (q.user != msg.sender) revert WrongUser();
        if (q.side != side) revert WrongSide();
        if (!factory.isRegistered(q.token)) revert TokenNotRegistered(q.token);
        if (tokenDisabled[q.token]) revert TokenIsDisabled(q.token);
        if (q.amount == 0 || q.price == 0) revert ZeroAmount();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (block.timestamp > q.marketTimestamp + maxQuoteAge) revert StaleMarketData();
        if (usedNonces[q.nonce]) revert NonceAlreadyUsed(q.nonce);

        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hashQuote(q), signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidSignature();
        if (!hasRole(ORACLE_SIGNER_ROLE, signer)) revert UnauthorizedSigner(signer);

        usedNonces[q.nonce] = true;
    }
}
