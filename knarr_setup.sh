#!/bin/bash

# Debian 12 Post-Install Configuration Script
# Hostname: knarr.star
# CPU: 8-core AMD FX-8320E
# RAM: 32GB

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Progress tracking
TOTAL_STEPS=20
CURRENT_STEP=0

progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "${BLUE}[Step $CURRENT_STEP/$TOTAL_STEPS] $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
fi

# Check if running on Debian 12
if ! grep -q "ID=debian" /etc/os-release || ! grep -q "VERSION_ID=\"12\"" /etc/os-release; then
    error "This script is designed for Debian 12 only"
fi

# Ensure systemd and D-Bus are running
if ! systemctl is-system-running --quiet; then
    log "Waiting for systemd to be fully running..."
    for i in {1..30}; do
        if systemctl is-system-running --quiet; then
            log "Systemd is ready"
            break
        fi
        if [[ $i -eq 30 ]]; then
            error "Systemd failed to start within 60 seconds"
        fi
        sleep 2
    done
fi

# Ensure D-Bus is installed and running
if ! command -v dbus-daemon &>/dev/null; then
    log "Installing D-Bus..."
    apt-get update
    apt-get install -y dbus
fi
systemctl start dbus
wait_for_service dbus

progress "Verifying RAID setup"
if ! mdadm --detail /dev/md0 &>/dev/null || ! mdadm --detail /dev/md1 &>/dev/null; then
    warn "RAID arrays /dev/md0 or /dev/md1 not found or not active"
    log "Attempting to assemble RAID arrays..."
    mdadm --assemble --scan || error "Failed to assemble RAID arrays"
fi
log "RAID arrays verified: $(mdadm --detail /dev/md0 | grep 'State' | awk '{print $3}'), $(mdadm --detail /dev/md1 | grep 'State' | awk '{print $3}')"

# Create backup directory for original configs
BACKUP_DIR="/root/config_backups_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
log "Configuration backups will be stored in: $BACKUP_DIR"

# Function to backup files safely
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "$BACKUP_DIR/$(basename "$file").$(date +%s)"
        log "Backed up: $file"
    fi
}

# Function to wait for service to be ready
wait_for_service() {
    local service="$1"
    local max_attempts="${2:-30}"
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if systemctl is-active --quiet "$service"; then
            log "Service $service is ready"
            return 0
        fi
        log "Waiting for $service to start (attempt $attempt/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    warn "Service $service failed to start within expected time"
    return 1
}

# Function to install packages with retry
install_packages() {
    local packages=("$@")
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if apt-get install -y "${packages[@]}"; then
            log "Successfully installed: ${packages[*]}"
            return 0
        fi
        warn "Package installation failed, attempt $attempt/$max_attempts"
        apt-get update
        attempt=$((attempt + 1))
        sleep 5
    done
    
    error "Failed to install packages after $max_attempts attempts: ${packages[*]}"
}

progress "Setting hostname and updating hosts file"
# Use alternative to hostnamectl if not available
if command -v hostnamectl &>/dev/null; then
    hostnamectl set-hostname knarr.star
else
    hostname knarr.star
    echo "knarr.star" > /etc/hostname
fi
if ! grep -q "127.0.0.1 knarr.star" /etc/hosts; then
    echo "127.0.0.1 knarr.star" >> /etc/hosts
fi

# ... (rest of the script remains unchanged until service enablement)

progress "Enabling and configuring services"
# Enable services
systemctl daemon-reload
for service in dnsmasq ssh nfs-kernel-server nftables k3s nginx redis-server gitea rng-tools-debian preload irqbalance; do
    systemctl enable "$service" || warn "Failed to enable $service"
done

# Set tuned profile
if command -v tuned-adm &>/dev/null; then
    tuned-adm profile throughput-performance || warn "Failed to set tuned profile"
else
    warn "tuned-adm not found, skipping profile configuration"
fi

progress "Starting services"
# Start services with proper dependency order
for service in redis-server dnsmasq ssh nfs-kernel-server nftables nginx gitea rng-tools-debian preload irqbalance k3s; do
    systemctl start "$service" || warn "Failed to start $service"
    wait_for_service "$service"
done

# Export NFS shares
exportfs -ra || warn "Failed to export NFS shares"

# Wait for k3s to be ready
log "Waiting for k3s to be ready..."
if command -v kubectl &>/dev/null; then
    for i in {1..30}; do
        if kubectl get nodes --request-timeout=10s &>/dev/null; then
            log "k3s is ready and responsive"
            break
        fi
        if [[ $i -eq 30 ]]; then
            warn "k3s may not be fully ready, but continuing"
        fi
        sleep 5
    done
else
    warn "kubectl not found, skipping k3s verification"
fi

progress "Final network configuration"
# Final network restart
systemctl restart networking || warn "Failed to restart networking"

log "Post-install configuration completed successfully!"

# Verify critical services
log "Verifying critical services..."
FAILED_SERVICES=()
CRITICAL_SERVICES=(dnsmasq ssh nfs-kernel-server nftables nginx redis-server gitea k3s)

for service in "${CRITICAL_SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$service"; then
        FAILED_SERVICES+=("$service")
    fi
done

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
    warn "Some services failed to start: ${FAILED_SERVICES[*]}"
    warn "Check logs with: journalctl -u <service_name>"
else
    log "All critical services are running successfully!"
fi

# Clean up first-boot service
if [[ -f /etc/systemd/system/knarr-setup.service ]]; then
    systemctl disable knarr-setup.service
    rm /etc/systemd/system/knarr-setup.service
    systemctl daemon-reload
    log "Cleaned up first-boot service"
fi

# Display system information
log "System Configuration Summary:"
echo "================================"
echo "Hostname: $(hostname)"
echo "Primary Interface: $PRIMARY_INTERFACE"
echo "IP Address: 192.168.1.120"
echo "DNS Server: Running on 127.0.0.1 and 192.168.1.120"
echo "SSH Port: 51599"
echo "Gitea URL: http://192.168.1.120:3000"
echo "NFS Share: /home/heimdall -> 192.168.1.0/24"
echo "Wildcard DNS: *.dev, *.test, *.star -> 192.168.1.120"
if command -v kubectl &>/dev/null; then
    echo "K3s Status: $(kubectl get nodes --no-headers 2>/dev/null | wc -l) node(s) ready"
else
    echo "K3s Status: kubectl not available"
fi
echo "Configuration Backups: $BACKUP_DIR"
echo "================================"

warn "Important next steps:"
echo "1. Run 'systemctl reboot' to apply all kernel parameters"
echo "2. Complete Gitea setup at http://192.168.1.120:3000"
echo "3. Verify DNS resolution: dig @192.168.1.120 test.dev"
echo "4. Test NFS mount from another machine"
echo "5. Configure SSH keys for secure access"

log "Setup completed! System is ready for reboot."
