# Findings — Live Bug Clusters

5 live-bug cluster 已被动态 PoC（`forge test` on main @ `a623eab`）确认可触发，共覆盖 **11 条 gravity-audit issue**。每 cluster 一节，结构：Exploit path / 当前 main 代码证据 / PoC 复现 / Fix 建议。

所有 `src/...:line` 引用指 `gravity_chain_core_contracts` @ `a623eab`。所有 PoC 路径指本目录 `poc/<N>/`。

---

## Cluster A — EpochConfig `setForNextEpoch` 无上限 → 永久 chain halt

**Severity**: Critical
**Issues**: #476, #472, #452, #439, #397 (5 条 near-duplicate)
**PoC**: [`poc/476/`](./poc/476/) — `forge test` **PASS**

### Exploit chain

1. 恶意 governance 提案调用 `EpochConfig.setForNextEpoch(type(uint64).max)`
2. 下一个 epoch boundary，`Reconfiguration._applyReconfiguration()` → `EpochConfig.applyPendingConfig()` 把 `epochIntervalMicros` 设成 `uint64.max`
3. 再下一 block，`Blocker.onBlockStart()` → `Reconfiguration.checkAndStartTransition()` → `_canTransition()` 计算 `lastReconfigurationTime + epochInterval` 在 `uint64` checked arithmetic 下 **Panic(0x11)**
4. Blocker 对 `checkAndStartTransition` **无 try/catch** → 每个 block prologue revert → 永久 chain halt
5. 治理恢复需要 block 推进，但 block 推进被 halt 本身阻断 → **无 on-chain recovery**

### 当前 main 证据

- `src/runtime/EpochConfig.sol:99-113` `setForNextEpoch` 只 reject `== 0`，无 MAX 检查
- `src/runtime/EpochConfig.sol:122-138` `applyPendingConfig` unconditionally latches pending value
- `src/blocker/Reconfiguration.sol:215-219` `_canTransition` 返回 `currentTime >= lastReconfigurationTime + epochInterval`，无 `unchecked` block
- `src/blocker/Blocker.sol:109-112` 调用 `checkAndStartTransition()` 无 try/catch
- repo-wide grep `MAX_EPOCH_INTERVAL` 零匹配

### PoC 复现

```bash
cd audit-recheck/poc/476 && forge test -vv
# [PASS] test_chainHaltExploitIsLive (gas: 37736)
# vm.expectRevert(stdError.arithmeticError) 匹配到 ExcessiveLockupDuration / Panic(0x11)
```

### Fix 建议（双层）

1. **输入侧**：`EpochConfig._validateConfig`（和它该被 `setForNextEpoch` / `initialize` 调用）加 `MAX_EPOCH_INTERVAL`（例如 7 天）。这是 Coacker 团队已经在 `StakingConfig._validateConfig` 做过的模式（见 `MAX_LOCKUP_DURATION = 4 years`）。
2. **消费侧**：`Reconfiguration._canTransition` 用 saturating arithmetic 或 early-return，即便 storage 有 pathological value，block prologue 也不 panic。

---

## Cluster B — Governance predeploy `_owner = 0x0`

**Severity**: Critical
**Issues**: #567, #559 (同根)
**PoC**: [`poc/567/`](./poc/567/) — `forge test` **PASS**

### Exploit chain

1. `genesis-tool` 以 BSC-style `insert_account_info` 部署 Governance，**只写 runtime bytecode，不执行 constructor**
2. `Ownable(initialOwner)` 从未执行 → `_owner` slot 保持 `0x0`
3. `addExecutor` 是 `onlyOwner` → 永远 revert
4. `execute` 是 `onlyExecutor`，而 `_executors` set 永远为空（addExecutor un-callable）→ 所有治理提案无法执行
5. `transferOwnership` 也是 `onlyOwner` → 无法修复
6. `renounceOwnership` 被 override 成 revert → 也无恢复路径

### 当前 main 证据

