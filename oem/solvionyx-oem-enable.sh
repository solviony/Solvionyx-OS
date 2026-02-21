#!/bin/bash
set -euo pipefail

FLAG="/etc/solvionyx/oem-enabled"
sudo mkdir -p /etc/solvionyx
sudo touch "$FLAG"
echo "OEM enabled: $(date -Is)" | sudo tee "$FLAG" >/dev/null
echo "OEM enabled (flag: $FLAG)"
