#!/bin/bash

# generate_aderyn_report.sh
# Automatically generate smart contract security analysis with Aderyn

set -e  # Exit immediately if a command exits with a non-zero status

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the absolute path of the current repository
REPO_ROOT=$(pwd)
SRC_DIR="$REPO_ROOT/src"
AUDIT_DIR="$REPO_ROOT/audit"

echo -e "${BLUE}==== Aderyn Static Analysis Tool ====${NC}"

# Check if src directory exists
if [ ! -d "$SRC_DIR" ]; then
  echo -e "${RED}Error: src directory not found at $SRC_DIR${NC}"
  exit 1
fi

# Create audit directory (if it doesn't exist)
if [ ! -d "$AUDIT_DIR" ]; then
  echo -e "${YELLOW}Creating audit directory...${NC}"
  mkdir -p "$AUDIT_DIR"
fi

# Check if Aderyn is installed
if ! command -v aderyn &> /dev/null; then
  echo -e "${YELLOW}Aderyn not found. Attempting to install...${NC}"
  
  # Try to install Aderyn using curl
  if command -v curl &> /dev/null; then
    echo -e "${YELLOW}Installing Aderyn via curl...${NC}"
    curl --proto '=https' --tlsv1.2 -LsSf https://github.com/cyfrin/aderyn/releases/latest/download/aderyn-installer.sh | bash
    
    # Add to PATH for current session
    export PATH="$HOME/.cargo/bin:$PATH"
    
  # Try npm if curl fails
  elif command -v npm &> /dev/null; then
    echo -e "${YELLOW}Installing Aderyn via npm...${NC}"
    npm install @cyfrin/aderyn -g
    
  # Try homebrew if on macOS/Linux
  elif command -v brew &> /dev/null; then
    echo -e "${YELLOW}Installing Aderyn via Homebrew...${NC}"
    brew install cyfrin/tap/aderyn
    
  else
    echo -e "${RED}Error: No supported package manager found.${NC}"
    echo -e "${YELLOW}Please install Aderyn manually:${NC}"
    echo -e "${YELLOW}  curl --proto '=https' --tlsv1.2 -LsSf https://github.com/cyfrin/aderyn/releases/latest/download/aderyn-installer.sh | bash${NC}"
    echo -e "${YELLOW}  or visit: https://github.com/Cyfrin/aderyn${NC}"
    exit 1
  fi
  
  # Verify installation
  if ! command -v aderyn &> /dev/null; then
    echo -e "${RED}Error: Aderyn installation failed.${NC}"
    echo -e "${YELLOW}Please try manual installation or check the official documentation.${NC}"
    exit 1
  fi
fi

echo -e "${GREEN}Aderyn found at: $(which aderyn)${NC}"
echo -e "${GREEN}Aderyn version: $(aderyn --version 2>/dev/null || echo 'Unknown')${NC}"

# Get current timestamp for report filename
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILENAME="aderyn_analysis_$TIMESTAMP.md"
REPORT_PATH="$AUDIT_DIR/$REPORT_FILENAME"

echo -e "${YELLOW}Starting Aderyn analysis...${NC}"
echo -e "${YELLOW}Report will be saved to: $REPORT_PATH${NC}"

# Run Aderyn analysis
echo -e "${YELLOW}Running Aderyn analysis...${NC}"

# Capture both stdout and stderr, and get exit code
set +e  # Don't exit on non-zero status temporarily
ADERYN_OUTPUT=$(aderyn --output "$REPORT_PATH" 2>&1)
ADERYN_EXIT_CODE=$?
set -e  # Re-enable exit on non-zero status

# Check if report was generated
if [ -f "$REPORT_PATH" ]; then
  echo -e "${GREEN}✅ Aderyn analysis completed successfully${NC}"
  
  # Count findings from the markdown report
  TOTAL_FINDINGS=$(grep -c "^## " "$REPORT_PATH" 2>/dev/null || echo "0")
  HIGH_FINDINGS=$(grep -c "Severity: High" "$REPORT_PATH" 2>/dev/null || echo "0")
  MEDIUM_FINDINGS=$(grep -c "Severity: Medium" "$REPORT_PATH" 2>/dev/null || echo "0")
  LOW_FINDINGS=$(grep -c "Severity: Low" "$REPORT_PATH" 2>/dev/null || echo "0")
  NC_FINDINGS=$(grep -c "Severity: NC" "$REPORT_PATH" 2>/dev/null || echo "0")
  
  # Terminal output based on findings
  if [ "$TOTAL_FINDINGS" -gt "0" ]; then
    echo -e "${RED} SECURITY ISSUES DETECTED!${NC}"
    echo -e "${BLUE} Issue Breakdown:${NC}"
    echo -e "${RED}  - High Severity: $HIGH_FINDINGS${NC}"
    echo -e "${YELLOW}  - Medium Severity: $MEDIUM_FINDINGS${NC}"
    echo -e "${BLUE}  - Low Severity: $LOW_FINDINGS${NC}"
    echo -e "${GREEN}  - Non-Critical: $NC_FINDINGS${NC}"
    echo -e "${BLUE}  - Total Findings: $TOTAL_FINDINGS${NC}"
  else
    echo -e "${GREEN}✅ No security issues detected by Aderyn${NC}"
  fi

  # Create a summary report with additional information
  SUMMARY_REPORT="$AUDIT_DIR/aderyn_summary_$TIMESTAMP.md"
  cat > "$SUMMARY_REPORT" << EOF
