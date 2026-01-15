// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import {
    StakePosition,
    ValidatorStatus,
    ValidatorConsensusInfo,
    ValidatorRecord,
    ProposalState,
    Proposal
} from "../../../src/foundation/Types.sol";

/// @title TypesTest
/// @notice Unit tests for Types definitions
/// @dev These tests primarily verify that types compile correctly and can be used as expected.
///      All timestamps in tests use microseconds (1 second = 1_000_000 microseconds).
contract TypesTest is Test {
    // Microsecond conversion factor
    uint64 internal constant MICRO = 1_000_000;

    // Example timestamps in microseconds (Nov 2023)
    uint64 internal constant TIMESTAMP_NOV_2023 = 1_700_000_000 * MICRO; // ~1.7e15
    uint64 internal constant TIMESTAMP_OCT_2023 = 1_699_000_000 * MICRO;
    uint64 internal constant TIMESTAMP_DEC_2023 = 1_701_000_000 * MICRO;
    uint64 internal constant ONE_DAY_MICROS = 86_400 * MICRO;

    // ========================================================================
    // StakePosition Tests
    // ========================================================================

    function test_StakePosition_Creation() public pure {
        uint64 lockedUntil = 1_700_000_000 * MICRO; // Nov 2023 in microseconds
        uint64 stakedAt = 1_699_000_000 * MICRO; // Oct 2023 in microseconds

        StakePosition memory pos = StakePosition({ amount: 1000 ether, lockedUntil: lockedUntil, stakedAt: stakedAt });

        assertEq(pos.amount, 1000 ether);
        assertEq(pos.lockedUntil, lockedUntil);
        assertEq(pos.stakedAt, stakedAt);
    }

    function test_StakePosition_DefaultValues() public pure {
        StakePosition memory pos;

        assertEq(pos.amount, 0);
        assertEq(pos.lockedUntil, 0);
        assertEq(pos.stakedAt, 0);
    }

    function testFuzz_StakePosition(
        uint256 amount,
        uint64 lockedUntil,
        uint64 stakedAt
    ) public pure {
        StakePosition memory pos = StakePosition({ amount: amount, lockedUntil: lockedUntil, stakedAt: stakedAt });

        assertEq(pos.amount, amount);
        assertEq(pos.lockedUntil, lockedUntil);
        assertEq(pos.stakedAt, stakedAt);
    }

    // ========================================================================
    // ValidatorStatus Tests
    // ========================================================================

    function test_ValidatorStatus_Values() public pure {
        assertEq(uint8(ValidatorStatus.INACTIVE), 0);
        assertEq(uint8(ValidatorStatus.PENDING_ACTIVE), 1);
        assertEq(uint8(ValidatorStatus.ACTIVE), 2);
        assertEq(uint8(ValidatorStatus.PENDING_INACTIVE), 3);
    }

    function test_ValidatorStatus_Casting() public pure {
        ValidatorStatus status = ValidatorStatus.ACTIVE;
        uint8 statusValue = uint8(status);
        assertEq(statusValue, 2);

        ValidatorStatus reconstructed = ValidatorStatus(statusValue);
        assertEq(uint8(reconstructed), uint8(status));
    }

    // ========================================================================
    // ValidatorConsensusInfo Tests
    // ========================================================================

    function test_ValidatorConsensusInfo_Creation() public pure {
        bytes memory pubkey = hex"aabbccdd";
        bytes memory pop = hex"11223344";
        bytes memory networkAddrs = hex"55667788";
        bytes memory fullnodeAddrs = hex"99aabbcc";

        ValidatorConsensusInfo memory info = ValidatorConsensusInfo({
            validator: address(0x1234),
            consensusPubkey: pubkey,
            consensusPop: pop,
            votingPower: 1000,
            validatorIndex: 5,
            networkAddresses: networkAddrs,
            fullnodeAddresses: fullnodeAddrs
        });

        assertEq(info.validator, address(0x1234));
        assertEq(info.consensusPubkey, pubkey);
        assertEq(info.consensusPop, pop);
        assertEq(info.votingPower, 1000);
        assertEq(info.validatorIndex, 5);
        assertEq(info.networkAddresses, networkAddrs);
        assertEq(info.fullnodeAddresses, fullnodeAddrs);
    }

    // ========================================================================
    // ValidatorRecord Tests
    // ========================================================================

    function test_ValidatorRecord_Creation() public pure {
        ValidatorRecord memory record = _createDefaultValidatorRecord();

        assertEq(record.validator, address(0x1234));
        assertEq(record.moniker, "TestValidator");
        assertEq(uint8(record.status), uint8(ValidatorStatus.ACTIVE));
        assertEq(record.bond, 1000 ether);
        assertEq(record.feeRecipient, address(0x5678));
        assertEq(record.pendingFeeRecipient, address(0));
        assertEq(record.stakingPool, address(0));
        assertEq(record.validatorIndex, 0);
    }

    function test_ValidatorRecord_AllStatuses() public pure {
        ValidatorRecord memory record = _createDefaultValidatorRecord();

        // Test all status transitions
        record.status = ValidatorStatus.INACTIVE;
        assertEq(uint8(record.status), 0);

        record.status = ValidatorStatus.PENDING_ACTIVE;
        assertEq(uint8(record.status), 1);

        record.status = ValidatorStatus.ACTIVE;
        assertEq(uint8(record.status), 2);

        record.status = ValidatorStatus.PENDING_INACTIVE;
        assertEq(uint8(record.status), 3);
    }

    // ========================================================================
    // ProposalState Tests
    // ========================================================================

    function test_ProposalState_Values() public pure {
        assertEq(uint8(ProposalState.PENDING), 0);
        assertEq(uint8(ProposalState.SUCCEEDED), 1);
        assertEq(uint8(ProposalState.FAILED), 2);
        assertEq(uint8(ProposalState.EXECUTED), 3);
        assertEq(uint8(ProposalState.CANCELLED), 4);
    }

    // ========================================================================
    // Proposal Tests
    // ========================================================================

    function test_Proposal_Creation() public pure {
        uint64 creationTime = TIMESTAMP_NOV_2023;
        uint64 expirationTime = TIMESTAMP_NOV_2023 + ONE_DAY_MICROS; // 1 day voting period

        Proposal memory prop = Proposal({
            id: 1,
            proposer: address(0x1234),
            executionHash: keccak256("execute"),
            metadataUri: "ipfs://QmTest",
            creationTime: creationTime,
            expirationTime: expirationTime,
            minVoteThreshold: 1000 ether,
            yesVotes: 0,
            noVotes: 0,
            isResolved: false,
            resolutionTime: 0
        });

        assertEq(prop.id, 1);
        assertEq(prop.proposer, address(0x1234));
        assertEq(prop.executionHash, keccak256("execute"));
        assertEq(prop.metadataUri, "ipfs://QmTest");
        assertEq(prop.creationTime, creationTime);
        assertEq(prop.expirationTime, expirationTime);
        assertEq(prop.minVoteThreshold, 1000 ether);
        assertEq(prop.yesVotes, 0);
        assertEq(prop.noVotes, 0);
        assertEq(prop.isResolved, false);
        assertEq(prop.resolutionTime, 0);
    }

    function test_Proposal_VoteAccumulation() public pure {
        Proposal memory prop = _createDefaultProposal();

        // Simulate voting
        prop.yesVotes += 500 ether;
        prop.noVotes += 200 ether;

        assertEq(prop.yesVotes, 500 ether);
        assertEq(prop.noVotes, 200 ether);
        assertTrue(prop.yesVotes > prop.noVotes);
    }

    function test_Proposal_Resolution() public pure {
        Proposal memory prop = _createDefaultProposal();

        uint64 resolutionTime = TIMESTAMP_NOV_2023 + (2 * ONE_DAY_MICROS); // Resolved 2 days after creation
        prop.isResolved = true;
        prop.resolutionTime = resolutionTime;

        assertTrue(prop.isResolved);
        assertEq(prop.resolutionTime, resolutionTime);
    }

    // ========================================================================
    // Array Tests (ensure structs can be properly stored in arrays)
    // ========================================================================

    function test_StakePosition_InArray() public pure {
        StakePosition[] memory positions = new StakePosition[](2);

        positions[0] =
            StakePosition({ amount: 100 ether, lockedUntil: TIMESTAMP_NOV_2023, stakedAt: TIMESTAMP_OCT_2023 });

        positions[1] =
            StakePosition({ amount: 200 ether, lockedUntil: TIMESTAMP_DEC_2023, stakedAt: TIMESTAMP_NOV_2023 });

        assertEq(positions[0].amount, 100 ether);
        assertEq(positions[0].lockedUntil, TIMESTAMP_NOV_2023);
        assertEq(positions[1].amount, 200 ether);
        assertEq(positions[1].lockedUntil, TIMESTAMP_DEC_2023);
    }

    // ========================================================================
    // Helper Functions
    // ========================================================================

    function _createDefaultValidatorRecord() internal pure returns (ValidatorRecord memory) {
        return ValidatorRecord({
            validator: address(0x1234),
            moniker: "TestValidator",
            status: ValidatorStatus.ACTIVE,
            bond: 1000 ether,
            consensusPubkey: hex"aabbccdd",
            consensusPop: hex"11223344",
            networkAddresses: hex"",
            fullnodeAddresses: hex"",
            feeRecipient: address(0x5678),
            pendingFeeRecipient: address(0),
            stakingPool: address(0),
            validatorIndex: 0
        });
    }

    function _createDefaultProposal() internal pure returns (Proposal memory) {
        return Proposal({
            id: 1,
            proposer: address(0x1234),
            executionHash: keccak256("execute"),
            metadataUri: "ipfs://QmTest",
            creationTime: TIMESTAMP_NOV_2023,
            expirationTime: TIMESTAMP_NOV_2023 + ONE_DAY_MICROS,
            minVoteThreshold: 1000 ether,
            yesVotes: 0,
            noVotes: 0,
            isResolved: false,
            resolutionTime: 0
        });
    }
}

