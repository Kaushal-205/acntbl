#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
forge install --no-git foundry-rs/forge-std@v1.9.7 OpenZeppelin/openzeppelin-contracts@v5.2.0
