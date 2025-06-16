#!/bin/bash

# Ensure script runs with Bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script requires Bash. Please run with 'bash ./preseed-iso.sh'"
  exit 1
fi

# Define base directory
BASE_DIR=/home/landnull/Downloads/Distros/Debian/Preseed

# Function to request and execute with sudo privileges
require_sudo() {
  local cmd="$1"
  echo "This step requires elevated permissions. Please enter your sudo password."
  while ! sudo -p "Sudo password: " -v 2>/dev/null; do
    echo "Invalid password or sudo privileges not granted. Please try again."
  done
  echo "Sudo privileges obtained."
  sudo bash -c "$cmd"
}

# Function to securely read password
read_password() {
  local prompt="$1"
  local password=""
  echo -n "$prompt"
  while IFS= read -r -s -n1 char; do
    if [[ $char == $'\0' ]]; then
      break
    elif [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
      if [ ${#password} -gt 0 ]; then
        password="${password%?}"
        echo -ne '\b \b'
      fi
    else
      password+="$char"
      echo -n '*'
    fi
  done
  echo
  echo "$password"
}

# Function to get and validate password
get_validated_password() {
  local prompt="$1"
  local min_length="${2:-8}"
  
  while true; do
    password1=$(read_password "$prompt: ")
    if [ ${#password1} -lt "$min_length" ]; then
      echo "Password must be at least $min_length characters long. Please try again."
      continue
    fi
    
    password2=$(read_password "Confirm $prompt: ")
    
    if [ "$password1" = "$password2" ]; then
      echo "$password1"
      return
    else
      echo "Passwords do not match. Please try again."
    fi
  done
}

# Function to hash password using mkpasswd
hash_password() {
  local password="$1"
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m sha-512 "$password"
  else
    echo "Error: mkpasswd not found. Please install whois package:"
    echo "  sudo apt-get install whois"
    exit 1
  fi
}

# Clean up any existing mounts first
echo "Checking for existing mounts..."
if mountpoint -q "$BASE_DIR/mount" 2>/dev/null; then
  echo "Found existing mount at $BASE_DIR/mount, unmounting..."
  require_sudo "umount \"$BASE_DIR/mount\" 2>/dev/null || true"
  echo "Cleaning up mount directory..."
  rm -rf "$BASE_DIR/mount"/* 2>/dev/null || true
fi

# Check and create directory structure with proper permissions
echo "Starting directory structure creation..."
if [ ! -d "$BASE_DIR" ]; then
  require_sudo "mkdir -p \"$BASE_DIR/origiso\" \"$BASE_DIR/mount\" \"$BASE_DIR/newiso/isolinux\" && chown -R landnull:landnull \"$BASE_DIR\" && chmod -R u+rwX \"$BASE_DIR\""
else
  # Ensure all required directories exist
  mkdir -p "$BASE_DIR/origiso" "$BASE_DIR/mount" "$BASE_DIR/newiso/isolinux"
fi
echo "Directory structure creation completed."

# Query and download latest Debian netinstall ISO
echo "Starting download of latest Debian netinstall ISO..."

# Function to detect latest netinst ISO name
detect_latest_iso() {
  echo "Detecting latest Debian netinst ISO version..." >&2
  
  # Try to get the latest version from Debian's directory listing
  LATEST_VERSION=$(curl -s "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/" | \
    grep -oP 'debian-[0-9]+\.[0-9]+\.[0-9]+-amd64-netinst\.iso' | \
    head -n 1)
  
  if [ -n "$LATEST_VERSION" ]; then
    echo "Detected latest version: $LATEST_VERSION" >&2
    echo "$LATEST_VERSION"
    return 0
  fi
  
  # Fallback: try to parse from main Debian CD page
  LATEST_VERSION=$(curl -s "https://www.debian.org/CD/netinst/" | \
    grep -oP 'debian-[0-9]+\.[0-9]+\.[0-9]+-amd64-netinst\.iso' | \
    head -n 1)
  
  if [ -n "$LATEST_VERSION" ]; then
    echo "Detected latest version from main page: $LATEST_VERSION" >&2
    echo "$LATEST_VERSION"
    return 0
  fi
  
  # Final fallback: use known current version
  echo "Could not auto-detect version, using fallback: debian-12.11.0-amd64-netinst.iso" >&2
  echo "debian-12.11.0-amd64-netinst.iso"
  return 1
}

# Detect the latest ISO name
LATEST_ISO=$(detect_latest_iso)
ISO_FILE="$BASE_DIR/origiso/$LATEST_ISO"

echo "Target ISO: $LATEST_ISO"
echo "Full path: $ISO_FILE"

# Check for existing netinst ISO
if [ -f "$ISO_FILE" ] && [ -s "$ISO_FILE" ]; then
  # Check if it's a valid ISO (should be larger than 300MB for netinst)
  SIZE=$(stat -f%z "$ISO_FILE" 2>/dev/null || stat -c%s "$ISO_FILE" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 314572800 ]; then  # 300MB
    echo "Valid Debian netinst ISO already exists, skipping download."
  else
    echo "Existing ISO appears to be mini.iso or corrupted, will download netinst..."
    rm -f "$ISO_FILE"
  fi
fi

if [ ! -f "$ISO_FILE" ]; then
  # Check for any existing netinst ISO in the origiso directory (avoid mini.iso)
  EXISTING_ISO=$(find "$BASE_DIR/origiso" -name "*netinst*.iso" -size +300M 2>/dev/null | head -n 1)
  if [ -n "$EXISTING_ISO" ]; then
    ISO_FILE="$EXISTING_ISO"
    echo "Using existing netinst ISO: $ISO_FILE"
  else
    echo "No suitable existing ISO found, downloading latest netinst..."
    
    # Try multiple download sources
    DOWNLOAD_URLS=(
      "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
      "https://ftp.debian.org/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
      "https://mirror.math.princeton.edu/pub/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
      "https://mirrors.kernel.org/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
    )
    
    DOWNLOAD_SUCCESS=false
    for url in "${DOWNLOAD_URLS[@]}"; do
      echo "Trying: $url"
      if wget --timeout=30 --tries=2 -O "$ISO_FILE" "$url"; then
        # Verify download size
        SIZE=$(stat -f%z "$ISO_FILE" 2>/dev/null || stat -c%s "$ISO_FILE" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt 314572800 ]; then
          echo "Download successful from: $url"
          DOWNLOAD_SUCCESS=true
          break
        else
          echo "Downloaded file too small, trying next mirror..."
          rm -f "$ISO_FILE"
        fi
      else
        echo "Download failed from: $url"
      fi
    done
    
    if [ "$DOWNLOAD_SUCCESS" = false ]; then
      echo "All automatic downloads failed. You can manually download from:"
      echo "https://www.debian.org/CD/netinst/"
      echo "Save it as: $ISO_FILE"
      read -r -p "Press Enter after manually downloading the ISO, or Ctrl+C to exit..."
      if [ ! -f "$ISO_FILE" ]; then
        echo "ISO file still not found. Exiting."
        exit 1
      fi
    fi
  fi
fi

# Verify ISO file exists and is readable
if [ ! -f "$ISO_FILE" ]; then
  echo "Error: ISO file not found at $ISO_FILE"
  exit 1
fi

if [ ! -r "$ISO_FILE" ]; then
  echo "Error: ISO file is not readable: $ISO_FILE"
  ls -la "$ISO_FILE"
  exit 1
fi

echo "Download of latest Debian netinstall ISO completed."

# Mount ISO as loop device
echo "Starting mount of ISO as loop device..."
echo "ISO file: $ISO_FILE"
echo "Mount point: $BASE_DIR/mount"

# Clear mount point if it has content
if [ -d "$BASE_DIR/mount" ] && [ "$(ls -A "$BASE_DIR/mount" 2>/dev/null)" ]; then
  echo "Mount point is not empty, clearing..."
  require_sudo "umount \"$BASE_DIR/mount\" 2>/dev/null || true"
  rm -rf "$BASE_DIR/mount"/*
fi

# Mount the ISO
require_sudo "mount -o loop \"$ISO_FILE\" \"$BASE_DIR/mount\"" || {
  echo "Failed to mount $ISO_FILE"
  echo "Checking file details..."
  ls -la "$ISO_FILE"
  echo "Checking dmesg for details..."
  sudo dmesg | tail -n 20
  exit 1
}
echo "Mount of ISO as loop device completed."

# Rsync contents to newiso
echo "Starting copy of ISO contents to newiso..."
# Clear destination first
rm -rf "$BASE_DIR/newiso"/*
require_sudo "rsync -av \"$BASE_DIR/mount/\" \"$BASE_DIR/newiso/\""
require_sudo "chown -R landnull:landnull \"$BASE_DIR/newiso\""
require_sudo "chmod -R u+w \"$BASE_DIR/newiso\""
echo "Copy of ISO contents to newiso completed."

# Unmount original ISO
echo "Starting unmount of original ISO..."
require_sudo "umount \"$BASE_DIR/mount\"" || { 
  echo "Failed to unmount $BASE_DIR/mount"
  echo "Checking what's using the mount point..."
  sudo lsof +D "$BASE_DIR/mount" 2>/dev/null || true
  exit 1
}
echo "Unmount of original ISO completed."

# Check if mkpasswd is available
if ! command -v mkpasswd >/dev/null 2>&1; then
  echo "mkpasswd is required for password hashing but not found."
  read -r -p "Would you like to install the whois package (contains mkpasswd)? [Y/n] " REPLY
  if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    require_sudo "apt-get update && apt-get install -y whois"
  else
    echo "Cannot proceed without mkpasswd. Exiting."
    exit 1
  fi
fi

# Prompt for post-install script location
echo "Starting configuration of post-install script..."
read -r -p "Enter the full path to the post-install script (leave blank to skip): " POST_INSTALL_SCRIPT
POST_INSTALL_FILENAME=""
if [ -n "$POST_INSTALL_SCRIPT" ]; then
  if [ -f "$POST_INSTALL_SCRIPT" ]; then
    POST_INSTALL_FILENAME=$(basename "$POST_INSTALL_SCRIPT")
    # Copy post-install script to newiso
    mkdir -p "$BASE_DIR/newiso/scripts" || { 
      echo "Failed to create scripts directory, trying with sudo..."
      require_sudo "mkdir -p \"$BASE_DIR/newiso/scripts\" && chown landnull:landnull \"$BASE_DIR/newiso/scripts\""
    }
    cp "$POST_INSTALL_SCRIPT" "$BASE_DIR/newiso/scripts/$POST_INSTALL_FILENAME" || { 
      echo "Failed to copy post-install script, trying with sudo..."
      require_sudo "cp \"$POST_INSTALL_SCRIPT\" \"$BASE_DIR/newiso/scripts/$POST_INSTALL_FILENAME\" && chown landnull:landnull \"$BASE_DIR/newiso/scripts/$POST_INSTALL_FILENAME\""
    }
    chmod +x "$BASE_DIR/newiso/scripts/$POST_INSTALL_FILENAME" || {
      echo "Failed to set executable permissions, trying with sudo..."
      require_sudo "chmod +x \"$BASE_DIR/newiso/scripts/$POST_INSTALL_FILENAME\""
    }
    echo "Post-install script copied to $BASE_DIR/newiso/scripts/$POST_INSTALL_FILENAME"
  else
    echo "Warning: Post-install script not found at $POST_INSTALL_SCRIPT. Skipping post-install configuration."
    POST_INSTALL_FILENAME=""
  fi
fi

# Add preseed.cfg from existing file if it exists
echo "Starting addition of preseed.cfg to newiso..."
PRESEED_FILE="$BASE_DIR/preseed.cfg"
if [ -f "$PRESEED_FILE" ]; then
  # Copy existing preseed file
  cp "$PRESEED_FILE" "$BASE_DIR/newiso/preseed.cfg" || { 
    echo "Failed to copy preseed.cfg as user, trying with sudo..."
    require_sudo "cp \"$PRESEED_FILE\" \"$BASE_DIR/newiso/preseed.cfg\" && chown landnull:landnull \"$BASE_DIR/newiso/preseed.cfg\""
  }
  
  echo "Existing preseed file found. Now configuring passwords..."
  ROOT_PASSWORD=$(get_validated_password "Root password" 8)
  USER_PASSWORD=$(get_validated_password "User password" 8)
  ROOT_HASH=$(hash_password "$ROOT_PASSWORD")
  USER_HASH=$(hash_password "$USER_PASSWORD")
  
  # Update preseed file with hashed passwords
  sed -i "s|d-i passwd/root-password-crypted password .*|d-i passwd/root-password-crypted password $ROOT_HASH|" "$BASE_DIR/newiso/preseed.cfg"
  sed -i "s|d-i passwd/user-password-crypted password .*|d-i passwd/user-password-crypted password $USER_HASH|" "$BASE_DIR/newiso/preseed.cfg"
  
  # Remove plaintext password entries
  sed -i "/d-i passwd\/user-password password/d" "$BASE_DIR/newiso/preseed.cfg"
  sed -i "/d-i passwd\/user-password-again password/d" "$BASE_DIR/newiso/preseed.cfg"
  
  # Add or update late_command for post-install script if provided
  if [ -n "$POST_INSTALL_FILENAME" ]; then
    if grep -q "d-i preseed/late_command string" "$BASE_DIR/newiso/preseed.cfg"; then
      sed -i "s|d-i preseed/late_command string .*|d-i preseed/late_command string in-target sh -c 'cp /cdrom/scripts/$POST_INSTALL_FILENAME /root/ && chmod +x /root/$POST_INSTALL_FILENAME && /root/$POST_INSTALL_FILENAME'|" "$BASE_DIR/newiso/preseed.cfg"
    else
      echo "d-i preseed/late_command string in-target sh -c 'cp /cdrom/scripts/$POST_INSTALL_FILENAME /root/ && chmod +x /root/$POST_INSTALL_FILENAME && /root/$POST_INSTALL_FILENAME'" >> "$BASE_DIR/newiso/preseed.cfg"
    fi
  fi
  
  # Copy to multiple locations
  cp "$BASE_DIR/newiso/preseed.cfg" "$BASE_DIR/newiso/preseed" 2>/dev/null || true
  mkdir -p "$BASE_DIR/newiso/debian" 2>/dev/null || true
  cp "$BASE_DIR/newiso/preseed.cfg" "$BASE_DIR/newiso/debian/preseed.cfg" 2>/dev/null || true
  
  echo "Preseed file updated with hashed passwords and copied to multiple locations."
  echo "Preseed file locations:"
  echo "  - /cdrom/preseed.cfg"
  echo "  - /cdrom/preseed"
  echo "  - /cdrom/debian/preseed.cfg"
else
  echo "No existing preseed.cfg found, creating new configuration..."
  ROOT_PASSWORD=$(get_validated_password "Root password" 8)
  USER_PASSWORD=$(get_validated_password "User password" 8)
  ROOT_HASH=$(hash_password "$ROOT_PASSWORD")
  USER_HASH=$(hash_password "$USER_PASSWORD")
  
  # Create a basic preseed template with hashed passwords
  cat > "$BASE_DIR/newiso/preseed.cfg" << 'PRESEED_EOF'
# Debian preseed configuration
# This is a basic template - customize as needed

# Localization
d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/language string en
d-i debian-installer/country string US

# Keyboard selection
d-i console-keymaps-at/keymap select us
d-i keyboard-configuration/xkb-keymap select us

# Network configuration
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string localdomain

# Mirror settings
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

# Account setup
d-i passwd/root-password-crypted password ROOT_HASH_PLACEHOLDER
d-i passwd/root-login boolean true
d-i passwd/user-fullname string Debian User
d-i passwd/username string user
d-i passwd/user-password-crypted password USER_HASH_PLACEHOLDER

# Clock and time zone setup
d-i clock-setup/utc boolean true
d-i time/zone string US/Eastern

# Partitioning
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# Package selection
tasksel tasksel/first multiselect standard, desktop
d-i pkgsel/include string openssh-server
d-i pkgsel/upgrade select full-upgrade

# Boot loader installation
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string default

# Finish installation
d-i finish-install/reboot_in_progress note
PRESEED_EOF
  
  # Replace password placeholders
  sed -i "s|ROOT_HASH_PLACEHOLDER|$ROOT_HASH|" "$BASE_DIR/newiso/preseed.cfg"
  sed -i "s|USER_HASH_PLACEHOLDER|$USER_HASH|" "$BASE_DIR/newiso/preseed.cfg"
  
  # Add late_command for post-install script if provided
  if [ -n "$POST_INSTALL_FILENAME" ]; then
    echo "d-i preseed/late_command string in-target sh -c 'cp /cdrom/scripts/$POST_INSTALL_FILENAME /root/ && chmod +x /root/$POST_INSTALL_FILENAME && /root/$POST_INSTALL_FILENAME'" >> "$BASE_DIR/newiso/preseed.cfg"
  fi
  
  # Copy to multiple locations
  cp "$BASE_DIR/newiso/preseed.cfg" "$BASE_DIR/newiso/preseed" 2>/dev/null || true
  mkdir -p "$BASE_DIR/newiso/debian" 2>/dev/null || true
  cp "$BASE_DIR/newiso/preseed.cfg" "$BASE_DIR/newiso/debian/preseed.cfg" 2>/dev/null || true
  
  echo "Basic preseed template created with hashed passwords. Please edit $BASE_DIR/newiso/preseed.cfg if needed."
fi
echo "Addition of preseed.cfg to newiso completed."

# Modify isolinux configuration for auto boot
echo "Starting modification of boot configuration..."

# Modify BIOS boot configuration (isolinux)
if [ -f "$BASE_DIR/newiso/isolinux/isolinux.cfg" ]; then
  BOOT_CONFIG="$BASE_DIR/newiso/isolinux/isolinux.cfg"
elif [ -f "$BASE_DIR/newiso/isolinux/txt.cfg" ]; then
  BOOT_CONFIG="$BASE_DIR/newiso/isolinux/txt.cfg"
else
  echo "Creating new isolinux configuration..."
  BOOT_CONFIG="$BASE_DIR/newiso/isolinux/isolinux.cfg"
fi

# Backup original config
cp "$BOOT_CONFIG" "$BOOT_CONFIG.backup" 2>/dev/null || true

# Create or modify boot configuration for BIOS
cat > "$BOOT_CONFIG" << 'EOF'
default auto-install
timeout 5
prompt 0

label auto-install
  menu label ^Auto-install Debian
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz file=/cdrom/preseed.cfg auto=true priority=critical preseed/file=/cdrom/preseed.cfg debian-installer/locale=en_US.UTF-8 console-setup/ask_detect=false keyboard-configuration/xkb-keymap=us quiet ---

label manual
  menu label ^Manual install
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz
EOF

# Modify UEFI boot configuration (GRUB)
if [ -f "$BASE_DIR/newiso/boot/grub/grub.cfg" ]; then
  echo "Modifying GRUB configuration for UEFI boot..."
  
  # Ensure we can write to the GRUB config file
  chmod u+w "$BASE_DIR/newiso/boot/grub/grub.cfg" 2>/dev/null || {
    echo "Fixing permissions on GRUB config file..."
    require_sudo "chmod u+w \"$BASE_DIR/newiso/boot/grub/grub.cfg\""
    require_sudo "chown landnull:landnull \"$BASE_DIR/newiso/boot/grub/grub.cfg\""
  }
  
  # Backup original GRUB config
  cp "$BASE_DIR/newiso/boot/grub/grub.cfg" "$BASE_DIR/newiso/boot/grub/grub.cfg.backup" 2>/dev/null || {
    echo "Could not backup GRUB config, continuing anyway..."
  }
  
  # Create new GRUB configuration
  cat > "$BASE_DIR/newiso/boot/grub/grub.cfg" << 'EOF'
if loadfont /boot/grub/font.pf2 ; then
  set gfxmode=auto
  insmod efi_gop
  insmod efi_uga
  insmod gfxterm
  terminal_output gfxterm
fi

set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue
set timeout=5
set default=0

menuentry "Auto-install Debian" {
  set background_color=black
  linux    /install.amd/vmlinuz vga=788 file=/cdrom/preseed.cfg auto=true priority=critical preseed/file=/cdrom/preseed.cfg debian-installer/locale=en_US.UTF-8 console-setup/ask_detect=false keyboard-configuration/xkb-keymap=us quiet ---
  initrd   /install.amd/initrd.gz
}

menuentry "Manual install" {
  set background_color=black
  linux    /install.amd/vmlinuz vga=788
  initrd   /install.amd/initrd.gz
}

menuentry "Advanced options" --class advanced {
  linux    /install.amd/vmlinuz vga=788
  initrd   /install.amd/initrd.gz
}
EOF

  echo "GRUB configuration updated for UEFI boot."
fi

echo "Modification of boot configuration completed."

# Create bootable ISO image with proper UEFI support
echo "Starting creation of bootable ISO image with UEFI support..."

# Verify required files exist
if [ -n "$POST_INSTALL_FILENAME" ] && [ ! -f "$BASE_DIR/newiso/isolinux/isolinux.bin" ]; then
  echo "Warning: isolinux.bin not found, BIOS boot may not work"
fi

if [ ! -f "$BASE_DIR/newiso/boot/grub/efi.img" ] && [ ! -d "$BASE_DIR/newiso/EFI" ]; then
  echo "Warning: No EFI boot files found, UEFI boot may not work"
  echo "Checking for EFI structure..."
  find "$BASE_DIR/newiso" -name "*efi*" -o -name "*EFI*" | head -10
fi

OUTPUT_ISO="$BASE_DIR/preseed-debian-$(date +%Y%m%d-%H%M).iso"

# Create the ISO with both BIOS and UEFI support
echo "Creating hybrid ISO with BIOS and UEFI support..."

# Method 1: Try with xorriso (preferred)
if command -v xorriso >/dev/null 2>&1; then
  echo "Using xorriso to create hybrid ISO..."
  
  # First, try to find the MBR template
  MBR_TEMPLATE=""
  if [ -f "$BASE_DIR/newiso/isolinux/isohdpfx.bin" ]; then
    MBR_TEMPLATE="$BASE_DIR/newiso/isolinux/isohdpfx.bin"
  elif [ -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]; then
    MBR_TEMPLATE="/usr/lib/ISOLINUX/isohdpfx.bin"
  elif [ -f "/usr/lib/syslinux/isohdpfx.bin" ]; then
    MBR_TEMPLATE="/usr/lib/syslinux/isohdpfx.bin"
  fi
  
  # Build xorriso command
  XORRISO_CMD="xorriso -as mkisofs -o \"$OUTPUT_ISO\" -V \"PRESEED_DEBIAN\" -J -joliet-long -cache-inodes"
  
  # Add BIOS boot support
  if [ -f "$BASE_DIR/newiso/isolinux/isolinux.bin" ]; then
    XORRISO_CMD="$XORRISO_CMD -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"
  fi
  
  # Add UEFI boot support
  if [ -f "$BASE_DIR/newiso/boot/grub/efi.img" ]; then
    XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot"
  elif [ -d "$BASE_DIR/newiso/EFI" ]; then
    # Alternative method for newer Debian ISOs
    XORRISO_CMD="$XORRISO_CMD -eltorito-alt-boot -e EFI/boot/bootx64.efi -no-emul-boot"
  fi
  
  # Add hybrid support
  if [ -n "$MBR_TEMPLATE" ]; then
    XORRISO_CMD="$XORRISO_CMD -isohybrid-mbr \"$MBR_TEMPLATE\""
  fi
  
  XORRISO_CMD="$XORRISO_CMD -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \"$BASE_DIR/newiso\""
  
  echo "Executing: $XORRISO_CMD"
  if eval "$XORRISO_CMD"; then
    echo "ISO created successfully with xorriso"
  else
    echo "xorriso failed, trying alternative method..."
    
    # Alternative xorriso method
    if xorriso -as mkisofs \
      -o "$OUTPUT_ISO" \
      -V "PRESEED_DEBIAN" \
      -isohybrid-mbr "$MBR_TEMPLATE" \
      -c isolinux/boot.cat \
      -b isolinux/isolinux.bin \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -eltorito-alt-boot \
      -e boot/grub/efi.img \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      "$BASE_DIR/newiso"; then
      echo "ISO created successfully with alternative xorriso method"
    else
      echo "Alternative xorriso method also failed"
      exit 1
    fi
  fi
  
else
  echo "xorriso not found, trying genisoimage..."
  
  # Method 2: Fallback to genisoimage
  if command -v genisoimage >/dev/null 2>&1; then
    if genisoimage -o "$OUTPUT_ISO" \
      -b isolinux/isolinux.bin \
      -c isolinux/boot.cat \
      -no-emul-boot \
      -boot-load-size 4 \
      -boot-info-table \
      -V "PRESEED_DEBIAN" \
      -J -joliet-long \
      "$BASE_DIR/newiso"; then
      echo "ISO created with genisoimage (BIOS only)"
    else
      echo "Failed to create ISO with genisoimage"
      exit 1
    fi
  else
    echo "Error: Neither xorriso nor genisoimage found. Please install one of them."
    echo "Ubuntu/Debian: sudo apt install xorriso"
    echo "CentOS/RHEL: sudo yum install xorriso"
    exit 1
  fi
fi

# Make the ISO hybrid (bootable from USB)
if command -v isohybrid >/dev/null 2>&1; then
  echo "Making ISO hybrid bootable..."
  if isohybrid "$OUTPUT_ISO" 2>/dev/null; then
    echo "ISO made hybrid bootable successfully"
  else
    echo "isohybrid failed, but ISO should still be bootable"
  fi
else
  echo "isohybrid not found, but ISO should still be bootable on most systems"
fi

echo "Creation of bootable ISO image completed: $OUTPUT_ISO"

# Verify the created ISO
if [ -f "$OUTPUT_ISO" ]; then
  SIZE=$(stat -f%z "$OUTPUT_ISO" 2>/dev/null || stat -c%s "$OUTPUT_ISO" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 100000000 ]; then  # 100MB minimum
    echo "ISO verification: OK (Size: $((SIZE / 1024 / 1024))MB)"
  else
    echo "Warning: ISO seems too small ($((SIZE / 1024 / 1024))MB)"
  fi
else
  echo "Error: ISO file was not created"
  exit 1
fi

# Prompt user to burn to USB
echo "Starting USB burn process..."
read -r -p "Would you like to burn the ISO to a USB drive? [Y/n] " REPLY
echo
if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
  # Show available drives
  echo "Available drives:"
  lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E 'disk'
  
  # Let user select drive
  read -r -p "Enter the device name (e.g., sdc): " USB_DEVICE
  USB_DRIVE="/dev/$USB_DEVICE"
  
  if [ ! -b "$USB_DRIVE" ]; then
    echo "Error: $USB_DRIVE is not a valid block device"
    exit 1
  fi
  
  echo "WARNING: This will completely wipe $USB_DRIVE"
  read -r -p "Are you sure you want to continue? [y/N] " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "USB burn cancelled."
    exit 0
  fi

  # DD command to write ISO to USB
  echo "Writing ISO to $USB_DRIVE..."
  if require_sudo "dd if=\"$OUTPUT_ISO\" of=\"$USB_DRIVE\" bs=4M status=progress oflag=sync"; then
    echo "ISO written to USB successfully"
  else
    echo "Failed to write to $USB_DRIVE"
    exit 1
  fi

  # Run sync command
  sync
  echo "USB burn process completed. The USB drive is ready to be removed."
  echo ""
  echo "UEFI Boot Instructions:"
  echo "1. Insert the USB drive into the target computer"
  echo "2. Boot and enter BIOS/UEFI settings (usually F2, F12, Del, or Esc)"
  echo "3. Ensure UEFI boot is enabled (not Legacy/CSM mode)"
  echo "4. Set the USB drive as the first boot device"
  echo "5. Save and exit BIOS/UEFI settings"
  echo "6. The system should boot into the Debian installer"
else
  echo "USB burn skipped. ISO image location: $OUTPUT_ISO"
fi

echo "Script completed successfully!"
echo ""
echo "Troubleshooting UEFI boot issues:"
echo "- Ensure your system's UEFI firmware is up to date"
echo "- Try disabling Secure Boot in BIOS/UEFI settings"
echo "- Verify the USB port is working (try different ports)"
echo "- Some systems require the USB drive to be formatted as GPT first"
echo "- Check if 'Fast Boot' or 'Ultra Fast Boot' is disabled in BIOS"
