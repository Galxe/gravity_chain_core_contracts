#!/bin/bash

# generate_mythril_report.sh
# Automatically generate smart contract security analysis with Mythril

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

echo -e "${BLUE}==== Mythril Security Analysis Tool ====${NC}"

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

# Check if Mythril is installed
if ! command -v myth &> /dev/null; then
  echo -e "${YELLOW}Mythril not found. Attempting to install via pip...${NC}"
  
  # Try to install Mythril
  if command -v pip3 &> /dev/null; then
    pip3 install mythril
  elif command -v pip &> /dev/null; then
    pip install mythril
  else
    echo -e "${RED}Error: pip not found. Please install Python and pip first.${NC}"
    echo -e "${YELLOW}Installation instructions:${NC}"
    echo -e "${YELLOW}  pip3 install mythril${NC}"
    echo -e "${YELLOW}  or use Docker: docker pull mythril/myth${NC}"
    exit 1
  fi
  
  # Verify installation
  if ! command -v myth &> /dev/null; then
    echo -e "${RED}Error: Mythril installation failed.${NC}"
    exit 1
  fi
fi

echo -e "${GREEN}Mythril found at: $(which myth)${NC}"
echo -e "${GREEN}Mythril version: $(myth version 2>/dev/null || echo 'Unknown')${NC}"

# Get current timestamp for report filename
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILENAME="mythril_analysis_$TIMESTAMP.md"
REPORT_PATH="$AUDIT_DIR/$REPORT_FILENAME"

echo -e "${YELLOW}Starting Mythril analysis...${NC}"
echo -e "${YELLOW}Report will be saved to: $REPORT_PATH${NC}"

# Initialize report file
cat > "$REPORT_PATH" << EOF
# Mythril Security Analysis Report

**Generated on:** $(date)
**Mythril Version:** $(myth version 2>/dev/null || echo 'Unknown')
**Project:** $(basename "$REPO_ROOT")

## Analysis Summary

EOF

# Track if any vulnerabilities found
VULNERABILITIES_FOUND=0
ANALYZED_FILES=0

# Find all Solidity files
echo -e "${YELLOW}Scanning for Solidity files in $SRC_DIR...${NC}"

# Analyze each Solidity file
for sol_file in $(find "$SRC_DIR" -name "*.sol" -type f); do
  ANALYZED_FILES=$((ANALYZED_FILES + 1))
  
  echo -e "${YELLOW}Analyzing: $sol_file${NC}"
  
  # Get relative path for cleaner output (cross-platform compatible)
  REL_PATH=$(echo "$sol_file" | sed "s|^$REPO_ROOT/||")
  
  # Add file section to report
  echo "### Analysis of \`$REL_PATH\`" >> "$REPORT_PATH"
  echo "" >> "$REPORT_PATH"
  
  # Run Mythril analysis with timeout and capture output
  MYTHRIL_OUTPUT=$(timeout 300 myth analyze "$sol_file" --execution-timeout 60 -t 3 2>&1 || true)
  
  # Check if analysis found issues
  if echo "$MYTHRIL_OUTPUT" | grep -q "==== "; then
    VULNERABILITIES_FOUND=$((VULNERABILITIES_FOUND + 1))
    echo -e "${RED}⚠️  Vulnerabilities found in $REL_PATH${NC}"
    
    echo "**Status:** ⚠️ Issues detected" >> "$REPORT_PATH"
    echo "" >> "$REPORT_PATH"
    echo '```' >> "$REPORT_PATH"
    echo "$MYTHRIL_OUTPUT" >> "$REPORT_PATH"
    echo '```' >> "$REPORT_PATH"
  else
    echo -e "${GREEN}✅ No issues found in $REL_PATH${NC}"
    
    echo "**Status:** ✅ No issues detected" >> "$REPORT_PATH"
    echo "" >> "$REPORT_PATH"
    
    # Show non-vulnerability output (if any)
    if [ ! -z "$MYTHRIL_OUTPUT" ]; then
      echo '<details>' >> "$REPORT_PATH"
      echo '<summary>Analysis Details</summary>' >> "$REPORT_PATH"
      echo "" >> "$REPORT_PATH"
      echo '```' >> "$REPORT_PATH"
      echo "$MYTHRIL_OUTPUT" >> "$REPORT_PATH"
      echo '```' >> "$REPORT_PATH"
      echo '</details>' >> "$REPORT_PATH"
    fi
  fi
  
  echo "" >> "$REPORT_PATH"
  echo "---" >> "$REPORT_PATH"
  echo "" >> "$REPORT_PATH"
done

# Add summary to report
cat >> "$REPORT_PATH" << EOF

## Final Summary

- **Files Analyzed:** $ANALYZED_FILES
- **Files with Issues:** $VULNERABILITIES_FOUND
- **Analysis Date:** $(date)

## Mythril Analysis Notes

- **Execution Timeout:** 60 seconds per contract
- **Transaction Depth:** 3 transactions
- **Analysis Type:** Symbolic execution with SMT solving

### Common Issue Types Detected by Mythril:

- **SWC-106:** Unprotected Selfdestruct
- **SWC-107:** Reentrancy
- **SWC-101:** Integer Overflow/Underflow
- **SWC-104:** Unchecked Call Return Value  
- **SWC-105:** Unprotected Ether Withdrawal
- **SWC-115:** Authorization through tx.origin

### Recommendations:

1. Review all detected issues carefully
2. Implement proper access controls
3. Use OpenZeppelin's security libraries
4. Consider formal verification for critical functions
5. Run additional tools like Slither and 4naly3er for comprehensive analysis

---

*This report was generated automatically by Mythril. Manual review is recommended.*
EOF

# Summary output
echo ""
echo -e "${GREEN}==== Mythril Analysis Complete! ====${NC}"
echo -e "${BLUE}📊 Analysis Summary:${NC}"
echo -e "${BLUE}  - Files analyzed: $ANALYZED_FILES${NC}"
echo -e "${BLUE}  - Files with issues: $VULNERABILITIES_FOUND${NC}"
echo -e "${BLUE}  - Report saved to: $AUDIT_DIR/$REPORT_FILENAME${NC}"

if [ $VULNERABILITIES_FOUND -gt 0 ]; then
  echo ""
  echo -e "${RED}⚠️  SECURITY ISSUES DETECTED!${NC}"
  echo -e "${RED}Please review the full report for details.${NC}"
  echo -e "${YELLOW}Consider running additional security tools:${NC}"
  echo -e "${YELLOW}  make slither${NC}"
  echo -e "${YELLOW}  make 4naly3er${NC}"
else
  echo ""
  echo -e "${GREEN}✅ No security issues detected by Mythril${NC}"
  echo -e "${YELLOW}Note: This doesn't guarantee the contracts are secure.${NC}"
  echo -e "${YELLOW}Consider running additional security tools for comprehensive analysis.${NC}"
fi

echo ""
echo -e "${BLUE}For more detailed analysis, consider:${NC}"
echo -e "${BLUE}  - Adjusting transaction depth: myth analyze <file> -t 5${NC}"
echo -e "${BLUE}  - Longer execution timeout: myth analyze <file> --execution-timeout 120${NC}"
echo -e "${BLUE}  - JSON output: myth analyze <file> -o json${NC}" 