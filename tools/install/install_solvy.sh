#!/bin/bash
echo "Installing Solvy system integration..."
systemctl disable solvy.service >/dev/null 2>&1 || true
cp systemd/solvy.service /usr/lib/systemd/system/
systemctl daemon-reload
systemctl enable solvy.service
echo "Solvy service enabled."
