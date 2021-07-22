// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VoteToken is ERC20('Democracy Financial Vote', 'VOTE') {
  mapping(uint256 => uint256) roundMintMultiplier;
  
  constructor() {
    _mint(msg.sender, 10000000 ether);
    
    roundMintMultiplier[0] = 1 ether;
    roundMintMultiplier[1] = 1 ether;
  }
  
  /**
   * @dev Destroys `amount` tokens from the caller.
   *
   * See {ERC20-_burn}.
   */
  function burn(uint256 amount) public virtual {
    _burn(_msgSender(), amount);
  }
  
  
  
  // Round system
  uint256 constant public ROUND_DURATION = 60 minutes;
  uint256 constant public ELECTION_REGISTRATION_START = 1625544400;
  uint256 constant public ELECTION_REGISTRATION_END = 1625544400 + 10 minutes;
  uint256 constant public ELECTION_START = 1625544400 + 20 minutes;
  uint256 constant public ELECTION_END = 1625544400 + 30 minutes;
  uint256 constant public ROUND_START = 1625544400 + 40 minutes;
  uint256 constant public CLAIM_PERIOD = 5 minutes;
  uint256 constant public DISMISS_PERIOD = 5 minutes;
  
  uint256 constant public DAILY_MINT_BUDGET = 30000 ether; // 10 representators + 1 president = 9,900,000 tokens per month
  uint256 constant public MIN_MINT_BUDGET_MULTIPLIER = 0.03 ether;
  
  uint256 constant public NEW_MINT_TIMELOCK = 7 days;
  
  function assignRoundMintMultiplier(uint256 round) public {
    roundMintMultiplier[round] = roundMintMultiplier[round - 1] * 3 / 4;
    if (roundMintMultiplier[round] < MIN_MINT_BUDGET_MULTIPLIER) {
      roundMintMultiplier[round] = MIN_MINT_BUDGET_MULTIPLIER;
    }
  }
  
  function getRoundAtTimestamp(uint256 firstRoundStart, uint256 timestamp) public pure returns(uint256) {
    return (ROUND_DURATION + timestamp - firstRoundStart) / ROUND_DURATION;
  }
  
  function getCurrentRound(uint256 firstRoundStart) public view returns(uint256) {
    return getRoundAtTimestamp(firstRoundStart, block.timestamp);
  }
  
  function getRoundStart(uint256 firstRoundStart, uint256 round) public pure returns(uint256) {
    return firstRoundStart + ROUND_DURATION * round;
  }
  
  function isUnderPeriod(uint256 firstRoundStart, uint256 firstRoundEnd) public view returns(bool result, uint256 startRound, uint256 endRound) {
    startRound = getCurrentRound(firstRoundStart);
    endRound = getCurrentRound(firstRoundEnd);
    result = (startRound - 1 == endRound);
  }
  
  
  
  // Government system
  struct RepresentatorProfile {
    string name;
    string description;
    string avatar;
    address representator;
    uint256 number;
  }
  
  // Representator number format: round * 1e27 + number
  mapping(address => mapping(uint256 => uint256)) representatorNumber; // representatorNumber[address][round] = numberOfThatRound
  mapping(uint256 => RepresentatorProfile) representatorProfile; // representatorProfile[number] = profileOfThatRepresentator
  mapping(uint256 => uint256) lastRepresentatorNumber; // lastRepresentatorNumber[round]
  
  event RegisterAsRepresentator(address indexed representator, uint256 indexed round, uint256 indexed number);
  function registerAsRepresentator(
    string calldata _name,
    string calldata _description,
    string calldata _avatar
  ) public returns(uint256) {
    uint256 registrationRound;
    uint256 _unused1;
    bool available;
    (available, registrationRound, _unused1) = isUnderPeriod(ELECTION_REGISTRATION_START, ELECTION_REGISTRATION_END);
    
    require(available, "Registration closed");
    require(representatorNumber[msg.sender][registrationRound] == 0, "Already registered");
    
    uint256 _number = registrationRound * 1e27 + lastRepresentatorNumber[registrationRound] + 1;
    
    representatorNumber[msg.sender][registrationRound] = _number;
    representatorProfile[_number] = RepresentatorProfile({
      name: _name,
      description: _description,
      avatar: _avatar,
      representator: msg.sender,
      number: _number
    });
    
    lastRepresentatorNumber[registrationRound]++;
    
    return _number;
  }
  
  function getRepresentatorProfile(address representator, uint256 round) public view returns(RepresentatorProfile memory) {
    return representatorProfile[representatorNumber[representator][round]];
  }
  
  // Chair ID number format: round * 1e27 + number
  mapping(uint256 => address) public representators; // representators[chairId] = address
  mapping(address => mapping(uint256 => uint256)) public representatorChairNumber;
  mapping(uint256 => uint256) public chairDailyMintLimitUsage; // chairDailyMintLimitUsage[chairId without round]
  mapping(uint256 => mapping(address => uint256)) public chairDailyMintLimitUsageByAddress; // chairDailyMintLimitUsage[chairId without round][address]
  mapping(uint256 => uint256) public chairClaimMaxScore; // chairClaimLastTimestamp[chairId] = lastTimestamp
  mapping(uint256 => uint256) public chairClaimLastTimestamp; // chairClaimLastTimestamp[chairId] = lastTimestamp
  
  function isPresidentByChairId(uint256 chairId) public pure returns(bool) {
    return chairId % 100 == 10;
  }
  
  function isPresident(address representator) public view returns(bool) {
    return isPresidentByChairId(representatorChairNumber[representator][getCurrentRound(ROUND_START)]);
  }
  
  
  
  // Base multi mint with daily mint limit logic from foodcourt.finance
  event AllowMinter(address indexed setter, address indexed target, bool allowed);
  event SetDailyMintLimit(address indexed setter, uint256 oldLimit, uint256 newLimit);

  struct MinterData {
    bool allowed;
    uint256 timelock;
    uint256 dailyLimit;
  }

  uint256 public constant DAILY_INTERVAL = 1 days;

  uint256 public minterTimelock = 0; // in seconds, will be hardcoded on production

  mapping(address => MinterData) public allowMinting;
  mapping(address => mapping(uint256 => uint256)) public dailyMint;
  mapping(uint256 => bool) public dailySalaryClaimed;
  
  function getDailyMintLimit(address minter) public view returns(uint256) {
    uint256 round = getCurrentRound(ROUND_START);
    return allowMinting[minter].dailyLimit * roundMintMultiplier[round];
  }
  
  // 1% of DAILY_MINT_BUDGET become salary of 
  function getDailySalary() public view returns(uint256) {
    uint256 round = getCurrentRound(ROUND_START);
    return DAILY_MINT_BUDGET * roundMintMultiplier[round] / 100;
  }

  /*function setAllowMinting(address _address, bool _allowed) public onlyOwner {
    if (_allowed) {
      allowMinting[_address].allowed = true;
      allowMinting[_address].timelock = block.timestamp + minterTimelock;
    } else {
      allowMinting[_address].allowed = false;
      allowMinting[_address].timelock = 0;
    }

    emit AllowMinter(_msgSender(), _address, _allowed);
  }*/

  /*function setDailyMintLimit(address _address, uint256 _limit) internal {
    emit SetDailyMintLimit(_msgSender(), allowMinting[_address].dailyLimit, _limit);
    allowMinting[_address].dailyLimit = _limit;
  }*/

  modifier onlyMinter {
    require(allowMinting[_msgSender()].dailyLimit > 0, "not minter");
    require(block.timestamp >= allowMinting[_msgSender()].timelock, "mint locked");
    _;
  }

  function mintDailyLimited(address _address, uint256 _amount) public view returns (bool) {
    return dailyMint[_address][block.timestamp / DAILY_INTERVAL] + _amount > getDailyMintLimit(_address);
  }

  function increaseMint(uint256 _amount) internal {
    require(!mintDailyLimited(_msgSender(), _amount), "mint limited");
    dailyMint[_msgSender()][block.timestamp / DAILY_INTERVAL] += _amount;
  }

  function mint(address _to, uint256 _amount) public onlyMinter {
    increaseMint(_amount);
    _mint(_to, _amount);
  }
  
  
  // Control minting
  function checkChair(uint256 _chairId) internal view returns(uint256 chairId, uint256 round) {
    require(_chairId <= 10, "Invalid chair");
    
    round = getCurrentRound(ROUND_START);
    chairId = round * 1e27 + _chairId;
    require(msg.sender == representators[chairId], "Not representator");
    require(chairClaimLastTimestamp[chairId] > 0 && block.timestamp > chairClaimLastTimestamp[chairId] + CLAIM_PERIOD, "Claiming");
  }
  
  event IncreaseDailyMintLimit(
    address indexed representator, 
    uint256 indexed chairId,
    address indexed target, 
    uint256 amount
  );
  function increaseDailyMintLimit(uint256 _chairId, address target, uint256 amount) public {
    (uint256 chairId, ) = checkChair(_chairId);
    
    require(chairDailyMintLimitUsage[_chairId] + amount <= DAILY_MINT_BUDGET);
    
    chairDailyMintLimitUsage[_chairId] += amount;
    chairDailyMintLimitUsageByAddress[_chairId][target] += amount;
    allowMinting[target].dailyLimit += amount;
    
    if (allowMinting[target].timelock == 0) {
      allowMinting[target].timelock = block.timestamp + NEW_MINT_TIMELOCK;
    }
    
    emit IncreaseDailyMintLimit(msg.sender, chairId, target, amount);
  }
  
  event DecreaseDailyMintLimit(
    address indexed representator, 
    uint256 indexed chairId,
    address indexed target, 
    uint256 amount
  );
  function decreaseDailyMintLimit(uint256 _chairId, address target, uint256 amount) public {
    (uint256 chairId, ) = checkChair(_chairId);
    
    require(chairDailyMintLimitUsage[_chairId] >= amount);
    require(chairDailyMintLimitUsageByAddress[_chairId][target] >= amount);
    require(allowMinting[target].dailyLimit >= amount);
    
    chairDailyMintLimitUsage[_chairId] -= amount;
    chairDailyMintLimitUsageByAddress[_chairId][target] -= amount;
    allowMinting[target].dailyLimit -= amount;
    
    if (allowMinting[target].dailyLimit == 0) {
      allowMinting[target].timelock = 0;
    }
    
    emit DecreaseDailyMintLimit(msg.sender, chairId, target, amount);
  }
  
  event ClaimDailySalary(address indexed claimer, uint256 indexed chairId, uint256 amount);
  function claimDailySalary(uint256 _chairId) public {
    (uint256 chairId, ) = checkChair(_chairId);
    
    require(!dailySalaryClaimed[chairId], "Already claimed");
    
    uint256 dailySalary = getDailySalary();
    _mint(msg.sender, dailySalary);
    dailySalaryClaimed[chairId] = true;
    
    emit ClaimDailySalary(msg.sender, chairId, dailySalary);
  }
  
  
  
  // Voting system
  // votingId = type * 1e45 + round * 1e27 + id
  // type[5..1] = (common+, common-, dismiss, support, election)
  struct VoteData {
    uint256 totalVote;
    uint256 start;
    uint256 end;
    uint256 changeExtend;
    address owner;
    string uri;
  }
  
  mapping(uint256 => VoteData) public voteData; // voteData[votingId]
  mapping(uint256 => mapping(address => uint256)) public votingRefund; // votingRefund[votingId][address]
  mapping(uint256 => mapping(address => uint256)) public yourVote; // yourVote[votingId][address]
  uint256 public nextCommonVoteId = 1;
  
  modifier validVotingId(uint256 votingType, uint256 votingRound, uint256 votingId) {
    require(votingType <= 5 && votingType >= 1, "InvType");
    require(votingRound < 1e17, "InvRound");
    require(votingId < 1e26, "InvId");
    _;
  }
  
  event NewVote(
    address indexed owner,
    uint256 indexed votingType,
    uint256 indexed votingRound,
    uint256 votingId,
    uint256 start,
    uint256 end,
    uint256 changeExtend,
    string uri
  );
  function _newVote(
    uint256 votingType, 
    uint256 votingRound, 
    uint256 votingId, 
    uint256 start, 
    uint256 end,
    uint256 changeExtend,
    address owner, 
    string memory uri
  ) internal validVotingId(votingType, votingRound, votingId) {
    uint256 _votingId = votingType * 1e45 + votingRound * 1e27 + votingId;
    
    if (voteData[_votingId].owner == address(0)) {
      voteData[_votingId] = VoteData({
        totalVote: 0,
        start: start,
        end: end,
        changeExtend: changeExtend,
        owner: owner,
        uri: uri
      });
    }
    
    emit NewVote(
      owner,
      votingType,
      votingRound,
      votingId,
      start,
      end,
      changeExtend,
      uri
    );
  }
  
  event Vote(
    address voter,
    uint256 indexed votingType,
    uint256 indexed votingRound,
    uint256 indexed votingId,
    uint256 amount,
    uint256 boostAmount
  );
  function vote(
    uint256 votingType, 
    uint256 votingRound, 
    uint256 votingId,
    uint256 amount,
    uint256 boostAmount
  ) public validVotingId(votingType, votingRound, votingId) {
    require(boostAmount <= amount, "Boost limit");
  
    uint256 _votingId = votingType * 1e45 + votingRound * 1e27 + votingId;
    
    if (votingType == 1) {
      address representator = representatorProfile[votingRound * 1e27 + votingId].representator;
      require(representator != address(0), "Invalid representator");
    
      _newVote(
        votingType,
        votingRound,
        votingId,
        getRoundStart(ELECTION_START, votingRound),
        getRoundStart(ELECTION_END, votingRound),
        0,
        representator,
        ""
      );
    } else if (votingType == 2 || votingType == 3) {
      address representator = representators[votingRound * 1e27 + votingId];
    
      require(representator != address(0), "Invalid representator");
    
      _newVote(
        votingType,
        votingRound,
        votingId,
        block.timestamp,
        block.timestamp + DISMISS_PERIOD,
        DISMISS_PERIOD,
        representator,
        ""
      );
      
      _burn(msg.sender, boostAmount);
    }
    
    VoteData storage data = voteData[_votingId];
    require(data.owner != address(0), "Invalid vote");
    require(block.timestamp >= data.start && block.timestamp <= data.end, "Invalid time");
    
    if (votingType != 2 && votingType != 3) {
      uint256 burnAmount = boostAmount * 6 / 10;
      uint256 donateAmount = boostAmount - burnAmount;
      _burn(msg.sender, burnAmount);
      _transfer(msg.sender, address(this), donateAmount);
      votingRefund[_votingId][data.owner] += donateAmount;
    }
    
    uint256 normalAmount = amount - boostAmount;
    _transfer(msg.sender, address(this), normalAmount);
    
    if (votingType == 1) {
      // Distribute 3% reward to let people participate in the main election events
      uint256 rewardAmount = normalAmount * 3 / 100;
      votingRefund[_votingId][msg.sender] += normalAmount + rewardAmount;
      _mint(address(this), rewardAmount);
    } else {
      votingRefund[_votingId][msg.sender] += normalAmount;
    }
    
    uint256 _competeVotingId = _votingId;
    
    if (votingType == 2) {
      _competeVotingId = 3 * 1e45 + votingRound * 1e27 + votingId;
    } else if (votingType == 3) {
      _competeVotingId = 2 * 1e45 + votingRound * 1e27 + votingId;
    } else if (votingType == 4) {
      _competeVotingId = 5 * 1e45 + votingRound * 1e27 + votingId;
    } else if (votingType == 5) {
      _competeVotingId = 4 * 1e45 + votingRound * 1e27 + votingId;
    }
    
    uint256 verdict = (data.totalVote == voteData[_competeVotingId].totalVote ? 0 : (data.totalVote < voteData[_competeVotingId].totalVote ? 1 : 2));
    
    data.totalVote += amount + boostAmount * 2;
    
    uint256 newVerdict = (data.totalVote == voteData[_competeVotingId].totalVote ? 0 : (data.totalVote < voteData[_competeVotingId].totalVote ? 1 : 2));
    
    if (verdict != newVerdict && block.timestamp + data.changeExtend > data.end) {
      data.end = block.timestamp + data.changeExtend;
    }
    
    emit Vote(
      msg.sender,
      votingType,
      votingRound,
      votingId,
      amount,
      boostAmount
    );
  }
  
  // Claim and dismiss chair
  event ClaimChair(address indexed claimer, uint256 indexed chairId);
  function claimChair(uint256 chairId) public {
    require(representators[chairId] == address(0) || block.timestamp <= chairClaimLastTimestamp[chairId] + CLAIM_PERIOD, "ended");
    
    uint256 round = getCurrentRound(ELECTION_END);
    uint256 number = representatorNumber[msg.sender][round];
    uint256 score = voteData[number].totalVote;
    
    require(score > chairClaimMaxScore[chairId], "notmax");
    
    representators[chairId] = msg.sender;
    chairClaimMaxScore[chairId] = score;
    chairClaimLastTimestamp[chairId] = block.timestamp;
    
    emit ClaimChair(msg.sender, chairId);
  }
  
  event ClaimPresident(address indexed claimer, uint256 indexed chairId);
  function claimPresident() public {
    uint256 round = getCurrentRound(ELECTION_END);
    uint256 number = representatorNumber[msg.sender][round];
    uint256 score = voteData[1e45 + number].totalVote;
    uint256 maxScore = 0;
    
    for (uint256 i = 0; i < 10; i++) {
      uint256 chairScore = chairClaimMaxScore[round * 1e27 + i];
      if (chairScore > maxScore) {
        maxScore = chairScore;
      }
    }
    
    require(maxScore > 0 && score == maxScore, "Not max");
    
    uint256 chairId = round * 1e27 + 10;
    representators[chairId] = msg.sender;
    chairClaimMaxScore[chairId] = score;
    chairClaimLastTimestamp[chairId] = block.timestamp;
    
    emit ClaimChair(msg.sender, chairId);
  }
}