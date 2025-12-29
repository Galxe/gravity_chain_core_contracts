# Foundry Template

A Foundry project generator for your next smart contract project 🚀

## Getting Started

### Requirements

Please install the following:

- **Git**
  - You'll know you've done it right if you can run `git --version`
- **Foundry / Foundryup**
  - You can test you've installed them right by running `forge --version` and get an output like: `forge 0.3.0 (f016135 2022-07-04T00:15:02.930499Z)`
  - To get the latest of each, just run `foundryup`
- **Cruft** (Project Template Tool)
  - **macOS**: `brew install cruft` 
  - **Other platforms**: `pip install cruft`
- **Make** (Build Tool)
  - Usually pre-installed on macOS/Linux
  - **Windows**: Install via [chocolatey](https://chocolatey.org/): `choco install make`

### Quickstart

```bash
# Install cruft (if you haven't already)
# macOS:
brew install cruft
# Other platforms:
pip install cruft

# Create a new project from the template
cruft create https://github.com/ggsrc/foundry-template

# Navigate to your new project directory
cd your-project-name

# Build the contracts
forge build
```

# Modules

## Testing

We've specially designed a vulnerable contract in `gravity_chain_core_contracts/src/VulnerableLendingPool.sol` for educational purposes. This contract contains intentional vulnerabilities that are revealed through different testing strategies:

- **Unit Tests** (`test/unit/`) - Test individual functions and reveal basic logic flaws
- **Fuzz Tests** (`test/fuzz/`) - Use random inputs to discover edge cases and input validation issues  
- **Invariant Tests** (`test/invariant/`) - Test system-wide properties to uncover complex vulnerabilities like reentrancy and state inconsistencies

Each testing approach exposes different types of vulnerabilities in the contract, making it an excellent learning resource for smart contract security.

**For detailed vulnerability analysis and testing strategies, see:**
👉 [Testing Strategy & Vulnerability Analysis](gravity_chain_core_contracts/test/README.md)

## Deployment

The template supports two deployment strategies:

### Native Forge Deployment
If you choose not to use Zeus during template creation, you can deploy contracts using Foundry's native methods:

```bash
forge script script/Deploy.s.sol --rpc-url <your_rpc_url> --private-key <your_private_key> --broadcast
```

For more information, consult the [Foundry Book](https://book.getfoundry.sh/).

### Zeus Deployment
If you selected Zeus during template creation, you get access to advanced deployment features:

- **Complex deployment orchestration** with dependency management
- **Deployment metadata tracking** for better project management
- **Multi-environment support** with consistent deployment patterns
- **Upgrade management** for proxy contracts

See the [Deployment Guide](gravity_chain_core_contracts/script/releases/README.md) for detailed Zeus usage instructions.



## Tenderly Virtual TestNets

If you selected Tenderly during template creation, you get comprehensive staging environment support with mainnet data for realistic testing:

### Key Features
- **Virtual TestNets** with real mainnet state for comprehensive testing
- **Automated CI/CD deployment** to staging environments via GitHub Actions
- **Transaction debugging** with detailed execution traces and gas profiling
- **Contract verification** in Tenderly's explorer with public links
- **Team collaboration** with shared staging environments

### What's Included
- **Multi-network support** - Mainnet and Base forks with configurable chain IDs
- **Automatic wallet funding** - 100 ETH per network for deployment accounts
- **PR deployment previews** - Automatic deployment comments with Tenderly dashboard links
- **Helper scripts** - `fixtures/load-fixtures.sh` with deployment utilities
- **Comprehensive documentation** - Setup guides, troubleshooting, and customization instructions

### Quick Start
```bash
# Setup environment
cp .env.example .env
# Edit with your Tenderly credentials

# Deploy locally
source fixtures/load-fixtures.sh
forge script script/deploy/SimpleToken.s.sol --broadcast
```

### CI/CD Integration
The included `tenderly-ci-cd.yml` workflow provides:
- **Push to main/develop** - Full deployment and testing
- **Pull Requests** - Deploy for review with dashboard links
- **Multi-network deployment** with artifact management
- **Contract verification** and build artifact uploads

For complete setup instructions, workflow customization, and troubleshooting guides, see the [Tenderly Integration Guide](gravity_chain_core_contracts/docs/TENDERLY.md).

## Security

The template includes four static analysis tools for comprehensive security auditing. **All tools support automatic installation** - simply run the make commands and they will be installed automatically if not already present.

### Slither
**Slither** is Trail of Bits' static analysis framework for Solidity that detects vulnerabilities through static code analysis.

**Usage**:
```bash
make slither
```

Slither automatically detects and reports:
- **Reentrancy vulnerabilities** - Functions vulnerable to reentrancy attacks
- **Access control issues** - Missing or incorrect access control mechanisms
- **Timestamp dependence** - Reliance on block.timestamp for critical logic
- **Unchecked external calls** - External calls without proper error handling
- **Integer overflow/underflow** - Arithmetic operations without safe math

**More info**: [Slither Documentation](https://github.com/crytic/slither) | [Detection Capabilities](https://github.com/crytic/slither#detectors)

### Mythril
**Mythril** is a security analysis tool that uses symbolic execution to detect complex vulnerabilities in Ethereum smart contracts.

**Usage**:
```bash
make mythril
```

Mythril excels at finding:
- **Reentrancy vulnerabilities** - Complex attack patterns across multiple transactions
- **Integer overflow/underflow** - Mathematical operation vulnerabilities  
- **Unprotected functions** - Access control bypasses
- **State manipulation** - Unexpected state changes
- **Call injection** - Dangerous external calls

**More info**: [Mythril Documentation](https://github.com/ConsenSys/mythril) | [Security Analysis Guide](https://mythril-classic.readthedocs.io/)

### 4naly3er
**4naly3er** is a static audit tool that provides complementary analysis with different detection algorithms.

**Usage**:
```bash
make 4naly3er
```

**More info**: [4naly3er Repository](https://github.com/Picodes/4naly3er) | [Usage Examples](https://github.com/Picodes/4naly3er#usage)

### Aderyn
**Aderyn** is a modern Rust-based Solidity static analyzer by Cyfrin that offers zero-configuration setup and fast performance.

**Usage**:
```bash
make aderyn
```

Aderyn automatically detects and reports:
- **Modern vulnerability patterns** - Up-to-date detection algorithms
- **Zero configuration required** - Works out of the box with Foundry and Hardhat
- **High performance** - Rust-based implementation for fast analysis
- **Editor integration** - VSCode extension available for real-time feedback
- **Multiple output formats** - Markdown, JSON, and SARIF reports

**More info**: [Aderyn Documentation](https://cyfrin.gitbook.io/cyfrin-docs/aderyn-cli/readme) | [GitHub Repository](https://github.com/Cyfrin/aderyn)

### Comprehensive Security Audit
Run all four security tools at once for complete coverage:

```bash
make audit
```

All tools automatically generate timestamped reports in the `audit/` directory, including both JSON and Markdown formats for detailed analysis and documentation.

**Note**: All security tools will be automatically installed when first run. No manual installation required!

## Linting

The template includes automated code quality tools to maintain consistent code style and catch common issues:

### Solidity Linting
**Solhint** is integrated for Solidity code style and quality checking.

**Usage**:
```bash
make lint      # Check for linting issues
make lint-fix  # Automatically fix linting issues where possible
```

The linting rules are configured in `.solhint.json` and help enforce:
- **Code style consistency** - Consistent formatting and naming conventions
- **Best practices** - Common Solidity patterns and anti-patterns
- **Gas optimization hints** - Suggestions for gas-efficient code
- **Security patterns** - Basic security-related code patterns

## Demo Files

The template comes with educational demo files to help you understand smart contract development patterns:

### Included Demo Files
- **`src/Counter.sol`** - Simple counter contract demonstrating basic state management
- **`src/CounterV2.sol`** - Upgraded version showing contract upgrade patterns
- **`src/VulnerableLendingPool.sol`** - Educational contract with intentional vulnerabilities
- **Sample test files** - Testing examples for all demo contracts
- **Deployment scripts** - Zeus deployment examples

### Managing Demo Files
You can easily remove all demo files when you're ready to start your own project:

```bash
make cleanup-demo
```

This command will:
- Remove all demo files
- Keep the project structure intact for your own contracts

**Note**: You can also choose to exclude demo files during template creation by answering "y" to the `cleanup_demo` prompt.

## GitHub Workflows

The template includes several pre-configured GitHub Actions workflows located in `gravity_chain_core_contracts/.github/workflows/`:

### Core Workflows
- **`test.yml`** - Continuous integration for contract compilation and testing
- **`security-audit.yml`** - Comprehensive security analysis with all four security tools
- **`typo-check.yml`** - Automated typo detection and correction

### Conditional Workflows
- **`cruft-update.yml`** - Automatic template updates (only included if auto-update is enabled during template creation)
- **`tenderly-ci-cd.yml`** - Tenderly Virtual TestNet deployment and testing (only included if Tenderly is selected during template creation)
- **`validate-deployment-scripts.yml`** - Validates Zeus deployment scripts (only included if Zeus is selected during template creation)

### Setting up Automatic Template Updates

If you enabled auto-updates during template creation, follow these steps to configure the required GitHub secret:

#### 1. Generate GitHub Personal Access Token (PAT)

1. Go to [GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)](https://github.com/settings/tokens)
2. Click **"Generate new token"** → **"Generate new token (classic)"**
3. Configure the token:
   - **Note**: `CICD_DOCKER_BUILD_PAT for template updates`
   - **Expiration**: Choose appropriate duration (recommended: 90 days or 1 year)
   - **Scopes**: Select the following permissions:
     - ✅ `repo` (Full control of private repositories)
     - ✅ `workflow` (Update GitHub Action workflows)
     - ✅ `write:packages` (Write packages to GitHub Package Registry)
4. Click **"Generate token"**
5. **Copy the token immediately** (you won't be able to see it again)

#### 2. Add Secret to Repository

Choose your preferred method:

**Option A: Using GitHub CLI (Recommended)**
```bash
# Set the secret using gh command
gh secret set CICD_DOCKER_BUILD_PAT --body "your_token_here"
```

**Option B: GitHub Web Interface**
1. Go to your repository → **Settings** → **Secrets and variables** → **Actions**
2. Click **"New repository secret"**
3. Set **Name**: `CICD_DOCKER_BUILD_PAT` and **Secret**: your token
4. Click **"Add secret"**

#### 3. Test the Workflow

1. Go to your repository → **Actions** tab
2. Find **"Update repository Template"** workflow
3. Click **"Run workflow"** → **"Run workflow"** (manually trigger)
4. Monitor the workflow execution to ensure it works correctly

The workflow will then run automatically every Monday at 2:00 AM UTC to check for template updates.
- **`validate-deployment-scripts.yml`** - Validates Zeus deployment scripts (only included if Zeus is selected during template creation)

These workflows provide automated testing, security scanning, and deployment validation to ensure code quality and reliability throughout the development process.
