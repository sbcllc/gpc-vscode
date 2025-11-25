#!/bin/bash
set -e

#===============================================================================
# GCP VS Code Remote Development Setup with Identity-Aware Proxy (IAP)
#===============================================================================
# This script sets up a secure VS Code development environment on GCP that you
# can access from your Chromebook via a browser. Access is protected by IAP,
# meaning only authorized Google accounts can connect.
#
# Two access methods are configured:
#   1. IAP Tunnel (simple): Run a gcloud command, then access localhost:8080
#   2. HTTPS Load Balancer (advanced): Access via a custom domain with Google login
#===============================================================================

#-------------------------------------------------------------------------------
# DEFAULT CONFIGURATION - Can be overridden by environment variables
#-------------------------------------------------------------------------------

# VM Configuration (override with env vars if needed)
VM_NAME="${VM_NAME:-dev-workstation}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"  # 4 vCPU, 16GB RAM
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-100GB}"

# For HTTPS Load Balancer (optional)
ENABLE_LOAD_BALANCER="${ENABLE_LOAD_BALANCER:-false}"
DOMAIN_NAME="${DOMAIN_NAME:-}"

# Additional authorized users (space-separated)
ADDITIONAL_USERS="${ADDITIONAL_USERS:-}"

# These will be set interactively
PROJECT_ID=""
AUTHORIZED_EMAIL=""

#-------------------------------------------------------------------------------
# Color output helpers
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#-------------------------------------------------------------------------------
# Check prerequisites
#-------------------------------------------------------------------------------
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check for gcloud
    if ! command -v gcloud &> /dev/null; then
        print_error "gcloud CLI is not installed. Please install it first:"
        echo "  https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
    
    # Check authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 | grep -q '@'; then
        print_error "Not authenticated with gcloud. Please run: gcloud auth login"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

#-------------------------------------------------------------------------------
# Get authenticated user email
#-------------------------------------------------------------------------------
get_user_email() {
    print_status "Detecting authenticated user..."
    
    # Get the active account from gcloud
    AUTHORIZED_EMAIL=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
    
    if [[ -z "$AUTHORIZED_EMAIL" ]]; then
        print_error "Could not detect authenticated user. Please run: gcloud auth login"
        exit 1
    fi
    
    echo ""
    echo -e "Detected authenticated user: ${GREEN}${AUTHORIZED_EMAIL}${NC}"
    echo ""
    read -p "Use this account? (Y/n): " confirm
    
    if [[ "$confirm" =~ ^[Nn] ]]; then
        read -p "Enter the email address to use: " AUTHORIZED_EMAIL
        if [[ -z "$AUTHORIZED_EMAIL" ]]; then
            print_error "Email address is required"
            exit 1
        fi
    fi
    
    print_success "Using account: $AUTHORIZED_EMAIL"
}

#-------------------------------------------------------------------------------
# Select or create project
#-------------------------------------------------------------------------------
select_or_create_project() {
    echo ""
    print_status "Fetching your GCP projects..."
    
    # Get list of projects
    local projects
    projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
    
    if [[ -z "$projects" ]]; then
        print_warning "No existing projects found."
        create_new_project
        return
    fi
    
    # Convert to array
    local project_array=()
    while IFS= read -r line; do
        project_array+=("$line")
    done <<< "$projects"
    
    local num_projects=${#project_array[@]}
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "                           SELECT A PROJECT"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Display projects with numbers
    local i=1
    for project in "${project_array[@]}"; do
        echo "  $i) $project"
        ((i++))
    done
    
    echo ""
    echo "  N) Create a NEW project"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    while true; do
        read -p "Enter your choice (1-$num_projects or N): " choice
        
        # Check if user wants to create new project
        if [[ "$choice" =~ ^[Nn]$ ]]; then
            create_new_project
            return
        fi
        
        # Validate numeric input
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num_projects )); then
            PROJECT_ID="${project_array[$((choice-1))]}"
            print_success "Selected project: $PROJECT_ID"
            
            # Verify billing is enabled
            check_billing
            return
        fi
        
        print_error "Invalid choice. Please enter a number between 1 and $num_projects, or N for new project."
    done
}

