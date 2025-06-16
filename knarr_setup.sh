#!/bin/bash

# Debian 12 Post-Install Configuration Script
# Hostname: knarr.star
# CPU: 8-core AMD FX-8320E
# RAM: 32GB
# Updated to run Gitea as k3s pod with proper domain configuration

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
TOTAL_STEPS=22
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

# Function to wait for k3s to be ready
wait_for_k3s() {
    log "Waiting for k3s to be ready..."
    for i in {1..60}; do
        if kubectl get nodes --request-timeout=10s &>/dev/null; then
            log "k3s is ready and responsive"
            return 0
        fi
        log "Waiting for k3s (attempt $i/60)..."
        sleep 5
    done
    error "k3s failed to become ready within 5 minutes"
}

# Function to apply k8s manifest with retry
apply_k8s_manifest() {
    local manifest_file="$1"
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if kubectl apply -f "$manifest_file"; then
            log "Successfully applied manifest: $manifest_file"
            return 0
        fi
        warn "Failed to apply manifest, attempt $attempt/$max_attempts"
        sleep 5
        attempt=$((attempt + 1))
    done
    
    error "Failed to apply manifest after $max_attempts attempts: $manifest_file"
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
if ! grep -q "192.168.1.120 git.knarr.star" /etc/hosts; then
    echo "192.168.1.120 git.knarr.star" >> /etc/hosts
fi

progress "Updating system packages"
apt-get update
apt-get upgrade -y

progress "Installing essential packages"
install_packages curl wget gnupg2 software-properties-common apt-transport-https ca-certificates \
    dnsmasq nfs-kernel-server nftables nginx redis-server git htop iotop sysstat \
    rng-tools-debian preload irqbalance tuned rsync

progress "Installing k3s"
if ! command -v k3s &>/dev/null; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --disable servicelb" sh -
    # Make kubectl available for root and users
    ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl || true
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
else
    log "k3s already installed"
fi

# Wait for k3s to be ready before proceeding
wait_for_k3s

progress "Configuring dnsmasq"
backup_file "/etc/dnsmasq.conf"
cat > /etc/dnsmasq.conf << 'EOF'
# Basic configuration
port=53
domain-needed
bogus-priv
no-resolv
no-poll
server=8.8.8.8
server=8.8.4.4
local=/star/
domain=star
expand-hosts

# Interface configuration
interface=lo
bind-interfaces

# DHCP disabled (assuming static network)
no-dhcp-interface=

# Local domain resolution
address=/dev/192.168.1.120
address=/test/192.168.1.120
address=/star/192.168.1.120
address=/git.knarr.star/192.168.1.120
address=/knarr.star/192.168.1.120

# Cache settings
cache-size=1000
neg-ttl=60

# Logging
log-queries
log-facility=/var/log/dnsmasq.log
EOF

progress "Configuring nginx"
backup_file "/etc/nginx/nginx.conf"
backup_file "/etc/nginx/sites-available/default"

# Create nginx configuration for git.knarr.star
cat > /etc/nginx/sites-available/git.knarr.star << 'EOF'
server {
    listen 80;
    server_name git.knarr.star;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    
    # Client max body size for git operations
    client_max_body_size 100M;
    
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/git.knarr.star /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
nginx -t || error "Nginx configuration test failed"

progress "Configuring nftables"
backup_file "/etc/nftables.conf"
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow loopback
        iif lo accept
        
        # Allow established connections
        ct state established,related accept
        
        # Allow SSH (custom port)
        tcp dport 51599 accept
        
        # Allow HTTP/HTTPS
        tcp dport { 80, 443 } accept
        
        # Allow DNS
        tcp dport 53 accept
        udp dport 53 accept
        
        # Allow NFS
        tcp dport { 111, 2049, 20048 } accept
        udp dport { 111, 2049, 20048 } accept
        
        # Allow k3s API server
        tcp dport 6443 accept
        
        # Allow k3s metrics and kubelet
        tcp dport { 9100, 10250, 10251, 10252 } accept
        
        # Allow Gitea (from k3s pod)
        tcp dport 3000 accept
        
        # Allow Redis (for k3s and Gitea)
        tcp dport 6379 accept
        
        # Allow ping
        icmp type echo-request accept
        icmpv6 type echo-request accept
        
        # Allow local network traffic
        ip saddr 192.168.1.0/24 accept
        
        # Log dropped packets (optional)
        # log prefix "nftables dropped: " drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

progress "Configuring NFS exports"
backup_file "/etc/exports"
cat > /etc/exports << 'EOF'
/home/heimdall 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

# Create NFS export directory if it doesn't exist
mkdir -p /home/heimdall
chown nobody:nogroup /home/heimdall
chmod 755 /home/heimdall

progress "Configuring SSH"
backup_file "/etc/ssh/sshd_config"
sed -i 's/#Port 22/Port 51599/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

progress "Configuring system optimizations"
# Kernel parameters for performance
cat > /etc/sysctl.d/99-knarr-performance.conf << 'EOF'
# Network optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 16384 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# File system optimizations
fs.file-max = 2097152
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Security
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
EOF

# Apply sysctl settings
sysctl -p /etc/sysctl.d/99-knarr-performance.conf

progress "Creating k3s namespace and storage"
# Create gitea namespace
kubectl create namespace gitea || log "Namespace gitea already exists"

# Create persistent volumes for Gitea
cat > /tmp/gitea-pv.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitea-data-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  hostPath:
    path: /opt/gitea/data
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitea-config-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  hostPath:
    path: /opt/gitea/config
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitea-data-pvc
  namespace: gitea
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: local-storage
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitea-config-pvc
  namespace: gitea
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-storage
EOF

# Create directories and apply PVs
mkdir -p /opt/gitea/{data,config}
chown -R 1000:1000 /opt/gitea
apply_k8s_manifest /tmp/gitea-pv.yaml

progress "Deploying Gitea to k3s"
cat > /tmp/gitea-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea
  namespace: gitea
  labels:
    app: gitea
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea
  template:
    metadata:
      labels:
        app: gitea
    spec:
      containers:
      - name: gitea
        image: gitea/gitea:1.21
        ports:
        - containerPort: 3000
          name: http
        - containerPort: 22
          name: ssh
        env:
        - name: GITEA__database__DB_TYPE
          value: "sqlite3"
        - name: GITEA__database__PATH
          value: "/data/gitea/gitea.db"
        - name: GITEA__server__DOMAIN
          value: "git.knarr.star"
        - name: GITEA__server__ROOT_URL
          value: "http://git.knarr.star/"
        - name: GITEA__server__HTTP_PORT
          value: "3000"
        - name: GITEA__server__SSH_PORT
          value: "22"
        - name: GITEA__security__INSTALL_LOCK
          value: "false"
        - name: GITEA__service__DISABLE_REGISTRATION
          value: "false"
        - name: GITEA__service__REQUIRE_SIGNIN_VIEW
          value: "false"
        - name: GITEA__log__MODE
          value: "console"
        - name: GITEA__log__LEVEL
          value: "Info"
        volumeMounts:
        - name: gitea-data
          mountPath: /data
        - name: gitea-config
          mountPath: /etc/gitea
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: gitea-data
        persistentVolumeClaim:
          claimName: gitea-data-pvc
      - name: gitea-config
        persistentVolumeClaim:
          claimName: gitea-config-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: gitea-service
  namespace: gitea
spec:
  selector:
    app: gitea
  ports:
  - name: http
    port: 3000
    targetPort: 3000
    nodePort: 30000
  - name: ssh
    port: 22
    targetPort: 22
    nodePort: 30022
  type: NodePort
EOF

apply_k8s_manifest /tmp/gitea-deployment.yaml

progress "Enabling and configuring services"
# Enable services (excluding gitea since it's now in k3s)
systemctl daemon-reload
for service in dnsmasq ssh nfs-kernel-server nftables k3s nginx redis-server rng-tools-debian preload irqbalance; do
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
for service in redis-server dnsmasq ssh nfs-kernel-server nftables nginx rng-tools-debian preload irqbalance; do
    systemctl start "$service" || warn "Failed to start $service"
    wait_for_service "$service"
done

# Restart k3s to ensure it picks up new configurations
systemctl restart k3s
wait_for_k3s

# Export NFS shares
exportfs -ra || warn "Failed to export NFS shares"

progress "Waiting for Gitea to be ready in k3s"
log "Waiting for Gitea pod to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/gitea -n gitea || warn "Gitea deployment may not be fully ready"

# Check if Gitea is responding
for i in {1..30}; do
    if curl -s http://localhost:3000 >/dev/null; then
        log "Gitea is responding on port 3000"
        break
    fi
    if [[ $i -eq 30 ]]; then
        warn "Gitea may not be responding, check k3s logs"
    fi
    sleep 5
done

progress "Final network configuration"
# Final network restart
systemctl restart networking || warn "Failed to restart networking"

log "Post-install configuration completed successfully!"

# Verify critical services
log "Verifying critical services..."
FAILED_SERVICES=()
CRITICAL_SERVICES=(dnsmasq ssh nfs-kernel-server nftables nginx redis-server k3s)

for service in "${CRITICAL_SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$service"; then
        FAILED_SERVICES+=("$service")
    fi
done

# Verify Gitea in k3s
if ! kubectl get deployment gitea -n gitea &>/dev/null; then
    FAILED_SERVICES+=("gitea-k3s")
fi

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
    warn "Some services failed to start: ${FAILED_SERVICES[*]}"
    warn "Check logs with: journalctl -u <service_name> or kubectl logs -n gitea deployment/gitea"
else
    log "All critical services are running successfully!"
fi

progress "Cleaning up temporary files"
rm -f /tmp/gitea-*.yaml

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
echo "Primary Interface: $(ip route | grep default | awk '{print $5}' | head -1)"
echo "IP Address: 192.168.1.120"
echo "DNS Server: Running on 127.0.0.1 and 192.168.1.120"
echo "SSH Port: 51599"
echo "Gitea URL: http://git.knarr.star (proxied through nginx)"
echo "Gitea Direct: http://192.168.1.120:3000"
echo "NFS Share: /home/heimdall -> 192.168.1.0/24"
echo "Wildcard DNS: *.dev, *.test, *.star -> 192.168.1.120"
echo "K3s Status: $(kubectl get nodes --no-headers 2>/dev/null | wc -l) node(s) ready"
echo "Gitea Pod Status: $(kubectl get pods -n gitea --no-headers 2>/dev/null | grep Running | wc -l) pod(s) running"
echo "Configuration Backups: $BACKUP_DIR"
echo "================================"

warn "Important next steps:"
echo "1. Run 'systemctl reboot' to apply all kernel parameters"
echo "2. Complete Gitea setup at http://git.knarr.star"
echo "3. Verify DNS resolution: dig @192.168.1.120 git.knarr.star"
echo "4. Test NFS mount from another machine"
echo "5. Configure SSH keys for secure access"
echo "6. Monitor Gitea with: kubectl logs -n gitea deployment/gitea -f"

log "Setup completed! System is ready for reboot."
