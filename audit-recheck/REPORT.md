# Gravity-Audit 二次审查 — 中期审查报告

**报告时间**：2026-04-20
**审查对象**：`Galxe/gravity-audit` 500 条 issue 中归属 `Galxe/gravity_chain_core_contracts` 的 271 条 contracts 子集
**对照代码**：`gravity_chain_core_contracts` main branch, commit `a623eab` (2026-04-17)
**扫描工作区**：`/home/kenji/galxe/Coacker/.audit-recheck/`

---

## 1. 执行摘要

已完成 **64/271 条（24%）** 的二次审查，覆盖**全部 Critical (7/7) 和全部 High (34/34)** severity，以及部分 Medium (21/171) 和 Low (2/59)。

### 分桶结果（64 条）

| 分类 | 数量 | 证据级别 |
|---|---|---|
| **EXISTS**（漏洞仍在）| **25** | 其中 **11 条**经 forge test 动态 PoC 确认可触发 |
| **PARTIAL**（部分修 / 部分 live）| **6** | 静态分析 |
| **NOT_EXISTS**（已修 or 本就 FP）| **33** | 静态分析，其中 9 条在 pilot 阶段匹配 ground truth |

### 动态 PoC 已确认可触发的 **5 个 live-bug cluster**（共 11 条 issue）

这 5 个 cluster 的 `forge test` 都**实际跑通了 attack**，不是静态推理。

---

## 2. 扫描进度（按 severity）

| Severity | 总数 | 已扫 | 剩余 | 覆盖率 |
|---|---|---|---|---|
| Critical | 7 | **7** | 0 | **100%** |
| High | 34 | **34** | 0 | **100%** |
| Medium | 171 | 21 | 150 | 12% |
| Low | 59 | 2 | 57 | 3% |
| **Total** | **271** | **64** | **207** | **24%** |

> 剩 207 条均为 medium/low。核心 live bug 已经捕获。

---

## 3. 方法论

### 静态 Auditor（每 issue 1 个 agent）

- 硬约束：对 issue `Data Flow` 每一步走进代码独立验证，产出结构化 JSON verdict
- 每步必须包含 `src/...:line_range` 引用
- 必须产出 `counterargument`（对自己结论的反驳）
- 扫描时 agent **看不到** `status:` label（blind judgment）

### 动态 PoC（foundry）

- 对 EXISTS + severity ≥ High 自动触发
- 每条 PoC 独立 foundry project（`.audit-recheck/poc/<N>/`）
- 复用 gravity_core src 通过 symlink，不污染原 repo
- `forge test` PASS = attack 在本地 EVM 实际复现

### 方法校准

在跑真实任务前，用 **9 条 ground truth**（6 `fixed-on-main` + 2 `false-positive` + 1 PoC-verified #476 live bug）做盲测：

- **Verdict 一致率：9/9**
- **fp/fixed 语义 hint 匹配率：8/9**（唯一分歧 #401 是"删除式 fix"vs"本就 FP"的分类差异，两者都对应 NOT_EXISTS）

校准后 pipeline 直接全量跑，省去 Reviewer 阶段。

---

## 4. EXISTS 清单（按证据级别 + severity）

### 4.1 🔴 已 PoC confirmed — 可触发的 live bugs

#### Cluster A — EpochConfig `setForNextEpoch` 无上限 → 永久 chain halt
- **Severity**：Critical
- **Issues**：#476, #472, #452, #439, #397（5 条 near-duplicate）
- **PoC**：`.audit-recheck/poc/476/` — `forge test` PASS
- **Observed**：governance 设 `epochIntervalMicros = uint64.max` → `applyPendingConfig` 接受 → 下一 block `_canTransition` 计算 `lastReconfigurationTime + epochInterval` 触发 `Panic(0x11)` → Blocker.onBlockStart 无 try/catch → 永久 chain halt
- **Fix 建议**：`EpochConfig._validateConfig` 加 `MAX_EPOCH_INTERVAL`；`Reconfiguration._canTransition` 加 saturating arithmetic 作为二道防线

