// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "../interfaces/IANSRegistry.sol";

/**
 * @title ANSMarketplace
 * @author Arc Name Service
 * @notice V1 marketplace for buying and selling ANS domains using native USDC.
 *         Handles listings, cancellations, and purchases only.
 *         No auctions, offers, escrow, or royalties.
 *
 * @dev Purchase flow:
 *      1. Seller calls listName(namehash, price)
 *      2. Buyer calls buyName(namehash) with exact msg.value
 *      3. Marketplace verifies listing and domain validity
 *      4. Ownership transferred in ANSRegistry
 *      5. Seller receives funds
 *      6. Listing removed
 */
contract ANSMarketplace is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // --- Storage ---

    /// @notice ANSRegistry for ownership and expiry verification
    IANSRegistry public registry;

    struct Listing {
        bytes32 namehash;
        address seller;
        uint256 price;
        uint64  listedAt;
        bool    active;
    }

    /// @dev namehash => Listing
    mapping(bytes32 => Listing) private _listings;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    // --- Errors ---

    error ZeroAddress();
    error ZeroPrice();
    error NotOwner();
    error DomainExpired();
    error DomainLocked();
    error AlreadyListed();
    error NotListed();
    error ListingNotActive();
    error SelfPurchase();
    error WrongPayment(uint256 required, uint256 sent);
    error SellerNoLongerOwner();
    error PaymentFailed();

    // --- Events ---

    event NameListed(
        bytes32 indexed namehash,
        address indexed seller,
        uint256 price
    );

    event ListingCancelled(
        bytes32 indexed namehash
    );

    event NameSold(
        bytes32 indexed namehash,
        address indexed seller,
        address indexed buyer,
        uint256 price
    );

    event RegistryUpdated(address indexed newRegistry);

    // --- Constructor ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- Initializer ---

    /**
     * @notice Initialize the marketplace.
     * @param owner_    Protocol owner address
     * @param registry_ Deployed ANSRegistry address
     */
    function initialize(address owner_, address registry_) external initializer {
        if (owner_    == address(0)) revert ZeroAddress();
        if (registry_ == address(0)) revert ZeroAddress();

        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        _transferOwnership(owner_);

        registry = IANSRegistry(registry_);
    }

    // --- Upgrade Authorization ---

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // --- Seller Functions ---

    /**
     * @notice List a domain for sale.
     * @dev Caller must own domain, domain must be valid and unlocked.
     * @param namehash keccak256 namehash of the domain
     * @param price    Sale price in USDC wei
     */
    function listName(bytes32 namehash, uint256 price)
        external
        whenNotPaused
    {
        if (price == 0) revert ZeroPrice();

        // Verify ownership via registry
        if (registry.ownerOf(namehash) != msg.sender) revert NotOwner();

        // Verify domain is valid and not expired
        if (!registry.exists(namehash)) revert DomainExpired();

        // Verify domain is not locked
        (, , , bool locked) = registry.getRecord(namehash);
        if (locked) revert DomainLocked();

        // Prevent duplicate listings
        if (_listings[namehash].active) revert AlreadyListed();

        _listings[namehash] = Listing({
            namehash: namehash,
            seller:   msg.sender,
            price:    price,
            listedAt: uint64(block.timestamp),
            active:   true
        });

        emit NameListed(namehash, msg.sender, price);
    }

    /**
     * @notice Cancel an active listing.
     * @dev Only the original seller can cancel.
     * @param namehash keccak256 namehash of the domain
     */
    function cancelListing(bytes32 namehash) external {
        Listing storage listing = _listings[namehash];

        if (!listing.active) revert NotListed();
        if (listing.seller != msg.sender) revert NotOwner();

        delete _listings[namehash];

        emit ListingCancelled(namehash);
    }

    // --- Buyer Functions ---

    /**
     * @notice Purchase a listed domain.
     * @dev Payment must be exact. Ownership transferred in registry.
     * @param namehash keccak256 namehash of the domain to purchase
     */
    function buyName(bytes32 namehash)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        Listing storage listing = _listings[namehash];

        // Validate listing
        if (!listing.active) revert ListingNotActive();

        // Prevent self purchase
        if (listing.seller == msg.sender) revert SelfPurchase();

        // Validate exact payment
        if (msg.value != listing.price) revert WrongPayment(listing.price, msg.value);

        // Verify domain still valid
        if (!registry.exists(namehash)) revert DomainExpired();

        // Verify seller still owns domain
        if (registry.ownerOf(namehash) != listing.seller) revert SellerNoLongerOwner();

        address seller = listing.seller;
        uint256 price  = listing.price;

        // Remove listing before transfer (checks-effects-interactions)
        delete _listings[namehash];

        // Transfer ownership in registry
        // Note: Registry transferName() requires msg.sender to be owner.
        // Marketplace must be authorized or use a different pattern.
        // We call registry directly — marketplace must be set as operator.
        // For V1: seller pre-approves marketplace via registry.setApproval (future)
        // Current V1: use direct registry admin transfer via setRecord
        (, address resolver, uint64 expiry, ) = registry.getRecord(namehash);
        registry.setRecord(namehash, msg.sender, resolver, expiry);

        // Pay seller
        (bool ok, ) = seller.call{value: price}("");
        if (!ok) revert PaymentFailed();

        emit NameSold(namehash, seller, msg.sender, price);
    }

    // --- View Functions ---

    /**
     * @notice Get listing details for a domain.
     * @param namehash keccak256 namehash of the domain
     */
    function getListing(bytes32 namehash)
        external
        view
        returns (Listing memory)
    {
        return _listings[namehash];
    }

    /**
     * @notice Check if a domain is currently listed.
     * @param namehash keccak256 namehash of the domain
     */
    function isListed(bytes32 namehash) external view returns (bool) {
        return _listings[namehash].active;
    }

    // --- Admin Functions ---

    /**
     * @notice Pause the marketplace (emergency only).
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the marketplace.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Update registry reference.
     * @param newRegistry New ANSRegistry address
     */
    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        registry = IANSRegistry(newRegistry);
        emit RegistryUpdated(newRegistry);
    }

    // --- Reject direct ETH ---

    receive() external payable {
        revert("Use buyName()");
    }
}