#-------------------------------------------------------------------------------
# Create a new project
#-------------------------------------------------------------------------------
create_new_project() {
    echo ""
    print_status "Creating a new GCP project..."
    echo ""
    
    while true; do
        read -p "Enter a project ID (lowercase letters, numbers, hyphens; 6-30 chars): " PROJECT_ID
        
        # Validate project ID format
        if [[ ! "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
            print_error "Invalid project ID format. Must be 6-30 characters, start with a letter,"
            echo "         contain only lowercase letters, numbers, and hyphens, and end with a letter or number."
            continue
        fi
        
        # Check if project ID already exists
        if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
            print_error "Project '$PROJECT_ID' already exists. Please choose a different name."
            continue
        fi
        
        break
    done
    
    read -p "Enter a project name (display name, can have spaces) [$PROJECT_ID]: " project_name
    project_name="${project_name:-$PROJECT_ID}"
    
    print_status "Creating project '$PROJECT_ID'..."
    
    if gcloud projects create "$PROJECT_ID" --name="$project_name"; then
        print_success "Project created: $PROJECT_ID"
    else
        print_error "Failed to create project. Please check your permissions."
        exit 1
    fi
    
    # Link billing account
    link_billing_account
}

#-------------------------------------------------------------------------------
# Check if billing is enabled
#-------------------------------------------------------------------------------
check_billing() {
    print_status "Checking billing status..."
    
    local billing_enabled
    billing_enabled=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null)
    
    if [[ "$billing_enabled" != "True" ]]; then
        print_warning "Billing is not enabled for project '$PROJECT_ID'."
        echo ""
        read -p "Would you like to link a billing account now? (Y/n): " confirm
        
        if [[ ! "$confirm" =~ ^[Nn] ]]; then
            link_billing_account
        else
            print_error "Billing must be enabled to create compute resources."
            echo "Please enable billing at: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
            exit 1
        fi
    else
        print_success "Billing is enabled"
    fi
}

#-------------------------------------------------------------------------------
# Link a billing account to the project
#-------------------------------------------------------------------------------
link_billing_account() {
    print_status "Fetching available billing accounts..."
    
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter="open=true" --format="value(name,displayName)" 2>/dev/null)
    
    if [[ -z "$billing_accounts" ]]; then
        print_error "No billing accounts found. Please create one at:"
        echo "  https://console.cloud.google.com/billing"
        exit 1
    fi
    
    # Parse billing accounts
    local account_ids=()
    local account_names=()
    
    while IFS=$'\t' read -r id name; do
        # Extract just the account ID (remove 'billingAccounts/' prefix if present)
        id="${id#billingAccounts/}"
        account_ids+=("$id")
        account_names+=("$name")
    done <<< "$billing_accounts"
    
    local num_accounts=${#account_ids[@]}
    
    if (( num_accounts == 1 )); then
        # Only one billing account, use it automatically
        local billing_account="${account_ids[0]}"
        print_status "Using billing account: ${account_names[0]}"
    else
        # Multiple accounts, let user choose
        echo ""
        echo "Available billing accounts:"
        echo ""
        
        local i=1
        for idx in "${!account_ids[@]}"; do
            echo "  $i) ${account_names[$idx]} (${account_ids[$idx]})"
            ((i++))
        done
        echo ""
        
        while true; do
            read -p "Select a billing account (1-$num_accounts): " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= num_accounts )); then
                billing_account="${account_ids[$((choice-1))]}"
                break
            fi
            
            print_error "Invalid choice. Please enter a number between 1 and $num_accounts."
        done
    fi
    
    print_status "Linking billing account to project..."
    
    if gcloud billing projects link "$PROJECT_ID" --billing-account="$billing_account"; then
        print_success "Billing account linked successfully"
    else
        print_error "Failed to link billing account. Please do it manually at:"
        echo "  https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# Prompt for additional configuration options