- `src/governance/Governance.sol:63-65` 构造函数是 `Ownable(initialOwner)`，没有 `initialize()` 函数
- `genesis-tool/src/execute.rs:31-54` 的 `CONTRACTS` deploy 路径只 `insert_account_info(..., AccountInfo::default())`，storage `Default::default()`
- `src/Genesis.sol:134-174` 的 `initialize` 没有 call to `SystemAddresses.GOVERNANCE`
- `src/governance/Governance.sol:85-87` `renounceOwnership` override → revert
- `test/unit/governance/Governance.t.sol:109-121` 项目自己的 unit test **显式 `vm.store` 种子 slot 0 和 slot 1** —— 测试作者承认 production path 无法自己 seed

### PoC 复现

```bash
cd audit-recheck/poc/567 && forge test -vv
# [PASS] test_attackSucceedsIfVulnerable
# 4 assertion cluster: owner==0 / addExecutor revert / transferOwnership revert / execute revert
```

### Fix 建议

**两个等价方案二选一**：
1. genesis-tool 在部署 Governance 后，对 slot 0（`_owner`）和 slot 1（`nextProposalId`）显式 `vm.store` 种子正确值
2. 给 Governance 合约加 `initialize(address owner)` 函数（类似其他 config contract 的模式），由 `Genesis.initialize` 调用

### ⚠️ Reviewer question

**gravity-reth node 在 chain start 时是否对 Genesis predeploy 做了 out-of-band state 种子？** 如果是，这个 PoC 在真实 chain 上可能不成立。需要和 node 团队确认。如果 node 没做，这是一个 critical live bug。

---

## Cluster C — Voting power live-read（非 snapshot）

**Severity**: High
**Issues**: #554
**PoC**: [`poc/554/`](./poc/554/) — `forge test` **PASS**

### Exploit chain

1. Attacker 持有 10 ETH `StakePool`
2. 创建 governance proposal（voting window 1 天）
3. Cast VoteYes 1 ETH（剩 9 ETH 票）
4. 调用 `StakePool.addStake{value: 90 ETH}` → `activeStake = 100 ETH`；`lockedUntil` 自动延长至覆盖 `expirationTime`
5. `Governance.getRemainingVotingPower` 是 **live read** → 返回 99 ETH
6. Cast 第二次 VoteYes 99 ETH → `yesVotes = 100 ETH`
7. 结果：单个 10 ETH 持仓者实际投出 100 ETH 票，违反 EC4/C10 invariant

### 当前 main 证据

- `src/governance/Governance.sol:178-197` `getRemainingVotingPower` → `_staking().getPoolVotingPower(stakePool, p.expirationTime)` 是 live read
- `src/governance/Governance.sol:276-337` `createProposal` 只做 proposer stake 检查，不 snapshot 任何 per-pool power
- `src/staking/StakePool.sol:675-708` `_getEffectiveStakeAt(atTime)` 用**当前** `activeStake`，仅守 `lockedUntil >= atTime`
- `src/staking/StakePool.sol:405-427` `addStake` 无 governance-aware 约束，auto-extend `lockedUntil = max(current, now + lockupDuration)`
- `usedVotingPower` 只累加 cast 的量，没有上限 check（上限由 `getRemainingVotingPower` 的 live read 决定）

### PoC 复现

```bash
cd audit-recheck/poc/554 && forge test -vv
# [PASS] test_attackSucceedsIfVulnerable
# yesVotes final: 100000000000000000000  ← 100 ETH voted
# usedVotingPower final: 100000000000000000000
```

### Fix 建议

`createProposal` 时为每个 pool 记录 `powerSnapshot[proposalId][pool] = getPoolVotingPower(pool, expirationTime)`，`_voteInternal` 以此 snapshot 为上限而不是 live read。或者采用 checkpoint pattern（OpenZeppelin `ERC20Votes`-style）。

---

## Cluster D — JWKManager `_regeneratePatchedJWKs` O(n²) → 永久 DoS

**Severity**: High
**Issues**: #494, #444, #579（同根，不同角度写法）
**PoC**: [`poc/494/`](./poc/494/) — `forge test` **PASS** with gas measurements

