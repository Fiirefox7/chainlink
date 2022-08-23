pragma solidity 0.8.6;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../vendor/@arbitrum/nitro-contracts/src/precompiles/ArbGasInfo.sol";
import "../vendor/@eth-optimism/contracts/0.8.6/contracts/L2/predeploys/OVM_GasPriceOracle.sol";
import "../ExecutionPrevention.sol";
import {OnChainConfig, State, Upkeep} from "./interfaces/KeeperRegistryInterface2_0.sol";
import "../interfaces/UpkeepTranscoderInterfaceDev.sol";
import "../../ConfirmedOwner.sol";
import "../../interfaces/AggregatorV3Interface.sol";
import "../../interfaces/LinkTokenInterface.sol";
import "../../interfaces/KeeperCompatibleInterface.sol";
import "./interfaces/OCR2Keeper.sol";

/**
 * @notice Base Keeper Registry contract, contains shared logic between
 * KeeperRegistry and KeeperRegistryLogic
 */
abstract contract KeeperRegistryBase2_0 is ConfirmedOwner, ExecutionPrevention, ReentrancyGuard, Pausable, OCR2Keeper {
  address internal constant ZERO_ADDRESS = address(0);
  address internal constant IGNORE_ADDRESS = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
  bytes4 internal constant CHECK_SELECTOR = KeeperCompatibleInterface.checkUpkeep.selector;
  bytes4 internal constant PERFORM_SELECTOR = KeeperCompatibleInterface.performUpkeep.selector;
  uint256 internal constant PERFORM_GAS_MIN = 2_300;
  uint256 internal constant CANCELLATION_DELAY = 50;
  uint256 internal constant PERFORM_GAS_CUSHION = 5_000;
  uint256 internal constant PPB_BASE = 1_000_000_000;
  uint32 internal constant UINT32_MAX = type(uint32).max;
  uint96 internal constant LINK_TOTAL_SUPPLY = 1e27;
  UpkeepFormatDev internal constant UPKEEP_TRANSCODER_VERSION_BASE = UpkeepFormatDev.V2;

  // L1_FEE_DATA_PADDING includes 35 bytes for L1 data padding for Optimism
  bytes public L1_FEE_DATA_PADDING = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
  // MAX_INPUT_DATA represents the estimated max size of the sum of L1 data padding and msg.data in performUpkeep
  // function, which includes 4 bytes for function selector, 32 bytes for upkeep id, 35 bytes for data padding, and
  // 64 bytes for estimated perform data
  bytes public MAX_INPUT_DATA =
    "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

  // TODO (sc-49442): Optimise upkeep storage
  // Upkeep storage
  EnumerableSet.UintSet internal s_upkeepIDs;
  mapping(uint256 => Upkeep) internal s_upkeep;
  mapping(uint256 => address) internal s_proposedAdmin;
  mapping(uint256 => bytes) internal s_checkData;

  // TODO (sc-49442): Optimise config + state storage
  // Registry config
  mapping(address => Transmitter) internal s_transmitters;
  mapping(address => Signer) internal s_signers;
  address[] internal s_signersList; // s_signersList contains the signing address of each oracle
  address[] internal s_transmittersList; // s_transmittersList contains the transmission address of each oracle
  uint8 internal s_f; // Number of faulty oracles allowed
  uint16 internal s_numOcrInstances; // Number of OCR instances
  uint64 s_offchainConfigVersion;
  bytes s_offchainConfig;
  mapping(address => address) internal s_proposedPayee;
  OnChainConfig internal s_onChainConfig;
  mapping(address => MigrationPermission) internal s_peerRegistryMigrationPermission;

  // Registry state
  uint32 internal s_configCount; // incremented each time a new config is posted, The count
  // is incorporated into the config digest to prevent replay attacks.
  bytes32 internal s_latestRootConfigDigest;
  // makes it easier for offchain systems to extract config from logs
  uint32 internal s_latestConfigBlockNumber;
  uint32 internal s_nonce; // Nonce for each upkeep created
  uint96 internal s_ownerLinkBalance;
  uint256 internal s_expectedLinkBalance;

  LinkTokenInterface public immutable LINK;
  AggregatorV3Interface public immutable LINK_ETH_FEED;
  AggregatorV3Interface public immutable FAST_GAS_FEED;
  OVM_GasPriceOracle public immutable OPTIMISM_ORACLE = OVM_GasPriceOracle(0x420000000000000000000000000000000000000F);
  ArbGasInfo public immutable ARB_NITRO_ORACLE = ArbGasInfo(0x000000000000000000000000000000000000006C);
  PaymentModel public immutable PAYMENT_MODEL;
  uint256 public immutable REGISTRY_GAS_OVERHEAD;

  error ArrayHasNoEntries();
  error CannotCancel();
  error DuplicateEntry();
  error GasLimitCanOnlyIncrease();
  error GasLimitOutsideRange();
  error IndexOutOfRange();
  error InsufficientFunds();
  error InvalidDataLength();
  error InvalidPayee();
  error InvalidRecipient();
  error KeepersMustTakeTurns();
  error MigrationNotPermitted();
  error NotAContract();
  error OnlyActiveKeepers();
  error OnlyCallableByAdmin();
  error OnlyCallableByLINKToken();
  error OnlyCallableByOwnerOrAdmin();
  error OnlyCallableByOwnerOrRegistrar();
  error OnlyCallableByPayee();
  error OnlyCallableByProposedAdmin();
  error OnlyCallableByProposedPayee();
  error OnlyPausedUpkeep();
  error OnlyUnpausedUpkeep();
  error ParameterLengthError();
  error PaymentGreaterThanAllLINK();
  error TargetCheckReverted(bytes reason);
  error TranscoderNotSet();
  error UpkeepCancelled();
  error UpkeepNotCanceled();
  error UpkeepNotNeeded();
  error ValueNotChanged();
  error ConfigDisgestMismatch();
  error IncorrectNumberOfSignatures();
  error OnlyActiveSigners();
  error DuplicateSigners();
  error StaleReport();
  error TooManyOracles();
  error IncorrectNumberOfSigners();
  error IncorrectNumberOfFaultyOracles();
  error RepeatedSigner();
  error RepeatedTransmitter();

  enum MigrationPermission {
    NONE,
    OUTGOING,
    INCOMING,
    BIDIRECTIONAL
  }

  enum UpkeepFailureReason {
    NONE,
    TARGET_CHECK_REVERTED,
    UPKEEP_NOT_NEEDED,
    UPKEEP_PAUSED,
    INSUFFICIENT_BALANCE
  }

  enum PaymentModel {
    DEFAULT,
    ARBITRUM,
    OPTIMISM
  }

  struct PerformParams {
    uint256 id;
    bytes performData;
    uint256 fastGasWei;
    uint256 linkEth;
    uint256 maxLinkPayment;
  }

  struct Transmitter {
    bool active;
    // Index of oracle in s_signersList/s_transmittersList
    uint8 index;
    uint96 balance;
    address payee;
  }

  struct Signer {
    bool active;
    // Index of oracle in s_signersList/s_transmittersList
    uint8 index;
  }

  event OnChainConfigSet(OnChainConfig config);
  event FundsAdded(uint256 indexed id, address indexed from, uint96 amount);
  event FundsWithdrawn(uint256 indexed id, uint256 amount, address to);
  event KeepersUpdated(address[] keepers, address[] payees);
  event OwnerFundsWithdrawn(uint96 amount);
  event PayeeshipTransferRequested(address indexed keeper, address indexed from, address indexed to);
  event PayeeshipTransferred(address indexed keeper, address indexed from, address indexed to);
  event PaymentWithdrawn(address indexed keeper, uint256 indexed amount, address indexed to, address payee);
  event UpkeepAdminTransferRequested(uint256 indexed id, address indexed from, address indexed to);
  event UpkeepAdminTransferred(uint256 indexed id, address indexed from, address indexed to);
  event UpkeepCanceled(uint256 indexed id, uint64 indexed atBlockHeight);
  event UpkeepCheckDataUpdated(uint256 indexed id, bytes newCheckData);
  event UpkeepGasLimitSet(uint256 indexed id, uint96 gasLimit);
  event UpkeepMigrated(uint256 indexed id, uint256 remainingBalance, address destination);
  event UpkeepPaused(uint256 indexed id);
  event UpkeepPerformed(
    uint256 indexed id,
    bool indexed success,
    uint256 gasUsed,
    uint32 checkBlockNumber,
    uint96 payment
  );
  event UpkeepReceived(uint256 indexed id, uint256 startingBalance, address importedFrom);
  event UpkeepUnpaused(uint256 indexed id);
  event UpkeepRegistered(uint256 indexed id, uint32 executeGas, address admin);

  /**
   * @param paymentModel the payment model of default, Arbitrum, or Optimism
   * @param registryGasOverhead the gas overhead used by registry in performUpkeep
   * @param link address of the LINK Token
   * @param linkEthFeed address of the LINK/ETH price feed
   * @param fastGasFeed address of the Fast Gas price feed
   */
  constructor(
    PaymentModel paymentModel,
    uint256 registryGasOverhead,
    address link,
    address linkEthFeed,
    address fastGasFeed
  ) ConfirmedOwner(msg.sender) {
    PAYMENT_MODEL = paymentModel;
    REGISTRY_GAS_OVERHEAD = registryGasOverhead;
    LINK = LinkTokenInterface(link);
    LINK_ETH_FEED = AggregatorV3Interface(linkEthFeed);
    FAST_GAS_FEED = AggregatorV3Interface(fastGasFeed);
  }

  /**
   * @dev retrieves feed data for fast gas/eth and link/eth prices. if the feed
   * data is stale it uses the configured fallback price. Once a price is picked
   * for gas it takes the min of gas price in the transaction or the fast gas
   * price in order to reduce costs for the upkeep clients.
   */
  function _getFeedData() internal view returns (uint256 gasWei, uint256 linkEth) {
    // TODO (sc-48706): Gas optimise this
    uint32 stalenessSeconds = s_onChainConfig.stalenessSeconds;
    bool staleFallback = stalenessSeconds > 0;
    uint256 timestamp;
    int256 feedValue;
    (, feedValue, , timestamp, ) = FAST_GAS_FEED.latestRoundData();
    if ((staleFallback && stalenessSeconds < block.timestamp - timestamp) || feedValue <= 0) {
      gasWei = s_onChainConfig.fallbackGasPrice;
    } else {
      gasWei = uint256(feedValue);
    }
    (, feedValue, , timestamp, ) = LINK_ETH_FEED.latestRoundData();
    if ((staleFallback && stalenessSeconds < block.timestamp - timestamp) || feedValue <= 0) {
      linkEth = s_onChainConfig.fallbackLinkPrice;
    } else {
      linkEth = uint256(feedValue);
    }
    return (gasWei, linkEth);
  }

  /**
   * @dev calculates LINK paid for gas spent plus a configure premium percentage
   * @param gasLimit the amount of gas used
   * @param fastGasWei the fast gas price
   * @param linkEth the exchange ratio between LINK and ETH
   * @param isExecution if this is triggered by a perform upkeep function
   */
  function _calculatePaymentAmount(
    uint256 gasLimit,
    uint256 fastGasWei,
    uint256 linkEth,
    bool isExecution
  ) internal view returns (uint96 gasPayment, uint96 premium) {
    OnChainConfig memory config = s_onChainConfig;
    uint256 gasWei = fastGasWei * config.gasCeilingMultiplier;
    // in case it's actual execution use actual gas price, capped by fastGasWei * gasCeilingMultiplier
    if (isExecution && tx.gasprice < gasWei) {
      gasWei = tx.gasprice;
    }

    uint256 weiForGas = gasWei * (gasLimit + REGISTRY_GAS_OVERHEAD);
    uint256 l1CostWei = 0;
    if (PAYMENT_MODEL == PaymentModel.OPTIMISM) {
      bytes memory txCallData = new bytes(0);
      if (isExecution) {
        txCallData = bytes.concat(msg.data, L1_FEE_DATA_PADDING);
      } else {
        txCallData = MAX_INPUT_DATA;
      }
      l1CostWei = OPTIMISM_ORACLE.getL1Fee(txCallData);
    } else if (PAYMENT_MODEL == PaymentModel.ARBITRUM) {
      l1CostWei = ARB_NITRO_ORACLE.getCurrentTxL1GasFees();
    }
    // if it's not performing upkeeps, use gas ceiling multiplier to estimate the upper bound
    if (!isExecution) {
      l1CostWei = config.gasCeilingMultiplier * l1CostWei;
    }

    uint256 gasPayment256 = ((weiForGas + l1CostWei) * 1e18) / linkEth;
    uint256 premium256 = (gasPayment * config.paymentPremiumPPB) / 1e9 + uint256(config.flatFeeMicroLink) * 1e12;
    // LINK_TOTAL_SUPPLY < UINT96_MAX
    if (gasPayment + premium > LINK_TOTAL_SUPPLY) revert PaymentGreaterThanAllLINK();
    return (uint96(gasPayment256), uint96(premium256));
  }

  /**
   * @dev ensures the upkeep is not cancelled and the caller is the upkeep admin
   */
  function requireAdminAndNotCancelled(Upkeep memory upkeep) internal view {
    if (msg.sender != upkeep.admin) revert OnlyCallableByAdmin();
    if (upkeep.maxValidBlocknumber != UINT32_MAX) revert UpkeepCancelled();
  }

  /**
   * @dev generates a PerformParams struct for use in _performUpkeepWithParams()
   */
  function _generatePerformParams(
    uint256 id,
    bytes memory performData,
    bool isExecution // Whether this is an actual perform execution or just a simulation
  ) internal view returns (PerformParams memory) {
    (uint256 fastGasWei, uint256 linkEth) = _getFeedData();
    (uint96 gasPayment, uint96 premium) = _calculatePaymentAmount(
      s_upkeep[id].executeGas,
      fastGasWei,
      linkEth,
      isExecution
    );

    return
      PerformParams({
        id: id,
        performData: performData,
        fastGasWei: fastGasWei,
        linkEth: linkEth,
        maxLinkPayment: gasPayment + premium
      });
  }

  /**
   * @dev Should be called on every config change, either OCR or onChainConfig
   * Recomputed the config digest and stores it
   */
  function _computeAndStoreConfigDigest(
    address[] memory signers,
    address[] memory transmitters,
    uint8 f,
    uint16 numOcrInstances,
    bytes memory onchainConfig,
    uint64 offchainConfigVersion,
    bytes memory offchainConfig
  ) internal {
    uint32 previousConfigBlockNumber = s_latestConfigBlockNumber;
    s_latestConfigBlockNumber = uint32(block.number);
    s_configCount += 1;

    s_latestRootConfigDigest = _configDigestFromConfigData(
      block.chainid,
      address(this),
      s_configCount,
      signers,
      transmitters,
      f,
      numOcrInstances,
      onchainConfig,
      offchainConfigVersion,
      offchainConfig
    );

    emit ConfigSet(
      previousConfigBlockNumber,
      s_latestRootConfigDigest,
      s_configCount,
      signers,
      transmitters,
      f,
      numOcrInstances,
      onchainConfig,
      offchainConfigVersion,
      offchainConfig
    );
  }
}