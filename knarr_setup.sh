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
NC='\033[0m' # No Color

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

# Create backup directory for original configs
BACKUP_DIR="/root/config_backups_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
log "Configuration backups will be stored in: $BACKUP_DIR"

log "Starting Debian 12 post-install configuration for knarr.star"

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
hostnamectl set-hostname knarr.star
if ! grep -q "127.0.0.1 knarr.star" /etc/hosts; then
    echo "127.0.0.1 knarr.star" >> /etc/hosts
fi

progress "Updating system packages"
apt-get update && apt-get upgrade -y

progress "Installing base utilities"
install_packages wget curl git mdadm procps ca-certificates lsb-release apt-transport-https gnupg2

progress "Configuring network interface"
backup_file /etc/network/interfaces

# Detect primary network interface
PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_INTERFACE" ]]; then
    PRIMARY_INTERFACE="eth0"
    warn "Could not detect primary interface, using default: $PRIMARY_INTERFACE"
fi

cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $PRIMARY_INTERFACE
iface $PRIMARY_INTERFACE inet static
  address 192.168.1.120
  netmask 255.255.255.0
  gateway 192.168.1.1
  dns-nameservers 1.1.1.1 1.0.0.1
EOF

progress "Configuring DNS resolution"
backup_file /etc/resolv.conf
# Remove immutable attribute if it exists
chattr -i /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

# Make resolv.conf immutable to prevent overwrites
chattr +i /etc/resolv.conf

progress "Installing and configuring DNSmasq"
install_packages dnsmasq dnsmasq-utils

backup_file /etc/dnsmasq.conf
cat > /etc/dnsmasq.conf << EOF
domain-needed
bogus-priv
no-resolv
no-poll
no-hosts
listen-address=127.0.0.1,192.168.1.120
bind-interfaces
except-interface=lo
local=/knarr/
domain=knarr
server=1.1.1.1
server=1.0.0.1
cache-size=20000
dns-forward-max=500
min-cache-ttl=3600
neg-ttl=600
no-dhcp-interface=
conf-dir=/etc/dnsmasq.d/,*.conf
log-queries
log-facility=/var/log/dnsmasq.log
EOF

# Create wildcard DNS configurations
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/wildcards.conf << 'EOF'
address=/dev/192.168.1.120
address=/test/192.168.1.120
address=/star/192.168.1.120
EOF

progress "Setting up users and shell configuration"
install_packages zsh git curl micro

# Clone antidote for zsh plugin management
if [[ ! -d /usr/local/share/antidote ]]; then
    git clone --depth=1 https://github.com/mattmc3/antidote.git /usr/local/share/antidote
    log "Antidote cloned successfully"
else
    log "Antidote already installed, updating..."
    cd /usr/local/share/antidote && git pull
fi

# Create zsh plugins configuration
mkdir -p /etc/antidote
cat > /etc/antidote/zsh_plugins.txt << 'EOF'
jeffreytse/zsh-vi-mode
rupa/z
romkatv/zsh-bench kind:path
olets/zsh-abbr kind:defer
mattmc3/ez-compinit
zsh-users/zsh-completions kind:fpath path:src
getantidote/use-omz
ohmyzsh/ohmyzsh path:lib
ohmyzsh/ohmyzsh path:plugins/colored-man-pages
ohmyzsh/ohmyzsh path:plugins/magic-enter
belak/zsh-utils path:editor
belak/zsh-utils path:history
belak/zsh-utils path:prompt
belak/zsh-utils path:utility
sindresorhus/pure kind:fpath
romkatv/powerlevel10k kind:fpath
mattmc3/zfunctions
zsh-users/zsh-autosuggestions
zdharma-continuum/fast-syntax-highlighting kind:defer
zsh-users/zsh-history-substring-search
EOF

# Configure root shell
log "Configuring root shell"
if [[ "$(getent passwd root | cut -d: -f7)" != "/bin/zsh" ]]; then
    chsh -s /bin/zsh root
fi

cat > /root/.zshrc << 'EOF'
source /usr/local/share/antidote/antidote.zsh
antidote load /etc/antidote/zsh_plugins.txt
autoload -Uz promptinit && promptinit && prompt pure
EOF

# Configure root's micro editor
mkdir -p /root/.config/micro
cat > /root/.config/micro/settings.json << 'EOF'
{
  "mkparents": true
}
EOF

# Create/configure heimdall user
log "Configuring heimdall user"
if ! id heimdall &>/dev/null; then
    useradd -m -s /bin/zsh -G sudo heimdall
    log "User heimdall created successfully"
else
    log "User heimdall already exists, updating configuration"
    usermod -s /bin/zsh -G sudo heimdall
fi

