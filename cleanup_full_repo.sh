#!/bin/bash
set -e

echo "======================================================="
echo "   🧹 Solvionyx OS — Full Repository Cleanup (Mode A)"
echo "======================================================="

###############################
# 1. REMOVE LEGACY VERSIONS
###############################
echo "🗑 Removing old OS version folders..."
rm -rf Solvionyx-OS-v4.3.6-Aurora || true
rm -rf Solvionyx-OS-v4.3.7-Aurora || true
rm -rf Solvionyx-OS-v4.3.8-Aurora || true

###############################
# 2. REMOVE BACKUP SCRIPTS
###############################
echo "🗑 Removing backup_sh_scripts (legacy Debian scripts)..."
rm -rf backup_sh_scripts || true

###############################
# 3. REMOVE TRASH & TEMP FILES
###############################
echo "🗑 Removing temp/test files..."
rm -f test.txt verify.txt cubic.conf || true

###############################
# 4. REMOVE REDUNDANT OLD WORKFLOWS
###############################
echo "🗑 Removing old GitHub workflow files..."
rm -f .github/workflows/auto_update_changelog.yml || true
rm -f .github/workflows/auto_changelog.yml || true
rm -f .github/workflows/auto_version_tag.yml || true
rm -f .github/workflows/build_all_editions.yml.bak || true

###############################
# 5. REMOVE OLD README AUTOBUILD
###############################
echo "🗑 Removing deprecated README_AUTOBUILD.md..."
rm -f README_AUTOBUILD.md || true

###############################
# 6. ENSURE ORGANIZED FOLDERS EXIST
###############################
echo "📁 Ensuring modern repo structure..."
mkdir -p builder branding recovery oem apt-repo app-store system-manager docs assets

###############################
# 7. MOVE ASSETS INTO assets/
###############################
echo "📁 Moving stray brand files into assets/..."
mkdir -p assets

if [ -f branding/logo.png ]; then cp branding/logo.png assets/logo.png; fi
if [ -f branding/bg.png ]; then cp branding/bg.png assets/bg.png; fi

###############################
# 8. CLEAN EMPTY FOLDERS
###############################
find . -type d -empty -delete

echo "======================================================="
echo "  ✨ Cleanup Complete — Your Repository Is Now Clean!  "
echo "======================================================="
