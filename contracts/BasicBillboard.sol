pragma solidity ^0.4.23;

import "./ERC809.sol";
import "openzeppelin-solidity/contracts/token/ERC721/ERC721Token.sol";
import "solidity-treemap/contracts/TreeMap.sol";

/// @title an example ERC809 implementation where a ERC721 token contract natively provides reservation/access interface
///  The goods being accessed are a fixed supply of advertisement spaces on a virtual billboard
///  Ad can be placed by setting the payload field of the reservation which will be rendered in the webapp
///
///  WARNING: this contract is for illustration only and should not be used in production
contract BasicBillboard is ERC809, ERC721Token {
  using TreeMap for TreeMap.Data;

  struct Reservation {
    address renter;
    // total price
    uint256 amount;
    // access period
    uint256 startTimestamp;
    uint256 stopTimestamp;
    // whether reservation has been settled
    bool settled;
    // payload to show on billboard
    string payload;
  }

  struct Token {
    // iterable of all reservations
    Reservation[] reservations;
    // mapping from start and end timestamps for each reservation to reservation id
    TreeMap.Data startTimestamps;
    TreeMap.Data stopTimestamps;
  }

  // mapping of all tokens
  mapping(uint => Token) tokens;
  // mapping of token owner's money
  mapping(address => uint) payouts;

  constructor(uint _tokens) public
    ERC721Token("BillboardSpace", "BBS")
  {
    for (uint i = 0; i < _tokens; i++) {
      super._mint(msg.sender, i);
    }
  }

  /// @dev Guarantees msg.sender is owner of the given token
  /// @param _tokenId uint256 ID of the token to validate its ownership belongs to msg.sender
  modifier onlyRenterOf(uint256 _tokenId, uint256 _time) {
    require(renterOf(_tokenId, _time) == msg.sender);
    _;
  }

  /// @notice Find the renter of an NFT token as of `_time`
  /// @dev The renter is who made a reservation on `_tokenId` and the reservation spans over `_time`.
  function renterOf(uint256 _tokenId, uint256 _time)
  public
  view
  returns(address)
  {
    Token storage token = tokens[_tokenId];
    bool found;
    uint256 startTime;
    uint256 reservationId;
    (found, startTime, reservationId) = token.startTimestamps.floorEntry(_time);
    if (found) {
      Reservation storage reservation = token.reservations[reservationId];
      if (reservation.stopTimestamp > _time) {
        return reservation.renter;
      }
    }
  }

  /// @notice set payload of `msg.sender`'s reservations between `_start` and `_stop`
  function setPayload(uint256 _tokenId, uint256 _start, uint256 _stop, string _payload)
  public
  returns(bool success)
  {
    // TODO: implement iterator in TreeMap for more efficient batch retrival
    Token storage token = tokens[_tokenId];
    Reservation[] storage reservations = token.reservations;

    bool found = true;
    uint startTime = _start;
    uint stopTime;
    uint reservationId;
    while (found) {
      // FIXME: a token should also have a `renter => startTimestamps` mapping to skip
      //   reservations that don't belong to a renter
      (found, startTime, reservationId) = token.startTimestamps.ceilingEntry(startTime);
      Reservation storage reservation = reservations[reservationId];
      stopTime = reservation.stopTimestamp;
      if (found && stopTime <= _stop && reservation.renter == msg.sender) {
        reservation.payload = _payload;

        success = true;
      }
    }
  }

  /// @notice Reserve access to token `_tokenId` from time `_start` to time `_stop`
  /// @dev A successful reservation must ensure each time slot in the range _start to _stop
  ///  is not previously reserved (by calling the function checkAvailable() described below)
  ///  and then emit a Reserve event.
  function reserve(uint256 _tokenId, uint256 _start, uint256 _stop)
  external
  payable
  returns(bool success)
  {
    if (checkAvailable(_tokenId, _start, _stop)) {
      Token storage token = tokens[_tokenId];
      Reservation[] storage reservations = token.reservations;
      uint id = reservations.length++;
      reservations[id] = Reservation(msg.sender, msg.value, _start, _stop, false, "");
      token.startTimestamps.put(_start, id);
      token.stopTimestamps.put(_stop, id);
      return true;
    }
  }

  /// @notice Revoke access to token `_tokenId` from `_renter` and settle payments
  /// @dev This function should be callable by either the owner of _tokenId or _renter,
  ///  however, the owner should only be able to call this function if now >= _stop to
  ///  prevent premature settlement of funds.
  function settle(uint256 _tokenId, address _renter, uint256 _stop)
  external
  returns(bool success)
  {
    address tokenOwner = ownerOf(_tokenId);
    // TODO: implement iterator in TreeMap for more efficient batch retrival
    Token storage token = tokens[_tokenId];
    Reservation[] storage reservations = token.reservations;

    bool found = true;
    uint stopTime = _stop;
    uint reservationId;
    while (found) {
      // FIXME: a token should also have a `renter => stopTimestamps` mapping to skip
      //   reservations that don't belong to a renter
      (found, stopTime, reservationId) = token.stopTimestamps.ceilingEntry(stopTime);
      Reservation storage reservation = reservations[reservationId];
      if (found && !reservation.settled && reservation.renter == _renter) {
        if (msg.sender == tokenOwner) {
          if (now < reservation.stopTimestamp) {
            revert("Reservation has yet completed and currently can only be settled by the renter!");
          }

          reservation.settled = true;
          payouts[tokenOwner] += reservation.amount;
          success = true;
        } else if (msg.sender == _renter) {
          reservation.settled = true;
          payouts[tokenOwner] += reservation.amount;
          success = true;
        }
      }
    }
  }

  /// @notice Query if token `_tokenId` if available to reserve between `_start` and `_stop` time
  /// @dev For the requested token, we examine its current resertions, check
  ///   1. whether the last reservation that has `startTime` before `_start` already ended before `_start`
  ///                Okay                            Bad
  ///           *startTime*   stopTime        *startTime*   stopTime
  ///             |---------|                  |---------|
  ///                          |-------               |-------
  ///                          _start                 _start
  ///   2. whether the soonest reservation that has `endTime` after `_end` will start after `_end`.
  ///                Okay                            Bad
  ///          startTime   *stopTime*         startTime   *stopTime*
  ///             |---------|                  |---------|
  ///    -------|                           -------|
  ///           _stop                              _stop
  ///
  //   NB: reservation interval are [start time, stop time] i.e. closed on both ends.
  function checkAvailable(uint256 _tokenId, uint256 _start, uint256 _stop)
  public
  view
  returns(bool available)
  {
    Token storage token = tokens[_tokenId];
    Reservation[] storage reservations = token.reservations;
    if (reservations.length > 0) {
      bool found;
      uint reservationId;

      uint stopTime;
      (found, stopTime, reservationId) = token.stopTimestamps.floorEntry(_stop);
      if(found && stopTime >= _start) {
        return false;
      }

      uint startTime;
      (found, startTime, reservationId) = token.startTimestamps.ceilingEntry(_start);
      if(found && startTime <= _stop) {
        return false;
      }
    }

    return true;
  }

  /// @notice Cancel reservation for `_tokenId` between `_start` and `_stop`
  function cancelReservation(uint256 _tokenId, uint256 _start, uint256 _stop)
  external
  returns (bool success)
  {
    // TODO: implement iterator in TreeMap for more efficient batch removal
    Token storage token = tokens[_tokenId];
    Reservation[] storage reservations = token.reservations;

    bool found = true;
    uint startTime = _start;
    uint stopTime;
    uint reservationId;
    // FIXME: a token should also have a `renter => startTimestamps` mapping to skip
    //   reservations that don't belong to a renter more efficiently
    (found, startTime, reservationId) = token.startTimestamps.ceilingEntry(startTime);
    while (found) {
      Reservation storage reservation = reservations[reservationId];
      stopTime = reservation.stopTimestamp;
      if (found) {
        if(stopTime <= _stop && reservation.renter == msg.sender) {
          token.startTimestamps.remove(startTime);
          token.stopTimestamps.remove(stopTime);
          delete reservations[reservationId];

          success = true;
        }

        (found, startTime, reservationId) = token.startTimestamps.higherEntry(startTime);
      }
    }
  }

}