#### Cluster B — Governance predeploy `_owner = 0x0`
- **Severity**：Critical
- **Issues**：#567, #559（同根）
- **PoC**：`.audit-recheck/poc/567/` — `forge test` PASS
- **Observed**：genesis-tool 以 BSC-style `insert_account_info` 部署 Governance 只写 runtime bytecode 不执行 constructor → `_owner` / `nextProposalId` 全为 0 → `addExecutor` / `execute` / `transferOwnership` / `acceptOwnership` 全部 revert，治理永久 un-callable
- **Fix 建议**：genesis-tool 对 Governance 补 `vm.store` 种子 slot 0（owner）；或为 Governance 新增 `initialize(address owner)` function，由 Genesis.sol 调用
- **Caveat**：如果 gravity-reth node 在 chain start 时做了 out-of-band state override（不在此 repo），PoC 无法证伪；需要与 node 团队确认

#### Cluster C — Voting power live-read（非 snapshot）
- **Severity**：High
- **Issues**：#554
- **PoC**：`.audit-recheck/poc/554/` — `forge test` PASS
- **Observed**：10 ETH pool，vote 1 ETH → `addStake{value: 90 ETH}` → 合法续 vote 99 ETH → 累计 `yesVotes = 100 ETH > 10 ETH snapshot`。违反 EC4/C10 invariant（单人投票超过 create 时持仓）
- **Fix 建议**：`createProposal` 时为该 pool 记录 `powerSnapshot[proposalId][pool]`，后续 `getRemainingVotingPower` 以 snapshot 为上限而非 live 读

#### Cluster D — JWKManager `_regeneratePatchedJWKs` O(n²) SSTORE
- **Severity**：High
- **Issues**：#494, #444, #579（同根）
- **PoC**：`.audit-recheck/poc/494/` — `forge test` PASS
- **Observed gas**：N=10 → 4.86M / N=20 → 10.6M (2.18x) / N=40 → 24.9M (5.12x) / **N=80 → 64.5M (13.27x)**；linear 只会 8x。**N=80 已超 30M block gas limit 2×** → oracle callback OOG，NativeOracle try/catch 吞错后 nonce 仍推进 → JWKManager 永久 brick
- **Fix 建议**：`_insertSortedIssuer` 改 memory 排序再一次 SSTORE；或引入 issuer cap + 增量更新；或分页 patch

#### Cluster E — `governanceReconfigure` 无 cooldown → mass eviction
- **Severity**：Critical-ish（High 在 issue 标签）
- **Issues**：#339, #462, #473, #357
- **PoC**：`.audit-recheck/poc/339/` — `forge test` PASS
- **Observed**：4 active validators → governance 单 batch 内两次 `governanceReconfigure()` → 第一次 reset `PerformanceTracker` 到全零，第二次 `evictUnderperformingValidators` 看到全零 → 降 N-1 个到 INACTIVE。**Voting power 400 ETH → 100 ETH**
- **Fix 建议**：(a) `governanceReconfigure` 加 `_canTransition()` 或 min cooldown；(b) `evictUnderperformingValidators` 的 `total == 0` 分支不应无条件 `shouldEvict = true`

### 4.2 🟡 静态 EXISTS，尚未 PoC — 需要 review 决定优先级

#### High severity（3 条）

| # | 标题 | 备注 |
|---|---|---|
| **#301** | GBridgeSender permit 前置运行 DoS | `permit()` 无 try/catch，mempool 里签名可被第三方抢跑消耗 nonce 造成 revert |
| **#367** | Genesis validator 初始化跳过 BLS PoP 验证 | `_initializeGenesisValidator` 故意跳过 precompile（注释说"precompile may not available"），但导致 pubkey squatting 可能 |
| **#420** | `removeExecutor` 无 min-count 守卫 | 仅在 owner == address(this) 自治场景下才构成 High；当前 Genesis 不这样配置 → **PARTIAL**（同源 #421） |

#### Medium severity（7 条）

