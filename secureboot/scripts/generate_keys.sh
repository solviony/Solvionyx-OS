#!/usr/bin/env bash
set -e

mkdir -p keys

echo "[Solvionyx] Generating Secure Boot keys..."

openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -subj "/CN=Solvionyx Platform Key/" \
  -keyout keys/PK.key -out keys/PK.crt

openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -subj "/CN=Solvionyx Key Exchange Key/" \
  -keyout keys/KEK.key -out keys/KEK.crt

openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -subj "/CN=Solvionyx Signature Database/" \
  -keyout keys/DB.key -out keys/DB.crt

echo "[Solvionyx] Keys generated:"
echo "PK.key / PK.crt"
echo "KEK.key / KEK.crt"
echo "DB.key / DB.crt"