#-------------------------------------------------------------------------------
prompt_configuration() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "                         CONFIGURATION OPTIONS"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Current settings (press Enter to accept defaults):"
    echo ""
    
    # VM Name
    read -p "  VM Name [$VM_NAME]: " input
    VM_NAME="${input:-$VM_NAME}"
    
    # Zone
    echo ""
    echo "  Popular zones: us-central1-a, us-east1-b, us-west1-a, europe-west1-b, asia-east1-a"
    read -p "  Zone [$ZONE]: " input
    ZONE="${input:-$ZONE}"
    
    # Machine Type
    echo ""
    echo "  Machine types: e2-medium (2 vCPU/4GB), e2-standard-4 (4 vCPU/16GB), e2-standard-8 (8 vCPU/32GB)"
    read -p "  Machine Type [$MACHINE_TYPE]: " input
    MACHINE_TYPE="${input:-$MACHINE_TYPE}"
    
    # Disk Size
    read -p "  Boot Disk Size [$BOOT_DISK_SIZE]: " input
    BOOT_DISK_SIZE="${input:-$BOOT_DISK_SIZE}"
    
    # Additional users
    echo ""
    read -p "  Additional authorized users (space-separated emails, or leave blank): " ADDITIONAL_USERS
    
    # Load balancer option
    echo ""
    read -p "  Enable HTTPS Load Balancer for custom domain? (y/N): " enable_lb
    if [[ "$enable_lb" =~ ^[Yy] ]]; then
        ENABLE_LOAD_BALANCER="true"
        read -p "  Enter your domain name (e.g., code.yourdomain.com): " DOMAIN_NAME
        if [[ -z "$DOMAIN_NAME" ]]; then
            print_warning "No domain provided, disabling load balancer option"
            ENABLE_LOAD_BALANCER="false"
        fi
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
}

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
validate_config() {
    print_status "Validating configuration..."
    
    if [[ -z "$PROJECT_ID" ]]; then
        print_error "PROJECT_ID is not set"
        exit 1
    fi
    
    if [[ -z "$AUTHORIZED_EMAIL" ]]; then
        print_error "AUTHORIZED_EMAIL is not set"
        exit 1
    fi
    
    if [[ "$ENABLE_LOAD_BALANCER" == "true" && -z "$DOMAIN_NAME" ]]; then
        print_error "DOMAIN_NAME is required when ENABLE_LOAD_BALANCER is true"
        exit 1
    fi
    
    # Display final configuration
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "                         CONFIGURATION SUMMARY"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Project:        $PROJECT_ID"
    echo "  User:           $AUTHORIZED_EMAIL"
    echo "  VM Name:        $VM_NAME"
    echo "  Zone:           $ZONE"
    echo "  Machine Type:   $MACHINE_TYPE"
    echo "  Disk Size:      $BOOT_DISK_SIZE"
    if [[ -n "$ADDITIONAL_USERS" ]]; then
        echo "  Extra Users:    $ADDITIONAL_USERS"
    fi
    if [[ "$ENABLE_LOAD_BALANCER" == "true" ]]; then
        echo "  Load Balancer:  Enabled"
        echo "  Domain:         $DOMAIN_NAME"
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    read -p "Proceed with this configuration? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Setup cancelled."
        exit 0
    fi
    
    print_success "Configuration validated"
}

#-------------------------------------------------------------------------------
# Enable required APIs
#-------------------------------------------------------------------------------
enable_apis() {
    print_status "Enabling required GCP APIs..."
    
    gcloud services enable compute.googleapis.com --project="$PROJECT_ID"
    gcloud services enable iap.googleapis.com --project="$PROJECT_ID"
    
    if [[ "$ENABLE_LOAD_BALANCER" == "true" ]]; then
        gcloud services enable certificatemanager.googleapis.com --project="$PROJECT_ID"
    fi
    
    print_success "APIs enabled"
}

#-------------------------------------------------------------------------------
# Setup Cloud NAT for outbound internet access
#-------------------------------------------------------------------------------
setup_cloud_nat() {
    print_status "Setting up Cloud NAT for outbound internet access..."
    
    local REGION="${ZONE%-*}"
    local ROUTER_NAME="nat-router"
    local NAT_NAME="nat-gateway"
    
    # Create Cloud Router if it doesn't exist
    if ! gcloud compute routers describe "$ROUTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        print_status "Creating Cloud Router..."
        gcloud compute routers create "$ROUTER_NAME" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --network=default
        print_success "Cloud Router created"
    else
        print_warning "Cloud Router '$ROUTER_NAME' already exists"
    fi
    
    # Create Cloud NAT if it doesn't exist
    if ! gcloud compute routers nats describe "$NAT_NAME" --router="$ROUTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        print_status "Creating Cloud NAT gateway..."
        gcloud compute routers nats create "$NAT_NAME" \
            --project="$PROJECT_ID" \
            --router="$ROUTER_NAME" \
            --region="$REGION" \
            --auto-allocate-nat-external-ips \
            --nat-all-subnet-ip-ranges
        print_success "Cloud NAT gateway created"
    else
        print_warning "Cloud NAT '$NAT_NAME' already exists"
    fi
    
    print_success "Cloud NAT setup complete - VM can now access the internet"
}