### Exploit chain

1. oracle 正常运作会累加 `_observedIssuers`（append-only，无 shrink API）
2. 每次 `onOracleEvent` / `setPatches` 都重跑 `_regeneratePatchedJWKs`
3. `_insertSortedIssuer` 对每个 issuer 在 `bytes`-typed storage array 做 shift insertion → O(n) SSTORE per iteration
4. 外层循环 N 次 → **Θ(n²) SSTORE**
5. 达到 `gas(N) > block gas limit` 阈值后，`NativeOracle._invokeCallback` 的 try/catch 吞 OOG，但 nonce 仍推进 → JWKManager state 冻结
6. 治理 `setPatches` 恢复也要跑同一个 O(n²) 路径 → **无 on-chain recovery**

### 当前 main 证据 + gas 测量

代码证据：
- `src/oracle/jwk/JWKManager.sol:334-359` `_regeneratePatchedJWKs` 无 cap / 无分页
- `src/oracle/jwk/JWKManager.sol:428-459` `_insertSortedIssuer` 的 shift loop
- `src/oracle/jwk/JWKManager.sol:312` `_observedIssuers.push()` 唯一写点，无删除 API
- `src/oracle/NativeOracle.sol:85` nonce 推进在 try/catch 前，`:314-325` callback OOG 被 swallow

实测 gas（跑在 main `a623eab`）:

| N issuers | Gas | Ratio vs N=10 |
|---:|---:|---:|
| 10 | 4,855,761 | 1.00× |
| 20 | 10,604,056 | 2.18× |
| 40 | 24,857,410 | 5.12× |
| **80** | **64,461,389** | **13.27×** |

Linear growth 只会 8×，实测 13.27× 且比例持续递增（2.18 → 2.34 → 2.59）→ 真 super-linear 增长，趋近 quadratic 极限 4.0。

**N=80 已超 30M block gas limit 2×** → oracle callback OOG，JWKManager 永久 brick。

### PoC 复现

```bash
cd audit-recheck/poc/494 && forge test -vv
# [PASS] test_attackSucceedsIfVulnerable (~5s)
# logs 输出 ratio_20_over_10_x100: 218 / ratio_40_over_10_x100: 511
```

### Fix 建议

**任选一个都能治标，想治本全做**：
1. `_insertSortedIssuer` 改 memory 排序再一次 SSTORE（从 Θ(n²) SSTORE 降到 O(n) SSTORE）
2. 引入 issuer cap（例如 N ≤ 32），或 issuer eviction/cleanup API
3. 把 regeneration 改成增量更新（仅处理 diff），不要每次全量重建

---

## Cluster E — `governanceReconfigure` 缺 cooldown → mass validator eviction

**Severity**: High (相关 issue 含 Critical 级别影响)
**Issues**: #339, #462, #473, #357
**PoC**: [`poc/339/`](./poc/339/) — `forge test` **PASS**

### Exploit chain

1. 治理 proposal 在一个 `execute()` batch 里连续调用 `Reconfiguration.governanceReconfigure()` 两次
2. 第一次：state 从 Idle 走完一轮 reconfigure，`_transitionState` 重置为 Idle；`PerformanceTracker.onNewEpoch(newValidatorCount)` **把所有 validator 的 performance counter 归零**
3. 第二次：只守 `DkgInProgress` 的检查（Idle → 通过），没有 `_canTransition()` / cooldown / 时间守卫；直接调 `evictUnderperformingValidators`
4. Eviction 读到 **全零的 performance** → 触发 `total == 0` 的 `shouldEvict = true` unconditional branch → 所有 active validator 被标记 evict
5. `_applyDeactivations` 在同 tx 内降 `N-1` 个 validator 到 `INACTIVE`（`remainingActive > 1` 守卫留最后 1 个避免彻底 halt）

### 当前 main 证据

