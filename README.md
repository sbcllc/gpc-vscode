# GCP VS Code (code-server)

🚀 **Secure VS Code (code-server) on GCP, protected by Cloud Identity-Aware Proxy (IAP). Ideal for Chromebooks or restricted networks!**

One script deploys a VM and configures:
- ✅ IAP-secured access (Google account login only)
- ✅ Simple tunnel: `gcloud start-iap-tunnel` → `localhost:8080`
- ✅ Optional HTTPS load balancer with custom domain + auto SSL

**No VPN or SSH keys needed. Fully configurable via env vars.**

## Features

- **Zero-trust Security**: Access protected by Google Cloud IAP - only authorized Google accounts can connect
- **Browser-based IDE**: Full VS Code experience through code-server
- **Chromebook Friendly**: Works perfectly from ChromeOS or any browser
- **Restricted Network Support**: IAP tunnel works through most firewalls
- **Simple Setup**: One command deployment with sensible defaults
- **Flexible Access**: IAP tunnel for development, optional HTTPS LB for production
- **Cost Effective**: No need for VPN infrastructure or bastion hosts

## Prerequisites

1. **Google Cloud Account** with billing enabled
2. **gcloud CLI** installed and authenticated
3. **A GCP Project** with appropriate permissions

```bash
# Install gcloud CLI (if not already installed)
# https://cloud.google.com/sdk/docs/install

# Authenticate with Google Cloud
gcloud auth login

# Set your default project (optional)
gcloud config set project YOUR_PROJECT_ID
```

## Quick Start

### 1. Clone and Configure

```bash
git clone https://github.com/sbcllc/gpc-vscode.git
cd gpc-vscode

# Copy the example config
cp .env.example .env

# Edit with your settings
nano .env  # or use your preferred editor
```

**Minimum required settings in `.env`:**
```bash
GCP_PROJECT_ID="your-project-id"
IAP_ALLOWED_EMAILS="your-email@gmail.com"
```

### 2. Deploy

```bash
# Make scripts executable
chmod +x deploy.sh connect.sh cleanup.sh

# Deploy the VM and configure IAP
./deploy.sh
```

### 3. Connect

```bash
# Start the IAP tunnel and open VS Code
./connect.sh
```

Or manually:
```bash
gcloud compute start-iap-tunnel code-server-vm 8080 \
  --local-host-port=localhost:8080 \
  --zone=us-central1-a \
  --project=YOUR_PROJECT_ID
```

Then open http://localhost:8080 in your browser.

## Configuration

All settings can be configured via environment variables or the `.env` file:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GCP_PROJECT_ID` | Yes | - | Your GCP project ID |
| `IAP_ALLOWED_EMAILS` | Yes | - | Comma-separated list of allowed email addresses |
| `GCP_REGION` | No | `us-central1` | GCP region for resources |
| `GCP_ZONE` | No | `us-central1-a` | GCP zone for the VM |
| `VM_NAME` | No | `code-server-vm` | Name of the VM instance |
| `VM_MACHINE_TYPE` | No | `e2-medium` | VM machine type |
| `BOOT_DISK_SIZE` | No | `50` | Boot disk size in GB |
| `BOOT_DISK_TYPE` | No | `pd-balanced` | Boot disk type |
| `CODE_SERVER_VERSION` | No | Latest | Specific code-server version to install |
| `ENABLE_HTTPS_LB` | No | `false` | Enable HTTPS load balancer |
| `CUSTOM_DOMAIN` | If HTTPS | - | Domain for HTTPS access |
| `SERVICE_ACCOUNT` | No | Default | Service account for the VM |

## Scripts

### deploy.sh

Main deployment script that:
- Enables required GCP APIs
- Creates firewall rules for IAP
- Creates a VM with code-server
- Configures IAP access for specified users
- Optionally sets up HTTPS load balancer

```bash
./deploy.sh [options]

Options:
  -h, --help          Show help message
  -e, --env FILE      Load config from specified file (default: .env)
  --dry-run           Show what would be done without making changes
  --https             Enable HTTPS load balancer setup
