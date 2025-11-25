#!/bin/bash
#
# deploy.sh - Deploy a secure VS Code (code-server) environment on GCP
#
# This script creates a VM with code-server and configures IAP for secure access.
# Only authorized Google accounts can connect - no VPN or SSH keys needed.
#
# Usage:
#   ./deploy.sh [options]
#
# Options:
#   -h, --help          Show this help message
#   -e, --env FILE      Load configuration from env file (default: .env)
#   --dry-run           Show what would be done without making changes
#   --https             Enable HTTPS load balancer setup
#
# Environment Variables:
#   GCP_PROJECT_ID      (required) GCP project ID
#   IAP_ALLOWED_EMAILS  (required) Comma-separated list of allowed emails
#   GCP_REGION          GCP region (default: us-central1)
#   GCP_ZONE            GCP zone (default: us-central1-a)
#   VM_NAME             VM instance name (default: code-server-vm)
#   VM_MACHINE_TYPE     VM machine type (default: e2-medium)
#   BOOT_DISK_SIZE      Boot disk size in GB (default: 50)
#   ENABLE_HTTPS_LB     Enable HTTPS load balancer (default: false)
#   CUSTOM_DOMAIN       Domain for HTTPS access (required if ENABLE_HTTPS_LB=true)
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
: "${GCP_REGION:=us-central1}"
: "${GCP_ZONE:=us-central1-a}"
: "${VM_NAME:=code-server-vm}"
: "${VM_MACHINE_TYPE:=e2-medium}"
: "${BOOT_DISK_SIZE:=50}"
: "${BOOT_DISK_TYPE:=pd-balanced}"
: "${CODE_SERVER_VERSION:=}"
: "${ENABLE_HTTPS_LB:=false}"
: "${CUSTOM_DOMAIN:=}"
: "${SERVICE_ACCOUNT:=}"
: "${VM_NETWORK_TAGS:=iap-tunnel,code-server}"
: "${RESOURCE_LABELS:=environment=development,app=code-server}"

DRY_RUN=false
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
            --https)
                ENABLE_HTTPS_LB=true
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
        # shellcheck source=/dev/null
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
    log_info "Checking prerequisites..."
    
    # Check gcloud CLI
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI not found. Please install Google Cloud SDK."
        log_error "Visit: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    # Check if authenticated
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
        log_error "Not authenticated with gcloud. Please run: gcloud auth login"
        exit 1
    fi
    
    # Check required variables
    if [[ -z "${GCP_PROJECT_ID:-}" ]]; then
        log_error "GCP_PROJECT_ID is required. Set it in .env or as environment variable."
        exit 1
    fi
    
    if [[ -z "${IAP_ALLOWED_EMAILS:-}" ]]; then
        log_error "IAP_ALLOWED_EMAILS is required. Set it in .env or as environment variable."
        exit 1
    fi
    
    # Check HTTPS requirements
    if [[ "$ENABLE_HTTPS_LB" == "true" ]] && [[ -z "$CUSTOM_DOMAIN" ]]; then
        log_error "CUSTOM_DOMAIN is required when ENABLE_HTTPS_LB is true"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Enable required APIs
enable_apis() {
    log_info "Enabling required GCP APIs..."
    
    local apis=(
        "compute.googleapis.com"
        "iap.googleapis.com"
    )
    
    if [[ "$ENABLE_HTTPS_LB" == "true" ]]; then
        apis+=("certificatemanager.googleapis.com")
    fi
    
    for api in "${apis[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would enable API: $api"
        else
            log_info "Enabling $api..."
            gcloud services enable "$api" --project="$GCP_PROJECT_ID" --quiet
        fi
    done
    
    log_success "APIs enabled"
}

