#!/bin/bash
echo "Merging all Solvy v3 chunks into final suite..."

mkdir -p solvy_v3_full

unzip solvy_daemon_v3.zip -d solvy_v3_full/
unzip solvy_gui_v3.zip -d solvy_v3_full/
unzip solvy_providers_v3.zip -d solvy_v3_full/
unzip solvionyx_store_branding.zip -d solvy_v3_full/
unzip solvy_whisper_v3.zip -d solvy_v3_full/ 2>/dev/null || true
unzip solvy_portable.zip -d solvy_v3_full/ 2>/dev/null || true

echo "Done! Final suite located at: solvy_v3_full/"
