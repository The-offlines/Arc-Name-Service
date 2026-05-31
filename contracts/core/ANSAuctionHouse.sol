// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "../interfaces/IANSRegistry.sol";

/**
 * @title ANSAuctionHouse
 * @author Arc Name Service
 * @notice Premium domain auction system for ANS protocol.
 *         Enables price discovery for valuable names like ai.arc, pay.arc.
 *         Seller creates auction, bidders compete, winner receives domain.
 *
 * @dev Auction lifecycle:
 *      createAuction() ? placeBid() ? settleAuction()
 *                      ? cancelAuction() (only before first bid)
 */
contract ANSAuctionHouse is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // --- Constants ---

    uint64 public constant DURATION_1D  = 1 days;
    uint64 public constant DURATION_3D  = 3 days;
    uint64 public constant DURATION_7D  = 7 days;
    uint64 public constant DURATION_14D = 14 days;

    // --- Storage ---

    IANSRegistry public registry;

    struct Auction {
        bytes32 namehash;
        address seller;
        uint256 startingBid;
        uint256 highestBid;
        address highestBidder;
        uint64  startTime;
        uint64  endTime;
        bool    settled;
        bool    cancelled;
    }

    mapping(uint256 => Auction) private _auctions;
    uint256 private _auctionCounter;

    /// @dev Storage gap for future upgrades
    uint256[50] private __gap;

    // --- Errors ---

    error ZeroAddress();
    error ZeroStartingBid();
    error NotOwner();
    error DomainExpired();
    error DomainLocked();
    error InvalidDuration();
    error AuctionNotFound();
    error AuctionNotActive();
    error AuctionEnded();
    error AuctionNotEnded();
    error AuctionAlreadySettled();
    error AuctionAlreadyCancelled();
    error BidTooLow(uint256 required, uint256 sent);
    error SelfBid();
    error HasBids();
    error NoBids();
    error RefundFailed();
    error PaymentFailed();
    error SellerNoLongerOwner();
    error NotSellerOrOwner();

    // --- Events ---

    event AuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed namehash,
        address indexed seller,
        uint256 startingBid,
        uint64  endTime
    );

    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );

    event AuctionCancelled(
        uint256 indexed auctionId
    );

    event AuctionSettled(
        uint256 indexed auctionId,
        bytes32 indexed namehash,
        address indexed winner,
        address seller,
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
        __Pausable_init();
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
     * @notice Create a new auction for a domain.
     * @param namehash    keccak256 namehash of the domain
     * @param startingBid Minimum opening bid in USDC wei
     * @param duration    Auction duration (use DURATION_* constants)
     * @return auctionId  ID of the created auction
     */
    function createAuction(
        bytes32 namehash,
        uint256 startingBid,
        uint64  duration
    ) external whenNotPaused returns (uint256 auctionId) {
        if (startingBid == 0) revert ZeroStartingBid();

        _validateDuration(duration);

        // Verify seller owns domain
        if (registry.ownerOf(namehash) != msg.sender) revert NotOwner();

        // Verify domain valid
        if (!registry.exists(namehash)) revert DomainExpired();

        // Verify domain not locked
        (, , , bool locked) = registry.getRecord(namehash);
        if (locked) revert DomainLocked();

        auctionId = ++_auctionCounter;

        uint64 startTime = uint64(block.timestamp);
        uint64 endTime   = startTime + duration;

        _auctions[auctionId] = Auction({
            namehash:      namehash,
            seller:        msg.sender,
            startingBid:   startingBid,
            highestBid:    0,
            highestBidder: address(0),
            startTime:     startTime,
            endTime:       endTime,
            settled:       false,
            cancelled:     false
        });

        emit AuctionCreated(auctionId, namehash, msg.sender, startingBid, endTime);
    }

    /**
     * @notice Cancel auction — only allowed before any bids placed.
     * @param auctionId ID of the auction to cancel
     */
    function cancelAuction(uint256 auctionId) external {
        Auction storage auction = _auctions[auctionId];

        if (auction.seller == address(0))  revert AuctionNotFound();
        if (auction.cancelled)             revert AuctionAlreadyCancelled();
        if (auction.settled)               revert AuctionAlreadySettled();

        // Only seller or protocol owner can cancel
        if (msg.sender != auction.seller && msg.sender != owner()) revert NotSellerOrOwner();

        // Cannot cancel if bids exist
        if (auction.highestBidder != address(0)) revert HasBids();

        auction.cancelled = true;

        emit AuctionCancelled(auctionId);
    }

    // --- Bidder Functions ---

    /**
     * @notice Place a bid on an active auction.
     * @dev Previous highest bidder is refunded automatically.
     *      Bid must exceed current highest bid or starting bid.
     * @param auctionId ID of the auction to bid on
     */
    function placeBid(uint256 auctionId) external payable nonReentrant whenNotPaused {
        Auction storage auction = _auctions[auctionId];

        if (auction.seller    == address(0)) revert AuctionNotFound();
        if (auction.cancelled)               revert AuctionAlreadyCancelled();
        if (auction.settled)                 revert AuctionAlreadySettled();
        if (block.timestamp > auction.endTime) revert AuctionEnded();

        // Prevent self bidding
        if (msg.sender == auction.seller) revert SelfBid();

        // Bid must exceed highest bid or starting bid
        uint256 minBid = auction.highestBid > 0
            ? auction.highestBid + 1
            : auction.startingBid;

        if (msg.value < minBid) revert BidTooLow(minBid, msg.value);

        // Refund previous highest bidder
        address previousBidder = auction.highestBidder;
        uint256 previousBid    = auction.highestBid;

        auction.highestBid    = msg.value;
        auction.highestBidder = msg.sender;

        if (previousBidder != address(0) && previousBid > 0) {
            (bool ok, ) = previousBidder.call{value: previousBid}("");
            if (!ok) revert RefundFailed();
        }

        emit BidPlaced(auctionId, msg.sender, msg.value);
    }

    // --- Settle ---

    /**
     * @notice Settle auction after it ends.
     * @dev Anyone can call settle after endTime.
     *      Transfers domain to winner and funds to seller.
     * @param auctionId ID of the auction to settle
     */
    function settleAuction(uint256 auctionId) external nonReentrant {
        Auction storage auction = _auctions[auctionId];

        if (auction.seller    == address(0)) revert AuctionNotFound();
        if (auction.cancelled)               revert AuctionAlreadyCancelled();
        if (auction.settled)                 revert AuctionAlreadySettled();
        if (block.timestamp <= auction.endTime) revert AuctionNotEnded();

        // Must have at least one bid
        if (auction.highestBidder == address(0)) revert NoBids();

        // Verify seller still owns domain
        if (registry.ownerOf(auction.namehash) != auction.seller) revert SellerNoLongerOwner();

        address seller  = auction.seller;
        address winner  = auction.highestBidder;
        uint256 amount  = auction.highestBid;
        bytes32 namehash = auction.namehash;

        // Mark settled before external calls
        auction.settled = true;

        // Transfer domain to winner via registry
        (, address resolver, uint64 expiry, ) = registry.getRecord(namehash);
        registry.setRecord(namehash, winner, resolver, expiry);

        // Transfer funds to seller
        (bool ok, ) = seller.call{value: amount}("");
        if (!ok) revert PaymentFailed();

        emit AuctionSettled(auctionId, namehash, winner, seller, amount);
    }

    // --- View Functions ---

    /**
     * @notice Get auction details by ID.
     */
    function getAuction(uint256 auctionId)
        external
        view
        returns (Auction memory)
    {
        return _auctions[auctionId];
    }

    /**
     * @notice Check if an auction is currently active.
     */
    function isActive(uint256 auctionId) external view returns (bool) {
        Auction storage auction = _auctions[auctionId];
        return !auction.settled &&
               !auction.cancelled &&
               block.timestamp <= auction.endTime &&
               auction.seller != address(0);
    }

    /**
     * @notice Get total auctions created.
     */
    function totalAuctions() external view returns (uint256) {
        return _auctionCounter;
    }

    // --- Admin ---

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        registry = IANSRegistry(newRegistry);
    }

    // --- Internal ---

    function _validateDuration(uint64 duration) internal pure {
        if (
            duration != DURATION_1D  &&
            duration != DURATION_3D  &&
            duration != DURATION_7D  &&
            duration != DURATION_14D
        ) revert InvalidDuration();
    }

    // --- Reject direct ETH ---

    receive() external payable {
        revert("Use placeBid()");
    }
}
