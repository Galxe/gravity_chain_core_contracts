#!/bin/bash

# Cleanup script to remove the demo files shipped with the template.
# Only the specific files added by the template are removed -- any
# contracts / tests you have written are left alone.

set -e  # Exit on any error

echo "Starting cleanup process..."

# Demo files written by the template:
DEMO_SRC_FILES=(
    "src/Counter.sol"
    "src/CounterV2.sol"
    "src/VulnerableLendingPool.sol"
)

DEMO_TEST_FILES=(
    "test/unit/VulnerableLendingPool.unit.t.sol"
    "test/fuzz/VulnerableLendingPool.fuzz.t.sol"
    "test/invariant/VulnerableLendingPool.invariant.t.sol"
)

remove_if_exists() {
    local f="$1"
    if [ -f "$f" ]; then
        echo "  Removing: $f"
        rm -f "$f"
    fi
}

echo "Removing demo source files..."
for f in "${DEMO_SRC_FILES[@]}"; do
    remove_if_exists "$f"
done

echo "Removing demo test files..."
for f in "${DEMO_TEST_FILES[@]}"; do
    remove_if_exists "$f"
done

# audit/ is a generated artifact directory -- safe to clear contents.
if [ -d "audit" ]; then
    echo "Clearing audit/ directory..."
    find "audit" -type f -delete
    find "audit" -type l -delete
fi

echo "Cleanup completed successfully!"