# Create firewall rule for IAP
create_firewall_rules() {
    log_info "Creating firewall rules for IAP..."
    
    local fw_rule_name="allow-iap-tunnel-${VM_NAME}"
    
    # Check if firewall rule exists
    if gcloud compute firewall-rules describe "$fw_rule_name" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Firewall rule $fw_rule_name already exists"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create firewall rule: $fw_rule_name"
        return 0
    fi
    
    # IAP uses IP range 35.235.240.0/20
    gcloud compute firewall-rules create "$fw_rule_name" \
        --project="$GCP_PROJECT_ID" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:22,tcp:8080 \
        --source-ranges=35.235.240.0/20 \
        --target-tags=iap-tunnel \
        --description="Allow IAP tunnel access to code-server"
    
    log_success "Firewall rule created: $fw_rule_name"
}

# Create the VM instance
create_vm() {
    log_info "Creating VM instance: $VM_NAME..."
    
    # Check if VM exists
    if gcloud compute instances describe "$VM_NAME" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_warn "VM $VM_NAME already exists in zone $GCP_ZONE"
        log_info "Use ./cleanup.sh to remove existing resources first"
        return 0
    fi
    
    # Build startup script path
    local startup_script="$SCRIPT_DIR/scripts/startup-script.sh"
    
    if [[ ! -f "$startup_script" ]]; then
        log_error "Startup script not found: $startup_script"
        exit 1
    fi
    
    # Prepare gcloud command arguments
    local vm_args=(
        "--project=$GCP_PROJECT_ID"
        "--zone=$GCP_ZONE"
        "--machine-type=$VM_MACHINE_TYPE"
        "--boot-disk-size=${BOOT_DISK_SIZE}GB"
        "--boot-disk-type=$BOOT_DISK_TYPE"
        "--image-family=ubuntu-2204-lts"
        "--image-project=ubuntu-os-cloud"
        "--tags=${VM_NETWORK_TAGS}"
        "--labels=${RESOURCE_LABELS}"
        "--metadata-from-file=startup-script=$startup_script"
        "--scopes=cloud-platform"
    )
    
    # Add code-server version metadata if specified
    if [[ -n "$CODE_SERVER_VERSION" ]]; then
        vm_args+=("--metadata=code-server-version=$CODE_SERVER_VERSION")
    fi
    
    # Add service account if specified
    if [[ -n "$SERVICE_ACCOUNT" ]]; then
        vm_args+=("--service-account=$SERVICE_ACCOUNT")
    fi
    
    # No external IP for security - access only via IAP
    vm_args+=("--no-address")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create VM with:"
        log_info "  gcloud compute instances create $VM_NAME ${vm_args[*]}"
        return 0
    fi
    
    gcloud compute instances create "$VM_NAME" "${vm_args[@]}"
    
    log_success "VM created: $VM_NAME"
    log_info "Waiting for VM to start and install code-server (this may take a few minutes)..."
}

# Configure IAP access
configure_iap() {
    log_info "Configuring IAP access..."
    
    # Convert comma-separated emails to individual IAM bindings
    IFS=',' read -ra EMAILS <<< "$IAP_ALLOWED_EMAILS"
    
    for email in "${EMAILS[@]}"; do
        email=$(echo "$email" | xargs)  # Trim whitespace
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would grant IAP access to: $email"
            continue
        fi
        
        log_info "Granting IAP access to: $email"
        
        gcloud compute instances add-iam-policy-binding "$VM_NAME" \
            --project="$GCP_PROJECT_ID" \
            --zone="$GCP_ZONE" \
            --role="roles/iap.tunnelResourceAccessor" \
            --member="user:$email" \
            --quiet
    done
    
    log_success "IAP access configured"
}

