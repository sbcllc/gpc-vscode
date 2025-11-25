#!/bin/bash
#
# connect.sh - Connect to code-server via IAP tunnel
#
# This script establishes an IAP tunnel to the code-server VM and opens
# the browser to access VS Code.
#
# Usage:
#   ./connect.sh [options]
#
# Options:
#   -h, --help          Show this help message
#   -e, --env FILE      Load configuration from env file (default: .env)
#   -p, --port PORT     Local port to use (default: 8080)
#   --no-browser        Don't open browser automatically
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Default configuration
: "${GCP_PROJECT_ID:=}"
: "${GCP_ZONE:=us-central1-a}"
: "${VM_NAME:=code-server-vm}"

LOCAL_PORT=8080
NO_BROWSER=false
ENV_FILE=".env"

# Show help
show_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^#//' | sed 's/^ //'
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -e|--env)
                ENV_FILE="$2"
                shift 2
                ;;
            -p|--port)
                LOCAL_PORT="$2"
                shift 2
                ;;
            --no-browser)
                NO_BROWSER=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

# Load environment file
load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        log_info "Loading configuration from $ENV_FILE"
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    elif [[ "$ENV_FILE" != ".env" ]]; then
        log_error "Environment file not found: $ENV_FILE"
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    # Check gcloud CLI
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI not found. Please install Google Cloud SDK."
        exit 1
    fi
    
    # Check if authenticated
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
        log_error "Not authenticated with gcloud. Please run: gcloud auth login"
        exit 1
    fi
    
    # Check required variables
    if [[ -z "$GCP_PROJECT_ID" ]]; then
        log_error "GCP_PROJECT_ID is required. Set it in .env or as environment variable."
        exit 1
    fi
}

# Check if VM exists and is running
check_vm() {
    log_info "Checking VM status..."
    
    local vm_status
    vm_status=$(gcloud compute instances describe "$VM_NAME" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT_ID" \
        --format="value(status)" 2>/dev/null) || {
        log_error "VM $VM_NAME not found in zone $GCP_ZONE"
        log_info "Run ./deploy.sh first to create the VM"
        exit 1
    }
    
    if [[ "$vm_status" != "RUNNING" ]]; then
        log_warn "VM is not running (status: $vm_status)"
        log_info "Starting VM..."
        gcloud compute instances start "$VM_NAME" \
            --zone="$GCP_ZONE" \
            --project="$GCP_PROJECT_ID"
        sleep 10
    fi
    
    log_success "VM is running"
}

# Open browser
open_browser() {
    if [[ "$NO_BROWSER" == "true" ]]; then
        return 0
    fi
    
    local url="http://localhost:$LOCAL_PORT"
    
    # Wait a moment for the tunnel to establish
    sleep 3
    
    log_info "Opening browser: $url"
    
    # Try different methods to open browser
    if command -v xdg-open &> /dev/null; then
        xdg-open "$url" 2>/dev/null &
    elif command -v open &> /dev/null; then
        open "$url" 2>/dev/null &
    elif command -v start &> /dev/null; then
        start "$url" 2>/dev/null &
    else
        log_warn "Could not open browser automatically"
        log_info "Please open: $url"
    fi
}

# Start IAP tunnel
start_tunnel() {
    log_info "Starting IAP tunnel..."
    log_info "VM: $VM_NAME"
    log_info "Zone: $GCP_ZONE"
    log_info "Local port: $LOCAL_PORT"
    echo ""
    
    log_success "=========================================="
    log_success "Tunnel starting..."
    log_success "=========================================="
    echo ""
    log_info "Access VS Code at: http://localhost:$LOCAL_PORT"
    log_info "Press Ctrl+C to stop the tunnel"
    echo ""
    
    # Open browser in background
    open_browser &
    
    # Start the tunnel
    gcloud compute start-iap-tunnel "$VM_NAME" 8080 \
        --local-host-port="localhost:$LOCAL_PORT" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT_ID"
}

# Main function
main() {
    parse_args "$@"
    load_env
    
    echo ""
    log_info "=========================================="
    log_info "Connecting to code-server via IAP"
    log_info "=========================================="
    echo ""
    
    check_prerequisites
    check_vm
    start_tunnel
}

main "$@"
