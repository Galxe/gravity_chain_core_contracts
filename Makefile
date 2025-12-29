.PHONY: help format format-check lint lint-fix slither mythril 4naly3er aderyn audit cleanup-demo

# Set default target to help
.DEFAULT_GOAL := help

# Glob pattern for Solidity files
SOL_FILES = 'src/**/*.sol'

help: ## Display help information
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

lint: ## Check Solidity code with Solhint
	@echo "Linting Solidity files..."
	@npx solhint $(SOL_FILES) || yarn solhint $(SOL_FILES)

lint-fix: ## Fix automatically fixable Solhint issues
	@echo "Fixing linting issues in Solidity files..."
	@npx solhint $(SOL_FILES) --fix || yarn solhint $(SOL_FILES) --fix

slither: ## Run Slither security analysis on all contracts
	@echo "Ensuring Slither script is executable..."
	@chmod +x script/generate_slither_report.sh
	@echo "Running Slither security analysis..."
	@./script/generate_slither_report.sh

mythril: ## Run Mythril security analysis on all contracts
	@echo "Ensuring Mythril script is executable..."
	@chmod +x script/generate_mythril_report.sh
	@echo "Running Mythril security analysis..."
	@./script/generate_mythril_report.sh

4naly3er: ## Generate smart contract audit report with 4naly3er
	@echo "Ensuring script is executable..."
	@chmod +x script/generate_4naly3er_report.sh
	@echo "Generating audit report..."
	@./script/generate_4naly3er_report.sh

aderyn: ## Run Aderyn static analysis on all contracts
	@echo "Ensuring Aderyn script is executable..."
	@chmod +x script/generate_aderyn_report.sh
	@echo "Running Aderyn static analysis..."
	@./script/generate_aderyn_report.sh

audit: ## Run all security analysis tools (Slither, Mythril, 4naly3er, Aderyn)
	@echo "Running comprehensive security audit..."
	@make slither
	@echo ""
	@make mythril
	@echo ""
	@make 4naly3er
	@echo ""
	@make aderyn
	@echo ""
	@echo "Security audit complete! Check the audit/ directory for reports."

cleanup-demo: ## Clean up demo files from project directories
	@echo "Ensuring cleanup script is executable..."
	@chmod +x script/cleanup-demo.sh
	@echo "Running cleanup script..."
	@./script/cleanup-demo.sh
