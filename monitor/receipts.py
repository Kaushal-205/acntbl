"""Observe deterministic guarantee receipts at a finalized EVM block. Emits JSON lines."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request


def decode_receipt(raw):
    if not re.fullmatch(r"0x[0-9a-fA-F]{640}", raw):
        raise ValueError("Unexpected receipt ABI")
    fields = [int(raw[i:i + 64], 16) for i in range(2, len(raw), 64)]
    provider, state, client, executor, beneficiary, payment, premium, benefit, accept_by, deliver_by = fields
    if state > 4 or provider == 0 or max(provider, client, executor, beneficiary) >= 2**160:
        raise ValueError("Invalid receipt fields")
    return dict(provider=f"0x{provider:040x}", state=state, client=f"0x{client:040x}",
                executor=f"0x{executor:040x}", beneficiary=f"0x{beneficiary:040x}", payment=payment,
                premium=premium, benefit=benefit, accept_before=accept_by, deliver_before=deliver_by)


def observe(call, contract, first_id, selectors):
    chain = int(call("eth_chainId", []), 16)
    block = call("eth_getBlockByNumber", ["finalized", False])
    if not block:
        raise ValueError("RPC must support finalized block reads")
    pinned = {"blockHash": block["hash"], "requireCanonical": True}
    timestamp = int(block["timestamp"], 16)

    def read(data):
        return call("eth_call", [{"to": contract, "data": data}, pinned])

    next_id = int(read(selectors[0]), 16)
    for receipt_id in range(first_id, next_id):
        r = decode_receipt(read(selectors[1] + f"{receipt_id:064x}"))
        if r["state"] == 3 or (r["state"] == 1 and timestamp >= r["deliver_before"]):
            evidence = dict(chain_id=chain, contract=contract.lower(), finalized_block=block["hash"],
                            timestamp=timestamp, receipt_id=receipt_id, receipt=r,
                            status="credited" if r["state"] == 3 else "expiry_callable")
            encoded = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
            yield {"sha256": hashlib.sha256(encoded).hexdigest(), "evidence": evidence}


def rpc(url, method, params):
    body = json.dumps(dict(jsonrpc="2.0", id=1, method=method, params=params)).encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError(f"{method} returned RPC error {result['error'].get('code')}")
    return result["result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("contract")
    parser.add_argument("--from-id", type=int, default=1)
    parser.add_argument("--interval", type=int, default=0, help="Seconds between scans; zero runs once")
    args = parser.parse_args()
    url = os.environ.get("RPC_URL")
    if not url or not re.fullmatch(r"0x[0-9a-fA-F]{40}", args.contract) or args.from_id < 1 or args.interval < 0:
        parser.error("Set RPC_URL and supply a contract, positive starting ID and nonnegative interval")
    selectors = [subprocess.check_output(["cast", "sig", sig], text=True).strip()
                 for sig in ("nextId()", "receipt(uint256)")]
    while True:
        try:
            for event in observe(lambda method, params: rpc(url, method, params), args.contract, args.from_id, selectors):
                print(json.dumps(event, sort_keys=True), flush=True)
        except (ValueError, RuntimeError, OSError) as error:
            print(f"Scan failed ({type(error).__name__})", file=sys.stderr, flush=True)
            if not args.interval:
                return 1
        if not args.interval:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
