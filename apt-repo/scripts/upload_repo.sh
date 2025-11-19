#!/usr/bin/env bash
set -e

if [ -z "$GCS_BUCKET" ]; then
  echo "Set GCS_BUCKET environment variable."
  exit 1
fi

echo "[Solvionyx] Uploading repo to GCS bucket: $GCS_BUCKET"

gsutil -m rsync -r repo "gs://$GCS_BUCKET/repo"

echo "[Solvionyx] Upload complete."
