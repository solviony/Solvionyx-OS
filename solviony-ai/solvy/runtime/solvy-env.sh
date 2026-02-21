#!/bin/sh

KEY_BASE="/etc/solvionyx/ai/keys"

if [ -f "$KEY_BASE/openai.key" ]; then
  export OPENAI_API_KEY="$(cat "$KEY_BASE/openai.key")"
fi

if [ -f "$KEY_BASE/gemini.key" ]; then
  export GEMINI_API_KEY="$(cat "$KEY_BASE/gemini.key")"
fi
