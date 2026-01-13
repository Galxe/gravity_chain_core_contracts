#!/usr/bin/env python3
"""
Extract bytecode from Foundry compiled artifacts

This script reads the compiled artifacts from the 'out' directory and extracts
the bytecode for each contract, saving it as .hex files with the same name
as the source .sol files.

Key difference:
- 'bytecode' contains constructor code + runtime code (used for deployment)
- 'deployedBytecode' contains only runtime code (what gets stored on-chain after deployment)

For genesis initialization, we need constructor bytecode to properly initialize contracts.
"""

import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Optional

def find_sol_files(src_dir: Path) -> Dict[str, Path]:
    """
    Find all .sol files in the src directory and its subdirectories.
    
    :param src_dir: Path to the src directory
    :return: Dictionary mapping contract names to their source file paths
    """
    sol_files = {}
    
    for sol_file in src_dir.rglob("*.sol"):
        # Get the contract name from the file name
        contract_name = sol_file.stem
        sol_files[contract_name] = sol_file
    
    return sol_files

def extract_contract_name_from_artifact(artifact_data: Dict) -> Optional[str]:
    """
    Extract the contract name from artifact data.
    
    :param artifact_data: The artifact JSON data
    :return: Contract name or None if not found
    """
    # Try different possible fields for contract name
    contract_name = (
        artifact_data.get("contractName") or
        artifact_data.get("name") or
        artifact_data.get("_format", {}).get("contractName")
    )
    
    return contract_name

def extract_bytecode_from_artifacts(out_dir: Path, src_dir: Path) -> Dict[str, str]:
    """
    Extract bytecode from all artifacts in the out directory.
    
    :param out_dir: Path to the out directory
    :param src_dir: Path to the src directory
    :return: Dictionary mapping contract names to their bytecode
    """
    bytecodes = {}
    
    # Find all contract directories in the out directory
    contract_dirs = [d for d in out_dir.iterdir() if d.is_dir() and d.name.endswith('.sol')]
    
    if not contract_dirs:
        print(f"[!] No contract directories found in {out_dir}")
        return bytecodes
    
    print(f"[*] Found {len(contract_dirs)} contract directories")
    
    for contract_dir in contract_dirs:
        # Get the contract name from the directory name
        contract_name = contract_dir.stem  # Remove .sol extension
        
        # Look for the JSON file in the contract directory
        json_files = list(contract_dir.glob("*.json"))
        if not json_files:
            print(f"   [!] No JSON file found in {contract_dir.name}")
            continue
        
        # Use the first JSON file (there should only be one)
        artifact_file = json_files[0]
        
        try:
            with open(artifact_file, 'r', encoding='utf-8') as f:
                artifact_data = json.load(f)
            
            bytecode = artifact_data.get("deployedBytecode", {}).get("object", "")
            if bytecode:
                print(f"   [!] Using deployedBytecode for {contract_name}")
            
            bytecodes[contract_name] = bytecode
            print(f"   [+] Extracted bytecode for {contract_name}")
            
        except Exception as e:
            print(f"   [!] Error processing {artifact_file}: {e}")
            continue
    
    return bytecodes

def save_bytecode_files(bytecodes: Dict[str, str], out_dir: Path) -> None:
    """
    Save bytecode to .hex files in the out directory.
    
    :param bytecodes: Dictionary mapping contract names to bytecode
    :param out_dir: Path to the out directory (where to save files)
    """
    print(f"[*] Extracted {len(bytecodes)} bytecodes")
    
    saved_count = 0
    
    for contract_name, bytecode in bytecodes.items():
        # Create the output filename based on the contract name
        output_filename = f"{contract_name}.hex"
        output_path = out_dir / output_filename
        
        # Save the bytecode
        output_path.write_text(bytecode)
        print(f"   -> Saved: {output_filename}")
        saved_count += 1
    
    print(f"\n[+] Successfully saved {saved_count} bytecode files")

def main():
    """Main function."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Extract bytecode from Foundry compiled artifacts")
    parser.add_argument("--out-dir", default="out",
                       help="Path to the compiled artifacts directory (default: out)")
    parser.add_argument("--output-dir", default=None,
                       help="Path to save .hex files (default: same as out-dir)")
    parser.add_argument("--src-dir", default="src",
                       help="Path to the source directory (default: src)")
    
    args = parser.parse_args()
    
    # Use Path objects
    out_dir = Path(args.out_dir)
    output_dir = Path(args.output_dir) if args.output_dir else out_dir
    src_dir = Path(args.src_dir)
    
    # Check if out directory exists
    if not out_dir.exists():
        print(f"[!] Error: out directory not found at {out_dir}")
        print("[!] Please run 'forge build' first to compile the contracts")
        sys.exit(1)
    
    print(f"[*] Source directory: {src_dir}")
    print(f"[*] Artifacts directory: {out_dir}")
    print(f"[*] Output directory: {output_dir}")
    
    # Extract bytecodes from artifacts
    bytecodes = extract_bytecode_from_artifacts(out_dir, src_dir)
    
    if not bytecodes:
        print("[!] No bytecodes found. Make sure contracts are compiled.")
        sys.exit(1)
    
    # Save bytecode files
    save_bytecode_files(bytecodes, output_dir)
    
    print(f"\n[+] Bytecode extraction completed successfully!")

if __name__ == "__main__":
    main() 