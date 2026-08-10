# LLMBattle local Anvil demo

This harness runs the validator-judged debate POC end to end on an isolated localhost Anvil chain. It is an
application deployment demo, not a replacement for Gravity consensus or the production validator contracts.

## Quick start

```bash
./scripts/llm-battle/run_local_demo.sh all
```

The command:

1. starts Anvil on `127.0.0.1:8547`;
2. deploys local Staking and ValidatorManagement adapters plus `LLMBattle`;
3. creates and funds a Rust-vs-Zig battle;
4. submits all three debate rounds;
5. snapshots four validators and commits votes;
6. advances local time, reveals a default `3-1` result, resolves, and withdraws every payout.

Anvil stays up after a successful run so the deployment can be inspected or reused. Stop only the managed process
with:

```bash
./scripts/llm-battle/run_local_demo.sh stop
```

For CI-style cleanup, use:

```bash
LLM_BATTLE_KEEP_ANVIL=0 ./scripts/llm-battle/run_local_demo.sh all
```

## Play another topic

The `play` action reuses the deployed arena and creates another battle. Content, vote split, and rewards are inputs,
not hard-coded deployment behavior:

```bash
LLM_BATTLE_QUESTION="Tabs or spaces: which one leads to civilization?" \
LLM_BATTLE_POSITION_A="Tabs" \
LLM_BATTLE_POSITION_B="Spaces" \
LLM_BATTLE_VOTES="2,1,2,2" \
./scripts/llm-battle/run_local_demo.sh play
```

Vote codes are `1 = SideA` and `2 = SideB`. Other useful inputs include:

- `LLM_BATTLE_WINNER_PRIZE_WEI`
- `LLM_BATTLE_JUROR_POOL_WEI`
- `LLM_BATTLE_A_OPENING`, `LLM_BATTLE_B_OPENING`
- `LLM_BATTLE_A_REBUTTAL`, `LLM_BATTLE_B_REBUTTAL`
- `LLM_BATTLE_A_FINISHER`, `LLM_BATTLE_B_FINISHER`
- `LLM_BATTLE_PORT` and `LLM_BATTLE_CHAIN_ID`

Generated state is written under `deployments/llm-battle/` and intentionally ignored by Git.

## Module boundaries

| Module | Responsibility |
| --- | --- |
| `LocalBattleInfrastructure.sol` | Demo-only validator membership and voter delegation |
| `01_DeployLLMBattleLocal.s.sol` | Deploy dependencies and write the deployment artifact |
| `02_CreateLLMBattleLocal.s.sol` | Create/fund a battle, submit rounds, lock the jury snapshot |
| `03_CommitLLMBattleVotes.s.sol` | Produce validator vote commitments |
| `04_RevealResolveLLMBattle.s.sol` | Reveal, resolve, claim juror rewards, withdraw escrow |
| `run_local_demo.sh` | Local process lifecycle and Anvil time travel only |

The separation is deliberate: new topics and argument styles are data; alternative UI or agent-driven contenders can
call the same contract; new vote/reward mechanics can become new application contracts or policy modules without
rewriting the Anvil lifecycle.

The demo salts are deterministic so the run is reproducible. They are not secret and must never be copied into a real
commit-reveal client. A production client must generate and protect a random salt until reveal time.
