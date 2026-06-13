#!/bin/bash
set -e

# OpenWrt ADB Upgrade Tool
# 将 ADB 从 1.0.32 升级到 35.0.1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
    cat << 'EOF'
OpenWrt ADB Upgrade Tool

Usage:
  ./install.sh [OPTIONS]

Options:
  --host HOST       OpenWrt router IP (default: 192.168.6.1)
  --user USER       SSH username (default: root)
  --port PORT       SSH port (default: 22)
  --rebuild         Force rebuild from Docker (ignore pre-built files)
  --dry-run         Show what would be done without executing
  -h, --help        Show this help message

Examples:
  ./install.sh                          # Use pre-built files (no Docker needed)
  ./install.sh --host 192.168.1.1       # Specify router IP
  ./install.sh --rebuild                # Force rebuild from Docker
  ./install.sh --host 10.0.0.1 --port 2222
EOF
    exit 0
}

HOST="192.168.6.1"
USER="root"
PORT="22"
REBUILD=false
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREBUILT_DIR="$SCRIPT_DIR/prebuilt"
TARBALL="$SCRIPT_DIR/adb-bundle.tar.gz"
OUTPUT_DIR="$SCRIPT_DIR/output"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --rebuild) REBUILD=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1" ;;
    esac
done

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
SSH_CMD="ssh $SSH_OPTS -p $PORT ${USER}@${HOST}"

check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v ssh &>/dev/null; then
        error "ssh not found. Please install OpenSSH."
    fi

    info "Testing SSH connection..."
    if ! $SSH_CMD "echo ok" &>/dev/null; then
        error "Cannot SSH to ${USER}@${HOST}:${PORT}. Check connection."
    fi

    info "Checking OpenWrt version..."
    local version=$($SSH_CMD "cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d\"'\" -f2")
    info "OpenWrt version: $version"

    local arch=$($SSH_CMD "uname -m")
    if [[ "$arch" != "x86_64" ]]; then
        error "This tool only supports x86_64 architecture. Detected: $arch"
    fi

    info "Prerequisites OK."
}

prepare_adb() {
    # 优先使用预编译文件
    if [[ -f "$TARBALL" ]]; then
        info "Using pre-built bundle: $TARBALL ($(ls -lh "$TARBALL" | awk '{print $5}'))"
        return 0
    fi

    if [[ -d "$PREBUILT_DIR/bin" ]] && [[ -f "$PREBUILT_DIR/bin/adb" ]]; then
        info "Using pre-built files from: $PREBUILT_DIR"
        return 0
    fi

    # 如果指定了 --rebuild 或没有预编译文件，使用 Docker 构建
    if $REBUILD || [[ ! -f "$TARBALL" ]]; then
        info "No pre-built files found. Building from Docker..."
        build_with_docker
        return 0
    fi

    error "No ADB files found. Run with --rebuild to build from Docker."
}

build_with_docker() {
    if ! command -v docker &>/dev/null; then
        error "docker not found. Please install Docker or use pre-built files."
    fi

    if ! docker info &>/dev/null 2>&1; then
        warn "Docker daemon not running. Attempting to start..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            open -a Docker
            sleep 10
            docker info &>/dev/null 2>&1 || error "Docker failed to start."
        else
            error "Docker daemon is not running."
        fi
    fi

    mkdir -p "$OUTPUT_DIR"

    info "Extracting ADB and dependencies from Alpine Linux..."
    docker run --rm --platform linux/amd64 -v "$OUTPUT_DIR:/out" alpine:3.20 sh -c "
        apk update >/dev/null 2>&1
        apk add --no-cache android-tools >/dev/null 2>&1
        mkdir -p /out/lib /out/bin
        cp /usr/bin/adb /out/bin/adb
        cp /usr/bin/fastboot /out/bin/fastboot 2>/dev/null
        ldd /usr/bin/adb | awk '/=>/ {print \$3}' | while read lib; do
            [ -f \"\$lib\" ] && cp -L \"\$lib\" /out/lib/ 2>/dev/null
        done
        cp -L /lib/ld-musl-x86_64.so.1 /out/lib/ 2>/dev/null
    "

    if [[ ! -f "$OUTPUT_DIR/bin/adb" ]]; then
        error "ADB extraction failed."
    fi

    # 创建 tarball
    cd "$OUTPUT_DIR"
    tar czf "$TARBALL" bin/ lib/
    cd "$SCRIPT_DIR"

    info "Bundle built: $TARBALL ($(ls -lh "$TARBALL" | awk '{print $5}'))"
    info "Tip: Copy adb-bundle.tar.gz to prebuilt/ for future use without Docker."
}

deploy_to_router() {
    info "Deploying ADB to router..."

    if $DRY_RUN; then
        warn "Dry run mode. Would deploy to ${USER}@${HOST}"
        return 0
    fi

    # Backup old adb
    $SSH_CMD "cp /usr/bin/adb /usr/bin/adb.old 2>/dev/null || true"

    # Upload and extract
    info "Uploading bundle ($(ls -lh "$TARBALL" | awk '{print $5}'))..."
    cat "$TARBALL" | $SSH_CMD "
        mkdir -p /usr/local/lib/adb-bin
        cd /usr/local/lib/adb-bin && tar xzf -
    "

    # Create wrapper script
    info "Installing wrapper script..."
    $SSH_CMD '
        cat > /usr/bin/adb << '\''WRAPPER'\''
#!/bin/sh
export LD_LIBRARY_PATH=/usr/local/lib/adb-bin/lib:$LD_LIBRARY_PATH
exec /usr/local/lib/adb-bin/bin/adb "$@"
WRAPPER
        chmod +x /usr/bin/adb
    '

    # Test
    info "Testing new ADB..."
    local version=$($SSH_CMD "/usr/bin/adb version 2>&1")
    echo "$version"

    if echo "$version" | grep -q "35.0.1"; then
        info "ADB 35.0.1 installed successfully!"
    else
        error "ADB version check failed."
    fi
}

restart_adb_server() {
    if $DRY_RUN; then
        warn "Dry run mode. Would restart ADB server."
        return 0
    fi

    info "Restarting ADB server..."
    $SSH_CMD "
        killall adb 2>/dev/null
        sleep 1
        /usr/bin/adb start-server
        echo '=== Connected Devices ==='
        /usr/bin/adb devices -l
    "
}

print_post_install() {
    echo ""
    echo "============================================"
    echo -e "${GREEN}Installation complete!${NC}"
    echo "============================================"
    echo ""
    echo "ADB Version: 35.0.1 (upgraded from 1.0.32)"
    echo ""
    echo "Next steps:"
    echo "  1. On your phone: Settings → Developer Options → Revoke USB debugging authorizations"
    echo "  2. Reconnect USB cable"
    echo "  3. Tap 'Allow' + check 'Always allow from this computer'"
    echo "  4. Test disconnect/reconnect - should NOT prompt again"
    echo ""
    echo "To rollback:"
    echo "  ./uninstall.sh ${HOST} ${USER} ${PORT}"
    echo ""
    echo "Files installed on router:"
    echo "  /usr/local/lib/adb-bin/     # ADB binary + libraries"
    echo "  /usr/bin/adb                # Wrapper script"
    echo "  /usr/bin/adb.old            # Backup of original ADB"
    echo ""
}

main() {
    echo ""
    echo "============================================"
    echo "  OpenWrt ADB Upgrade Tool"
    echo "  1.0.32 → 35.0.1"
    echo "============================================"
    echo ""

    check_prerequisites
    prepare_adb
    deploy_to_router
    restart_adb_server
    print_post_install
}

main "$@"
