#!/bin/bash

# generate_slither_report.sh
# Automatically generate smart contract security analysis with Slither

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
CONFIG_FILE="$REPO_ROOT/slither.config.json"

echo -e "${BLUE}==== Slither Security Analysis Tool ====${NC}"

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

# Check if Slither is installed
if ! command -v slither &> /dev/null; then
  echo -e "${YELLOW}Slither not found. Attempting to install via pip...${NC}"
  
  # Try to install Slither
  if command -v pip3 &> /dev/null; then
    echo -e "${YELLOW}Installing slither-analyzer...${NC}"
    pip3 install slither-analyzer
  elif command -v pip &> /dev/null; then
    echo -e "${YELLOW}Installing slither-analyzer...${NC}"
    pip install slither-analyzer
  elif command -v pipx &> /dev/null; then
    echo -e "${YELLOW}Installing slither-analyzer...${NC}"
    pipx install slither-analyzer
  else
    echo -e "${RED}Error: pip not found. Please install Python and pip first.${NC}"
    echo -e "${YELLOW}Installation instructions:${NC}"
    echo -e "${YELLOW}  pip3 install slither-analyzer${NC}"
    echo -e "${YELLOW}  or visit: https://github.com/crytic/slither${NC}"
    exit 1
  fi
  
  # Verify installation
  if ! command -v slither &> /dev/null; then
    echo -e "${RED}Error: Slither installation failed.${NC}"
    echo -e "${YELLOW}Please try manual installation:${NC}"
    echo -e "${YELLOW}  pip3 install slither-analyzer${NC}"
    exit 1
  fi
fi

echo -e "${GREEN}Slither found at: $(which slither)${NC}"
echo -e "${GREEN}Slither version: $(slither --version 2>/dev/null || echo 'Unknown')${NC}"

# Get current timestamp for report filename
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILENAME="slither_analysis_$TIMESTAMP.json"
REPORT_PATH="$AUDIT_DIR/$REPORT_FILENAME"

echo -e "${YELLOW}Starting Slither analysis...${NC}"
echo -e "${YELLOW}Report will be saved to: $REPORT_PATH${NC}"

# Check if config file exists
if [ -f "$CONFIG_FILE" ]; then
  echo -e "${GREEN}Using configuration file: $CONFIG_FILE${NC}"
  CONFIG_OPTION="--config-file $CONFIG_FILE"
else
  echo -e "${YELLOW}No configuration file found, using default settings${NC}"
  CONFIG_OPTION=""
fi

# Run Slither analysis
echo -e "${YELLOW}Running Slither analysis...${NC}"

# Capture both stdout and stderr, and get exit code
set +e  # Don't exit on non-zero status temporarily
SLITHER_OUTPUT=$(slither . $CONFIG_OPTION --json "$REPORT_PATH" 2>&1)
SLITHER_EXIT_CODE=$?
set -e  # Re-enable exit on non-zero status

# Create a markdown report as well
MARKDOWN_REPORT="$AUDIT_DIR/slither_analysis_$TIMESTAMP.md"

# Initialize markdown report
cat > "$MARKDOWN_REPORT" << EOF
# Slither Security Analysis Report

**Generated on:** $(date)
**Slither Version:** $(slither --version 2>/dev/null || echo 'Unknown')
**Project:** $(basename "$REPO_ROOT")
**Configuration:** $([ -f "$CONFIG_FILE" ] && echo "Custom config used" || echo "Default settings")

## Analysis Summary

EOF

# Parse JSON results if available
if [ -f "$REPORT_PATH" ]; then
  # Count different types of findings
  TOTAL_RESULTS=$(cat "$REPORT_PATH" | grep -o '"impact":' | wc -l | tr -d ' ' || echo "0")
  HIGH_ISSUES=$(cat "$REPORT_PATH" | grep -o '"impact":"High"' | wc -l | tr -d ' ' || echo "0")
  MEDIUM_ISSUES=$(cat "$REPORT_PATH" | grep -o '"impact":"Medium"' | wc -l | tr -d ' ' || echo "0")
  LOW_ISSUES=$(cat "$REPORT_PATH" | grep -o '"impact":"Low"' | wc -l | tr -d ' ' || echo "0")
  INFO_ISSUES=$(cat "$REPORT_PATH" | grep -o '"impact":"Informational"' | wc -l | tr -d ' ' || echo "0")
  
  # Add summary to markdown
  cat >> "$MARKDOWN_REPORT" << EOF
