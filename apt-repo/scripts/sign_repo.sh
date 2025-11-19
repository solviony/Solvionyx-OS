#!/usr/bin/env bash
set -e

echo "[Solvionyx] Signing repository with GPG key..."

gpg --batch --yes --default-key "Solvionyx Repo" \
    -abs -o repo/dists/stable/Release.gpg repo/dists/stable/Release

gpg --batch --yes --default-key "Solvionyx Repo" \
    --clearsign -o repo/dists/stable/InRelease repo/dists/stable/Release

echo "[Solvionyx] Repo signed."
