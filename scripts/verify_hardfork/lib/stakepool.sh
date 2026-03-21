#!/usr/bin/env bash
# lib/stakepool.sh — StakePool-specific verification utilities.
#
# Handles the special case where StakePool has an immutable FACTORY variable
# that must be patched before computing the expected codehash.

# Generate expected codehash for StakePool by patching FACTORY immutable.
# Usage: generate_stakepool_hash <repo_root>
# Prints the expected codehash to stdout.
generate_stakepool_hash() {
    local repo_root="$1"

    local patched_bytecode
    patched_bytecode=$(cd "$repo_root" && python3 -c "
import subprocess, json, sys

# Get template bytecode
result = subprocess.run(['forge', 'inspect', 'StakePool', 'deployedBytecode'],
                        capture_output=True, text=True)
bytecode_hex = result.stdout.strip()
if bytecode_hex.startswith('0x'):
    bytecode_hex = bytecode_hex[2:]

# Get immutable references from build artifact
with open('out/StakePool.sol/StakePool.json') as f:
    artifact = json.load(f)
imm_refs = artifact.get('deployedBytecode', {}).get('immutableReferences', {})

# Collect all immutable references
all_refs = []
for ast_id, refs in imm_refs.items():
    for ref in refs:
        all_refs.append((ref['start'], ref['length']))

if len(all_refs) != 2:
    print(f'ERROR: Expected 2 immutable references, got {len(all_refs)}', file=sys.stderr)
    sys.exit(1)

# Patch with FACTORY = Staking system address
factory_hex = '00000000000000000000000000000000000000000000000000000001625f2000'
patched = bytearray(bytes.fromhex(bytecode_hex))
for (start, length) in all_refs:
    assert length == 32, f'Expected 32-byte immutable, got {length}'
    patched[start:start+32] = bytes.fromhex(factory_hex)

# Output patched bytecode as 0x-prefixed hex
print('0x' + patched.hex())
")

    if [ -z "$patched_bytecode" ]; then
        echo "ERROR: Failed to compute StakePool bytecode" >&2
        return 1
    fi

    cast keccak "$patched_bytecode"
}