# Setup HTTPS Load Balancer (optional)
setup_https_lb() {
    if [[ "$ENABLE_HTTPS_LB" != "true" ]]; then
        return 0
    fi
    
    log_info "Setting up HTTPS Load Balancer..."
    
    local neg_name="${VM_NAME}-neg"
    local backend_name="${VM_NAME}-backend"
    local health_check_name="${VM_NAME}-health-check"
    local url_map_name="${VM_NAME}-url-map"
    local proxy_name="${VM_NAME}-https-proxy"
    local cert_name="${VM_NAME}-cert"
    local forwarding_rule_name="${VM_NAME}-forwarding-rule"
    local ip_name="${VM_NAME}-ip"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create HTTPS LB resources:"
        log_info "  - Reserved IP: $ip_name"
        log_info "  - SSL Certificate: $cert_name for $CUSTOM_DOMAIN"
        log_info "  - Health check: $health_check_name"
        log_info "  - Network Endpoint Group: $neg_name"
        log_info "  - Backend service: $backend_name"
        log_info "  - URL map: $url_map_name"
        log_info "  - HTTPS proxy: $proxy_name"
        log_info "  - Forwarding rule: $forwarding_rule_name"
        return 0
    fi
    
    # Reserve static IP
    if ! gcloud compute addresses describe "$ip_name" \
        --global \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Reserving static IP..."
        gcloud compute addresses create "$ip_name" \
            --project="$GCP_PROJECT_ID" \
            --global \
            --ip-version=IPV4
    fi
    
    local static_ip
    static_ip=$(gcloud compute addresses describe "$ip_name" \
        --global \
        --project="$GCP_PROJECT_ID" \
        --format="value(address)")
    log_info "Static IP: $static_ip"
    
    # Create managed SSL certificate
    if ! gcloud compute ssl-certificates describe "$cert_name" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating managed SSL certificate..."
        gcloud compute ssl-certificates create "$cert_name" \
            --project="$GCP_PROJECT_ID" \
            --domains="$CUSTOM_DOMAIN" \
            --global
    fi
    
    # Create health check
    if ! gcloud compute health-checks describe "$health_check_name" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating health check..."
        gcloud compute health-checks create http "$health_check_name" \
            --project="$GCP_PROJECT_ID" \
            --port=8080 \
            --request-path="/"
    fi
    
    # Create instance group and add VM
    local ig_name="${VM_NAME}-ig"
    if ! gcloud compute instance-groups unmanaged describe "$ig_name" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating instance group..."
        gcloud compute instance-groups unmanaged create "$ig_name" \
            --project="$GCP_PROJECT_ID" \
            --zone="$GCP_ZONE"
        
        gcloud compute instance-groups unmanaged add-instances "$ig_name" \
            --project="$GCP_PROJECT_ID" \
            --zone="$GCP_ZONE" \
            --instances="$VM_NAME"
        
        gcloud compute instance-groups unmanaged set-named-ports "$ig_name" \
            --project="$GCP_PROJECT_ID" \
            --zone="$GCP_ZONE" \
            --named-ports=http:8080
    fi
    
    # Create backend service
    if ! gcloud compute backend-services describe "$backend_name" \
        --global \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating backend service..."
        gcloud compute backend-services create "$backend_name" \
            --project="$GCP_PROJECT_ID" \
            --global \
            --protocol=HTTP \
            --port-name=http \
            --health-checks="$health_check_name" \
            --iap=enabled
        
        gcloud compute backend-services add-backend "$backend_name" \
            --project="$GCP_PROJECT_ID" \
            --global \
            --instance-group="$ig_name" \
            --instance-group-zone="$GCP_ZONE"
    fi
    
    # Configure IAP on backend service
    for email in "${EMAILS[@]}"; do
        email=$(echo "$email" | xargs)
        gcloud iap web add-iam-policy-binding \
            --project="$GCP_PROJECT_ID" \
            --resource-type=backend-services \
            --service="$backend_name" \
            --role="roles/iap.httpsResourceAccessor" \
            --member="user:$email" \
            --quiet 2>/dev/null || true
    done
    
    # Create URL map
    if ! gcloud compute url-maps describe "$url_map_name" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating URL map..."
        gcloud compute url-maps create "$url_map_name" \
            --project="$GCP_PROJECT_ID" \
            --default-service="$backend_name"
    fi
    
    # Create HTTPS proxy
    if ! gcloud compute target-https-proxies describe "$proxy_name" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating HTTPS proxy..."
        gcloud compute target-https-proxies create "$proxy_name" \
            --project="$GCP_PROJECT_ID" \
            --ssl-certificates="$cert_name" \
            --url-map="$url_map_name"
    fi
    
    # Create forwarding rule
    if ! gcloud compute forwarding-rules describe "$forwarding_rule_name" \
        --global \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating forwarding rule..."
        gcloud compute forwarding-rules create "$forwarding_rule_name" \
            --project="$GCP_PROJECT_ID" \
            --global \
            --address="$ip_name" \
            --target-https-proxy="$proxy_name" \
            --ports=443
    fi
    
    # Allow traffic from load balancer
    local lb_fw_rule="allow-lb-${VM_NAME}"
    if ! gcloud compute firewall-rules describe "$lb_fw_rule" \
        --project="$GCP_PROJECT_ID" &>/dev/null; then
        log_info "Creating firewall rule for load balancer..."
        gcloud compute firewall-rules create "$lb_fw_rule" \
            --project="$GCP_PROJECT_ID" \
            --direction=INGRESS \
            --priority=1000 \
            --network=default \
            --action=ALLOW \
            --rules=tcp:8080 \
            --source-ranges=130.211.0.0/22,35.191.0.0/16 \
            --target-tags=code-server \
            --description="Allow load balancer health checks and traffic"
    fi
    
    log_success "HTTPS Load Balancer setup complete"
    log_warn "Please configure your DNS:"
    log_info "  Add an A record: $CUSTOM_DOMAIN -> $static_ip"
    log_info "  SSL certificate provisioning may take up to 24 hours"
}