### Findings Summary
- **Total Issues:** $TOTAL_RESULTS
- **High Impact:** $HIGH_ISSUES
- **Medium Impact:** $MEDIUM_ISSUES  
- **Low Impact:** $LOW_ISSUES
- **Informational:** $INFO_ISSUES

### Analysis Status
EOF

  if [ $SLITHER_EXIT_CODE -eq 0 ]; then
    echo "✅ **Analysis completed successfully**" >> "$MARKDOWN_REPORT"
    echo -e "${GREEN}✅ Slither analysis completed successfully${NC}"
  else
    echo "⚠️ **Analysis completed with warnings/errors**" >> "$MARKDOWN_REPORT"
    echo -e "${YELLOW}⚠️ Slither analysis completed with warnings${NC}"
  fi

  # Add detailed output
  cat >> "$MARKDOWN_REPORT" << EOF

## Detailed Analysis Output

\`\`\`
$SLITHER_OUTPUT
\`\`\`

## Report Files Generated

- **JSON Report:** \`$REPORT_FILENAME\`
- **Markdown Report:** \`slither_analysis_$TIMESTAMP.md\`

## Understanding Slither Results

### Impact Levels:
- **High**: Critical security vulnerabilities that should be fixed immediately
- **Medium**: Important issues that could lead to security problems
- **Low**: Minor issues and best practice violations
- **Informational**: Code quality and optimization suggestions

### Common Issue Types:
- **Reentrancy**: Functions vulnerable to reentrancy attacks
- **Timestamp dependence**: Reliance on block.timestamp for critical logic
- **Unchecked external calls**: External calls without proper error handling
- **Access controls**: Missing or incorrect access control mechanisms
- **Integer overflow/underflow**: Arithmetic operations without safe math

### Recommendations:
1. **Prioritize High and Medium impact issues**
2. **Review all findings in context of your specific use case**
3. **Consider using OpenZeppelin's security libraries**
4. **Implement comprehensive testing for identified issues**
5. **Run additional security tools (Mythril, 4naly3er) for comprehensive analysis**

---

*This report was generated automatically by Slither. Manual review and testing are recommended.*
EOF

  # Terminal output based on findings
  if [ "$TOTAL_RESULTS" -gt "0" ]; then
    echo -e "${RED} SECURITY ISSUES DETECTED!${NC}"
    echo -e "${BLUE} Issue Breakdown:${NC}"
    echo -e "${RED}  - High Impact: $HIGH_ISSUES${NC}"
    echo -e "${YELLOW}  - Medium Impact: $MEDIUM_ISSUES${NC}"
    echo -e "${BLUE}  - Low Impact: $LOW_ISSUES${NC}"
    echo -e "${GREEN}  - Informational: $INFO_ISSUES${NC}"
  else
    echo -e "${GREEN}✅ No security issues detected by Slither${NC}"
  fi

else
  echo -e "${RED}Error: JSON report not generated${NC}"
  cat >> "$MARKDOWN_REPORT" << EOF
❌ **Analysis failed to generate JSON report**

### Error Output:
\`\`\`
$SLITHER_OUTPUT
\`\`\`

### Troubleshooting:
1. Check that all dependencies are properly installed
2. Verify that Solidity contracts compile successfully
3. Ensure slither.config.json is valid (if present)
4. Try running: \`forge build\` first to compile contracts

EOF
fi

# Summary output
echo ""
echo -e "${GREEN}==== Slither Analysis Complete! ====${NC}"
echo -e "${BLUE}📊 Analysis Summary:${NC}"
echo -e "${BLUE}  - JSON report: $AUDIT_DIR/$REPORT_FILENAME${NC}"
echo -e "${BLUE}  - Markdown report: $AUDIT_DIR/slither_analysis_$TIMESTAMP.md${NC}"

if [ "$TOTAL_RESULTS" -gt "0" ]; then
  echo -e "${YELLOW}Consider running additional security tools:${NC}"
  echo -e "${YELLOW}  make mythril${NC}"
  echo -e "${YELLOW}  make 4naly3er${NC}"
else
  echo -e "${YELLOW}Note: This doesn't guarantee the contracts are secure.${NC}"
  echo -e "${YELLOW}Consider running additional security tools for comprehensive analysis.${NC}"
fi

echo ""
echo -e "${BLUE}For more information:${NC}"
echo -e "${BLUE}  - Slither documentation: https://github.com/crytic/slither${NC}"
echo -e "${BLUE}  - Custom detectors: slither . --list-detectors${NC}"
echo -e "${BLUE}  - Configuration help: slither . --help${NC}" 