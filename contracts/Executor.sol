pragma solidity 0.4.24;

import "./base/ownership/Ownable.sol";
import "./base/token/ERC20.sol";
import "./base/token/WETH.sol";

import "./Collectable.sol";
import "./TransferProxy.sol";
import "./StakeContract.sol";
import "./PaymentRegistry.sol";
import "./KyberNetworkInterface.sol";
import "./ApprovedRegistry.sol";

/** @title Contains all the data required for a user's active subscription. */
/** @author Kerman Kohli - <kerman@8xprotocol.com> */

contract Executor is Ownable {

    TransferProxy public transferProxy;
    StakeContract public stakeContract;
    PaymentRegistry public paymentRegistry;
    KyberNetworkInterface public kyberProxy;
    ApprovedRegistry public approvedRegistry;

    uint public cancellationPeriod;

    event SubscriptionActivated(
        address indexed subscriptionAddress,
        bytes32 indexed subscriptionIdentifier,
        address indexed tokenAddress,
        uint dueDate,
        uint amount,
        uint fee
    );

    event SubscriptionProcessed(
        address indexed subscriptionAddress,
        bytes32 indexed subscriptionIdentifier,
        address indexed claimant,
        uint dueDate,
        uint staked
    );

    event SubscriptionReleased(
        address indexed subscriptionAddress,
        bytes32 indexed subscriptionIdentifier,
        address indexed releasedBy,
        uint dueDate
    );

    event SubscriptionLatePaymentCaught(
        address indexed subscriptionAddress,
        bytes32 indexed subscriptionIdentifier,
        address indexed originalClaimant,
        address newClaimant,
        uint amountLost
    );

    /**
      * PUBLIC FUNCTIONS
    */

    /** @dev Set the addresses for the relevant contracts
      * @param _transferProxyAddress the address for the designated transfer proxy.
      * @param _stakeContractAddress the address for the stake contract.
      * @param _paymentRegistryAddress the address for the payment registry.
      * @param _kyberAddress the address for the kyber network contract.
      * @param _approvedRegistryAddress the address for the approved registry contract.
    */
    constructor(
        address _transferProxyAddress,
        address _stakeContractAddress,
        address _paymentRegistryAddress,
        address _kyberAddress,
        address _approvedRegistryAddress
    )
        public
    {
        // @TODO: Figure out how to add tests for this

        transferProxy = TransferProxy(_transferProxyAddress);
        stakeContract = StakeContract(_stakeContractAddress);
        paymentRegistry = PaymentRegistry(_paymentRegistryAddress);
        kyberProxy = KyberNetworkInterface(_kyberAddress);
        approvedRegistry = ApprovedRegistry(_approvedRegistryAddress);
    }

    /** @dev Set the amount of time after a payment a service node has to cancel.
      * @param _period is the amount of time they have.
    */
    function setCancellationPeriod(uint _period) public onlyOwner {
        cancellationPeriod = _period;
    }

    /** @dev Active a subscription once it's been created (make the first payment) paid from wrapped Ether.
      * @param _subscriptionContract is the contract where the details exist(adheres to Collectible contract interface).
      * @param _subscriptionIdentifier is the identifier of that customer's subscription with its relevant details.
    */
    function activateSubscription(
        address _subscriptionContract,
        bytes32 _subscriptionIdentifier
    )
        public
        returns (bool success)
    {

        // Initiate an instance of the collectable subscription
        Collectable subscription = Collectable(_subscriptionContract);

        // Check if the subscription is valid
        require(approvedRegistry.isContractAuthorised(_subscriptionContract));
        require(subscription.isValidSubscription(_subscriptionIdentifier) == false);

        // Get the detauls of the subscription
        ERC20 transactingToken = ERC20(subscription.getSubscriptionTokenAddress(_subscriptionIdentifier));
        uint subscriptionInterval = subscription.getSubscriptionInterval(_subscriptionIdentifier);
        uint amountDue = subscription.getAmountDueFromSubscription(_subscriptionIdentifier);
        uint fee = subscription.getSubscriptionFee(_subscriptionIdentifier);
        (address consumer, address business) = subscription.getSubscriptionFromToAddresses(_subscriptionIdentifier);

        // Make the payment safely
        attemptPayment(transactingToken, consumer, business, amountDue);

        // Create a new record in the payments registry
        paymentRegistry.createNewPayment(
            _subscriptionIdentifier, // Subscription identifier
            address(transactingToken), // Token address
            currentTimestamp() + subscriptionInterval, // Next due date
            amountDue, // Amount due
            fee // Fee
        );

        // Start the subscription
        subscription.setStartDate(currentTimestamp(), _subscriptionIdentifier);

        // Emit the appropriate event to show subscription has been activated
        emit SubscriptionActivated(
            _subscriptionContract,
            _subscriptionIdentifier,
            address(transactingToken),
            amountDue,
            currentTimestamp() + subscriptionInterval,
            fee
        );
    }

    /** @dev Collect the payment due from the subscriber.
      * @param _subscriptionContract is the contract where the details exist(adheres to Collectible contract interface).
      * @param _subscriptionIdentifier is the identifier of that customer's subscription with its relevant details.
    */
    function processSubscription(
        address _subscriptionContract,
        bytes32 _subscriptionIdentifier
    )
        public
    {
        // Get the current payment registry object (if it doesn't exist execution will eventually fail)
        (
            address tokenAddress,
            uint dueDate,
            uint amount,
            uint fee,
            uint lastPaymentDate,
            address claimant,
            uint executionPeriod,
            uint stakeMultiplier
        ) = paymentRegistry.getPaymentInformation(_subscriptionIdentifier);

        // Check to make sure the payment is due
        require(currentTimestamp() >= dueDate);

        // Check to make sure it hasn't been claimed by someone else or belongs to you
        require(claimant == msg.sender || claimant == 0);

        // Check it isn't too late to claim (past execution) or too late
        Collectable subscription = Collectable(_subscriptionContract);
        uint interval = subscription.getSubscriptionInterval(_subscriptionIdentifier);
        // @TODO: Implementation

        // Check that the service node calling has enough staked tokens
        uint currentMultiplier = currentMultiplierFor(tokenAddress);
        uint requiredStake = currentMultiplier * amount;

        if (stakeMultiplier == 0) {
            require(stakeContract.getAvailableStake(msg.sender, tokenAddress) >= requiredStake);
        }

        // Make payments to the business and service node
        if (attemptPaymentElseCancel(
            _subscriptionContract,
            _subscriptionIdentifier,
            tokenAddress,
            msg.sender,
            amount,
            fee,
            stakeMultiplier
        ) == false) {
            // We cancel the subscription if payment couldn't be made
            // Could be due to invalid subscription (cancelled) or insufficient funds
            return;
        }

        // If the current multiplier is lower than the one in the object, free the difference
        if (stakeMultiplier > currentMultiplierFor(tokenAddress)) {
            stakeContract.unlockTokens(
                msg.sender,
                tokenAddress,
                (stakeMultiplier - (requiredStake/amount)) * amount
            );
        } else if (stakeMultiplier == 0) {
            stakeContract.lockTokens(msg.sender, tokenAddress, requiredStake);
        }

        // Update the payment registry
        paymentRegistry.claimPayment(
            _subscriptionIdentifier, // Identifier of subscription
            msg.sender, // The claimant
            dueDate + interval, // Next payment due date
            currentMultiplier // Current multiplier set for the currency
        );

        // Emit the subscription processed event
        emit SubscriptionProcessed(_subscriptionContract, _subscriptionIdentifier, msg.sender, dueDate + interval, requiredStake);

    }

    /** @dev Release the payment/responsibility of a service node
      * @param _subscriptionContract is the contract where the details exist(adheres to Collectible contract interface).
      * @param _subscriptionIdentifier is the identifier of that customer's subscription with its relevant details.
    */
    function releaseSubscription(
        address _subscriptionContract,
        bytes32 _subscriptionIdentifier
    )
        public
    {

        // Get the payment registry informatio
        (
            address tokenAddress,
            uint dueDate,
            uint amount,
            ,
            uint lastPaymentDate,
            address claimant,
            uint executionPeriod,
            uint stakeMultiplier
        ) = paymentRegistry.getPaymentInformation(_subscriptionIdentifier);

        // Check that it belongs to the rightful claimant/service node
        // This also means we're not talking about a first time payment
        require(claimant == msg.sender);

        // Make sure we're within the cancellation window
        uint minimumDate = lastPaymentDate + executionPeriod;
        require(
            currentTimestamp() >= minimumDate && // Must be past last payment date and the execution period
            currentTimestamp() < (minimumDate + cancellationPeriod) // Can't be past the cancellation period
        );

        // Call the remove claim on payments registry
        paymentRegistry.removeClaimant(
            _subscriptionIdentifier,
            msg.sender
        );

        // Unstake tokens
        stakeContract.unlockTokens(
            msg.sender,
            tokenAddress,
            amount * stakeMultiplier
        );

        // Emit the correct event
        emit SubscriptionReleased(_subscriptionContract, _subscriptionIdentifier, msg.sender, dueDate);

    }

    /** @dev Catch another service node who didn't process their payment on time.
      * @param _subscriptionContract is the contract where the details exist(adheres to Collectible contract interface).
      * @param _subscriptionIdentifier is the identifier of that customer's subscription with its relevant details.
    */
    function catchLateSubscription(
        address _subscriptionContract,
        bytes32 _subscriptionIdentifier
    )
        public
    {

        // Get the payment object
        (
            address tokenAddress,
            uint dueDate,
            uint amount,
            ,
            ,
            address claimant,
            uint executionPeriod,
            uint stakeMultiplier
        ) = paymentRegistry.getPaymentInformation(_subscriptionIdentifier);

        // First make sure it's past the due date and execution period
        require(currentTimestamp() > (dueDate + executionPeriod));

        // Ensure the original claimant can't call this function
        require(msg.sender != claimant);

        // Slash the tokens and give them to this caller = $$$
        stakeContract.transferStake(
            claimant,
            tokenAddress,
            amount * stakeMultiplier,
            msg.sender
        );

        // Remove as claimant
        paymentRegistry.removeClaimant(
            _subscriptionIdentifier,
            claimant
        );

        // Call collect payment function as this caller
        processSubscription(_subscriptionContract, _subscriptionIdentifier);

        // Emit an event to say a late payment was caught and processed
        emit SubscriptionLatePaymentCaught(
            _subscriptionContract,
            _subscriptionIdentifier,
            claimant,
            msg.sender,
            amount * stakeMultiplier
        );
    }

    // @TODO: Handle stale payments

    /**
      * INTERNAL FUNCTIONS
    */
    /** @dev Current timestamp returned via a function in order for mocks in tests
    */
    function currentTimestamp()
        internal
        view
        returns (uint timetstamp)
    {
        // solhint-disable-next-line
        return block.timestamp;
    }

    /**
      * PRIVATE FUNCTION
    */

    function attemptPaymentElseCancel(
        address _subscriptionContract,
        bytes32 _subscriptionIdentifier,
        address _tokenAddress,
        address _serviceNode,
        uint _amount,
        uint _fee,
        uint _stakeMultiplier
    )
        private
        returns (bool)
    {
        Collectable subscription = Collectable(_subscriptionContract);
        ERC20 transactingToken = ERC20(_tokenAddress);

        (address consumer, address business) = subscription.getSubscriptionFromToAddresses(_subscriptionIdentifier);

        bool validSubscription = subscription.isValidSubscription(_subscriptionIdentifier);

        if (transactingToken.balanceOf(consumer) >= _amount && validSubscription == true) {
            // Make the payments
            attemptPayment(transactingToken, consumer, business, _amount - _fee);
            attemptPayment(transactingToken, consumer, _serviceNode, _fee);
            return true;
        } else {
            // Terminate the subscription if it hasn't already
            if (validSubscription == true) {
                subscription.cancelSubscription(_subscriptionIdentifier);
            }

            // Refund the gas to the service node by freeing up storage
            paymentRegistry.deletePayment(_subscriptionIdentifier);

            // Unstake tokens
            stakeContract.unlockTokens(
                msg.sender,
                _tokenAddress,
                _amount * _stakeMultiplier
            );

            return false;
        }
    }

    function attemptPayment(
        ERC20 _transactingToken,
        address _from,
        address _to,
        uint _amount
    )
        private
        returns (bool)
    {
        // Get the businesses balance before the transaction
        uint balanceOfBusinessBeforeTransfer = _transactingToken.balanceOf(_to);

        // Check if the user has enough funds
        require(_transactingToken.balanceOf(_from) >= _amount);

        // Send currency to the destination business
        transferProxy.transferFrom(address(_transactingToken), _from, _to, _amount);

        // Check the business actually received the funds by checking the difference
        require((_transactingToken.balanceOf(_to) - balanceOfBusinessBeforeTransfer) == _amount);
    }

    function currentMultiplierFor(address _tokenAddress) public returns(uint) {
        return approvedRegistry.getMultiplierFor(_tokenAddress);
    }

}