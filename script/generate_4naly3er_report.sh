#!/bin/bash

# generate_4naly3er_report.sh
# Automatically generate smart contract security audit report

set -e  # Exit immediately if a command exits with a non-zero status

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the absolute path of the current repository
REPO_ROOT=$(pwd)
PARENT_DIR=$(dirname "$REPO_ROOT")
ANALYZER_DIR="$PARENT_DIR/4naly3er"
SRC_DIR="$REPO_ROOT/src"
AUDIT_DIR="$REPO_ROOT/audit"
GITHUB_URL=""  # Can be passed as a parameter

# Receive GitHub URL as an optional parameter
if [ "$1" != "" ]; then
  GITHUB_URL="$1"
fi

echo -e "${BLUE}==== Smart Contract Audit Report Generator ====${NC}"

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

# Check and clone 4naly3er
if [ ! -d "$ANALYZER_DIR" ]; then
  echo -e "${YELLOW}Cloning 4naly3er to $ANALYZER_DIR...${NC}"
  git clone https://github.com/Picodes/4naly3er "$ANALYZER_DIR"
  
  # Apply fix for known issue with uselessOverride detector
  echo -e "${YELLOW}Applying fix for uselessOverride detector issue...${NC}"
  if [ -f "$ANALYZER_DIR/src/issues/NC/uselessOverride.ts" ]; then
    rm -f "$ANALYZER_DIR/src/issues/NC/uselessOverride.ts"
    echo -e "${GREEN}Removed problematic uselessOverride.ts detector${NC}"
  fi
  
  # Install dependencies
  echo -e "${YELLOW}Installing dependencies for 4naly3er...${NC}"
  cd "$ANALYZER_DIR" && yarn install
else
  echo -e "${GREEN}4naly3er already exists at $ANALYZER_DIR${NC}"
  
  # Update code
  echo -e "${YELLOW}Updating 4naly3er...${NC}"
  cd "$ANALYZER_DIR" && git pull
  
  # Apply fix for known issue with uselessOverride detector
  echo -e "${YELLOW}Applying fix for uselessOverride detector issue...${NC}"
  if [ -f "$ANALYZER_DIR/src/issues/NC/uselessOverride.ts" ]; then
    rm -f "$ANALYZER_DIR/src/issues/NC/uselessOverride.ts"
    echo -e "${GREEN}Removed problematic uselessOverride.ts detector${NC}"
  fi
fi

# Copy remappings.txt to src directory (if it exists)
if [ -f "$REPO_ROOT/remappings.txt" ]; then
  echo -e "${YELLOW}Copying remappings.txt to src directory...${NC}"
  cp "$REPO_ROOT/remappings.txt" "$SRC_DIR/"
fi

# Run analyzer
echo -e "${YELLOW}Running contract analysis...${NC}"
cd "$ANALYZER_DIR"

# Use GitHub URL (if provided)
if [ "$GITHUB_URL" != "" ]; then
  echo -e "${YELLOW}Using GitHub URL: $GITHUB_URL${NC}"
  yarn analyze "$SRC_DIR" "" "$GITHUB_URL"
else
  yarn analyze "$SRC_DIR"
fi

# Check if report was generated
if [ -f "$ANALYZER_DIR/report.md" ]; then
  # Get current timestamp as part of the filename
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  REPORT_FILENAME="4naly3er_report_$TIMESTAMP.md"
  
  # Copy report to audit directory
  echo -e "${GREEN}Copying report to $AUDIT_DIR/$REPORT_FILENAME${NC}"
  cp "$ANALYZER_DIR/report.md" "$AUDIT_DIR/$REPORT_FILENAME"
  
  echo -e "${GREEN}Success! 4naly3er report generated at:${NC}"
  echo -e "${BLUE}$AUDIT_DIR/$REPORT_FILENAME${NC}"
else
  echo -e "${RED}Error: Report not generated. Check 4naly3er logs for details.${NC}"
  exit 1
fi

# Cleanup
echo -e "${YELLOW}Cleaning up...${NC}"
if [ -f "$SRC_DIR/remappings.txt" ] && [ -f "$REPO_ROOT/remappings.txt" ]; then
  # If source file still exists, delete the copied file
  rm "$SRC_DIR/remappings.txt"
fi

echo -e "${GREEN}==== Audit report generation complete! ====${NC}" 