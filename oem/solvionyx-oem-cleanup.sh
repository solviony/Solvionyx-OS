#!/bin/bash
set -euo pipefail

FLAG="/etc/solvionyx/oem-enabled"
MARK="/var/lib/solvionyx/oem-cleaned"

# Only act if OEM mode was explicitly enabled
[ -f "$FLAG" ] || exit 0
[ -f "$MARK" ] && exit 0

# If OEM user exists, remove it
if id -u oem >/dev/null 2>&1; then
  userdel -r oem >/dev/null 2>&1 || true
fi

mkdir -p /var/lib/solvionyx
touch "$MARK"

exit 0
#!/bin/bash
set -euo pipefail

FLAG="/etc/solvionyx/oem-enabled"
MARK="/var/lib/solvionyx/oem-cleaned"

# Only act if OEM mode was explicitly enabled
[ -f "$FLAG" ] || exit 0
[ -f "$MARK" ] && exit 0

# If OEM user exists, remove it
if id -u oem >/dev/null 2>&1; then
  userdel -r oem >/dev/null 2>&1 || true
fi

mkdir -p /var/lib/solvionyx
touch "$MARK"

exit 0
