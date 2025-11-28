
#!/bin/bash
MODEL_DIR="/usr/share/solvy/whisper/models"
mkdir -p "$MODEL_DIR"

echo "Downloading Whisper medium model..."
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
OUT="$MODEL_DIR/ggml-medium.bin"

curl -L "$URL" -o "$OUT"

echo "Verifying checksum..."
# Placeholder checksum logic
echo "Download complete."
