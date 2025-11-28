#!/bin/bash
echo "Updating Solvy components..."
systemctl stop solvy.service
# sync folders placeholder
systemctl start solvy.service
echo "Solvy updated."