#-------------------------------------------------------------------------------
# Create startup script for VM
#-------------------------------------------------------------------------------
create_startup_script() {
    cat << 'STARTUP_SCRIPT'
#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/startup-script.log) 2>&1

echo "Starting setup at $(date)"

# Update system
apt-get update
apt-get upgrade -y

# Install common development tools
apt-get install -y \
    git \
    curl \
    wget \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    docker.io \
    docker-compose \
    htop \
    tmux \
    vim \
    unzip

# Install code-server
curl -fsSL https://code-server.dev/install.sh | sh

# Create code-server config directory
mkdir -p /home/$(logname)/.config/code-server

# Configure code-server (no auth since IAP handles it)
cat > /home/$(logname)/.config/code-server/config.yaml << EOF
bind-addr: 0.0.0.0:8080
auth: none
cert: false
EOF

# Fix ownership
chown -R $(logname):$(logname) /home/$(logname)/.config

# Enable and start code-server
systemctl enable code-server@$(logname)
systemctl start code-server@$(logname)

# Add user to docker group
usermod -aG docker $(logname)

echo "Setup completed at $(date)"
STARTUP_SCRIPT
}

#-------------------------------------------------------------------------------
# Create the VM
#-------------------------------------------------------------------------------
create_vm() {
    print_status "Creating VM: $VM_NAME..."
    
    # Check if VM already exists
    if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        print_warning "VM $VM_NAME already exists. Skipping creation."
        return 0
    fi
    
    # Create startup script file
    STARTUP_SCRIPT_FILE=$(mktemp)
    create_startup_script > "$STARTUP_SCRIPT_FILE"
    
    gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --boot-disk-size="$BOOT_DISK_SIZE" \
        --boot-disk-type=pd-ssd \
        --image-family=ubuntu-2204-lts \
        --image-project=ubuntu-os-cloud \
        --no-address \
        --tags=iap-tunnel,code-server \
        --metadata-from-file=startup-script="$STARTUP_SCRIPT_FILE" \
        --scopes=cloud-platform
    
    rm "$STARTUP_SCRIPT_FILE"
    
    print_success "VM created successfully"
}

#-------------------------------------------------------------------------------
# Create firewall rules
#-------------------------------------------------------------------------------
create_firewall_rules() {
    print_status "Creating firewall rules..."
    
    # IAP tunnel firewall rule
    if ! gcloud compute firewall-rules describe allow-iap-tunnel --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute firewall-rules create allow-iap-tunnel \
            --project="$PROJECT_ID" \
            --direction=INGRESS \
            --action=ALLOW \
            --rules=tcp:22,tcp:8080 \
            --source-ranges=35.235.240.0/20 \
            --target-tags=iap-tunnel \
            --description="Allow IAP tunnel access to SSH and code-server"
        print_success "Firewall rule 'allow-iap-tunnel' created"
    else
        print_warning "Firewall rule 'allow-iap-tunnel' already exists"
    fi
    
    # Health check firewall rule (for load balancer)
    if [[ "$ENABLE_LOAD_BALANCER" == "true" ]]; then
        if ! gcloud compute firewall-rules describe allow-health-check --project="$PROJECT_ID" &>/dev/null; then
            gcloud compute firewall-rules create allow-health-check \
                --project="$PROJECT_ID" \
                --direction=INGRESS \
                --action=ALLOW \
                --rules=tcp:8080 \
                --source-ranges=130.211.0.0/22,35.191.0.0/16 \
                --target-tags=code-server \
                --description="Allow Google health checks"
            print_success "Firewall rule 'allow-health-check' created"
        else
            print_warning "Firewall rule 'allow-health-check' already exists"
        fi
    fi
}

#-------------------------------------------------------------------------------
# Configure IAP access
#-------------------------------------------------------------------------------
configure_iap_access() {
    print_status "Configuring IAP access..."
    
    # Grant IAP tunnel access to primary user
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:$AUTHORIZED_EMAIL" \
        --role="roles/iap.tunnelResourceAccessor" \
        --condition=None \
        --quiet
    
    # Grant compute instance access
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:$AUTHORIZED_EMAIL" \
        --role="roles/compute.instanceAdmin.v1" \
        --condition=None \
        --quiet
    
    # Add additional users if specified
    for user in $ADDITIONAL_USERS; do
        print_status "Adding IAP access for: $user"
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="user:$user" \
            --role="roles/iap.tunnelResourceAccessor" \
            --condition=None \
            --quiet
    done
    
    print_success "IAP access configured"
}