| # | 标题 | 潜在严重度升级 |
|---|---|---|
| **#532** | ConsensusConfig opaque bytes 无 BCS 验证 | off-chain 依赖，无法二值化 |
| **#555** | Governance 绝对 quorum 死锁 | config-dependent，med-confidence |
| **#560** | Genesis 跳过 `isPool` check → 永久 epoch DoS | 严重度可能应升为 High |
| **#562** | Reconfiguration init 时 Timestamp=0 | genesis ordering hazard |
| **#563** | NativeOracle/JWKManager 缺 `_requireInitialized` | 与同 repo 其他 config 不一致 |
| **#569** | ORACLE_REQUEST_QUEUE 保留地址但 genesis 不部署 | latent，同 Cluster B 机制 |
| **#580** | Consensus pubkey squatting | 同 #367 cluster |

### 4.3 🟡 PARTIAL — 部分修部分 live（6 条）

| # | Severity | 说明 |
|---|---|---|
| **#297** | High | primary（`execute` bypass resolve）已修，secondary（atomicity guard dead code）仍在但不可利用 |
| **#421** | High | 仅自治场景下 High；当前 Governance owner 是 EOA 所以 Low severity |
| **#503** | High | interval=1 DoS live；uint64 overflow 被 `^0.8.30` checked-arith 阻断 |
| **#572** | Medium | 2-step timelock 加了，但 voting > voterChangeDelay(1 day) 场景仍可利用 |
| **#574** | Medium | grace period 没加，但 eviction 顺序调整使新 validator 有 1 epoch buffer |
| **#577** | **Medium** — **"half-fix" 发现** | **config cap 对 `lockupDuration` 和 `unbondingDelay` 加了 MAX，但 `minimumStake` 没加** → attacker-governance 可 DoS 新 pool 创建 |

---

## 5. NOT_EXISTS（33 条）

这 33 条已按静态数据流 trace 被判定在 current main 不复现。大多数 hint 为 `fixed`（有明确 commit 修复），少量为 `fp`（本就不构成漏洞，如 #395 PRECISION_FACTOR / #491 EVM atomicity 反驳 / #507 trust-model FP / #573 unstake 不降 voting power / #491 Genesis 原子性）。

完整 NOT_EXISTS 列表见附录或 `.audit-recheck/data/pilot/verdicts/auditor_*.json`。

---

## 6. Cluster 全景（去重）

**19 个独立 cluster** 覆盖 25 EXISTS + 6 PARTIAL = 31 条。其中：

- ✅ **5 clusters** PoC confirmed live（11 条）
- 🟡 **3 clusters** 静态 EXISTS，可 PoC 验证（#301 / #367 / #420 high severity）
- 🆕 **5 clusters** Batch 3 新发现 medium（#301 / #569 / #562 / #560 / #577 等）
- ❓ **2 clusters** 不易二值化（#532 / #555）
- ⚠️ **4 clusters** PARTIAL

---

## 7. 还没做的工作

### 7.1 扫描未覆盖
- **207 条 medium/low** 未扫（150 medium + 57 low）
- Critical / High 全覆盖，但 medium/low 中**可能还有升级为实际 high 的 issue**（#560 就是例子，标为 medium 但实际 live 且后果严重）

### 7.2 静态 EXISTS 未补 PoC
- 14 条 EXISTS 是纯静态判决。高价值补 PoC 候选：
  - **#301**（High, GBridgeSender permit）— 应该容易写 PoC
  - **#367**（High, PoP skip）— 需要 Genesis initialize 模拟
  - **#420**（High, removeExecutor）— 需要自治场景 setup
  - **#560**（Medium 但影响极大，epoch DoS）— 值得补
- 其他 medium 按 review 优先级决定

### 7.3 跳过的阶段
- **Reviewer / Judge 对抗式第二轮审查**：pilot 9/9 通过后跳过。如果 reviewer 对某些 EXISTS 判决有怀疑，可以针对性启动
- **OPEN 但实际已修的 triage 建议**：有些 NOT_EXISTS 的 label 还是 OPEN（如 #403 label=OPEN 但实际已修），可以给 maintainer 一份"应 close"清单

---

## 8. 建议的 review 顺序

### 对 reviewer — 时间有限时按这个顺序看