- `src/blocker/Reconfiguration.sol:141-166` `governanceReconfigure` 只守 `requireAllowed(GOVERNANCE)` + `_requireInitialized` + `DkgInProgress != 进行中`
- `src/blocker/Reconfiguration.sol:215-219` 的 `_canTransition`（时间守卫）**没有被 `governanceReconfigure` 调用**（只有 `checkAndStartTransition` 调用）
- `src/blocker/Reconfiguration.sol:265-296` `_applyReconfiguration` 重置 `_transitionState = Idle`
- `src/blocker/PerformanceTracker.sol:101-116` `onNewEpoch` 零化 performance 数组
- `src/staking/ValidatorManagement.sol:694-723` `evictUnderperformingValidators` 有 `total == 0 → shouldEvict = true` 的无条件 branch (lines 701-703)
- `src/governance/Governance.sol:482-536` `execute` 循环 targets 无 dedup → 一个 batch 连续调 N 次

### PoC 复现

```bash
cd audit-recheck/poc/339 && forge test -vv
# [PASS] test_attackSucceedsIfVulnerable (gas: 540585)
# 4 active validators 被降至 1
# Total voting power: 400 ETH → 100 ETH
```

注意 PoC 使用 MockStaking 简化部署（真实 Staking+StakePool 不影响 eviction path，只是 PoC setup 更简洁）。核心断言（`_activeValidators.length` 从 4 变 1，`_pendingInactive` / `INACTIVE` 状态）直接针对 `ValidatorManagement` state。

### Fix 建议

**两个独立修复，都加更稳**：
1. `governanceReconfigure` 加 cooldown：要么调 `_canTransition()`，要么加 `lastGovernanceReconfigureTime + MIN_COOLDOWN` 检查
2. `evictUnderperformingValidators` 的 `total == 0` 分支不应该无条件 `shouldEvict = true`；应该 return / skip（因为 "0 total proposals" 通常意味着新一轮刚开始，没有 performance 数据）

---

## Ground-truth reference — Cluster F: #273 `renewLockUntil` A/B 对照

**Status**: Already fixed in main (`status: fixed-on-main` label)
**PoC**: [`poc/273/`](./poc/273/)

这 **不是** live bug，而是方法论校准的参考点。

- 在旧 commit `27b22c3`（tag `gravity-testnet-v1.0.0`）：PoC PASS，`lockedUntil` 被 attacker 单笔推到 `uint64.max-1`，funds 锁 584,910 年
- 在 main `a623eab`：PoC FAIL，被 `MAX_LOCKUP_DURATION = 4 years` 检查阻断（`src/staking/StakePool.sol:461-463`）

**reviewer 如果想重现**：
```bash
cd audit-recheck/poc/273
forge test -vv  # on main → FAIL (fix works)

# 切到旧 commit：
(cd ../../../ && git checkout 27b22c3)
forge clean && forge test -vv  # now → PASS (attack works on old code)

# 务必切回 main：
(cd ../../../ && git checkout main)
```

---

## 静态 EXISTS — 尚未 PoC

下列是 Auditor agent 判为 EXISTS 但尚未跑 dynamic PoC 确认的 issue。顺序按 severity 排。

### High severity（3 条 — 应该补 PoC）

| # | 一句话 | 备注 |
|---|---|---|
| **#301** | `GBridgeSender.bridgeToGravityWithPermit` 的 permit 调用无 try/catch，mempool 里任何人可抢跑签名消耗 nonce，持续 DoS 目标 bridging 行为 | 经典 permit front-running。PoC 容易写 |
| **#367** | Genesis `_initializeGenesisValidator` 故意跳过 BLS PoP 精度校验（"precompile may not be available at genesis"），但 spec v2 说应有 PoP check → 实现/spec 偏离，pubkey squatting 风险 | 需要 genesis 模拟 |
| **#420** | `Governance.removeExecutor` 无 min-count 守卫；owner 可 remove 到空 executor set → `execute` 永久 un-callable。当前 Genesis 没把 owner 配成自治（`#421` 是同 cluster，因为非自治配置被判为 PARTIAL），但自治化升级后会激活 | PoC 需要自治场景 |

