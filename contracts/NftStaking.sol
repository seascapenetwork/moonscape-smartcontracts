pragma solidity 0.6.7;

import "./openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./openzeppelin/contracts/access/Ownable.sol";
import "./openzeppelin/contracts/math/SafeMath.sol";
import "./openzeppelin/contracts/utils/Counters.sol";
import "./NFTFactory.sol";
import "./openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./SeascapeNFT.sol";

/// @title A Liquidity pool mining
/// @author Medet Ahmetson <admin@blocklords.io>
/// @notice Contract is attached to Seascape Nft Factory
contract NftStaking is Ownable, IERC721Receiver {
    using SafeMath for uint256;
    using Counters for Counters.Counter;

    uint256 scaler = 10**18;
	
    NFTFactory nftFactory;
    
    IERC20 public CWS;
    SeascapeNFT private nft;

    Counters.Counter private sessionId;

    /// @dev Total amount of Crowns stored for all sessions
    uint256 rewardSupply = 0;

    /// @notice game event struct. as event is a solidity keyword, we call them session instead.
    struct Session {
        uint256 totalReward;   // amount of CWS to airdrop
	uint256 period;        // session duration in seconds
	uint256 startTime;     // session start in unixtimestamp
	uint256 claimed;       // amount of distributed reward
	uint256 totalSp;       // amount of lp token deposited to the session by users
	uint256 rewardUnit;    // reward per second = totalReward/period
    }

    /// @notice balance of lp token that each player deposited to game session
    struct Balance {
	uint256 claimedTime;       // amount of claimed CWS reward
	uint256 nftId;
	uint256 sp;                // seascape points
    }

    uint256 public lastSessionId;
    mapping(uint256 => Session) public sessions;
    mapping(uint256 => mapping(address => uint256)) public slots;
    mapping(uint256 => mapping(address => Balance[3])) public balances;
    mapping(uint256 => mapping(address => uint)) public depositTimes;

    event SessionStarted(uint256 sessionIdd, uint256 reward, uint256 startTime, uint256 endTime);
    event Deposited(address indexed owner, uint256 sessionId, uint256 nftId);
    event Claimed(address indexed owner, uint256 sessionId, uint256 amount, uint256 nftId);

    constructor(IERC20 _cws, address _nftFactory, address _nft) public {
	CWS = _cws;

	sessionId.increment(); 	// starts at value 1

	nftFactory = NFTFactory(_nftFactory);

	nft = SeascapeNFT(_nft);
    }
    
    //--------------------------------------------------
    // Only owner
    //--------------------------------------------------

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) override external returns (bytes4) {	    
	return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }    

    /// @notice Starts a staking session for a finit _period of
    /// time, starting from _startTime. The _totalReward of
    /// CWS tokens will be distributed in every second. It allows to claim a
    /// a _generation Seascape NFT.
    function startSession(uint256 _totalReward, uint256 _period,  uint256 _startTime, uint256 _generation) external onlyOwner {
	require(_startTime > block.timestamp,         "Seascape Staking: Seassion should start in the future");
	require(_period > 0,                          "Seascape Staking: Session duration should be greater than 0");
	require(_totalReward > 0,                     "Seascape Staking: Total reward of tokens to share should be greater than 0");

	// game session for the lp token was already created, then:
	if (lastSessionId > 0) {
	    require(isStartedFor(lastSessionId)==false,     "Seascape Staking: Can't start when session is active");
	}

	// required CWS balance of this contract
	uint256 newSupply = rewardSupply.add(_totalReward);
	require(CWS.balanceOf(address(this)) >= newSupply, "Seascape Staking: Not enough balance of Crowns for reward");

	//--------------------------------------------------------------------
	// creating the session
	//--------------------------------------------------------------------
	uint256 _sessionId = sessionId.current();
	uint256 _rewardUnit = _totalReward.div(_period);	
	sessions[_sessionId] = Session(_totalReward, _period, _startTime, 0, 0, _rewardUnit);
	
	//--------------------------------------------------------------------
        // updating rest of session related data
	//--------------------------------------------------------------------
	sessionId.increment();
	rewardSupply = newSupply;
	lastSessionId = _sessionId;

	emit SessionStarted(_sessionId, _totalReward, _startTime, _startTime + _period);
    }
     
    /// @dev sets an nft factory, a smartcontract that mints tokens.
    /// the nft factory should give a permission on it's own side to this contract too.
    function setNFTFactory(address _address) external onlyOwner {
	nftFactory = NFTFactory(_address);
    }


    //--------------------------------------------------
    // Only game users
    //--------------------------------------------------

    /// @notice deposits _amount of LP token
    function deposit(uint256 _sessionId, uint256 _nftId, uint256 _sp, uint8 _v, bytes32 _r, bytes32 _s) external {
	require(_nftId > 0,              "Nft Staking: Nft id must be greater than 0");
	require(_sp > 0,                  "Nft Staking: Seascape Points must be greater than 0");
	require(_sessionId > 0,           "Nft Staking: Session id should be greater than 0!");
	require(isStartedFor(_sessionId), "Nft Staking: Session is not active");
	require(nft.ownerOf(_nftId) == msg.sender, "Nft Staking: Nft is not owned by method caller");
	require(slots[_sessionId][msg.sender] < 3, "Nft Staking: all slots are used");

	
	/// Validation of quality
	// message is generated as owner + amount + last time stamp + quality
	bytes32 _messageNoPrefix = keccak256(abi.encodePacked(_nftId, _sp));
	bytes32 _message = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _messageNoPrefix));
	address _recover = ecrecover(_message, _v, _r, _s);
	require(_recover == owner(),     "Nft Staking: Seascape points verification failed");
	
	nft.safeTransferFrom(msg.sender, address(this), _nftId);

	Session storage _session  = sessions[_sessionId];
	Balance[3] storage _balances  = balances[_sessionId][msg.sender];
	uint index = 0;
	// use next empty slot
	if (slots[_sessionId][msg.sender] > 0) {
	    index = slots[_sessionId][msg.sender];
	}

	// If user withdrew all LP tokens, but deposited before for the session
	// Means, that player still can't mint more token anymore.
        balances[_sessionId][msg.sender][index] = Balance(block.timestamp, _nftId, _sp);
	
	_session.totalSp                        = _session.totalSp.add(_sp);
	depositTimes[_sessionId][msg.sender]    = block.timestamp;
	slots[_sessionId][msg.sender]           = slots[_sessionId][msg.sender].add(1);
       
        emit Deposited(msg.sender, _sessionId, _nftId);
    }

    function transfer(uint256 _sessionId, uint256 _index) internal returns(uint256) {
	Session storage _session = sessions[_sessionId];
	Balance storage _balance = balances[_sessionId][msg.sender][_index];

	uint256 _interest = calculateInterest(_sessionId, msg.sender, _index);

	require(CWS.transfer(msg.sender, _interest) == true, "Seascape Staking: Failed to transfer reward CWS token");
		
	_session.claimed     = _session.claimed.add(_interest);
	rewardSupply         = rewardSupply.sub(_interest);

	return _interest;
    }


    /// @notice Withdraws _amount of LP token
    /// of type _token out of Staking contract.
    function claim(uint256 _sessionId, uint256 _index) external {
	require(_index < slots[_sessionId][msg.sender],             "Nft Staking: slot is not deposited");
	require(balances[_sessionId][msg.sender][_index].nftId > 0, "Nft Staking: nft at the given slot was not set");

	uint256 _claimed = transfer(_sessionId, _index);	

	Balance storage _balance = balances[_sessionId][msg.sender][_index];
	uint256 _nftId = _balance.nftId;
        nft.burn(_nftId);	
	sessions[_sessionId].totalSp = sessions[_sessionId].totalSp.sub(_balance.sp);
	slots[_sessionId][msg.sender] = slots[_sessionId][msg.sender].sub(1);

	delete balances[_sessionId][msg.sender][_index];	
	
	emit Claimed(msg.sender, _sessionId, _claimed, _nftId);
    }	    
	    
    function claimAll(uint256 _sessionId) external {
	require(slots[_sessionId][msg.sender] > 0, "Nft Staking: all slots are empty");
	
	for (uint _index=0; _index<slots[_sessionId][msg.sender]; _index++) {
   	    uint256 _claimed = transfer(_sessionId, _index);

	    Balance storage _balance = balances[_sessionId][msg.sender][_index];

	    uint256 _nftId = _balance.nftId;
	    nft.burn(_nftId);
	    sessions[_sessionId].totalSp = sessions[_sessionId].totalSp.sub(_balance.sp);

	    delete balances[_sessionId][msg.sender][_index];

	    emit Claimed(msg.sender, _sessionId, _claimed, _nftId);	
	}

	slots[_sessionId][msg.sender] = 0;		
    }	    

    //--------------------------------------------------
    // Public methods
    //--------------------------------------------------

    /// @notice Returns amount of CWS Tokens that _address could claim.
    function claimable(uint256 _sessionId, address _owner, uint256 _index) external view returns(uint256) {
	return calculateInterest(_sessionId, _owner, _index);
    }

    /// @notice Returns total amount of Staked LP Tokens
    function stakedBalance(uint256 _sessionId) external view returns(uint256) {
	return sessions[_sessionId].totalSp;
    }

    //---------------------------------------------------
    // Internal methods
    //---------------------------------------------------
    
    function isStartedFor(uint256 _sessionId) internal view returns(bool) {	
	if (sessions[_sessionId].totalReward == 0) {
	    return false;
	}

	if (now > sessions[_sessionId].startTime + sessions[_sessionId].period) {
	    return false;
	}

	return true;
    }

    function calculateInterest(uint256 _sessionId, address _owner, uint256 _index) internal view returns(uint256) {	    
	Session storage _session = sessions[_sessionId];
	Balance storage _balance = balances[_sessionId][_owner][_index];

	// How much of total deposit is belong to player as a floating number
	uint256 _sessionCap = block.timestamp;
	if (isStartedFor(_sessionId) == false) {
	    _sessionCap = _session.startTime.add(_session.period);
	}

	uint256 _portion = _balance.sp.mul(scaler).div(_session.totalSp);
	
       	uint256 _interest = _session.rewardUnit.mul(_portion).div(scaler);

	// _balance.startTime is misleading.
	// Because, it's updated in every deposit time or claim time.
	uint256 _earnPeriod = _sessionCap.sub(_balance.claimedTime);
	
	return _interest.mul(_earnPeriod);
    }
}

