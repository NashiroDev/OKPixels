#!/usr/bin/env python3
"""
Sub-script for board 0.
It continually checks "board0.txt" for an updated timestamp.
When a new update is detected, it loads "template.html", removes the timestamp line
from the board data, converts the board data into a valid JavaScript array literal,
replaces placeholders (<!--BOARD_DATA-->, <!--BOARD_ID-->, and <!--LAST_UPDATE_TIME-->),
and pushes the resulting HTML to the storage contract.
Additionally, after each successful transaction, it logs the fee paid (in ETH)
to a shared "fee.txt" file.
Environment variables:
  - PRIVATE_KEY0 : The private key for board 0.
  - TOKEN_ID0    : The token id for board 0. (If not provided, board id 0 is used as default.)
  - CONTRACT_ADDRESS, RPC_URLS, etc.
"""

import os
import time
import json
import datetime
import fcntl  # for file locking (works on Linux)
from web3 import Web3, HTTPProvider
from dotenv import load_dotenv

# Load environment variables.
load_dotenv()

# ----------------------- CONFIGURATION -----------------------
BOARD_ID = 2
FIXED_KEY = "0xfc77a78c81db9794340a10dbcb0632f44d2d889f2cac2911b039a50f90ead7d0"

# Contract info.
CONTRACT_ADDRESS = os.getenv("CONTRACT_ADDRESS")
RPC_URLS = os.getenv("RPC_URLS").split(",")

# Contract ABI.
CONTRACT_ABI = [
    {
        "inputs": [
            {"internalType": "uint256", "name": "tokenId", "type": "uint256"},
            {"internalType": "bytes32", "name": "key", "type": "bytes32"},
            {"internalType": "string", "name": "data", "type": "string"}
        ],
        "name": "storeString",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    }
]

# --------------------- LOADING PRIVATE KEY AND TOKEN ID ---------------------
PRIVATE_KEY = os.getenv(f"PRIVATE_KEY{BOARD_ID}")
if not PRIVATE_KEY:
    print(f"Error: Environment variable PRIVATE_KEY{BOARD_ID} not found.")
    exit(1)

token_id_env = os.getenv(f"TOKEN_ID{BOARD_ID}")
if token_id_env is None:
    print(f"Warning: TOKEN_ID{BOARD_ID} not found. Using BOARD_ID as default token id.")
    TOKEN_ID = BOARD_ID
else:
    try:
        TOKEN_ID = int(token_id_env)
    except Exception as e:
        print(f"Error converting TOKEN_ID{BOARD_ID} to integer: {e}")
        TOKEN_ID = BOARD_ID

# --------------------- GAS PRICE AND FEE LOGGING ---------------------
# Global variable for the current gas price (in wei).
# Base gas price is now 2e6 wei (i.e. 0.002 gwei), maximum is 6e6 wei (0.006 gwei),
# and the increment on timeout is 1e6 wei (0.001 gwei).
current_gas_price_wei = int(1.3e6)
GAS_PRICE_MAX = int(3e6)

def update_fee_file(new_fee):
    """
    Appends the new fee (in ETH) to the shared fee.txt file while updating a running total.
    The file format:
       First line: "TOTAL: <total fee in ETH>"
       Subsequent lines: each fee paid for an update.
    A simple file lock via fcntl is employed.
    """
    fee_filename = "fee.txt"
    try:
        # Open file for reading and writing (or create it if it does not exist).
        try:
            f = open(fee_filename, "r+")
        except FileNotFoundError:
            f = open(fee_filename, "w+")
        # Lock file exclusively.
        fcntl.flock(f, fcntl.LOCK_EX)
        lines = f.readlines()
        if lines and lines[0].startswith("TOTAL:"):
            try:
                current_total = float(lines[0].strip().split("TOTAL:")[1])
            except Exception:
                current_total = 0.0
            fee_entries = lines[1:]
        else:
            current_total = 0.0
            fee_entries = []
        new_total = current_total + new_fee
        # Rewind and truncate file.
        f.seek(0)
        f.truncate()
        # Write new total.
        f.write(f"TOTAL: {new_total:.10f}\n")
        # Write previous fee entries.
        for entry in fee_entries:
            f.write(entry)
        # Append the new fee.
        f.write(f"{new_fee:.10f}\n")
        f.flush()
        fcntl.flock(f, fcntl.LOCK_UN)
        f.close()
        print(f"Updated fee.txt: added fee {new_fee:.10f} ETH. New total: {new_total:.10f} ETH.")
    except Exception as e:
        print(f"Error updating fee.txt: {e}")

# --------------------- HELPER FUNCTIONS ---------------------
def generate_html(board_data_js, board_id, timestamp):
    """
    Loads the HTML template ("template.html") and replaces placeholders with:
      • <!--BOARD_DATA--> replaced by board_data_js (a JS array literal created by json.dumps)
      • <!--BOARD_ID--> replaced by board_id
      • <!--LAST_UPDATE_TIME--> replaced by the timestamp.
    Returns the resulting HTML string.
    """
    try:
        with open("template.html", "r") as f:
            template_content = f.read()
    except Exception as e:
        print("Error reading template.html:", e)
        return None

    html = (template_content.replace("<!--BOARD_DATA-->", board_data_js)
                            .replace("<!--BOARD_ID-->", str(board_id))
                            .replace("<!--LAST_UPDATE_TIME-->", timestamp))
    return html

