#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

HOST="${1:-192.168.6.1}"
USER="${2:-root}"
PORT="${3:-22}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
SSH_CMD="ssh $SSH_OPTS -p $PORT ${USER}@${HOST}"

echo ""
echo "============================================"
echo "  OpenWrt ADB Rollback Tool"
echo "  35.0.1 → 1.0.32"
echo "============================================"
echo ""

info "Checking for backup..."
if ! $SSH_CMD "test -f /usr/bin/adb.old" 2>/dev/null; then
    error "No backup found at /usr/bin/adb.old. Cannot rollback."
fi

info "Current ADB version:"
$SSH_CMD "/usr/bin/adb version 2>&1" || true

read -p "Rollback to old ADB? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
fi

info "Restoring old ADB..."
$SSH_CMD "
    cp /usr/bin/adb.old /usr/bin/adb
    killall adb 2>/dev/null
    sleep 1
    /usr/bin/adb start-server
    echo '=== Version ==='
    /usr/bin/adb version
    echo '=== Devices ==='
    /usr/bin/adb devices -l
"

info "Removing upgraded ADB files..."
$SSH_CMD "rm -rf /usr/local/lib/adb-bin"

read -p "Remove wrapper script and old backup? (y/N) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    $SSH_CMD "rm -f /usr/bin/adb.old /usr/bin/adb-new"
    info "Cleaned up."
fi

echo ""
info "Rollback complete. ADB has been restored to the original version."
echo ""
