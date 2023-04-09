// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../types/HiLoTypes.sol";
import "./IHiLo.sol";
import "../evaluator/IHiLoEvaluator.sol";
import "../../shuffle/IShuffle.sol";
import "../../account/IAccountManagement.sol";

// The main game logic contract
contract HiLo is Ownable, IHiLo {
    // Maps board id to a single board data
    mapping(uint256 => Board) public boards;

    // Maps board id to the map from player's permanent address to player's game status
    mapping(uint256 => mapping(address => PlayerStatus)) public playerStatuses;

    // ZK shuffle contract
    IShuffle public shuffle;

    // Poker evaluatoras contract
    IHiLoEvaluator public hiLoEvaluator;

    // Account manager
    IAccountManagement public accountManagement;

    uint256 public immutable MIN_PLAYERS = 2;

    bool public needPresendGas;

    event EvaluatorSet(address indexed evaluator);
    event ShuffleSet(address indexed shuffle);

    // ========================= Modiftiers =============================

    // Checks if `msg.sender` is in game `boardId` no matter `msg.sender` is permanent account
    // or ephemeral account.
    modifier checkPlayerExist(uint256 boardId) {
        require(
            accountManagement.getCurGameId(
                accountManagement.getPermanentAccount(msg.sender)
            ) == boardId,
            "Player is not in a game"
        );
        _;
    }

    // ====================================================================
    // ========================= Public functions =========================
    // these public functions are intended to be interacted with end users
    // ====================================================================
    constructor(
        address shuffle_,
        address hiLoEvaluator_,
        address accountManagement_,
        bool needPresendGas_
    ) {
        setShuffle(shuffle_);
        setEvaluator(hiLoEvaluator_);
        setAccountManagement(accountManagement_);
        setNeedPresendGas(needPresendGas_);
    }

    // Checks if it is `msg.sender`'s turn to play which supports `msg.sender` as either ephemeral account
    // or permanent account.
    function ensureYourTurn(uint256 boardId) internal view {
        require(
            boards[boardId].nextPlayer ==
                playerStatuses[boardId][
                    accountManagement.getPermanentAccount(msg.sender)
                ].index,
            "Not your turn"
        );
    }

    // Checks if `boardId` is in the specified game `stage`. (Not using modifiers to reduce contract size)
    function ensureValidStage(GameStage stage, uint256 boardId) internal view {
        require(stage == boards[boardId].stage, "Invalid game stage");
    }

    // Sets shuffle contract.
    function setShuffle(address shuffle_) public onlyOwner {
        require(shuffle_ != address(0), "empty address");
        shuffle = IShuffle(shuffle_);
    }

    // Sets account management contract.
    function setAccountManagement(address accountManagement_) public onlyOwner {
        require(accountManagement_ != address(0), "empty address");
        accountManagement = IAccountManagement(accountManagement_);
    }

    // Sets evaluator contract.
    function setEvaluator(address hiLoEvaluator_) public onlyOwner {
        require(hiLoEvaluator_ != address(0), "empty address");
        hiLoEvaluator = IHiLoEvaluator(hiLoEvaluator_);
    }

    // Set the gas required to play a round of game,
    function setNeedPresendGas(bool needPresendGas_) public onlyOwner {
        needPresendGas = needPresendGas_;
    }

    // Creates a board when starting a new game. Returns the newly created board id.
    function createBoard(uint256 numPlayers) external {
        uint256 boardId = accountManagement.generateGameId();
        require(GameStage.NotStarted == boards[boardId].stage, "game created");
        require(numPlayers == MIN_PLAYERS, "required players == 2");
        Board memory board;
        board.stage = GameStage.Started;
        // Number of stages = 7
        board.betsEachRound = new uint256[][](7);
        board.betTypeEachRound = new uint256[][](7);
        board.numPlayers = numPlayers;
        boards[boardId] = board;
        emit BoardCreated(
            accountManagement.getPermanentAccount(msg.sender),
            boardId
        );
        shuffle.setGameSettings(numPlayers, boardId);
    }

    // Joins the `boardId` board with the public key `pk`, the `ephemeralAccount` that `msg.sender`
    // wants to authorize, and `buyIn` amount of chips.
    // Reverts when a) user has joined; b) board players reach the limit.
    function join(
        uint256[2] calldata pk,
        address ephemeralAccount,
        uint256 buyIn,
        uint256 boardId
    ) public payable {
        ensureValidStage(GameStage.Started, boardId);
        accountManagement.join(msg.sender, boardId, buyIn);
        boards[boardId].permanentAccounts.push(msg.sender);
        accountManagement.authorize(msg.sender, ephemeralAccount);
        // fund the ephemeral account, so players don't have to fund the game account manually
        if (needPresendGas) {
            bool success = payable(ephemeralAccount).send(msg.value);
            require(success, "send ether to ephemeral account failed");
        }
        boards[boardId].handCards.push(new uint256[](0));
        boards[boardId].bets.push(0);
        boards[boardId].playerInPots.push(true);
        boards[boardId].chips.push(buyIn);
        boards[boardId].pks.push(pk);
        Board memory board = boards[boardId];
        uint256 playerCount = board.permanentAccounts.length;
        shuffle.register(msg.sender, pk, boardId);
        if (playerCount == board.numPlayers) {
            board.stage = GameStage.Shuffle;
            board.dealer = playerCount - 1;
            board.potSize = buyIn * playerCount;
        }
        boards[boardId] = board;
        emit JoinedBoard(msg.sender, boardId);
    }

    // Shuffles the deck without submitting the proof.
    function shuffleDeck(
        uint256[52] calldata shuffledX0,
        uint256[52] calldata shuffledX1,
        uint256[2] calldata selector,
        uint256 boardId
    ) external checkPlayerExist(boardId) {
        ensureValidStage(GameStage.Shuffle, boardId);
        ensureYourTurn(boardId);
        address permanentAccount = accountManagement.getPermanentAccount(
            msg.sender
        );
        shuffle.shuffleDeck(
            permanentAccount,
            shuffledX0,
            shuffledX1,
            selector,
            boardId
        );
        emit DeckShuffled(permanentAccount, boardId);
        _moveToTheNextStage(boardId);
    }

    // Submits the proof for shuffling the deck.
    function shuffleProof(uint256[8] calldata proof, uint256 boardId) external {
        address permanentAccount = accountManagement.getPermanentAccount(
            msg.sender
        );
        uint256 playerIdx = shuffle.UNREACHABLE_PLAYER_INDEX();
        for (uint256 i = 0; i < boards[boardId].permanentAccounts.length; i++) {
            if (permanentAccount == boards[boardId].permanentAccounts[i]) {
                playerIdx = i;
            }
        }
        require(
            playerIdx != shuffle.UNREACHABLE_PLAYER_INDEX(),
            "Not in the game"
        );
        shuffle.shuffleProof(proof, boardId, playerIdx);
    }

    function dealComputation(
        uint256[] calldata cardIdx,
        uint256[8][] calldata proof,
        uint256[2][] memory decryptedCard,
        uint256[2][] memory initDelta,
        uint256 boardId,
        bool shouldVerifyDeal
    ) internal {
        require(
            cardIdx.length > 0 &&
                proof.length == cardIdx.length &&
                decryptedCard.length == cardIdx.length &&
                initDelta.length == cardIdx.length
        );
        address permanentAccount = accountManagement.getPermanentAccount(
            msg.sender
        );
        for (uint256 i = 0; i < cardIdx.length; ++i) {
            shuffle.deal(
                permanentAccount,
                cardIdx[i],
                playerStatuses[boardId][permanentAccount].index,
                proof[i],
                decryptedCard[i],
                initDelta[i],
                boardId,
                shouldVerifyDeal
            );
        }
        emit BatchDecryptProofProvided(
            permanentAccount,
            cardIdx.length,
            boardId
        );
    }

    function deal(
        uint256[] calldata cardIdx,
        uint256[8][] calldata proof,
        uint256[2][] memory decryptedCard,
        uint256[2][] memory initDelta,
        uint256 boardId
    ) external checkPlayerExist(boardId) {
        // TODO: connect card index with game stage. See `library BoardManagerView`
        // cardIdxMatchesGameStage(cardIdx, boardId);
        ensureYourTurn(boardId);
        dealComputation(cardIdx, proof, decryptedCard, initDelta, boardId, false);
        _moveToTheNextStage(boardId);
    }

    //get card value for one card in hand, customized for HiLo game specifically
    function getCardValue(
        uint256 boardId,
        uint256 playerIdx
    ) internal view returns (uint256) {
        uint256 actualCardValue = shuffle.search(
            boards[boardId].handCards[playerIdx][0],
            boardId
        );
        require(
            actualCardValue != shuffle.INVALID_CARD_INDEX(),
            "invalid card, something is wrong"
        );
        return actualCardValue;
    }

    // ====================================================================
    // ========================== View functions ==========================
    // ====================================================================

    // Gets board with `boardId`. This is a workaround to provide a getter since
    // we cannot export dynamic mappings.
    function getBoard(uint256 boardId) external view returns (Board memory) {
        return boards[boardId];
    }

    // Gets the player index of `msg.sender`
    function getPlayerIndex(uint256 boardId) public view returns (uint256) {
        address permanentAccount = accountManagement.getPermanentAccount(
            msg.sender
        );
        return playerStatuses[boardId][permanentAccount].index;
    }

    // ====================================================================
    // ========================= Internals functions ======================
    // ====================================================================

    function _moveToTheNextStage(uint256 boardId) internal {
        // when the status reach the end, there is no way for this game to be replayed
        uint256 nextStage = uint256(boards[boardId].stage) + 1;
        require(nextStage <= uint256(GameStage.Ended), "game already ended");
        // now it's another round
        boards[boardId].stage = GameStage(nextStage);
        boards[boardId].betsEachRound[nextStage] = new uint256[](
            boards[boardId].permanentAccounts.length
        );
        boards[boardId].betTypeEachRound[nextStage] = new uint256[](
            boards[boardId].permanentAccounts.length
        );
        emit GameStageChanged(GameStage(nextStage), boardId);
        _postRound(boards[boardId].stage, boardId);
    }

    // Do something right after the game stage updated
    function _postRound(
        GameStage newStage,
        uint256 boardId
    ) internal {
        if (newStage == GameStage.Ended) {
            // Determine the winner
            uint winner = 0; // winner 0 is the server by default
            if (
                hiLoEvaluator.evaluate(
                    getCardValue(boardId, 0), // first card server has
                    boards[boardId].guess,
                    getCardValue(boardId, 1) // second card player has
                )
            ) {
                winner = 1; // winner 1 is the player, if it evaluates to true, the player wins
            }
            // Settle the winner
            address winnerAddress = boards[boardId].permanentAccounts[winner];
            // Update game state
            boards[boardId].winner = winnerAddress;
            return;
        }
    }
}