#-------------------------------------------------------------------------------
# Setup HTTPS Load Balancer with IAP (optional)
#-------------------------------------------------------------------------------
setup_load_balancer() {
    if [[ "$ENABLE_LOAD_BALANCER" != "true" ]]; then
        return 0
    fi
    
    print_status "Setting up HTTPS Load Balancer with IAP..."
    
    REGION="${ZONE%-*}"
    
    # Reserve static IP
    if ! gcloud compute addresses describe code-server-ip --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute addresses create code-server-ip \
            --project="$PROJECT_ID" \
            --global
        print_success "Static IP reserved"
    fi
    
    STATIC_IP=$(gcloud compute addresses describe code-server-ip \
        --global \
        --project="$PROJECT_ID" \
        --format="get(address)")
    
    print_status "Static IP: $STATIC_IP"
    print_warning "Point your DNS record for $DOMAIN_NAME to $STATIC_IP"
    
    # Create health check
    if ! gcloud compute health-checks describe code-server-health-check --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute health-checks create http code-server-health-check \
            --project="$PROJECT_ID" \
            --port=8080 \
            --request-path="/" \
            --check-interval=30s \
            --timeout=10s \
            --healthy-threshold=2 \
            --unhealthy-threshold=3
        print_success "Health check created"
    fi
    
    # Create instance group
    if ! gcloud compute instance-groups unmanaged describe code-server-group --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute instance-groups unmanaged create code-server-group \
            --project="$PROJECT_ID" \
            --zone="$ZONE"
        
        gcloud compute instance-groups unmanaged add-instances code-server-group \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --instances="$VM_NAME"
        
        gcloud compute instance-groups unmanaged set-named-ports code-server-group \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --named-ports=http:8080
        print_success "Instance group created"
    fi
    
    # Create backend service
    if ! gcloud compute backend-services describe code-server-backend --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute backend-services create code-server-backend \
            --project="$PROJECT_ID" \
            --global \
            --protocol=HTTP \
            --port-name=http \
            --health-checks=code-server-health-check \
            --timeout=3600s \
            --connection-draining-timeout=300s
        
        gcloud compute backend-services add-backend code-server-backend \
            --project="$PROJECT_ID" \
            --global \
            --instance-group=code-server-group \
            --instance-group-zone="$ZONE"
        print_success "Backend service created"
    fi
    
    # Enable IAP on backend service
    print_status "Enabling IAP on backend service..."
    gcloud compute backend-services update code-server-backend \
        --project="$PROJECT_ID" \
        --global \
        --iap=enabled
    
    # Grant IAP web user access
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="user:$AUTHORIZED_EMAIL" \
        --role="roles/iap.httpsResourceAccessor" \
        --condition=None \
        --quiet
    
    for user in $ADDITIONAL_USERS; do
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="user:$user" \
            --role="roles/iap.httpsResourceAccessor" \
            --condition=None \
            --quiet
    done
    
    # Create URL map
    if ! gcloud compute url-maps describe code-server-url-map --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute url-maps create code-server-url-map \
            --project="$PROJECT_ID" \
            --default-service=code-server-backend
        print_success "URL map created"
    fi
    
    # Create managed SSL certificate
    if ! gcloud compute ssl-certificates describe code-server-cert --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute ssl-certificates create code-server-cert \
            --project="$PROJECT_ID" \
            --global \
            --domains="$DOMAIN_NAME"
        print_success "SSL certificate created (may take 15-60 min to provision)"
    fi
    
    # Create HTTPS proxy
    if ! gcloud compute target-https-proxies describe code-server-https-proxy --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute target-https-proxies create code-server-https-proxy \
            --project="$PROJECT_ID" \
            --url-map=code-server-url-map \
            --ssl-certificates=code-server-cert
        print_success "HTTPS proxy created"
    fi
    
    # Create forwarding rule
    if ! gcloud compute forwarding-rules describe code-server-https-rule --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute forwarding-rules create code-server-https-rule \
            --project="$PROJECT_ID" \
            --global \
            --address=code-server-ip \
            --target-https-proxy=code-server-https-proxy \
            --ports=443
        print_success "Forwarding rule created"
    fi
    
    print_success "Load balancer setup complete"
}

