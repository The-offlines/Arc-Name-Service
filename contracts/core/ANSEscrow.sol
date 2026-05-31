// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IANSRegistry.sol";

/**
 * @title ANSEscrow
 * @author Arc Name Service
 * @notice Trustless escrow layer for ANS domain trades.
 *         Seller creates deal, buyer funds it, escrow holds
 *         funds until domain is transferred, then releases payment.
 *
 * @dev Deal lifecycle:
 *      createDeal() ? fundDeal() ? completeDeal()
 *                               ? cancelDeal() (before funded)
 *                               ? refundDeal() (after funded, if needed)
 */
contract ANSEscrow is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // --- Storage ---

    IANSRegistry public registry;

    struct EscrowDeal {
        bytes32 namehash;
        address seller;
        address buyer;
        uint256 amount;
        uint64  createdAt;
        bool    funded;
        bool    completed;
        bool    cancelled;
    }

    /// @dev dealId => EscrowDeal
    mapping(uint256 => EscrowDeal) private _deals;

    /// @dev auto-incrementing deal counter
    uint256 private _dealCounter;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    // --- Errors ---

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error DomainExpired();
    error DomainLocked();
    error SelfDeal();
    error DealNotFound();
    error AlreadyFunded();
    error NotFunded();
    error AlreadyCompleted();
    error AlreadyCancelled();
    error NotBuyer();
    error NotSeller();
    error WrongPayment(uint256 required, uint256 sent);
    error SellerNoLongerOwner();
    error PaymentFailed();
    error RefundFailed();

    // --- Events ---

    event DealCreated(
        uint256 indexed dealId,
        bytes32 indexed namehash,
        address indexed seller,
        address buyer,
        uint256 amount
    );

    event DealFunded(
        uint256 indexed dealId,
        address indexed buyer,
        uint256 amount
    );

    event DealCompleted(
        uint256 indexed dealId,
        bytes32 indexed namehash,
        address indexed seller,
        address buyer,
        uint256 amount
    );

    event DealCancelled(
        uint256 indexed dealId
    );

    event DealRefunded(
        uint256 indexed dealId,
        address indexed buyer,
        uint256 amount
    );

    // --- Constructor ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- Initializer ---

    function initialize(address owner_, address registry_) external initializer {
        if (owner_    == address(0)) revert ZeroAddress();
        if (registry_ == address(0)) revert ZeroAddress();

        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _transferOwnership(owner_);

        registry = IANSRegistry(registry_);
    }

    // --- Upgrade ---

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // --- Seller Functions ---

    /**
     * @notice Seller creates an escrow deal for a specific buyer.
     * @param namehash keccak256 namehash of the domain
     * @param buyer    Address of the intended buyer
     * @param amount   Required payment amount in USDC wei
     * @return dealId  ID of the created deal
     */
    function createDeal(
        bytes32 namehash,
        address buyer,
        uint256 amount
    ) external returns (uint256 dealId) {
        if (buyer  == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();
        if (buyer  == msg.sender) revert SelfDeal();

        // Verify seller owns domain
        if (registry.ownerOf(namehash) != msg.sender) revert NotOwner();

        // Verify domain valid and not expired
        if (!registry.exists(namehash)) revert DomainExpired();

        // Verify domain not locked
        (, , , bool locked) = registry.getRecord(namehash);
        if (locked) revert DomainLocked();

        dealId = ++_dealCounter;

        _deals[dealId] = EscrowDeal({
            namehash:  namehash,
            seller:    msg.sender,
            buyer:     buyer,
            amount:    amount,
            createdAt: uint64(block.timestamp),
            funded:    false,
            completed: false,
            cancelled: false
        });

        emit DealCreated(dealId, namehash, msg.sender, buyer, amount);
    }

    /**
     * @notice Seller cancels deal before it is funded.
     * @param dealId ID of the deal to cancel
     */
    function cancelDeal(uint256 dealId) external {
        EscrowDeal storage deal = _deals[dealId];

        if (deal.seller == address(0)) revert DealNotFound();
        if (deal.seller != msg.sender) revert NotSeller();
        if (deal.funded)               revert AlreadyFunded();
        if (deal.cancelled)            revert AlreadyCancelled();
        if (deal.completed)            revert AlreadyCompleted();

        deal.cancelled = true;

        emit DealCancelled(dealId);
    }

    // --- Buyer Functions ---

    /**
     * @notice Buyer funds the escrow deal with exact payment.
     * @dev Funds held in contract until completeDeal() or refundDeal().
     * @param dealId ID of the deal to fund
     */
    function fundDeal(uint256 dealId) external payable nonReentrant {
        EscrowDeal storage deal = _deals[dealId];

        if (deal.seller    == address(0)) revert DealNotFound();
        if (deal.buyer     != msg.sender) revert NotBuyer();
        if (deal.funded)                  revert AlreadyFunded();
        if (deal.cancelled)               revert AlreadyCancelled();
        if (deal.completed)               revert AlreadyCompleted();
        if (msg.value      != deal.amount) revert WrongPayment(deal.amount, msg.value);

        deal.funded = true;

        emit DealFunded(dealId, msg.sender, msg.value);
    }

    // --- Complete ---

    /**
     * @notice Complete the deal — transfer domain and release payment.
     * @dev Can be called by either seller or buyer once funded.
     *      Verifies seller still owns domain before transferring.
     * @param dealId ID of the deal to complete
     */
    function completeDeal(uint256 dealId) external nonReentrant {
        EscrowDeal storage deal = _deals[dealId];

        if (deal.seller == address(0))  revert DealNotFound();
        if (!deal.funded)               revert NotFunded();
        if (deal.completed)             revert AlreadyCompleted();
        if (deal.cancelled)             revert AlreadyCancelled();

        // Only seller or buyer can complete
        if (msg.sender != deal.seller && msg.sender != deal.buyer) revert NotOwner();

        // Verify seller still owns domain
        if (registry.ownerOf(deal.namehash) != deal.seller) revert SellerNoLongerOwner();

        // Verify domain still valid
        if (!registry.exists(deal.namehash)) revert DomainExpired();

        address seller = deal.seller;
        address buyer  = deal.buyer;
        uint256 amount = deal.amount;
        bytes32 namehash = deal.namehash;

        // Mark complete before external calls
        deal.completed = true;

        // Transfer domain ownership in registry
        (, address resolver, uint64 expiry, ) = registry.getRecord(namehash);
        registry.setRecord(namehash, buyer, resolver, expiry);

        // Release payment to seller
        (bool ok, ) = seller.call{value: amount}("");
        if (!ok) revert PaymentFailed();

        emit DealCompleted(dealId, namehash, seller, buyer, amount);
    }

    /**
     * @notice Refund buyer if deal cannot be completed.
     * @dev Only owner can trigger emergency refund.
     *      Used if seller transfers domain outside escrow.
     * @param dealId ID of the deal to refund
     */
    function refundDeal(uint256 dealId) external nonReentrant onlyOwner {
        EscrowDeal storage deal = _deals[dealId];

        if (deal.seller == address(0)) revert DealNotFound();
        if (!deal.funded)              revert NotFunded();
        if (deal.completed)            revert AlreadyCompleted();
        if (deal.cancelled)            revert AlreadyCancelled();

        address buyer  = deal.buyer;
        uint256 amount = deal.amount;

        deal.cancelled = true;

        (bool ok, ) = buyer.call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit DealRefunded(dealId, buyer, amount);
    }

    // --- View Functions ---

    /**
     * @notice Get deal details by ID.
     */
    function getDeal(uint256 dealId)
        external
        view
        returns (EscrowDeal memory)
    {
        return _deals[dealId];
    }

    /**
     * @notice Get total number of deals created.
     */
    function totalDeals() external view returns (uint256) {
        return _dealCounter;
    }

    /**
     * @notice Update registry reference.
     */
    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        registry = IANSRegistry(newRegistry);
    }

    // --- Reject direct ETH ---

    receive() external payable {
        revert("Use fundDeal()");
    }
}
