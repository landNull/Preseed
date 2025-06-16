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
    if [ ${#password1} -lt $min_length ]; then
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

# Add preseed.cfg from existing file if it exists
echo "Starting addition of preseed.cfg to newiso..."
PRESEED_FILE="$BASE_DIR/preseed.cfg"

# Check if mkpasswd is available
if ! command -v mkpasswd >/dev/null 2>&1; then
  echo "mkpasswd is required for password hashing but not found."
  read -p "Would you like to install the whois package (contains mkpasswd)? [Y/n] " -r
  if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
    require_sudo "apt-get update && apt-get install -y whois"
  else
    echo "Cannot proceed without mkpasswd. Exiting."
    exit 1
  fi
fi

if [ -f "$PRESEED_FILE" ]; then
  # Copy existing preseed file
  cp "$PRESEED_FILE" "$BASE_DIR/newiso/preseed.cfg" || { 
    echo "Failed to copy preseed.cfg as user, trying with sudo..."
    require_sudo "cp \"$PRESEED_FILE\" \"$BASE_DIR/newiso/preseed.cfg\" && chown landnull:landnull \"$BASE_DIR/newiso/preseed.cfg\""
  }
  
  echo "Existing preseed file found. Now configuring passwords..."
else
  echo "No existing preseed.cfg found, creating new configuration..."
  
  # Create a basic preseed template
  cat > "$BASE_DIR/newiso/preseed.cfg" << 'PRESEED_EOF'
