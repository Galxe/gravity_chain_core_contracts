import json
import sys


def transform_accounts(
    genesis_accounts_path, genesis_contracts_path, output_path="account_alloc.json"
):
    """Combine genesis accounts and contracts into account allocation format."""
    
    # Load genesis accounts (address -> account_info mapping)
    with open(genesis_accounts_path, "r") as f:
        accounts_data = json.load(f)

    # Load genesis contracts (address -> bytecode mapping)
    with open(genesis_contracts_path, "r") as f:
        contracts_data = json.load(f)

    # Create account allocation format
    account_alloc = {}
    
    # Process all accounts
    for addr, account_info in accounts_data.items():
        # Extract balance from account info
        balance = account_info["info"]["balance"]
        
        # Get contract bytecode if this address has a contract
        code = contracts_data.get(addr)
        
        # Create account allocation entry
        account_alloc[addr] = {
            "balance": balance,
            "nonce": account_info["info"]["nonce"],
            "code": code,  # Will be None if not a contract
            "storage": account_info.get("storage", {})
        }
    
    # Write the combined allocation
    with open(output_path, "w") as f:
        json.dump(account_alloc, f, indent=2)
    
    print(f"✅ Successfully combined {len(accounts_data)} accounts and {len(contracts_data)} contracts")
    print(f"✅ Total accounts in allocation: {len(account_alloc)}")
    print(f"✅ Successfully wrote to {output_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 combine_account_alloc.py <genesis_contracts.json> <genesis_accounts.json>")
        sys.exit(1)
    
    file_a = sys.argv[1]  # genesis_contracts.json
    file_b = sys.argv[2]  # genesis_accounts.json
    
    transform_accounts(file_b, file_a)