### Medium severity（7 条）

| # | 一句话 | 备注 |
|---|---|---|
| **#532** | `ConsensusConfig.setForNextEpoch` opaque bytes 无 BCS 格式验证，恶意 payload 可在 epoch 边界阻塞 off-chain consensus/VM | on-chain 无法二值化 |
| **#555** | Governance 绝对 `minVotingThreshold` 可以高于总 voting power → 永久无法达成 quorum；config 改 proposal 自己也需要 quorum → 鸡生蛋 | 依赖 config 值，med confidence |
| **#560** | `Genesis ValidatorManagement.initialize` 跳过 `IStaking.isPool` 检查，non-pool 地址（EOA / 外 contract）可被写入 `_validators[]` → reconfig 时走 `getPoolVotingPower` 调用 `onlyValidPool` → revert → 永久 epoch DoS | **可能应该升为 High**。PoC 可写 |
| **#562** | `Reconfiguration.initialize` 在 Timestamp 未 set 时读取 → `lastReconfigurationTime = 0`；第一 block `realTime >= 0 + epochInterval` 恒为 true → 第一个 block 就立即触发 epoch reconfiguration（包括 validator eviction） | Genesis ordering hazard |
| **#563** | `NativeOracle` / `JWKManager` 的 state-mutating 函数**无 `_requireInitialized`** 守卫，而同 repo 所有 config contract 都有 → 在 empty `sourceTypes` / empty `issuers` 启动时 contract `_initialized=false` 但仍可写入 | 一致性 gap |
| **#569** | `SystemAddresses.ORACLE_REQUEST_QUEUE = 0x1625F4002` 在 `SystemAddresses.sol` 保留，但 **genesis-tool 的 CONTRACTS 数组里缺失** → address 在 genesis 后是 zero-code EOA；目前 `src` 里无 caller 所以是 latent | 同 Cluster B 机制 |
| **#577** | ⭐ **"half-fix" 发现** — `StakingConfig._validateConfig` 为 `lockupDurationMicros`（4 年）和 `unbondingDelayMicros`（1 年）加了 MAX 上限，**但 `_minimumStake` 没加** → 治理仍可 `setForNextEpoch(type(uint256).max, ...)` DoS 所有 `createPool` | 静态扫描才能发现的残缺修复 |

---

## PARTIAL（6 条）

| # | Severity | Primary fixed | Residual live |
|---|---|---|---|
| #297 | High | `execute()` 补了 `ProposalNotResolved` guard | 二级观察（atomicity guard 其实是 dead code）为真但不可利用 |
| #421 | High | 自治场景才 High | 当前 owner 是 EOA → 降级 Low |
| #503 | High | uint64 overflow 被 `^0.8.30` checked-arith 阻断 | `interval=1` 的正 live（每块都 thrash reconfigure）|
| #572 | Medium | `setVoter` 改为 2-step timelock（1 day） | `votingDurationMicros > 1 day` 场景下仍可 mid-vote 切换 voter，重新分配剩余 voting budget |
| #574 | Medium | eviction 顺序调整，新 validator 有 1 epoch 缓冲 | "performance=0 → 立即 evict" 的 surface 仍在，只是窗口变了 |
| #577 | Medium | `lockupDuration` / `unbondingDelay` 加了 MAX | `_minimumStake` 没加 — 治理仍可 DoS createPool（详见上表）|

---

## NOT_EXISTS（33 条）

详见 [`VERDICTS.md`](./VERDICTS.md) 完整表格。主要分两类：
- **已修 (`hint: fixed`)**：明确 commit 修复，Auditor 能引用到具体 guard / refactor
- **本就 FP (`hint: fp`)**：issue 描述逻辑上不成立（如 #395 被输入域约束反驳、#491 被 EVM atomicity 反驳、#507 在 trust model 内是正常行为、#573 unstake 不 actually 降低 voting power 等）

每条的详细 reasoning 看 [`verdicts/auditor_<N>.json`](./verdicts/) 的 `reasoning_chain` 和 `key_evidence` 字段。
