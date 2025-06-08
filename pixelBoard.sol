// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC721 {
    function balanceOf(address owner) external view returns (uint256);
}
contract PixelBoard {

    address private _owner;

    modifier onlyOwner() {
        require(msg.sender == _owner, "Caller is not the owner");
        _;
    }

    modifier onlyEOA() {
        require(tx.origin == msg.sender, "Contracts not allowed");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner is zero address");
        _owner = newOwner;
    }

    // --- PixelBoard logic ---

    struct Cell {
        address owner;
        string color;
        uint256 edition;
    }

    struct PixelActivity {
        uint256 totalPixelPlaced;
        uint256 totalPixelAlive;
        uint256 totalEthPaid;
    }

    // Helper for checking if address is in allPixelUsers
    mapping(address => bool) private _hasPlacedPixel;
    // Helper for checking if community is in allCommunities
    mapping(string => bool) private _isCommunityRegistered;

    mapping(uint8 => mapping(uint256 => mapping(uint256 => Cell))) public boards;
    mapping(address => PixelActivity) public userActivity;
    mapping(string => PixelActivity) public communityActivity;
    mapping(address => string) public userCommunity;
    mapping(string => bool) public validColors;

    string[] public allCommunities;
    address[] public allPixelUsers;
    bool public paused;
    uint256 public constant BASE_COST = 0.000022 ether;
    uint256 public constant COST_MULTIPLIER = 115; // 115% = 1.15x
    uint256 public constant COST_DIVISOR = 100;

    IERC721 private constant OKP = IERC721(0xfc31b8313263500B6DF814113bB3ea15252c2D7f);
    IERC721 private constant OKC = IERC721(0xCE2830932889C7fB5e5206287C43554E673dCc88);

    event PixelSet(
        uint8 boardId,
        uint256 x,
        uint256 y,
        string color,
        address owner,
        uint256 edition,
        uint256 totalPixelPlaced,
        uint256 totalPixelAlive,
        uint256 totalEthPaid
    );

    constructor() {
        _owner = msg.sender;

        string[16] memory colors = [
            "white", "black", "gray", "silver", "maroon", "red", "purple", "fuscia",
            "green", "lime", "olive", "yellow", "navy", "blue", "teal", "aqua"
        ];
        for (uint256 i = 0; i < colors.length; i++) {
            validColors[colors[i]] = true;
        }
    }

    function setPixel(string[] memory cellData) external payable whenNotPaused onlyEOA {
        require(cellData.length == 4, "Array must have 4 elements");
        require(bytes(userCommunity[msg.sender]).length > 0, "Set a community first");
        uint8 boardId = uint8(parseUint(cellData[0]));
        uint256 x = parseUint(cellData[1]);
        uint256 y = parseUint(cellData[2]);
        string memory color = cellData[3];

        require(boardId < 4, "Invalid boardId");
        require(validColors[color], "Invalid color");

        uint256 cost = getPixelCost(boardId, x, y);
        Cell storage cell = boards[boardId][x][y];
        require(msg.value >= cost, "Insufficient payment");

        address prevOwner = cell.owner;
        string memory prevCommunity = userCommunity[prevOwner];

        if (prevOwner != address(0)) {
            require(userActivity[prevOwner].totalPixelAlive > 0, "Owner has no alive pixels");
            userActivity[prevOwner].totalPixelAlive -= 1;
            if (bytes(prevCommunity).length > 0) {
                communityActivity[prevCommunity].totalPixelAlive -= 1;
            }
        }

        cell.owner = msg.sender;
        cell.color = color;
        cell.edition += 1;

        userActivity[msg.sender].totalPixelPlaced += 1;
        userActivity[msg.sender].totalPixelAlive += 1;
        userActivity[msg.sender].totalEthPaid += cost;

        string memory community = userCommunity[msg.sender];
        communityActivity[community].totalPixelPlaced += 1;
        communityActivity[community].totalPixelAlive += 1;
        communityActivity[community].totalEthPaid += cost;

        if (!_hasPlacedPixel[msg.sender]) {
            allPixelUsers.push(msg.sender);
            _hasPlacedPixel[msg.sender] = true;
        }

        emit PixelSet(
            boardId,
            x,
            y,
            color,
            msg.sender,
            cell.edition,
            userActivity[msg.sender].totalPixelPlaced,
            userActivity[msg.sender].totalPixelAlive,
            userActivity[msg.sender].totalEthPaid
        );

        uint256 refund = 0;
        if (OKP.balanceOf(msg.sender) > 0) {
            refund = (cost * 30) / 100;
        } else if (OKC.balanceOf(msg.sender) > 0) {
            refund = (cost * 15) / 100;
        }

        // Refund overpayment and NFT discount
        uint256 totalRefund = refund + (msg.value > cost ? (msg.value - cost) : 0);
        if (totalRefund > 0) {
            payable(msg.sender).transfer(totalRefund);
        }
    }

    function setPixels(
        uint8 boardId,
        uint256[] memory xList,
        uint256[] memory yList,
        string[] memory colorList
    ) external payable whenNotPaused onlyEOA {
        require(boardId < 4, "Invalid boardId");
        require(
            xList.length > 0 && yList.length > 0,
            "xList and yList must not be empty"
        );
        require(
            colorList.length == xList.length * yList.length,
            "colorList length must be xList.length * yList.length"
        );
        require(bytes(userCommunity[msg.sender]).length > 0, "Set community first");

        uint256 totalCost = 0;
        string memory community = userCommunity[msg.sender];

        // Validate all colors and sum costs
        for (uint256 i = 0; i < xList.length; i++) {
            for (uint256 j = 0; j < yList.length; j++) {
                uint256 colorIdx = i * yList.length + j;
                require(validColors[colorList[colorIdx]], "Invalid color");
                totalCost += getPixelCost(boardId, xList[i], yList[j]);
            }
        }
        require(msg.value >= totalCost, "Insufficient payment");

        for (uint256 i = 0; i < xList.length; i++) {
            for (uint256 j = 0; j < yList.length; j++) {
                uint256 colorIdx = i * yList.length + j;
                Cell storage cell = boards[boardId][xList[i]][yList[j]];
                address prevOwner = cell.owner;
                string memory prevCommunity = userCommunity[prevOwner];
                uint256 pixelCost = getPixelCost(boardId, xList[i], yList[j]);

                if (prevOwner != address(0)) {
                    require(userActivity[prevOwner].totalPixelAlive > 0, "Owner has no alive pixels");
                    userActivity[prevOwner].totalPixelAlive -= 1;
                    if (bytes(prevCommunity).length > 0) {
                        communityActivity[prevCommunity].totalPixelAlive -= 1;
                    }
                }

                cell.owner = msg.sender;
                cell.color = colorList[colorIdx];
                cell.edition += 1;

                userActivity[msg.sender].totalPixelPlaced += 1;
                userActivity[msg.sender].totalPixelAlive += 1;
                userActivity[msg.sender].totalEthPaid += pixelCost;

                communityActivity[community].totalPixelPlaced += 1;
                communityActivity[community].totalPixelAlive += 1;
                communityActivity[community].totalEthPaid += pixelCost;

                emit PixelSet(
                    boardId,
                    xList[i],
                    yList[j],
                    colorList[colorIdx],
                    msg.sender,
                    cell.edition,
                    userActivity[msg.sender].totalPixelPlaced,
                    userActivity[msg.sender].totalPixelAlive,
                    userActivity[msg.sender].totalEthPaid
                );
            }
        }

        if (!_hasPlacedPixel[msg.sender]) {
            allPixelUsers.push(msg.sender);
            _hasPlacedPixel[msg.sender] = true;
        }

        // Calculate refund for NFT holders
        uint256 refund = 0;
        if (OKP.balanceOf(msg.sender) > 0) {
            refund = (totalCost * 30) / 100;
        } else if (OKC.balanceOf(msg.sender) > 0) {
            refund = (totalCost * 15) / 100;
        }

        // Refund overpayment and NFT discount
        uint256 totalRefund = refund + (msg.value > totalCost ? (msg.value - totalCost) : 0);
        if (totalRefund > 0) {
            payable(msg.sender).transfer(totalRefund);
        }
    }

    function setCommunity(string memory community) external onlyEOA {
        require(bytes(community).length > 0, "Community required");
        require(bytes(community).length <= 16, "Max 16 chars");
        require(bytes(userCommunity[msg.sender]).length == 0, "Cannot change community");
        userCommunity[msg.sender] = community;
        if (!_isCommunityRegistered[community]) {
            allCommunities.push(community);
            _isCommunityRegistered[community] = true;
        }
    }

    function getPixelCost(
        uint8 boardId,
        uint256 x,
        uint256 y
    ) public view returns (uint256) {
        require(boardId < 4, "Invalid boardId");
        require(x < 170 && x >= 0, "Invalid x coordinate");
        require(y < 100 && y >= 0, "Invalid y coordinate");
        uint256 edition = boards[boardId][x][y].edition;
        return
            (BASE_COST * (COST_MULTIPLIER**edition)) / (COST_DIVISOR**edition);
    }

    function getPixelsCost(
        uint8 boardId,
        uint256[] memory xList,
        uint256[] memory yList
    ) external view returns (uint256 totalCost) {
        require(boardId < 4, "Invalid boardId");
        require(
            xList.length > 0 && yList.length > 0,
            "xList and yList must not be empty"
        );

        for (uint256 i = 0; i < xList.length; i++) {
            require(xList[i] < 170 && xList[i] >= 0, "Invalid x coordinate");
        }
        for (uint256 j = 0; j < yList.length; j++) {
            require(yList[j] < 100 && yList[j] >= 0, "Invalid y coordinate");
        }
        for (uint256 i = 0; i < xList.length; i++) {
            for (uint256 j = 0; j < yList.length; j++) {
                totalCost += getPixelCost(boardId, xList[i], yList[j]);
            }
        }
    }

    function retrieveEth(address payable recipient) external onlyOwner {
        require(recipient != address(0), "Zero address");
        recipient.transfer(address(this).balance);
    }

    function pause(bool _paused) external onlyOwner {
        paused = _paused;
    }
    function getAllCommunities() external view returns (string[] memory) {
        return allCommunities;
    }
    function getAllPixelUsers() external view returns (address[] memory) {
        return allPixelUsers;
    }
    // Helper: convert string to uint256
    function parseUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            require(b[i] >= 0x30 && b[i] <= 0x39, "Invalid uint string");
            result = result * 10 + (uint8(b[i]) - 48);
        }
        return result;
    }
}