# Configure heimdall shell
cat > /home/heimdall/.zshrc << 'EOF'
source /usr/local/share/antidote/antidote.zsh
antidote load /etc/antidote/zsh_plugins.txt
autoload -Uz promptinit && promptinit && prompt pure
EOF

# Configure heimdall's micro editor
mkdir -p /home/heimdall/.config/micro
cat > /home/heimdall/.config/micro/settings.json << 'EOF'
{
  "mkparents": true,
  "autosu": true
}
EOF

chown -R heimdall:heimdall /home/heimdall

# Configure sudo for heimdall
install_packages sudo
cat > /etc/sudoers.d/heimdall << 'EOF'
heimdall ALL=(ALL) NOPASSWD:ALL
EOF

progress "Applying performance tweaks"
# Sysctl configuration
cat > /etc/sysctl.d/99-performance.conf << 'EOF'
# Network optimizations
net.core.somaxconn=65535
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3

# Memory optimizations
vm.swappiness=10
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50

# File descriptor limits
fs.file-max=2097152
fs.nr_open=2097152
EOF

# Apply sysctl settings
sysctl -p /etc/sysctl.d/99-performance.conf

progress "Updating GRUB configuration"
backup_file /etc/default/grub
if ! grep -q "mitigations=off" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=off elevator=none transparent_hugepage=always"/' /etc/default/grub
    update-grub
    log "GRUB updated with performance parameters"
else
    log "GRUB already configured with performance parameters"
fi

progress "Configuring CPU and system performance"
# CPU governor configuration
install_packages cpufrequtils
cat > /etc/default/cpufrequtils << 'EOF'
GOVERNOR="performance"
EOF

# Entropy configuration
install_packages rng-tools-debian
cat > /etc/default/rng-tools-debian << 'EOF'
HRNGDEVICE=/dev/urandom
RNGDOPTIONS="--rng-driver=kernel --fill-watermark=90% --feed-interval=1"
EOF

# ZRAM configuration (only if not already configured)
if ! dpkg -l | grep -q zram-tools; then
    install_packages zram-tools
    cat > /etc/default/zramswap << 'EOF'
ALGO=lz4
PERCENT=25
PRIORITY=100
EOF
fi

# Tuned installation and configuration
install_packages tuned python3-configobj python3-decorator python3-pyudev python3-linux-procfs python3-schedutils virt-what
systemctl enable tuned

# Additional performance tools
install_packages preload irqbalance htop

progress "Configuring SSH server"
install_packages openssh-server

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/custom.conf << 'EOF'
Port 51599
PermitRootLogin yes
X11Forwarding no
UseDNS no
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 3
EOF

progress "Installing and configuring NFS server"
install_packages nfs-kernel-server rpcbind

backup_file /etc/exports
cat > /etc/exports << 'EOF'
/home/heimdall 192.168.1.0/24(rw,sync,no_subtree_check)
EOF

backup_file /etc/nfs.conf
cat > /etc/nfs.conf << 'EOF'
[nfsd]
threads=16
tcp=y
vers3=n
vers4=y
vers4.0=y
vers4.1=y
vers4.2=y
EOF

progress "Configuring nftables firewall"
install_packages nftables

backup_file /etc/nftables.conf
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    
    # Loopback
    iif lo accept
    
    # Established/related connections
    ct state established,related accept
    
    # SSH on custom port
    tcp dport 51599 accept
    
    # DNS from local network
    udp dport 53 ip saddr 192.168.1.0/24 accept
    tcp dport 53 ip saddr 192.168.1.0/24 accept
    
    # NFS from local network
    tcp dport { 2049, 111, 32765-32769 } ip saddr 192.168.1.0/24 accept
    udp dport { 2049, 111, 32765-32769 } ip saddr 192.168.1.0/24 accept
    
    # Kubernetes and web services
    tcp dport { 6443, 10250, 80, 443, 3000 } accept
    
    # ICMP ping
    icmp type echo-request limit rate 10/second accept
    
    # Rate-limited logging
    limit rate 5/minute log prefix "nftables-dropped: "
    drop
  }
  
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
  
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF

progress "Installing Kubernetes (k3s)"
install_packages iptables conntrack libnetfilter-conntrack3 ethtool socat bridge-utils

# Install k3s with better configuration
if ! command -v k3s &> /dev/null; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
    log "k3s installed successfully"
else
    log "k3s already installed, skipping installation"
fi

# Install kubectl
if ! command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
    log "kubectl installed successfully"
else
    log "kubectl already installed, skipping installation"
fi

# K3s performance configuration
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml << 'EOF'
disable:
  - traefik
kube-apiserver-arg:
  - "max-requests-inflight=1000"
  - "max-mutating-requests-inflight=500"
kubelet-arg:
  - "max-pods=250"
  - "cpu-manager-policy=static"
  - "kube-reserved=cpu=500m,memory=1Gi"
  - "system-reserved=cpu=500m,memory=1Gi"