def push_to_contract(html):
    """
    Attempts to push the given HTML string to the storage contract.
    Uses the current global gas price (in wei) for the transaction.
    If a transaction remains pending (timeout), increases the gas price by 0.3e6 wei (up to GAS_PRICE_MAX).
    On success, logs the fee paid to fee.txt and resets the gas price to the base value.
    """
    global current_gas_price_wei
    print("Pushing HTML to contract...")
    for rpc in RPC_URLS:
        w3 = Web3(HTTPProvider(rpc))
        if not w3.is_connected():
            print(f"RPC endpoint {rpc} not connected. Skipping...")
            continue
        try:
            account = w3.eth.account.from_key(PRIVATE_KEY)
            contract = w3.eth.contract(address=CONTRACT_ADDRESS, abi=CONTRACT_ABI)
            gas_wei = current_gas_price_wei
            txn = contract.functions.storeString(TOKEN_ID, FIXED_KEY, html).build_transaction({
                'chainId': w3.eth.chain_id,
                'gas': 29504000,  # you may adjust the gas limit if needed
                'gasPrice': gas_wei,
                'nonce': w3.eth.get_transaction_count(account.address),
            })
            signed = account.sign_transaction(txn)
            tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
            print(f"Transaction sent via {rpc} with gas price {current_gas_price_wei/1e6:.3f} gwei. Waiting for receipt...")
            # Wait for receipt with a timeout of 60 seconds.
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
            if receipt.status == 1:
                print(f"Successfully pushed HTML for board {BOARD_ID} via {rpc}. Transaction hash: {tx_hash.hex()}")
                # Compute fee paid in wei and convert to ETH.
                fee_wei = receipt.gasUsed * gas_wei
                fee_eth = fee_wei / 1e18
                update_fee_file(fee_eth)
                # Reset gas price on success to the base value.
                current_gas_price_wei = int(1.3e6)
                return True
            else:
                print(f"Transaction for board {BOARD_ID} via {rpc} failed.")
        except Exception as e:
            err_str = str(e).lower()
            if "timeout" in err_str:
                print(f"Timeout reached for board {BOARD_ID} via {rpc} at gas price {current_gas_price_wei/1e6:.3f} gwei.")
                if current_gas_price_wei < GAS_PRICE_MAX:
                    current_gas_price_wei += int(0.3e6)
                    print(f"Increasing gas price to {current_gas_price_wei/1e6:.3f} gwei.")
                else:
                    print(f"Maximum gas price reached for board {BOARD_ID}.")
            else:
                print(f"Error pushing board {BOARD_ID} via {rpc}: {e}")
    return False

# --------------------- MAIN LOOP ---------------------
def main_loop():
    board_file = f"board{BOARD_ID}.txt"
    last_timestamp = None

    print(f"Starting updater for board {BOARD_ID} (token {TOKEN_ID}).")
    while True:
        try:
            with open(board_file, "r") as f:
                lines = f.read().splitlines()
            if not lines:
                print(f"Empty board file '{board_file}'. Waiting 60s...")
                time.sleep(60)
                continue

            # Ensure that the last nonempty line is a timestamp line.
            if not lines[-1].startswith("Timestamp:"):
                print(f"Board file '{board_file}' missing a timestamp line. Waiting...")
                time.sleep(60)
                continue

            # Retrieve update timestamp from the file.
            timestamp_line = lines[-1]
            current_timestamp = timestamp_line.replace("Timestamp: ", "").strip()
            # Only process the update if it is new or if the previous push failed.
            if last_timestamp is not None and current_timestamp == last_timestamp:
                print(f"[{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] No new update for board {BOARD_ID}. Sleeping for 1 minute.")
                time.sleep(60)
                continue

            print(f"[{current_timestamp}] Detected update for board {BOARD_ID}.")

            # Remove the timestamp line, leaving only the board data.
            board_data_lines = lines[:-1]
            # Convert the board data into a JSON array literal.
            board_data_js = json.dumps(board_data_lines)
            # Generate HTML using the template.
            html = generate_html(board_data_js, BOARD_ID, current_timestamp)
            if html is None:
                print("HTML generation failed. Retrying in 1 minute.")
                time.sleep(60)
                continue

            print("Attempting to push update to the storage contract...")
            if push_to_contract(html):
                print(f"Board {BOARD_ID} updated on-chain successfully.")
                # Only on success, update the last_timestamp so that this update is not reprocessed.
                last_timestamp = current_timestamp
            else:
                print("Failed to push update to the contract. Will retry same update on next cycle.")
        except FileNotFoundError:
            print(f"Board file '{board_file}' not found. Waiting for it to be created...")
        except Exception as e:
            print("Error in updater loop:", e)
        time.sleep(60)

if __name__ == '__main__':
    main_loop()
