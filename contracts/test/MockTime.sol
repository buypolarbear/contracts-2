pragma solidity 0.4.24;

/** @title Mock contract in order to test time logic reliably. */
/** @author Kerman Kohli - <kerman@8xprotocol.com> */

contract MockTime {
    // solhint-disable-next-line
    uint public currentTime = block.timestamp;

    /** PUBLIC FUNCTIONS */
    /** @dev Set the time in the contract
      *
    */
    function setTime(uint _time)
        public
    {
        currentTime = _time;
    }

    /** @dev Turn back the time in the contract
      *
    */
    function turnBackTime(uint _seconds)
        public
    {
        currentTime -= _seconds;
    }

    /** INTERNAL FUNCTIONS */
    /** @dev A mock of the current timsstamp
      *
    */
    function currentTimestamp()
        internal
        view
        returns (uint _timetstamp)
    {
        return currentTime;
    }
}