#-------------------------------------------------------------------------------
# Create helper scripts
#-------------------------------------------------------------------------------
create_helper_scripts() {
    print_status "Creating helper scripts..."
    
    # Connect script
    cat > connect-to-dev.sh << EOF
#!/bin/bash
# Connect to your development environment via IAP tunnel

PROJECT_ID="$PROJECT_ID"
VM_NAME="$VM_NAME"
ZONE="$ZONE"

echo "Starting IAP tunnel to code-server..."
echo "Once connected, open http://localhost:8080 in your browser"
echo "Press Ctrl+C to disconnect"
echo ""

gcloud compute start-iap-tunnel "\$VM_NAME" 8080 \\
    --local-host-port=localhost:8080 \\
    --zone="\$ZONE" \\
    --project="\$PROJECT_ID"
EOF
    chmod +x connect-to-dev.sh
    
    # SSH script
    cat > ssh-to-dev.sh << EOF
#!/bin/bash
# SSH into your development VM

PROJECT_ID="$PROJECT_ID"
VM_NAME="$VM_NAME"
ZONE="$ZONE"

gcloud compute ssh "\$VM_NAME" \\
    --zone="\$ZONE" \\
    --project="\$PROJECT_ID" \\
    --tunnel-through-iap
EOF
    chmod +x ssh-to-dev.sh
    
    # Start/Stop scripts
    cat > start-dev.sh << EOF
#!/bin/bash
# Start your development VM

PROJECT_ID="$PROJECT_ID"
VM_NAME="$VM_NAME"
ZONE="$ZONE"

echo "Starting VM \$VM_NAME..."
gcloud compute instances start "\$VM_NAME" \\
    --zone="\$ZONE" \\
    --project="\$PROJECT_ID"

echo "Waiting for VM to be ready..."
sleep 30

echo "VM started. Run ./connect-to-dev.sh to connect."
EOF
    chmod +x start-dev.sh
    
    cat > stop-dev.sh << EOF
#!/bin/bash
# Stop your development VM (saves money when not in use)

PROJECT_ID="$PROJECT_ID"
VM_NAME="$VM_NAME"
ZONE="$ZONE"

echo "Stopping VM \$VM_NAME..."
gcloud compute instances stop "\$VM_NAME" \\
    --zone="\$ZONE" \\
    --project="\$PROJECT_ID"

echo "VM stopped."
EOF
    chmod +x stop-dev.sh
    
    # Status script
    cat > status-dev.sh << EOF
#!/bin/bash
# Check status of your development VM

PROJECT_ID="$PROJECT_ID"
VM_NAME="$VM_NAME"
ZONE="$ZONE"

gcloud compute instances describe "\$VM_NAME" \\
    --zone="\$ZONE" \\
    --project="\$PROJECT_ID" \\
    --format="table(name,status,machineType.basename(),zone.basename())"
EOF
    chmod +x status-dev.sh
    
    print_success "Helper scripts created"
}

