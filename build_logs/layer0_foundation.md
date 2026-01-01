# Layer 0: Foundation — Build Progress

**Last Updated**: 2026-01-01  
**Status**: ✅ Complete (Spec + Implementation + Tests)

---

## Overview

Layer 0 provides the foundation for all Gravity system contracts: address constants, access control, core types, and
custom errors. Zero external dependencies.

---

## Specification Status

| Document        | Status      | Location                     |
| --------------- | ----------- | ---------------------------- |
| Foundation Spec | ✅ Complete | `spec_v2/foundation.spec.md` |

---

## Implementation Status

| Contract                  | Status      | Location          | Notes                             |
| ------------------------- | ----------- | ----------------- | --------------------------------- |
| `SystemAddresses.sol`     | ✅ Complete | `src/foundation/` | Compile-time address constants    |
| `SystemAccessControl.sol` | ✅ Complete | `src/foundation/` | Free functions for access control |
| `Types.sol`               | ✅ Complete | `src/foundation/` | Core structs and enums            |
| `Errors.sol`              | ✅ Complete | `src/foundation/` | Custom errors library             |

---

## Test Status

| Test File                   | Status  | Tests                 |
| --------------------------- | ------- | --------------------- |
| `SystemAddresses.t.sol`     | ✅ Pass | 4 tests               |
| `SystemAccessControl.t.sol` | ✅ Pass | 26 tests (incl. fuzz) |
| `Types.t.sol`               | ✅ Pass | 14 tests (incl. fuzz) |
| `Errors.t.sol`              | ✅ Pass | 33 tests (incl. fuzz) |

**Total: 77 tests passed**

---

## Design Decisions Log

| Date       | Decision                                                  | Rationale                                                   |
| ---------- | --------------------------------------------------------- | ----------------------------------------------------------- |
| 2026-01-01 | Use `0x1625F2xxx` address pattern                         | Production-ready, Gravity-specific addressing               |
| 2026-01-01 | Use `SystemAddresses.sol` naming (not `GravityAddresses`) | Consistency with build plan spec                            |
| 2026-01-01 | Free functions for access control                         | More flexible than library asserts, no inheritance required |
| 2026-01-01 | New system addresses require hardfork                     | Compile-time constants cannot be changed at runtime         |
| 2026-01-01 | All timestamps use microseconds (`uint64`)                | Consistent with Aptos; use Timestamp contract internally    |

---

## Resolved Questions

| Question                   | Answer                                              |
| -------------------------- | --------------------------------------------------- |
| Address Allocation         | More addresses may be added in the future as needed |
| Address Pattern Origin     | No documentation needed                             |
| Post-Genesis Extensibility | Adding new addresses requires a **hardfork**        |

---

## Dependencies

```
Layer 0: Foundation (this layer)
    └── No dependencies

Dependents:
    ├── Layer 1: Config + Time (Timestamp, StakingConfig, ValidatorConfig)
    ├── Layer 2: Staking + Voting
    ├── Layer 3: Validator Registry
    ├── Layer 4: Block
    ├── Layer 5: Reconfiguration
    └── Layer 6: Governance
```

---

## Next Steps

1. [x] Review foundation spec with team
2. [x] Implement `SystemAddresses.sol`
3. [x] Implement `SystemAccessControl.sol`
4. [x] Implement `Types.sol`
5. [x] Implement `Errors.sol`
6. [x] Write unit tests for all foundation contracts
7. [x] Run `forge build` and fix any compilation issues
8. [x] Run `forge test` — 77 tests pass

**Layer 0 is complete. Ready to proceed to Layer 1 (Config + Time).**

---

## Changelog

### 2026-01-01

- Created foundation layer specification (`spec_v2/foundation.spec.md`)
- Established design decisions for addresses, naming, and access control patterns
- Created this progress tracking document
- Implemented all foundation contracts:
  - `src/foundation/SystemAddresses.sol` — 10 system addresses
  - `src/foundation/SystemAccessControl.sol` — 5 overloaded `requireAllowed` functions
  - `src/foundation/Types.sol` — 8 types (StakePosition, ValidatorStatus, etc.)
  - `src/foundation/Errors.sol` — 24 custom errors
- Implemented comprehensive test suite:
  - `test/unit/foundation/SystemAddresses.t.sol` — 4 tests
  - `test/unit/foundation/SystemAccessControl.t.sol` — 26 tests
  - `test/unit/foundation/Types.t.sol` — 14 tests
  - `test/unit/foundation/Errors.t.sol` — 33 tests
- All 77 tests pass
