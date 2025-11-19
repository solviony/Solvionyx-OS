# Solvionyx APT Repository Builder

Includes:
- Repository structure
- Key signing
- Build scripts
- Upload scripts

Usage:
  ./scripts/add_package.sh package.deb
  ./scripts/build_repo.sh
  ./scripts/sign_repo.sh
  GCS_BUCKET=solvionyx-os ./scripts/upload_repo.sh
