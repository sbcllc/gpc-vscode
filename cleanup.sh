#!/bin/bash
#
# cleanup.sh - Remove all GCP resources created by deploy.sh
#
# This script removes the VM, firewall rules, and optionally the HTTPS
# load balancer resources.
#
# Usage:
#   ./cleanup.sh [options]
#
# Options:
#   -h, --help          Show this help message
#   -e, --env FILE      Load configuration from env file (default: .env)
#   --dry-run           Show what would be deleted without making changes
#   -y, --yes           Skip confirmation prompt
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

DRY_RUN=false
SKIP_CONFIRM=false
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
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                SKIP_CONFIRM=true
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
    
    # Check required variables
    if [[ -z "$GCP_PROJECT_ID" ]]; then
        log_error "GCP_PROJECT_ID is required. Set it in .env or as environment variable."
        exit 1
    fi
}

# Delete resource if exists
delete_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local extra_args="${3:-}"
    
    log_info "Checking $resource_type: $resource_name"
    
    local describe_cmd="gcloud compute $resource_type describe $resource_name --project=$GCP_PROJECT_ID $extra_args"
    local delete_cmd="gcloud compute $resource_type delete $resource_name --project=$GCP_PROJECT_ID $extra_args --quiet"
    
    if eval "$describe_cmd" &>/dev/null; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would delete $resource_type: $resource_name"
        else
            log_info "Deleting $resource_type: $resource_name"
            eval "$delete_cmd" || log_warn "Failed to delete $resource_type: $resource_name"
        fi
    else
        log_info "$resource_type not found: $resource_name (skipping)"
    fi
}

# Delete forwarding rule
delete_forwarding_rule() {
    local name="$1"
    local scope="$2"
    
    local scope_flag=""
    if [[ "$scope" == "global" ]]; then
        scope_flag="--global"
    fi
    
    delete_resource "forwarding-rules" "$name" "$scope_flag"
}

# Delete target HTTPS proxy
delete_https_proxy() {
    local name="$1"
    delete_resource "target-https-proxies" "$name" ""
}

# Delete URL map
delete_url_map() {
    local name="$1"
    delete_resource "url-maps" "$name" ""
}

# Delete backend service
delete_backend_service() {
    local name="$1"
    delete_resource "backend-services" "$name" "--global"
}

# Delete health check
delete_health_check() {
    local name="$1"
    delete_resource "health-checks" "$name" ""
}

# Delete instance group
delete_instance_group() {
    local name="$1"
    delete_resource "instance-groups unmanaged" "$name" "--zone=$GCP_ZONE"
}

# Delete SSL certificate
delete_ssl_certificate() {
    local name="$1"
    delete_resource "ssl-certificates" "$name" ""
}

# Delete static IP
delete_static_ip() {
    local name="$1"
    delete_resource "addresses" "$name" "--global"
}

# Delete VM instance
delete_vm() {
    delete_resource "instances" "$VM_NAME" "--zone=$GCP_ZONE"
}

# Delete firewall rules
delete_firewall_rules() {
    local fw_rules=(
        "allow-iap-tunnel-${VM_NAME}"
        "allow-lb-${VM_NAME}"
    )
    
    for rule in "${fw_rules[@]}"; do
        delete_resource "firewall-rules" "$rule" ""
    done
}

# Main cleanup function
cleanup() {
    log_info "Starting cleanup..."
    
    # HTTPS Load Balancer resources (must be deleted in order)
    delete_forwarding_rule "${VM_NAME}-forwarding-rule" "global"
    delete_https_proxy "${VM_NAME}-https-proxy"
    delete_url_map "${VM_NAME}-url-map"
    delete_backend_service "${VM_NAME}-backend"
    delete_health_check "${VM_NAME}-health-check"
    delete_instance_group "${VM_NAME}-ig"
    delete_ssl_certificate "${VM_NAME}-cert"
    delete_static_ip "${VM_NAME}-ip"
    
    # VM and firewall rules
    delete_vm
    delete_firewall_rules
    
    log_success "Cleanup complete!"
}

# Confirm cleanup
confirm_cleanup() {
    if [[ "$SKIP_CONFIRM" == "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    
    echo ""
    log_warn "This will delete the following resources:"
    echo "  - VM: $VM_NAME"
    echo "  - Firewall rules"
    echo "  - HTTPS Load Balancer resources (if configured)"
    echo ""
    
    read -r -p "Are you sure you want to continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log_info "Cleanup cancelled"
            exit 0
            ;;
    esac
}

# Main function
main() {
    parse_args "$@"
    load_env
    
    echo ""
    log_info "=========================================="
    log_info "GCP code-server Cleanup"
    log_info "=========================================="
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "Running in DRY-RUN mode - no changes will be made"
        echo ""
    fi
    
    check_prerequisites
    confirm_cleanup
    
    # Set project
    gcloud config set project "$GCP_PROJECT_ID" --quiet 2>/dev/null || true
    
    cleanup
}

main "$@"
