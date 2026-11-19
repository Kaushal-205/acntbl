"""Reconstruct a victim proof from public ClaimEntry logs using a finalized RPC endpoint."""
import argparse
import json
import os
import re
import subprocess

from monitor.receipts import rpc


def keccak(data):
    output = subprocess.check_output(["cast", "keccak", "0x" + data.hex()], text=True)
    return bytes.fromhex(output.strip()[2:])


def word(n):
    return n.to_bytes(32, "big")


def build_proof(leaves, position, hash_fn=keccak):
    if not 0 <= position < len(leaves):
        raise ValueError("Claim is absent")
    level = list(leaves)
    proof = []
    while len(level) > 1:
        sibling = position ^ 1
        if sibling < len(level):
            proof.append(level[sibling])
        parents = []
        for i in range(0, len(level), 2):
            pair = level[i:i+2]
            parents.append(hash_fn(b"".join(sorted(pair))) if len(pair) == 2 else pair[0])
        level = parents
        position //= 2
    return level[0], proof


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("escrow")
    parser.add_argument("epoch", type=int)
    parser.add_argument("root")
    parser.add_argument("claim_id")
    parser.add_argument("--deployment-block", type=int, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", args.escrow) or args.epoch < 1 or args.deployment_block < 0:
        parser.error("Invalid escrow, epoch or deployment block")
    if not all(re.fullmatch(r"0x[0-9a-fA-F]{64}", v) for v in (args.root, args.claim_id)):
        parser.error("Expected 32-byte root and claim ID")
    url = os.environ["RPC_URL"]
    chain = int(rpc(url, "eth_chainId", []), 16)
    head = int(rpc(url, "eth_getBlockByNumber", ["finalized", False])["number"], 16)
    event = keccak(b"ClaimEntry(uint256,bytes32,bytes32,address,uint256)")
    topics = ["0x"+event.hex(), "0x"+word(args.epoch).hex(), args.root]
    entries = []
    for start in range(args.deployment_block, head+1, 2000):
        logs = rpc(url, "eth_getLogs", [{"address": args.escrow, "topics": topics,
            "fromBlock": hex(start), "toBlock": hex(min(start + 1999, head))}])
        for log in logs:
            raw = bytes.fromhex(log["data"][2:])
            if len(raw) != 64:
                raise ValueError("Unexpected event data")
            entries.append((bytes.fromhex(log["topics"][3][2:]), raw))
        if entries:
            break  # The escrow publishes the full list atomically and only once per root.
    entries.sort()
    index = next((i for i, (claim_id, _) in enumerate(entries) if claim_id.hex() == args.claim_id[2:].lower()), -1)
    prefix = word(chain) + word(int(args.escrow, 16)) + word(args.epoch)
    root, proof = build_proof([keccak(keccak(prefix + cid + data)) for cid, data in entries], index)
    if root.hex() != args.root[2:].lower():
        raise ValueError("RPC claim data does not reproduce the supplied root")
    data = entries[index][1]
    print(json.dumps(dict(epoch=args.epoch, claimId=args.claim_id, victim="0x"+data[12:32].hex(),
                          loss=str(int.from_bytes(data[32:], "big")), proof=["0x"+p.hex() for p in proof])))


if __name__ == "__main__":
    main()
