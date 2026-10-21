#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in install.sh scripts/*.sh scripts/lib/*.sh tests/*.sh; do
    bash -n "$script"
done
bash tests/runtime-config.sh
bash tests/network-config.sh
bash tests/users.sh
bash tests/proxyarp-routing.sh