1. **先看 5 个 confirmed live cluster**（第 4.1 节），每个 cluster 有 `poc_<N>.json` + `verdict.md` + forge output，15 分钟可看完一个
2. **然后看 3 个 high severity 静态 EXISTS**（#301 / #367 / #420），每条 `auditor_<N>.json` 的 `data_flow_trace` 就是 review checklist
3. **PARTIAL 6 条**（4.3）：确认各自"部分修"是否符合团队风险 tolerance
4. **33 条 NOT_EXISTS** 抽样 5% review（~2 条）做 QA drift check
5. **medium EXISTS 7 条**（4.2）— 尤其 #560 / #562 建议升级到 high severity

### 对下一步扩展 — 剩 207 条

- **继续 Batch 4+**（medium 主力批次），预计还需 10-11 批（3-4h）
- 每批完成后如有新 EXISTS + critical/high，自动触发 PoC
- 估计剩余 150 medium / 57 low 里 live bug 密度会比 high 低（~30%）

---

## 9. 产物目录结构

```
.audit-recheck/
├── data/
│   ├── issues.json                        # 全 500 条 gravity-audit issue raw
│   ├── batch_c_list.json                  # 262 条扫描清单（按 severity 降序）
│   ├── ground_truth_8.json                # pilot 校准集
│   └── pilot/
│       ├── inputs/
│       │   └── <N>.md                     # 每条 issue input（label 剥离）
│       ├── verdicts/
│       │   ├── auditor_<N>.json           # 每条 static Auditor 结构化 verdict
│       │   └── poc_<N>.json               # 每条 dynamic PoC 结构化结果
│       └── summary/
│           ├── pilot_A_report.md          # 9 条 ground truth 校准报告
│           └── review_report.md           # 本报告
└── poc/
    ├── PIPELINE.md                        # PoC 搭建 & 踩坑沉淀
    ├── 273/                               # A/B 对照（旧版 PASS / 新版 FAIL）
    ├── 339/                               # governanceReconfigure mass eviction
    ├── 476/                               # EpochConfig chain halt
    ├── 494/                               # JWK O(n²) gas 测量
    ├── 554/                               # Voting power live-read
    └── 567/                               # Governance predeploy owner=0
```

每个 `poc/<N>/` 包含：`foundry.toml`, `remappings.txt`, `lib/*` (symlinks), `test/POC_<N>.t.sol`, `results/main_a623eab.txt`, `results/verdict.md`。独立 foundry project，reviewer 可直接 `cd` 进去 `forge test` 验证。

---

## 10. 关键方法论 insight（供下次审计参考）

1. **数据流硬约束有效**：Auditor prompt 强制每步 `src/...:N-M` 引用后，9/9 校准通过，无浮于表面判决。
2. **静态 + 动态双路证据**：静态 Auditor 负责 triage 覆盖，动态 PoC 负责对高价值 issue 做地面真相确认。单 PoC 成本 ~20-40 min（含 agent 自动写 + debug），比 1 条 Auditor 贵 ~10×，所以必须筛过。
3. **#403 发现**：Pipeline 能发现 "label 未更新但实际已修"（`fixed-on-main` 标签滞后）的 issue — 对 maintainer 的 triage 工作量是显性减负。
4. **#577 发现**：静态扫能发现 "half-fix"（修了家族一部分漏了一部分），这是纯人工 triage 容易漏的类别。
5. **Cluster 合并**：271 条里有大量 near-duplicate（EpochConfig 家族 5 条、JWK O(n²) 3 条、governanceReconfigure 4 条）。Maintainer 应考虑合并管理。

---

## 11. Open questions 给 reviewer

1. **gravity-reth node 是否对 genesis predeploy 做 out-of-band state 种子？** 这决定 Cluster B（#567/#559）和 #569 是真 live bug 还是 node 层已处理的 false concern。
2. **`minimumStake` 上限应设多少合理？** #577 揭示的残缺修复，需要团队定一个 MAX。
3. **`voterChangeDelay` 与 `votingDurationMicros` 的上下限关系**？#572 的残留攻击路径依赖这俩的关系。
4. **Reviewer 是否接受 Medium severity 静态 EXISTS（未 PoC）作为 action item**？如果要全部补 PoC 还需 ~3-5h。

---

**报告结束**。欢迎 reviewer 回报修正，我会回到 pipeline 继续扫剩 207 条 medium/low，或按 reviewer 指示补 PoC。