# Print connection instructions
print_instructions() {
    echo ""
    log_success "=========================================="
    log_success "Deployment complete!"
    log_success "=========================================="
    echo ""
    
    log_info "VM Name: $VM_NAME"
    log_info "Zone: $GCP_ZONE"
    log_info "Project: $GCP_PROJECT_ID"
    echo ""
    
    log_info "To connect via IAP tunnel (recommended):"
    echo ""
    echo "  1. Start the tunnel:"
    echo "     gcloud compute start-iap-tunnel $VM_NAME 8080 \\"
    echo "       --local-host-port=localhost:8080 \\"
    echo "       --zone=$GCP_ZONE \\"
    echo "       --project=$GCP_PROJECT_ID"
    echo ""
    echo "  2. Open in browser:"
    echo "     http://localhost:8080"
    echo ""
    echo "  Or use the helper script:"
    echo "     ./connect.sh"
    echo ""
    
    if [[ "$ENABLE_HTTPS_LB" == "true" ]]; then
        log_info "HTTPS Access (after DNS configuration):"
        echo "     https://$CUSTOM_DOMAIN"
        echo ""
    fi
    
    log_info "Allowed users:"
    IFS=',' read -ra EMAILS <<< "$IAP_ALLOWED_EMAILS"
    for email in "${EMAILS[@]}"; do
        echo "  - $(echo "$email" | xargs)"
    done
    echo ""
    
    log_info "To clean up resources:"
    echo "     ./cleanup.sh"
    echo ""
}

# Main function
main() {
    parse_args "$@"
    load_env
    
    echo ""
    log_info "=========================================="
    log_info "GCP VS Code (code-server) Deployment"
    log_info "=========================================="
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "Running in DRY-RUN mode - no changes will be made"
        echo ""
    fi
    
    # Set project
    gcloud config set project "$GCP_PROJECT_ID" --quiet 2>/dev/null || true
    
    check_prerequisites
    enable_apis
    create_firewall_rules
    create_vm
    configure_iap
    setup_https_lb
    print_instructions
}

main "$@"
