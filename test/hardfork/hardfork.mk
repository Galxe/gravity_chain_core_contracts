SHELL := /bin/bash

# ============================================================================
# Hardfork Fixture Management & Testing
# ============================================================================
# Separated from root Makefile for cleaner organization.
# Included via `include test/hardfork/hardfork.mk` in the root Makefile.
#
# Usage:
#   make extract-fixtures TAG=gravity-testnet-v1.0.0
#   make extract-storage-layouts TAG=gravity-testnet-v1.0.0
#   make storage-diff TAG=gravity-testnet-v1.0.0 CONTRACT=StakingConfig
#   make storage-diff-all TAG=gravity-testnet-v1.0.0
#   make hardfork-test

.PHONY: extract-fixtures extract-storage-layouts storage-diff storage-diff-all hardfork-test

# System contracts that need bytecode extraction for hardfork fixtures.
FIXTURE_CONTRACTS = \
	StakingConfig ValidatorConfig Staking ValidatorManagement \
	Reconfiguration NativeOracle Blocker ValidatorPerformanceTracker \
	GovernanceConfig Governance StakePool EpochConfig ConsensusConfig \
	ExecutionConfig VersionConfig RandomnessConfig Timestamp DKG JWKManager

FIXTURE_DIR = test/hardfork/fixtures
WORKTREE_BASE = /tmp/gcc-fixture

extract-fixtures: ## Extract runtime bytecodes from a git tag (TAG=<git-tag>)
	@test -n "$(TAG)" || { echo "❌ Usage: make extract-fixtures TAG=<git-tag>"; exit 1; }
	@echo "🔧 Extracting bytecodes from $(TAG)..."
	@mkdir -p $(FIXTURE_DIR)/$(TAG)
	@if [ -d "$(WORKTREE_BASE)-$(TAG)" ]; then \
		git worktree remove "$(WORKTREE_BASE)-$(TAG)" --force 2>/dev/null || true; \
	fi
	@git worktree add "$(WORKTREE_BASE)-$(TAG)" $(TAG) 2>&1 | tail -1
	@cd "$(WORKTREE_BASE)-$(TAG)" && npm install --silent 2>/dev/null && forge build --silent 2>/dev/null
	@echo "📦 Extracting runtime bytecodes:"
	@for c in $(FIXTURE_CONTRACTS); do \
		json="$(WORKTREE_BASE)-$(TAG)/out/$${c}.sol/$${c}.json"; \
		if [ -f "$$json" ]; then \
			python3 -c "import json; f=open('$$json'); d=json.load(f); print(d['deployedBytecode']['object'],end='')" \
				> $(FIXTURE_DIR)/$(TAG)/$${c}.hex; \
			size=$$(wc -c < $(FIXTURE_DIR)/$(TAG)/$${c}.hex); \
			echo "  ✅ $${c} ($${size} bytes)"; \
		else \
			echo "  ⚠️  $${c} — not found in $(TAG)"; \
		fi; \
	done
	@git worktree remove "$(WORKTREE_BASE)-$(TAG)" --force 2>/dev/null
	@echo "✅ Fixtures → $(FIXTURE_DIR)/$(TAG)/ ($$(ls $(FIXTURE_DIR)/$(TAG)/*.hex 2>/dev/null | wc -l) files)"

extract-storage-layouts: ## Extract storage layouts from a git tag (TAG=<git-tag>)
	@test -n "$(TAG)" || { echo "❌ Usage: make extract-storage-layouts TAG=<git-tag>"; exit 1; }
	@echo "📐 Extracting storage layouts from $(TAG)..."
	@mkdir -p $(FIXTURE_DIR)/$(TAG)
	@if [ -d "$(WORKTREE_BASE)-$(TAG)" ]; then \
		git worktree remove "$(WORKTREE_BASE)-$(TAG)" --force 2>/dev/null || true; \
	fi
	@git worktree add "$(WORKTREE_BASE)-$(TAG)" $(TAG) 2>&1 | tail -1
	@cd "$(WORKTREE_BASE)-$(TAG)" && npm install --silent 2>/dev/null && forge build --silent 2>/dev/null
	@for c in $(FIXTURE_CONTRACTS); do \
		json="$(WORKTREE_BASE)-$(TAG)/out/$${c}.sol/$${c}.json"; \
		if [ -f "$$json" ]; then \
			python3 -c "import json,sys; d=json.load(open('$$json')); \
				st=d.get('storageLayout',{}); json.dump(st,sys.stdout,indent=2)" \
				> $(FIXTURE_DIR)/$(TAG)/$${c}.storage.json 2>/dev/null; \
			if [ -s "$(FIXTURE_DIR)/$(TAG)/$${c}.storage.json" ]; then \
				echo "  ✅ $${c}"; \
			else \
				rm -f "$(FIXTURE_DIR)/$(TAG)/$${c}.storage.json"; \
			fi; \
		fi; \
	done
	@git worktree remove "$(WORKTREE_BASE)-$(TAG)" --force 2>/dev/null
	@echo "✅ Storage layouts → $(FIXTURE_DIR)/$(TAG)/"

storage-diff: ## Diff storage layout: tag vs HEAD (TAG=<tag> CONTRACT=<name>)
	@test -n "$(TAG)" -a -n "$(CONTRACT)" || { echo "❌ Usage: make storage-diff TAG=<tag> CONTRACT=<name>"; exit 1; }
	@old="$(FIXTURE_DIR)/$(TAG)/$(CONTRACT).storage.json"; \
	if [ ! -f "$$old" ]; then \
		echo "❌ Old layout not found: $$old (run extract-storage-layouts first)"; exit 1; \
	fi; \
	echo "📐 $(CONTRACT): $(TAG) → HEAD"; \
	forge inspect $(CONTRACT) storage-layout --json 2>/dev/null > /tmp/storage-new-$(CONTRACT).json; \
	diff \
		<(python3 -c "import json; [print(f\"{x['label']:30s} slot={x['slot']:>3s} offset={x['offset']:>3} type={x['type']}\") for x in json.load(open('$$old')).get('storage',[])]") \
		<(python3 -c "import json; [print(f\"{x['label']:30s} slot={x['slot']:>3s} offset={x['offset']:>3} type={x['type']}\") for x in json.load(open('/tmp/storage-new-$(CONTRACT).json')).get('storage',[])]") \
		&& echo "  ✅ No changes" || true; \
	echo ""

storage-diff-all: ## Diff all storage layouts between tag and HEAD (TAG=<tag>)
	@test -n "$(TAG)" || { echo "❌ Usage: make storage-diff-all TAG=<tag>"; exit 1; }
	@for c in $(FIXTURE_CONTRACTS); do \
		if [ -f "$(FIXTURE_DIR)/$(TAG)/$${c}.storage.json" ]; then \
			$(MAKE) --no-print-directory storage-diff TAG=$(TAG) CONTRACT=$$c; \
		fi; \
	done

hardfork-test: ## Run all hardfork tests
	forge test --match-path "test/hardfork/*" -v
