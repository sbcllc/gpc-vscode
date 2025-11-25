# GCP VS Code Remote Development Setup

Securely access VS Code from your Chromebook using GCP Compute Engine and Identity-Aware Proxy (IAP).

## Quick Start

### 1. Prerequisites

- Google Cloud account with billing enabled
- `gcloud` CLI installed on your Chromebook
  - Install via: `curl https://sdk.cloud.google.com | bash`
- Authenticate with: `gcloud auth login`

### 2. Run the Setup

```bash
chmod +x gcp-vscode-setup.sh
./gcp-vscode-setup.sh
```

The script will interactively:
1. **Detect your Google account** from `gcloud auth list`
2. **Let you select a project** or create a new one
3. **Prompt for configuration options** (VM size, zone, etc.)
4. **Set up everything automatically**

### 3. Connect to VS Code

After setup completes (wait 3-5 minutes for code-server to install):

```bash
./connect-to-dev.sh
```

Then open **http://localhost:8080** in Chrome.

## Helper Scripts

| Script | Description |
|--------|-------------|
| `./connect-to-dev.sh` | Start IAP tunnel and connect to VS Code |
| `./ssh-to-dev.sh` | SSH into the VM |
| `./start-dev.sh` | Start the VM |
| `./stop-dev.sh` | Stop the VM (saves money!) |
| `./status-dev.sh` | Check VM status |

## Cost Management

**Stop your VM when not coding** to avoid charges:

```bash
./stop-dev.sh  # Stop VM - no compute charges
./start-dev.sh # Start VM when ready to code
```

Estimated costs:
- **Running**: ~$0.13/hour for e2-standard-4
- **Stopped**: ~$10/month for 100GB SSD (storage only)
- **IAP**: Free

## Optional: HTTPS with Custom Domain

For direct browser access without running the tunnel command, you'll be prompted during setup to enable the HTTPS Load Balancer option.

Or set via environment variables:
```bash
ENABLE_LOAD_BALANCER=true DOMAIN_NAME="code.yourdomain.com" ./gcp-vscode-setup.sh
```

After setup:
1. Point your DNS A record to the static IP shown in the output
2. Wait 15-60 minutes for SSL certificate provisioning
3. Access via `https://code.yourdomain.com` - Google login required

## Adding More Users

During setup, you'll be prompted for additional authorized users. You can also add users after setup:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member=user:newuser@gmail.com \
    --role=roles/iap.tunnelResourceAccessor
```

Or set via environment variable before running:
```bash
ADDITIONAL_USERS="colleague1@gmail.com colleague2@company.com" ./gcp-vscode-setup.sh
```

## Cleanup

Remove all created resources:

```bash
./gcp-vscode-setup.sh --cleanup
```

## Troubleshooting

**"Permission denied" when connecting:**
- Ensure your account has `roles/iap.tunnelResourceAccessor`
- Wait a few minutes for IAM changes to propagate

**code-server not responding:**
- SSH into the VM: `./ssh-to-dev.sh`
- Check logs: `sudo journalctl -u code-server@$USER -f`
- Restart: `sudo systemctl restart code-server@$USER`

**Slow performance:**
- Upgrade machine type in the script
- Consider zones closer to your location

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Chromebook    │────▶│   IAP Tunnel    │────▶│   GCP VM        │
│   (Browser)     │     │   (Auth Layer)  │     │   (code-server) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        │ localhost:8080        │ Google Auth           │ No public IP
        │                       │ Only authorized       │ Secure
        └───────────────────────┴───────────────────────┘
```

Security features:
- No public IP on the VM
- IAP authenticates via Google account
- Only authorized users can access
- All traffic encrypted