```

### connect.sh

Helper script to establish IAP tunnel and connect:

```bash
./connect.sh [options]

Options:
  -h, --help          Show help message
  -e, --env FILE      Load config from specified file
  -p, --port PORT     Local port to use (default: 8080)
  --no-browser        Don't open browser automatically
```

### cleanup.sh

Remove all created resources:

```bash
./cleanup.sh [options]

Options:
  -h, --help          Show help message
  -e, --env FILE      Load config from specified file
  --dry-run           Show what would be deleted
  -y, --yes           Skip confirmation prompt
```

## HTTPS Load Balancer (Optional)

For production use or easier access, you can enable an HTTPS load balancer with a custom domain and automatic SSL certificate:

1. **Configure in `.env`:**
```bash
ENABLE_HTTPS_LB="true"
CUSTOM_DOMAIN="code.yourdomain.com"
```

2. **Deploy:**
```bash
./deploy.sh --https
```

3. **Configure DNS:**
After deployment, add an A record pointing your domain to the static IP shown in the output.

4. **Wait for SSL:**
Google-managed SSL certificates may take up to 24 hours to provision.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         User's Browser                          │
│                    (Chromebook, Desktop, etc.)                  │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │ Option 1: IAP Tunnel
                                │ (gcloud start-iap-tunnel)
                                │
                    ┌───────────▼───────────┐
                    │   Cloud IAP           │
                    │   (Authentication)    │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │   GCP VM              │
                    │   code-server:8080    │
                    │   (No external IP)    │
                    └───────────────────────┘

        ─── OR ───

                                │ Option 2: HTTPS LB
                                │ (https://code.yourdomain.com)
                                │
                    ┌───────────▼───────────┐
                    │   HTTPS Load Balancer │
                    │   + IAP + Auto SSL    │
                    └───────────┬───────────┘
                                │
                    ┌───────────▼───────────┐
                    │   GCP VM              │
                    │   code-server:8080    │
                    └───────────────────────┘
```

## Security

- **No external IP**: The VM has no public IP address, reducing attack surface
- **IAP Authentication**: Only authorized Google accounts can access
- **No SSH Keys**: IAP provides secure tunneling without managing SSH keys
- **Password-free code-server**: IAP handles authentication, so code-server runs without password
- **Firewall Rules**: Only IAP and (optionally) load balancer IPs can reach the VM

## Troubleshooting

### "Permission denied" when connecting via IAP

Ensure your email is in `IAP_ALLOWED_EMAILS` and the IAM binding was created:

```bash
gcloud compute instances get-iam-policy code-server-vm \
  --zone=us-central1-a \
  --project=YOUR_PROJECT_ID
```

### code-server not responding

Check if code-server is running on the VM:

```bash
gcloud compute ssh code-server-vm \
  --zone=us-central1-a \
  --project=YOUR_PROJECT_ID \
  --tunnel-through-iap \
  -- sudo systemctl status code-server
```

### Installation logs

View the startup script logs:

```bash
gcloud compute ssh code-server-vm \
  --zone=us-central1-a \
  --project=YOUR_PROJECT_ID \
  --tunnel-through-iap \
  -- sudo cat /var/log/code-server-install.log
```

### HTTPS certificate not provisioning

- Ensure DNS A record is correctly configured
- Check certificate status:
```bash
gcloud compute ssl-certificates describe code-server-vm-cert \
  --project=YOUR_PROJECT_ID
```

## Cost Estimation

Approximate monthly costs (us-central1):

| Resource | Specification | Est. Cost/Month |
|----------|---------------|-----------------|
| VM (e2-medium) | 2 vCPU, 4GB RAM | ~$24 |
| Boot Disk | 50GB pd-balanced | ~$5 |
| HTTPS LB | Optional | ~$18 |
| **Total** | | **~$29-47** |

*Costs vary by region and usage. Use [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) for accurate estimates.*

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