EOF

progress "Installing and configuring nginx"
install_packages nginx

backup_file /etc/nginx/nginx.conf
cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

http {
    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # MIME
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;
    
    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    
    # Proxy cache
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=my_cache:10m max_size=10g inactive=60m use_temp_path=off;
    
    # Virtual Host Configs
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Create nginx cache directory
mkdir -p /var/cache/nginx
chown -R www-data:www-data /var/cache/nginx

progress "Installing Podman for container development"
install_packages podman fuse-overlayfs conmon crun slirp4netns uidmap

mkdir -p /etc/containers
cat > /etc/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,fsync=0"
EOF

# Configure rootless storage for heimdall
mkdir -p /home/heimdall/.config/containers
cat > /home/heimdall/.config/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,fsync=0"
EOF
chown -R heimdall:heimdall /home/heimdall/.config

progress "Installing Redis for caching"
install_packages redis-server redis-tools

backup_file /etc/redis/redis.conf
cat > /etc/redis/redis.conf << 'EOF'
bind 127.0.0.1
port 6379
timeout 0
tcp-keepalive 300
daemonize yes
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log
databases 16
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis
maxmemory 512mb
maxmemory-policy allkeys-lru
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes
EOF

progress "Setting up Gitea git server"
# Create Gitea directories
mkdir -p /var/lib/gitea/{data,custom/conf}

# Download Gitea binary with version check
GITEA_VERSION="1.22.2"
if [[ ! -f /usr/local/bin/gitea ]] || [[ "$(/usr/local/bin/gitea --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1)" != "$GITEA_VERSION" ]]; then
    wget -O /usr/local/bin/gitea "https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64"
    chmod +x /usr/local/bin/gitea
    log "Gitea binary downloaded successfully"
else
    log "Gitea binary is up to date"
fi

# Gitea configuration
cat > /var/lib/gitea/custom/conf/app.ini << 'EOF'
[server]
HTTP_PORT = 3000
DISABLE_SSH = false
SSH_PORT = 2222
BUILTIN_SSH_SERVER_USER = git

[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/data/gitea.db

[cache]
ADAPTER = redis
HOST = redis://127.0.0.1:6379/0

[session]
PROVIDER = redis
PROVIDER_CONFIG = network=tcp,addr=127.0.0.1:6379,db=1

[queue]
TYPE = redis
CONN_STR = redis://127.0.0.1:6379/2

[security]
INSTALL_LOCK = false
SECRET_KEY = $(openssl rand -base64 32)

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW = false
EOF

# Create Gitea service user
if ! id git &>/dev/null; then
    useradd --system --create-home --home-dir /var/lib/gitea --shell /bin/bash git
    chown -R git:git /var/lib/gitea
fi

# Create Gitea systemd service
cat > /etc/systemd/system/gitea.service << 'EOF'
[Unit]
Description=Gitea (Git with a cup of tea)
After=syslog.target
After=network.target
After=redis.service

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /var/lib/gitea/custom/conf/app.ini
Restart=always
Environment=USER=git HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF

progress "Enabling and configuring services"
# Enable services
systemctl daemon-reload
systemctl enable dnsmasq
systemctl enable ssh
systemctl enable nfs-kernel-server
systemctl enable nftables
systemctl enable k3s
systemctl enable nginx
systemctl enable redis-server
systemctl enable gitea
systemctl enable rng-tools-debian
systemctl enable preload
systemctl enable irqbalance

# Set tuned profile
tuned-adm profile throughput-performance

progress "Starting services"
# Start services with proper dependency order
systemctl start redis-server
wait_for_service redis-server

systemctl start dnsmasq
systemctl start ssh  
systemctl start nfs-kernel-server
systemctl start nftables
systemctl start nginx
systemctl start gitea
systemctl start rng-tools-debian
systemctl start preload
systemctl start irqbalance

# Export NFS shares
exportfs -ra

# Wait for k3s to be ready
log "Waiting for k3s to be ready..."
systemctl start k3s
wait_for_service k3s

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

progress "Final network configuration"
# Final network restart
systemctl restart networking

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
echo "K3s Status: $(kubectl get nodes --no-headers 2>/dev/null | wc -l) node(s) ready"
echo "Configuration Backups: $BACKUP_DIR"
echo "================================"

warn "Important next steps:"
echo "1. Run 'systemctl reboot' to apply all kernel parameters"
echo "2. Complete Gitea setup at http://192.168.1.120:3000"
echo "3. Verify DNS resolution: dig @192.168.1.120 test.dev"
echo "4. Test NFS mount from another machine"
echo "5. Configure SSH keys for secure access"

log "Setup completed! System is ready for reboot."
