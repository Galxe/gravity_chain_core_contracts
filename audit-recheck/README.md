# Audit Recheck — Coacker AI Audit 二次审查产出

这是针对 `Galxe/gravity-audit` 中 500 条候选漏洞 issue 的二次审查中期产出，**只覆盖 `gravity_chain_core_contracts` 子集（271 条）**。

## TL;DR

- 已扫 **64 / 271** 条（24%），**全部 Critical (7) + 全部 High (34) + 部分 Medium/Low (23)**。
- 静态 Auditor 给出：**25 EXISTS / 6 PARTIAL / 33 NOT_EXISTS**。
- 其中 **5 个 live-bug cluster（去重后 11 条 issue）已经用 foundry 动态 PoC 在 `main` (`a623eab`) 上跑通 attack**，不是静态推理。
- 方法校准：9 条 ground truth（含 1 条 PoC 独立确认的 live bug）盲测，**Auditor agent 9/9 verdict 匹配**。

## 文档入口

| 文件 | 用途 |
|---|---|
| [`REPORT.md`](./REPORT.md) | 方法 + 结果 + 关键发现，**reviewer 从这里开始** |
| [`FINDINGS.md`](./FINDINGS.md) | 6 个 cluster 的逐条详细 writeup（5 live + 1 A/B 对照）|
| [`VERDICTS.md`](./VERDICTS.md) | 64 条完整分桶表（severity × verdict × hint）|
| [`verdicts/`](./verdicts/) | 每条 issue 的结构化 JSON verdict（含 data-flow trace + 证据）|
| [`poc/`](./poc/) | 6 个独立 foundry PoC project |

## 如何验证 PoC（reviewer）

**前置**（首次跑一次）：在 repo 根目录跑 `npm install`（或 `yarn install`），确保 `node_modules/@openzeppelin/contracts` 和 `node_modules/forge-std` 到位。PoC 通过 symlink `lib/node_modules -> ../../../../node_modules` 引用。

每个 `poc/<N>/` 是独立 foundry project，`cd` 进去直接跑：

```bash
cd audit-recheck/poc/476 && forge test -vv
# Ran 1 test: [PASS] test_chainHaltExploitIsLive
```

所有 **5 个 live-bug PoC 在 `main` 上 PASS**：

| PoC | Issues covered | Verdict | 代表影响 |
|---|---|---|---|
| `poc/476/` | #476 #472 #452 #439 #397 | PASS | EpochConfig overflow → chain halt（Panic(0x11) 被触发）|
| `poc/567/` | #567 #559 | PASS | Governance predeploy `_owner=0` → 治理永久 un-callable |
| `poc/554/` | #554 | PASS | Voting power live-read → 10 ETH pool 可投 100 ETH 票 |
| `poc/494/` | #494 #444 #579 | PASS | JWKManager O(n²) gas → N=80 时 64M gas 超 30M block limit |
| `poc/339/` | #339 #462 #473 #357 | PASS | `governanceReconfigure` 无 cooldown → 4 validators 降至 1 |

**`poc/273/`** 是 ground-truth A/B 对照案例：在旧 commit `27b22c3` PoC PASS（attack 成功），在 `main` PoC FAIL（fix 生效阻断）。这个 PoC 用来方法论校准，不是证明 live bug。

## 工作区 & 方法说明

完整的 pipeline 工作区（orchestrator、prompt 模板、原始 500 条 issue、262 条扫描清单等）在 Coacker repo：

```
/home/kenji/galxe/Coacker/.audit-recheck/
├── data/pilot/              # 64 条 issue input / verdicts / summary
├── poc/PIPELINE.md          # PoC 流程沉淀
└── poc/{273,339,476,494,554,567}/  # 每个 PoC 的原始开发工作区
```

本 PR 是**对外可 review 的归档**：只携带 reviewer 需要复现的最小产物（PoC + docs + structured verdicts）。

## 还没做的

1. **207 条 medium/low 未扫**（150 medium + 57 low）—— 估计还需 3-4h 工作跑完。
2. **14 条静态 EXISTS 没补 PoC**，其中 3 条 high severity 值得补（#301 / #367 / #420）。
3. **Reviewer 对抗式独立复核**省略（pilot 9/9 后决定）。

见 `REPORT.md` §7 详细清单。
