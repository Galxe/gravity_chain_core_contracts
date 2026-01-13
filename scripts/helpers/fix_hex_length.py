#!/usr/bin/env python3
"""
Fix hex string length to ensure all hex values have even length.
This script processes account_alloc.json and ensures all hex strings 
(including 0x prefixed ones) have even length by padding with leading zeros.
"""

import json
import sys
import argparse
from typing import Any


def fix_hex_length(value: str) -> str:
    """
    Fix hex string to have even length by padding with leading zeros.
    
    Args:
        value: Hex string (with or without 0x prefix)
    
    Returns:
        Hex string with even length
    """
    if not isinstance(value, str):
        return value
    
    # Check if it's a hex string
    if not value.startswith('0x'):
        return value
    
    # Remove 0x prefix
    hex_part = value[2:]
    
    # If already even length, return as is
    if len(hex_part) % 2 == 0:
        return value
    
    # Pad with leading zero to make even length
    padded_hex = '0' + hex_part
    return '0x' + padded_hex


def process_value(value: Any) -> Any:
    """
    Recursively process a value to fix hex strings.
    
    Args:
        value: Any value (string, dict, list, etc.)
    
    Returns:
        Processed value with fixed hex strings
    """
    if isinstance(value, str):
        return fix_hex_length(value)
    elif isinstance(value, dict):
        # Process both keys and values recursively
        processed_dict = {}
        for k, v in value.items():
            # Fix hex strings in keys too
            fixed_key = fix_hex_length(k) if isinstance(k, str) else k
            processed_dict[fixed_key] = process_value(v)
        return processed_dict
    elif isinstance(value, list):
        return [process_value(item) for item in value]
    else:
        return value


def process_file(input_file: str, output_file: str | None = None) -> None:
    """
    Process a JSON file to fix hex string lengths.
    
    Args:
        input_file: Path to input JSON file
        output_file: Path to output JSON file (optional, defaults to input_file)
    """
    if output_file is None:
        output_file = input_file
    
    print(f"🔧 Processing {input_file}...")
    
    try:
        # Load JSON file
        with open(input_file, 'r') as f:
            data = json.load(f)
        
        print(f"📊 Loaded JSON data with {len(data)} top-level keys")
        
        # Process the data
        processed_data = process_value(data)
        
        # Count hex strings processed
        hex_count = 0
        def count_hex_strings(obj):
            nonlocal hex_count
            if isinstance(obj, str) and obj.startswith('0x'):
                original_len = len(obj[2:])
                if original_len % 2 != 0:
                    hex_count += 1
            elif isinstance(obj, dict):
                # Count hex strings in both keys and values
                for k, v in obj.items():
                    if isinstance(k, str) and k.startswith('0x'):
                        original_len = len(k[2:])
                        if original_len % 2 != 0:
                            hex_count += 1
                    count_hex_strings(v)
            elif isinstance(obj, list):
                for item in obj:
                    count_hex_strings(item)
        
        count_hex_strings(data)
        
        # Save processed data
        with open(output_file, 'w') as f:
            json.dump(processed_data, f, indent=2)
        
        print(f"✅ Successfully processed {hex_count} hex strings")
        print(f"💾 Saved to {output_file}")
        
    except FileNotFoundError:
        print(f"❌ Error: File {input_file} not found")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"❌ Error: Invalid JSON in {input_file}: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Error: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Fix hex string lengths in JSON files to ensure even length"
    )
    parser.add_argument(
        "input_file",
        help="Input JSON file to process"
    )
    parser.add_argument(
        "-o", "--output",
        help="Output file (defaults to input file if not specified)"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )
    
    args = parser.parse_args()
    
    if args.verbose:
        print(f"🔍 Verbose mode enabled")
        print(f"📁 Input file: {args.input_file}")
        if args.output:
            print(f"📁 Output file: {args.output}")
    
    process_file(args.input_file, args.output)


if __name__ == "__main__":
    main() 