#-------------------------------------------------------------------------------
# Print summary
#-------------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "==============================================================================="
    echo -e "${GREEN}SETUP COMPLETE${NC}"
    echo "==============================================================================="
    echo ""
    echo "Your secure VS Code development environment is ready!"
    echo ""
    echo -e "${BLUE}VM Details:${NC}"
    echo "  Name: $VM_NAME"
    echo "  Zone: $ZONE"
    echo "  Type: $MACHINE_TYPE"
    echo ""
    echo -e "${BLUE}How to Connect (IAP Tunnel Method):${NC}"
    echo "  1. Run: ./connect-to-dev.sh"
    echo "  2. Open: http://localhost:8080"
    echo ""
    echo -e "${BLUE}Or manually:${NC}"
    echo "  gcloud compute start-iap-tunnel $VM_NAME 8080 \\"
    echo "      --local-host-port=localhost:8080 \\"
    echo "      --zone=$ZONE \\"
    echo "      --project=$PROJECT_ID"
    echo ""
    
    if [[ "$ENABLE_LOAD_BALANCER" == "true" ]]; then
        STATIC_IP=$(gcloud compute addresses describe code-server-ip \
            --global \
            --project="$PROJECT_ID" \
            --format="get(address)" 2>/dev/null || echo "N/A")
        
        echo -e "${BLUE}HTTPS Load Balancer (Alternative Method):${NC}"
        echo "  URL: https://$DOMAIN_NAME"
        echo "  Static IP: $STATIC_IP"
        echo ""
        echo -e "${YELLOW}IMPORTANT:${NC} Configure your DNS to point $DOMAIN_NAME to $STATIC_IP"
        echo "  SSL certificate provisioning may take 15-60 minutes."
        echo ""
    fi
    
    echo -e "${BLUE}Helper Scripts Created:${NC}"
    echo "  ./connect-to-dev.sh  - Start IAP tunnel and connect"
    echo "  ./ssh-to-dev.sh      - SSH into the VM"
    echo "  ./start-dev.sh       - Start the VM"
    echo "  ./stop-dev.sh        - Stop the VM (saves costs)"
    echo "  ./status-dev.sh      - Check VM status"
    echo ""
    echo -e "${BLUE}Cost Saving Tips:${NC}"
    echo "  - Run ./stop-dev.sh when not coding to avoid charges"
    echo "  - VM only incurs charges when running"
    echo "  - Disk storage is always charged (~\$10/month for 100GB SSD)"
    echo ""
    echo -e "${YELLOW}Note:${NC} The VM startup script needs a few minutes to complete."
    echo "  Wait 3-5 minutes before first connection for code-server to install."
    echo ""
    echo "==============================================================================="
}

#-------------------------------------------------------------------------------
# Cleanup function (optional - run with --cleanup flag)
#-------------------------------------------------------------------------------
cleanup() {
    print_warning "This will delete all resources created by this script!"
    echo ""
    echo "Resources to be deleted in project '$PROJECT_ID':"
    echo "  - VM: $VM_NAME"
    echo "  - Cloud NAT: nat-gateway"
    echo "  - Cloud Router: nat-router"
    echo "  - Firewall rules: allow-iap-tunnel, allow-health-check"
    echo "  - Load balancer components (if they exist)"
    echo ""
    read -p "Are you sure you want to delete these resources? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi
    
    print_status "Cleaning up resources..."
    
    # Delete load balancer components (if they exist)
    gcloud compute forwarding-rules delete code-server-https-rule --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute target-https-proxies delete code-server-https-proxy --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute ssl-certificates delete code-server-cert --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute url-maps delete code-server-url-map --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute backend-services delete code-server-backend --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute instance-groups unmanaged delete code-server-group --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute health-checks delete code-server-health-check --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute addresses delete code-server-ip --global --project="$PROJECT_ID" --quiet 2>/dev/null || true
    
    # Delete firewall rules
    gcloud compute firewall-rules delete allow-iap-tunnel --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute firewall-rules delete allow-health-check --project="$PROJECT_ID" --quiet 2>/dev/null || true
    
    # Delete VM
    gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --quiet 2>/dev/null || true
    
    # Delete Cloud NAT and Router
    local REGION="${ZONE%-*}"
    gcloud compute routers nats delete nat-gateway --router=nat-router --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null || true
    gcloud compute routers delete nat-router --region="$REGION" --project="$PROJECT_ID" --quiet 2>/dev/null || true
    
    # Clean up local helper scripts
    rm -f connect-to-dev.sh ssh-to-dev.sh start-dev.sh stop-dev.sh status-dev.sh 2>/dev/null || true
    
    print_success "Cleanup complete"
}

#-------------------------------------------------------------------------------
# Main execution
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo "==============================================================================="
    echo "        GCP VS Code Remote Development Setup with Identity-Aware Proxy"
    echo "==============================================================================="
    echo ""
    
    # Check for cleanup flag
    if [[ "$1" == "--cleanup" ]]; then
        # For cleanup, we need to get project interactively too
        check_prerequisites
        get_user_email
        select_or_create_project
        cleanup
        exit 0
    fi
    
    # Interactive setup flow
    check_prerequisites
    get_user_email
    select_or_create_project
    prompt_configuration
    validate_config
    
    print_status "Setting default project to: $PROJECT_ID"
    gcloud config set project "$PROJECT_ID"
    
    enable_apis
    setup_cloud_nat
    create_vm
    create_firewall_rules
    configure_iap_access
    setup_load_balancer
    create_helper_scripts
    print_summary
}

# Run main function
main "$@"