# Aderyn Analysis Summary

**Generated on:** $(date)
**Aderyn Version:** $(aderyn --version 2>/dev/null || echo 'Unknown')
**Project:** $(basename "$REPO_ROOT")

## Analysis Results

### Findings Summary
- **Total Issues:** $TOTAL_FINDINGS
- **High Severity:** $HIGH_FINDINGS
- **Medium Severity:** $MEDIUM_FINDINGS  
- **Low Severity:** $LOW_FINDINGS
- **Non-Critical:** $NC_FINDINGS

### Analysis Status
$([ $ADERYN_EXIT_CODE -eq 0 ] && echo "✅ **Analysis completed successfully**" || echo "⚠️ **Analysis completed with warnings**")

### Command Output
\`\`\`
$ADERYN_OUTPUT
\`\`\`

## Understanding Aderyn Results

### Severity Levels:
- **High**: Critical security vulnerabilities that should be fixed immediately
- **Medium**: Important issues that could lead to security problems
- **Low**: Minor issues and best practice violations
- **NC (Non-Critical)**: Code quality and optimization suggestions

### Aderyn's Strengths:
- **Rust-based performance**: Fast execution with low resource usage
- **Modern detection**: Up-to-date vulnerability patterns
- **Zero configuration**: Works out of the box with Foundry and Hardhat
- **Editor integration**: VSCode extension available
- **Multiple output formats**: Markdown, JSON, and SARIF reports

### Recommendations:
1. **Prioritize High and Medium severity issues**
2. **Review all findings in context of your specific use case**
3. **Use Aderyn's VSCode extension for real-time feedback**
4. **Integrate into CI/CD pipeline for continuous monitoring**
5. **Combine with other tools (Slither, Mythril) for comprehensive analysis**

### Additional Resources:
- **Aderyn Documentation**: https://cyfrin.gitbook.io/cyfrin-docs/aderyn-cli/readme
- **VSCode Extension**: Available on Visual Studio Marketplace
- **GitHub Repository**: https://github.com/Cyfrin/aderyn

---

*This report was generated automatically by Aderyn. Manual review and testing are recommended.*
EOF

  echo -e "${BLUE}📊 Analysis Summary:${NC}"
  echo -e "${BLUE}  - Main report: $AUDIT_DIR/$REPORT_FILENAME${NC}"
  echo -e "${BLUE}  - Summary report: $AUDIT_DIR/aderyn_summary_$TIMESTAMP.md${NC}"

else
  echo -e "${RED}Error: Report not generated${NC}"
  echo -e "${RED}Command output: $ADERYN_OUTPUT${NC}"
fi

# Summary output
echo ""
echo -e "${GREEN}==== Aderyn Analysis Complete! ====${NC}"

if [ "$TOTAL_FINDINGS" -gt "0" ]; then
  echo -e "${YELLOW}Consider running additional security tools:${NC}"
  echo -e "${YELLOW}  make slither${NC}"
  echo -e "${YELLOW}  make mythril${NC}"
  echo -e "${YELLOW}  make 4naly3er${NC}"
else
  echo -e "${YELLOW}Note: This doesn't guarantee the contracts are secure.${NC}"
  echo -e "${YELLOW}Consider running additional security tools for comprehensive analysis.${NC}"
fi

echo ""
echo -e "${BLUE}For more information:${NC}"
echo -e "${BLUE}  - Aderyn documentation: https://cyfrin.gitbook.io/cyfrin-docs/aderyn-cli/readme${NC}"
echo -e "${BLUE}  - VSCode extension: Search 'Aderyn' in VS Code marketplace${NC}"
echo -e "${BLUE}  - GitHub repository: https://github.com/Cyfrin/aderyn${NC}" 