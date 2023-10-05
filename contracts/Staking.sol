// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;
import "./Injector.sol";

contract Staking is IStaking, InjectorContextHolder {
    uint256 internal constant BALANCE_COMPACT_PRECISION = 1e12;
    uint16 internal constant COMMISSION_RATE_MIN_VALUE = 0; // 0%
    uint16 internal constant COMMISSION_RATE_MAX_VALUE = 7000; // 30%
    uint64 internal constant TRANSFER_GAS_LIMIT = 30000;
    uint256 internal _nowReward;

    // validator events
    event ValidatorAdded(
        address indexed validator,
        address owner,
        uint8 status,
        uint16 commissionRate
    );
    event ValidatorModified(
        address indexed validator,
        address owner,
        uint8 status,
        uint16 commissionRate
    );
    event ValidatorRemoved(address indexed validator);
    event ValidatorOwnerClaimed(
        address indexed validator,
        uint256 amount,
        uint64 epoch
    );
    event ValidatorSlashed(
        address indexed validator,
        uint32 slashes,
        uint64 epoch
    );
    event ValidatorJailed(address indexed validator, uint64 epoch);
    event ValidatorDeposited(
        address indexed validator,
        uint256 amount,
        uint64 epoch
    );
    event ValidatorReleased(address indexed validator, uint64 epoch);

    // staker events
    event Delegated(
        address indexed validator,
        address indexed staker,
        uint256 amount,
        uint64 epoch
    );
    event Undelegated(
        address indexed validator,
        address indexed staker,
        uint256 amount,
        uint64 epoch
    );
    event Claimed(
        address indexed validator,
        address indexed staker,
        uint256 amount,
        uint64 epoch
    );

    enum ValidatorStatus {
        NotFound,
        Active,
        Pending,
        Jail
    }

    struct ValidatorSnapshot {
        uint96 totalRewards;
        uint112 totalDelegated;
        uint32 slashesCount;
        uint16 commissionRate;
    }

    struct Validator {
        address validatorAddress;
        address ownerAddress;
        ValidatorStatus status;
        uint64 changedAt;
        uint64 jailedBefore;
        uint64 claimedAt;
    }

    struct DelegationOpDelegate {
        uint112 amount;
        uint64 epoch;
    }

    struct DelegationOpUndelegate {
        uint112 amount;
        uint64 epoch;
    }

    struct ValidatorDelegation {
        DelegationOpDelegate[] delegateQueue;
        uint64 delegateGap;
        DelegationOpUndelegate[] undelegateQueue;
        uint64 undelegateGap;
    }

    // mapping from validator address to validator
    mapping(address => Validator) internal _validatorsMap;

    mapping(address => bool) internal _validatorsUnlock;
    // mapping from validator owner to validator address
    mapping(address => address) internal _validatorOwners;
    // list of all validators that are in validators mapping
    address[] internal _activeValidatorsList;
    // mapping with stakers to validators at epoch (validator -> delegator -> delegation)
    mapping(address => mapping(address => ValidatorDelegation))
        internal _validatorDelegations;
    // mapping with validator snapshots per each epoch (validator -> epoch -> snapshot)
    mapping(address => mapping(uint64 => ValidatorSnapshot))
        internal _validatorSnapshots;

    constructor(
        bytes memory constructorParams
    ) InjectorContextHolder(constructorParams) {}

    function ctor(
        address[] calldata validators,
        uint256[] calldata initialStakes,
        uint16 commissionRate
    ) external whenNotInitialized {
        require(initialStakes.length == validators.length);
        uint256 totalStakes = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            _addValidator(
                validators[i],
                validators[i],
                ValidatorStatus.Active,
                commissionRate,
                initialStakes[i],
                0
            );
            totalStakes += initialStakes[i];
        }
        require(address(this).balance == totalStakes, "init balance error");
    }

    function getValidatorDelegation(
        address validatorAddress,
        address delegator
    ) external view override returns (uint256 delegatedAmount, uint64 atEpoch) {
        ValidatorDelegation memory delegation = _validatorDelegations[
            validatorAddress
        ][delegator];
        if (delegation.delegateQueue.length == 0) {
            return (delegatedAmount = 0, atEpoch = 0);
        }
        DelegationOpDelegate memory snapshot = delegation.delegateQueue[
            delegation.delegateQueue.length - 1
        ];
        return (
            delegatedAmount =
                uint256(snapshot.amount) *
                BALANCE_COMPACT_PRECISION,
            atEpoch = snapshot.epoch
        );
    }

    function getNowReward() external view returns (uint256) {
        return _nowReward;
    }

    function getValidatorStatus(
        address validatorAddress
    )
        external
        view
        override
        returns (
            address ownerAddress,
            uint8 status,
            uint256 totalDelegated,
            uint32 slashesCount,
            uint64 changedAt,
            uint64 jailedBefore,
            uint64 claimedAt,
            uint16 commissionRate,
            uint96 totalRewards
        )
    {
        Validator memory validator = _validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _validatorSnapshots[
            validator.validatorAddress
        ][validator.changedAt];
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated =
                uint256(snapshot.totalDelegated) *
                BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    function getValidatorStatusAtEpoch(
        address validatorAddress,
        uint64 epoch
    )
        external
        view
        returns (
            address ownerAddress,
            uint8 status,
            uint256 totalDelegated,
            uint32 slashesCount,
            uint64 changedAt,
            uint64 jailedBefore,
            uint64 claimedAt,
            uint16 commissionRate,
            uint96 totalRewards
        )
    {
        Validator memory validator = _validatorsMap[validatorAddress];
        ValidatorSnapshot memory snapshot = _touchValidatorSnapshotImmutable(
            validator,
            epoch
        );
        return (
            ownerAddress = validator.ownerAddress,
            status = uint8(validator.status),
            totalDelegated =
                uint256(snapshot.totalDelegated) *
                BALANCE_COMPACT_PRECISION,
            slashesCount = snapshot.slashesCount,
            changedAt = validator.changedAt,
            jailedBefore = validator.jailedBefore,
            claimedAt = validator.claimedAt,
            commissionRate = snapshot.commissionRate,
            totalRewards = snapshot.totalRewards
        );
    }

    function getValidatorByOwner(
        address owner
    ) external view override returns (address) {
        return _validatorOwners[owner];
    }

    function releaseValidatorFromJail(address validatorAddress) external {
        // make sure validator is in jail
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status == ValidatorStatus.Jail, "not in jail");
        // only validator owner
        require(msg.sender == validator.ownerAddress, "only owner");
        require(_currentEpoch() >= validator.jailedBefore, "still in jail");
        // update validator status
        validator.status = ValidatorStatus.Active;
        _validatorsMap[validatorAddress] = validator;
        _activeValidatorsList.push(validatorAddress);
        // emit event
        emit ValidatorReleased(validatorAddress, _currentEpoch());
    }

    function _totalDelegatedToValidator(
        Validator memory validator
    ) internal view returns (uint256) {
        ValidatorSnapshot memory snapshot = _validatorSnapshots[
            validator.validatorAddress
        ][validator.changedAt];
        return uint256(snapshot.totalDelegated) * BALANCE_COMPACT_PRECISION;
    }

    function delegate(address validatorAddress) external payable override {
        _delegateTo(msg.sender, validatorAddress, msg.value);
    }

    function undelegate(
        address validatorAddress,
        uint256 amount
    ) external override {
        _undelegateFrom(msg.sender, validatorAddress, amount);
    }

    function currentEpoch() external view returns (uint64) {
        return _currentEpoch();
    }

    function nextEpoch() external view returns (uint64) {
        return _nextEpoch();
    }

    function _currentEpoch() internal view returns (uint64) {
        return
            uint64(
                block.number / _chainConfigContract.getEpochBlockInterval() + 0
            );
    }

    function _nextEpoch() internal view returns (uint64) {
        return _currentEpoch() + 1;
    }

    function _touchValidatorSnapshot(
        Validator memory validator,
        uint64 epoch
    ) internal returns (ValidatorSnapshot storage) {
        ValidatorSnapshot storage snapshot = _validatorSnapshots[
            validator.validatorAddress
        ][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot = _validatorSnapshots[
            validator.validatorAddress
        ][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // we must save last affected epoch for this validator to be able to restore total delegated
        // amount in the future (check condition upper)
        if (epoch > validator.changedAt) {
            validator.changedAt = epoch;
        }
        return snapshot;
    }

    function _touchValidatorSnapshotImmutable(
        Validator memory validator,
        uint64 epoch
    ) internal view returns (ValidatorSnapshot memory) {
        ValidatorSnapshot memory snapshot = _validatorSnapshots[
            validator.validatorAddress
        ][epoch];
        // if snapshot is already initialized then just return it
        if (snapshot.totalDelegated > 0) {
            return snapshot;
        }
        // find previous snapshot to copy parameters from it
        ValidatorSnapshot memory lastModifiedSnapshot = _validatorSnapshots[
            validator.validatorAddress
        ][validator.changedAt];
        // last modified snapshot might store zero value, for first delegation it might happen and its not critical
        snapshot.totalDelegated = lastModifiedSnapshot.totalDelegated;
        snapshot.commissionRate = lastModifiedSnapshot.commissionRate;
        // return existing or new snapshot
        return snapshot;
    }

    function _delegateTo(
        address fromDelegator,
        address toValidator,
        uint256 amount
    ) internal {
        // check is minimum delegate amount
        require(
            amount >= _chainConfigContract.getMinStakingAmount() && amount != 0,
            "too low"
        );
        require(amount % BALANCE_COMPACT_PRECISION == 0, "bad remainder");
        // make sure amount is greater than min staking amount
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[toValidator];
        require(validator.status != ValidatorStatus.NotFound, "not found");
        uint64 atEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(
            validator,
            atEpoch
        );
        validatorSnapshot.totalDelegated += uint112(
            amount / BALANCE_COMPACT_PRECISION
        );
        _validatorsMap[toValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = _validatorDelegations[
            toValidator
        ][fromDelegator];
        if (delegation.delegateQueue.length > 0) {
            DelegationOpDelegate storage recentDelegateOp = delegation
                .delegateQueue[delegation.delegateQueue.length - 1];
            // if we already have pending snapshot for the next epoch then just increase new amount,
            // otherwise create next pending snapshot. (tbh it can't be greater, but what we can do here instead?)
            if (recentDelegateOp.epoch >= atEpoch) {
                recentDelegateOp.amount += uint112(
                    amount / BALANCE_COMPACT_PRECISION
                );
            } else {
                delegation.delegateQueue.push(
                    DelegationOpDelegate({
                        epoch: atEpoch,
                        amount: recentDelegateOp.amount +
                            uint112(amount / BALANCE_COMPACT_PRECISION)
                    })
                );
            }
        } else {
            // there is no any delegations at al, lets create the first one
            delegation.delegateQueue.push(
                DelegationOpDelegate({
                    epoch: atEpoch,
                    amount: uint112(amount / BALANCE_COMPACT_PRECISION)
                })
            );
        }
        // emit event with the next epoch
        emit Delegated(toValidator, fromDelegator, amount, atEpoch);
    }

    function _undelegateFrom(
        address toDelegator,
        address fromValidator,
        uint256 amount
    ) internal {
        // check minimum delegate amount
        require(
            amount >= _chainConfigContract.getMinStakingAmount() && amount != 0,
            "too low"
        );
        require(amount % BALANCE_COMPACT_PRECISION == 0, "bad remainder");
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[fromValidator];
        if (
            !_validatorsUnlock[fromValidator] &&
            msg.sender == validator.ownerAddress
        ) {
            revert("unlock");
        }
        uint64 beforeEpoch = _nextEpoch();
        // Lets upgrade next snapshot parameters:
        // + find snapshot for the next epoch after current block
        // + increase total delegated amount in the next epoch for this validator
        // + re-save validator because last affected epoch might change
        ValidatorSnapshot storage validatorSnapshot = _touchValidatorSnapshot(
            validator,
            beforeEpoch
        );
        require(
            validatorSnapshot.totalDelegated >=
                uint112(amount / BALANCE_COMPACT_PRECISION),
            "insufficient balance"
        );
        validatorSnapshot.totalDelegated -= uint112(
            amount / BALANCE_COMPACT_PRECISION
        );
        _validatorsMap[fromValidator] = validator;
        // if last pending delegate has the same next epoch then its safe to just increase total
        // staked amount because it can't affect current validator set, but otherwise we must create
        // new record in delegation queue with the last epoch (delegations are ordered by epoch)
        ValidatorDelegation storage delegation = _validatorDelegations[
            fromValidator
        ][toDelegator];
        require(delegation.delegateQueue.length > 0, "delegation is empty");
        DelegationOpDelegate storage recentDelegateOp = delegation
            .delegateQueue[delegation.delegateQueue.length - 1];
        require(
            recentDelegateOp.amount >=
                uint64(amount / BALANCE_COMPACT_PRECISION),
            "insufficient balance"
        );
        uint112 nextDelegatedAmount = recentDelegateOp.amount -
            uint112(amount / BALANCE_COMPACT_PRECISION);
        if (recentDelegateOp.epoch >= beforeEpoch) {
            // decrease total delegated amount for the next epoch
            recentDelegateOp.amount = nextDelegatedAmount;
        } else {
            // there is no pending delegations, so lets create the new one with the new amount
            delegation.delegateQueue.push(
                DelegationOpDelegate({
                    epoch: beforeEpoch,
                    amount: nextDelegatedAmount
                })
            );
        }
        // create new undelegate queue operation with soft lock
        delegation.undelegateQueue.push(
            DelegationOpUndelegate({
                amount: uint112(amount / BALANCE_COMPACT_PRECISION),
                epoch: beforeEpoch + _chainConfigContract.getUndelegatePeriod()
            })
        );
        // emit event with the next epoch number
        _validatorsUnlock[fromValidator] = false;
        emit Undelegated(fromValidator, toDelegator, amount, beforeEpoch);
    }

    function _claimDelegatorRewardsAndPendingUndelegates(
        address validator,
        address delegator,
        uint64 beforeEpochExclude
    ) internal {
        ValidatorDelegation storage delegation = _validatorDelegations[
            validator
        ][delegator];
        uint256 availableFunds = 0;
        uint256 sysReward = 0;
        // process delegate queue to calculate staking rewards
        uint64 delegateGap = delegation.delegateGap;
        for (
            uint256 queueLength = delegation.delegateQueue.length;
            delegateGap < queueLength;

        ) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[
                delegateGap
            ];
            if (delegateOp.epoch >= beforeEpochExclude) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegateGap < queueLength - 1) {
                voteChangedAtEpoch = delegation
                    .delegateQueue[delegateGap + 1]
                    .epoch;
            }
            for (
                ;
                delegateOp.epoch < beforeEpochExclude &&
                    (voteChangedAtEpoch == 0 ||
                        delegateOp.epoch < voteChangedAtEpoch);
                delegateOp.epoch++
            ) {
                ValidatorSnapshot
                    memory validatorSnapshot = _validatorSnapshots[validator][
                        delegateOp.epoch
                    ];
                sysReward = _sysReward(validator, delegator, delegateOp.amount);
                availableFunds += sysReward;
                _nowReward += sysReward;
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee /*uint256 ownerFee*/ /*uint256 systemFee*/,
                    ,

                ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds +=
                    (delegatorFee * delegateOp.amount) /
                    validatorSnapshot.totalDelegated;
            }
            // if we have reached end of the delegation list then lets stay on the last item, but with updated latest processed epoch
            if (delegateGap >= queueLength - 1) {
                delegation.delegateQueue[delegateGap] = delegateOp;
                break;
            }
            delete delegation.delegateQueue[delegateGap];
            ++delegateGap;
        }
        delegation.delegateGap = delegateGap;
        // process all items from undelegate queue
        uint64 undelegateGap = delegation.undelegateGap;
        for (
            uint256 queueLength = delegation.undelegateQueue.length;
            undelegateGap < queueLength;

        ) {
            DelegationOpUndelegate memory undelegateOp = delegation
                .undelegateQueue[undelegateGap];
            if (undelegateOp.epoch > beforeEpochExclude) {
                break;
            }
            availableFunds +=
                uint256(undelegateOp.amount) *
                BALANCE_COMPACT_PRECISION;
            delete delegation.undelegateQueue[undelegateGap];
            ++undelegateGap;
        }
        delegation.undelegateGap = undelegateGap;
        _safeTransferWithGasLimit(payable(delegator), availableFunds);
        // emit event
        emit Claimed(validator, delegator, availableFunds, beforeEpochExclude);
    }

    function _calcDelegatorRewardsAndPendingUndelegates(
        address validator,
        address delegator,
        uint64 beforeEpoch
    ) internal view returns (uint256) {
        ValidatorDelegation memory delegation = _validatorDelegations[
            validator
        ][delegator];
        uint256 availableFunds = 0;
        // process delegate queue to calculate staking rewards
        while (delegation.delegateGap < delegation.delegateQueue.length) {
            DelegationOpDelegate memory delegateOp = delegation.delegateQueue[
                delegation.delegateGap
            ];
            if (delegateOp.epoch >= beforeEpoch) {
                break;
            }
            uint256 voteChangedAtEpoch = 0;
            if (delegation.delegateGap < delegation.delegateQueue.length - 1) {
                voteChangedAtEpoch = delegation
                    .delegateQueue[delegation.delegateGap + 1]
                    .epoch;
            }
            for (
                ;
                delegateOp.epoch < beforeEpoch &&
                    (voteChangedAtEpoch == 0 ||
                        delegateOp.epoch < voteChangedAtEpoch);
                delegateOp.epoch++
            ) {
                ValidatorSnapshot
                    memory validatorSnapshot = _validatorSnapshots[validator][
                        delegateOp.epoch
                    ];
                availableFunds += _sysReward(
                    validator,
                    delegator,
                    delegateOp.amount
                );
                if (validatorSnapshot.totalDelegated == 0) {
                    continue;
                }
                (
                    uint256 delegatorFee /*uint256 ownerFee*/ /*uint256 systemFee*/,
                    ,

                ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
                availableFunds +=
                    (delegatorFee * delegateOp.amount) /
                    validatorSnapshot.totalDelegated;
            }
            ++delegation.delegateGap;
        }
        // process all items from undelegate queue
        while (delegation.undelegateGap < delegation.undelegateQueue.length) {
            DelegationOpUndelegate memory undelegateOp = delegation
                .undelegateQueue[delegation.undelegateGap];
            if (undelegateOp.epoch > beforeEpoch) {
                break;
            }
            availableFunds +=
                uint256(undelegateOp.amount) *
                BALANCE_COMPACT_PRECISION;
            ++delegation.undelegateGap;
        }
        // return available for claim funds
        return availableFunds;
    }

    function _claimValidatorOwnerRewards(
        Validator storage validator,
        uint64 beforeEpoch
    ) internal {
        uint256 availableFunds = 0;
        uint256 systemFee = 0;
        uint64 claimAt = validator.claimedAt;
        for (; claimAt < beforeEpoch; claimAt++) {
            ValidatorSnapshot memory validatorSnapshot = _validatorSnapshots[
                validator.validatorAddress
            ][claimAt];
            (
                ,
                /*uint256 delegatorFee*/ uint256 ownerFee,
                uint256 slashingFee
            ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
            availableFunds += ownerFee;
            systemFee += slashingFee;
        }
        validator.claimedAt = claimAt;
        _safeTransferWithGasLimit(
            payable(validator.ownerAddress),
            availableFunds
        );
        // if we have system fee then pay it to treasury account
        if (systemFee > 0) {
            _unsafeTransfer(payable(address(_systemRewardContract)), systemFee);
        }
        emit ValidatorOwnerClaimed(
            validator.validatorAddress,
            availableFunds,
            beforeEpoch
        );
    }

    function _calcValidatorOwnerRewards(
        Validator memory validator,
        uint64 beforeEpoch
    ) internal view returns (uint256) {
        uint256 availableFunds = 0;
        for (; validator.claimedAt < beforeEpoch; validator.claimedAt++) {
            ValidatorSnapshot memory validatorSnapshot = _validatorSnapshots[
                validator.validatorAddress
            ][validator.claimedAt];
            (
                ,
                /*uint256 delegatorFee*/ uint256 ownerFee /*uint256 systemFee*/,

            ) = _calcValidatorSnapshotEpochPayout(validatorSnapshot);
            availableFunds += ownerFee;
        }
        return availableFunds;
    }

    function _calcValidatorSnapshotEpochPayout(
        ValidatorSnapshot memory validatorSnapshot
    )
        internal
        view
        returns (uint256 delegatorFee, uint256 ownerFee, uint256 systemFee)
    {
        // detect validator slashing to transfer all rewards to treasury
        if (
            validatorSnapshot.slashesCount >=
            _chainConfigContract.getMisdemeanorThreshold()
        ) {
            return (
                delegatorFee = 0,
                ownerFee = 0,
                systemFee = validatorSnapshot.totalRewards
            );
        } else if (validatorSnapshot.totalDelegated == 0) {
            return (
                delegatorFee = 0,
                ownerFee = validatorSnapshot.totalRewards,
                systemFee = 0
            );
        }
        // ownerFee_(18+4-4=18) = totalRewards_18 * commissionRate_4 / 1e4
        ownerFee =
            (uint256(validatorSnapshot.totalRewards) *
                validatorSnapshot.commissionRate) /
            1e4;
        // delegatorRewards = totalRewards - ownerFee
        delegatorFee = validatorSnapshot.totalRewards - ownerFee;
        // default system fee is zero for epoch
        systemFee = 0;
    }

    function registerValidator(
        address validatorAddress,
        uint16 commissionRate
    ) external payable override {
        uint256 initialStake = msg.value;
        // // initial stake amount should be greater than minimum validator staking amount
        require(
            initialStake >= _chainConfigContract.getMinValidatorStakeAmount(),
            "too low"
        );
        require(initialStake % BALANCE_COMPACT_PRECISION == 0, "bad remainder");
        // add new validator as pending
        _addValidator(
            validatorAddress,
            msg.sender,
            ValidatorStatus.Pending,
            commissionRate,
            initialStake,
            _nextEpoch()
        );
    }

    function addValidator(
        address account
    ) external virtual override onlyFromGovernance {
        _addValidator(
            account,
            account,
            ValidatorStatus.Active,
            0,
            0,
            _nextEpoch()
        );
    }

    function _addValidator(
        address validatorAddress,
        address validatorOwner,
        ValidatorStatus status,
        uint16 commissionRate,
        uint256 initialStake,
        uint64 sinceEpoch
    ) internal {
        // validator commission rate
        require(
            commissionRate >= COMMISSION_RATE_MIN_VALUE &&
                commissionRate <= COMMISSION_RATE_MAX_VALUE,
            "bad rate"
        );
        // init validator default params
        Validator memory validator = _validatorsMap[validatorAddress];
        require(
            _validatorsMap[validatorAddress].status == ValidatorStatus.NotFound,
            "val is use"
        );
        validator.validatorAddress = validatorAddress;
        validator.ownerAddress = validatorOwner;
        validator.status = status;
        validator.changedAt = sinceEpoch;
        _validatorsMap[validatorAddress] = validator;
        // save validator owner
        require(_validatorOwners[validatorOwner] == address(0x00), "owner use");
        _validatorOwners[validatorOwner] = validatorAddress;
        // add new validator to array
        if (status == ValidatorStatus.Active) {
            _activeValidatorsList.push(validatorAddress);
        }
        // push initial validator snapshot at zero epoch with default params
        _validatorSnapshots[validatorAddress][sinceEpoch] = ValidatorSnapshot(
            0,
            uint112(initialStake / BALANCE_COMPACT_PRECISION),
            0,
            commissionRate
        );
        // delegate initial stake to validator owner
        ValidatorDelegation storage delegation = _validatorDelegations[
            validatorAddress
        ][validatorOwner];
        require(delegation.delegateQueue.length == 0, "delegation is use");
        delegation.delegateQueue.push(
            DelegationOpDelegate(
                uint112(initialStake / BALANCE_COMPACT_PRECISION),
                sinceEpoch
            )
        );
        // emit event
        emit ValidatorAdded(
            validatorAddress,
            validatorOwner,
            uint8(status),
            commissionRate
        );
    }

    function removeValidator(
        address account
    ) external virtual override onlyFromGovernance {
        _removeValidator(account);
    }

    function _removeValidatorFromActiveList(address validatorAddress) internal {
        // find index of validator in validator set
        int256 indexOf = -1;
        for (uint256 i = 0; i < _activeValidatorsList.length; i++) {
            if (_activeValidatorsList[i] != validatorAddress) continue;
            indexOf = int256(i);
            break;
        }
        // remove validator from array (since we remove only active it might not exist in the list)
        if (indexOf >= 0) {
            if (
                _activeValidatorsList.length > 1 &&
                uint256(indexOf) != _activeValidatorsList.length - 1
            ) {
                _activeValidatorsList[uint256(indexOf)] = _activeValidatorsList[
                    _activeValidatorsList.length - 1
                ];
            }
            _activeValidatorsList.pop();
        }
    }

    function _removeValidator(address account) internal {
        Validator memory validator = _validatorsMap[account];
        require(validator.status != ValidatorStatus.NotFound, "not found");
        // remove validator from active list if exists
        _removeValidatorFromActiveList(account);
        // remove from validators map
        delete _validatorOwners[validator.ownerAddress];
        delete _validatorsMap[account];
        // emit event about it
        emit ValidatorRemoved(account);
    }

    function activateValidator(
        address validator
    ) external virtual override onlyFromGovernance {
        _activateValidator(validator);
    }

    function _activateValidator(address validatorAddress) internal {
        Validator memory validator = _validatorsMap[validatorAddress];
        require(
            _validatorsMap[validatorAddress].status == ValidatorStatus.Pending,
            "not pending"
        );
        _activeValidatorsList.push(validatorAddress);
        validator.status = ValidatorStatus.Active;
        _validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(
            validator,
            _nextEpoch()
        );
        emit ValidatorModified(
            validatorAddress,
            validator.ownerAddress,
            uint8(validator.status),
            snapshot.commissionRate
        );
    }

    function disableValidator(
        address validator
    ) external virtual override onlyFromGovernance {
        _disableValidator(validator);
    }

    function unlockValidator(
        address validator
    ) external virtual override onlyFromGovernance {
        _validatorsUnlock[validator] = true;
    }

    function _disableValidator(address validatorAddress) internal {
        Validator memory validator = _validatorsMap[validatorAddress];
        require(
            _validatorsMap[validatorAddress].status == ValidatorStatus.Active,
            "not active"
        );
        _removeValidatorFromActiveList(validatorAddress);
        validator.status = ValidatorStatus.Pending;
        _validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(
            validator,
            _nextEpoch()
        );
        emit ValidatorModified(
            validatorAddress,
            validator.ownerAddress,
            uint8(validator.status),
            snapshot.commissionRate
        );
    }

    function changeValidatorCommissionRate(
        address validatorAddress,
        uint16 commissionRate
    ) external {
        require(
            commissionRate >= COMMISSION_RATE_MIN_VALUE &&
                commissionRate <= COMMISSION_RATE_MAX_VALUE,
            "bad rate"
        );
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "not found");
        require(validator.ownerAddress == msg.sender, "only owner");
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(
            validator,
            _nextEpoch()
        );
        snapshot.commissionRate = commissionRate;
        _validatorsMap[validatorAddress] = validator;
        emit ValidatorModified(
            validator.validatorAddress,
            validator.ownerAddress,
            uint8(validator.status),
            commissionRate
        );
    }

    function changeValidatorOwner(
        address validatorAddress,
        address newOwner
    ) external override {
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.ownerAddress == msg.sender, "only owner");
        require(_validatorOwners[newOwner] == address(0x00), "owner use");
        ValidatorDelegation storage delegation = _validatorDelegations[
            validatorAddress
        ][newOwner];
        require(delegation.delegateQueue.length == 0, "is use");
        delete _validatorOwners[validator.ownerAddress];
        _validatorDelegations[validatorAddress][
            newOwner
        ] = _validatorDelegations[validatorAddress][validator.ownerAddress];
        delete _validatorDelegations[validatorAddress][newOwner];
        validator.ownerAddress = newOwner;
        _validatorOwners[newOwner] = validatorAddress;
        _validatorsMap[validatorAddress] = validator;
        ValidatorSnapshot storage snapshot = _touchValidatorSnapshot(
            validator,
            _nextEpoch()
        );
        emit ValidatorModified(
            validator.validatorAddress,
            validator.ownerAddress,
            uint8(validator.status),
            snapshot.commissionRate
        );
    }

    function isValidatorActive(
        address account
    ) external view override returns (bool) {
        if (_validatorsMap[account].status != ValidatorStatus.Active) {
            return false;
        }
        address[] memory topValidators = _getValidators();
        for (uint256 i = 0; i < topValidators.length; i++) {
            if (topValidators[i] == account) return true;
        }
        return false;
    }

    function isValidator(
        address account
    ) external view override returns (bool) {
        return _validatorsMap[account].status != ValidatorStatus.NotFound;
    }

    function _getValidators() internal view returns (address[] memory) {
        uint256 n = _activeValidatorsList.length;
        address[] memory orderedValidators = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            orderedValidators[i] = _activeValidatorsList[i];
        }
        // we need to select k top validators out of n
        uint256 k = _chainConfigContract.getActiveValidatorsLength();
        if (k > n) {
            k = n;
        }
        for (uint256 i = 0; i < k; i++) {
            uint256 nextValidator = i;
            Validator memory currentMax = _validatorsMap[
                orderedValidators[nextValidator]
            ];
            for (uint256 j = i + 1; j < n; j++) {
                Validator memory current = _validatorsMap[orderedValidators[j]];
                if (
                    _totalDelegatedToValidator(currentMax) <
                    _totalDelegatedToValidator(current)
                ) {
                    nextValidator = j;
                    currentMax = current;
                }
            }
            address backup = orderedValidators[i];
            orderedValidators[i] = orderedValidators[nextValidator];
            orderedValidators[nextValidator] = backup;
        }
        // this is to cut array to first k elements without copying
        assembly {
            mstore(orderedValidators, k)
        }
        return orderedValidators;
    }

    function getValidators() external view override returns (address[] memory) {
        return _getValidators();
    }

    function deposit(
        address validatorAddress
    ) external payable virtual override onlyFromCoinbase onlyZeroGasPrice {
        _depositFee(validatorAddress);
    }

    function _depositFee(address validatorAddress) internal {
        require(msg.value > 0, "deposit is zero");
        // make sure validator is active
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "not found");
        uint64 epoch = _currentEpoch();
        // increase total pending rewards for validator for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(
            validator,
            epoch
        );
        currentSnapshot.totalRewards += uint96(msg.value);
        // emit event
        emit ValidatorDeposited(validatorAddress, msg.value, epoch);
    }

    function getValidatorFee(
        address validatorAddress
    ) external view override returns (uint256) {
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _currentEpoch());
    }

    function getPendingValidatorFee(
        address validatorAddress
    ) external view override returns (uint256) {
        // make sure validator exists at least
        Validator memory validator = _validatorsMap[validatorAddress];
        if (validator.status == ValidatorStatus.NotFound) {
            return 0;
        }
        // calc validator rewards
        return _calcValidatorOwnerRewards(validator, _nextEpoch());
    }

    function claimValidatorFee(address validatorAddress) external override {
        // make sure validator exists at least
        Validator storage validator = _validatorsMap[validatorAddress];
        // only validator owner can claim deposit fee
        require(msg.sender == validator.ownerAddress, "only owner");
        // claim all validator fees
        _claimValidatorOwnerRewards(validator, _currentEpoch());
    }

    function claimValidatorFeeAtEpoch(
        address validatorAddress,
        uint64 beforeEpoch
    ) external override {
        // make sure validator exists at least
        Validator storage validator = _validatorsMap[validatorAddress];
        // only validator owner can claim deposit fee
        require(msg.sender == validator.ownerAddress, "only owner");
        // we disallow to claim rewards from future epochs
        require(beforeEpoch <= _currentEpoch());
        // claim all validator fees
        _claimValidatorOwnerRewards(validator, beforeEpoch);
    }

    function getDelegatorFee(
        address validatorAddress,
        address delegatorAddress
    ) external view override returns (uint256) {
        return
            _calcDelegatorRewardsAndPendingUndelegates(
                validatorAddress,
                delegatorAddress,
                _currentEpoch()
            );
    }

    function getPendingDelegatorFee(
        address validatorAddress,
        address delegatorAddress
    ) external view override returns (uint256) {
        return
            _calcDelegatorRewardsAndPendingUndelegates(
                validatorAddress,
                delegatorAddress,
                _nextEpoch()
            );
    }

    function claimDelegatorFee(address validatorAddress) external override {
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(
            validatorAddress,
            msg.sender,
            _currentEpoch()
        );
    }

    function claimDelegatorFeeAtEpoch(
        address validatorAddress,
        uint64 beforeEpoch
    ) external override {
        // make sure delegator can't claim future epochs
        require(beforeEpoch <= _currentEpoch());
        // claim all confirmed delegator fees including undelegates
        _claimDelegatorRewardsAndPendingUndelegates(
            validatorAddress,
            msg.sender,
            beforeEpoch
        );
    }

    function _safeTransferWithGasLimit(
        address payable recipient,
        uint256 amount
    ) internal {
        (bool success, ) = recipient.call{
            value: amount,
            gas: TRANSFER_GAS_LIMIT
        }("");
        require(success, "fail transfer");
    }

    function _unsafeTransfer(
        address payable recipient,
        uint256 amount
    ) internal {
        (bool success, ) = payable(address(recipient)).call{value: amount}("");
        require(success, "fail transfer");
    }

    function slash(
        address validatorAddress
    ) external virtual override onlyFromSlashingIndicator {
        _slashValidator(validatorAddress);
    }

    function _sysReward(
        address validators,
        address delegator,
        uint112 money
    ) internal view returns (uint256) {
        Validator memory validator = _validatorsMap[validators];

        if (
            _nowReward < _chainConfigContract.getMaxSystemRewards() &&
            validator.status == ValidatorStatus.Active
        ) {
            if (validator.ownerAddress == delegator) {
                return
                    uint256((money * 10) / 36500) * BALANCE_COMPACT_PRECISION;
            }
            
            if (money / 1e6 >= 50000) {
                return uint256((money * 4) / 36500) * BALANCE_COMPACT_PRECISION;
            } else {
                return uint256((money * 3) / 36500) * BALANCE_COMPACT_PRECISION;
            }
        }

        return 0;
    }

    function _slashValidator(address validatorAddress) internal {
        // make sure validator exists
        Validator memory validator = _validatorsMap[validatorAddress];
        require(validator.status != ValidatorStatus.NotFound, "not found");
        uint64 epoch = _currentEpoch();
        // increase slashes for current epoch
        ValidatorSnapshot storage currentSnapshot = _touchValidatorSnapshot(
            validator,
            epoch
        );
        uint32 slashesCount = currentSnapshot.slashesCount + 1;
        currentSnapshot.slashesCount = slashesCount;
        // validator state might change, lets update it
        _validatorsMap[validatorAddress] = validator;
        // if validator has a lot of misses then put it in jail for 1 week (if epoch is 1 day)
        if (slashesCount == _chainConfigContract.getFelonyThreshold()) {
            validator.jailedBefore =
                _currentEpoch() +
                _chainConfigContract.getValidatorJailEpochLength();
            validator.status = ValidatorStatus.Jail;
            _removeValidatorFromActiveList(validatorAddress);
            _validatorsMap[validatorAddress] = validator;
            emit ValidatorJailed(validatorAddress, epoch);
        }
        emit ValidatorSlashed(validatorAddress, slashesCount, epoch);
    }
}
