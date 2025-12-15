#!/bin/bash

# Define colors for better terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
RESET='\033[0m' # No Color
BOLD_GREEN='\033[1;32m'
BOLD_MAGENTA='\033[1;35m'
BOLD_BLUE='\033[1;34m'
BOLD_RED='\033[1;31m'
BOLD_CYAN='\033[1;36m'
BOLD_YELLOW='\033[1;33m'

# --- Global Paths and Markers ---
TRUST_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$TRUST_SCRIPT_PATH")"
SETUP_MARKER_FILE="/var/lib/mtpulse/.setup_complete_v2"
SCRIPT_VERSION="1.0.0"

# --- OS Detection ---
check_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
      echo -e "\033[0;31m❌ Error: This script only supports Ubuntu and Debian.\033[0m"
      echo -e "\033[0;33mDetected OS: $PRETTY_NAME\033[0m"
      exit 1
    fi
  else
    echo -e "\033[0;31m❌ Error: Cannot detect operating system. /etc/os-release not found.\033[0m"
    exit 1
  fi
}

# Run OS check immediately
check_os

# --- Helper Functions ---

draw_line() {
  local color="$1"
  local char="$2"
  local length=${3:-40}
  printf "${color}"
  for ((i=0; i<length; i++)); do
    printf "$char"
  done
  printf "${RESET}\n"
}

print_success() {
  local message="$1"
  echo -e "\033[0;32m✅ $message\033[0m"
}

print_error() {
  local message="$1"
  echo -e "\033[0;31m❌ $message\033[0m"
}

draw_green_line() {
  echo -e "${GREEN}+--------------------------------------------------------+${RESET}"
}

# --- Initial Setup ---
perform_initial_setup() {
  if [ -f "$SETUP_MARKER_FILE" ]; then
    return 0
  fi

  echo -e "${CYAN}Performing initial setup (installing dependencies)...${RESET}"
  sudo apt update
  sudo apt install -y git make build-essential libssl-dev zlib1g-dev curl wget tar xxd figlet
  
  sudo mkdir -p "$(dirname "$SETUP_MARKER_FILE")"
  sudo touch "$SETUP_MARKER_FILE"
  print_success "Initial setup complete."
  echo ""
}

# --- Actions ---

install_mtproxy_action() {
  clear
  echo ""
  draw_line "$CYAN" "=" 40
  echo -e "${BOLD_GREEN}     📥 Install MTProto Proxy (Official)${RESET}"
  draw_line "$CYAN" "=" 40
  echo ""

  # 1. Check for existing binary
  local skip_compile=false
  if [ -f "/usr/local/bin/mtproto-proxy" ]; then
      echo -e "${YELLOW}Existing MTProxy binary found.${RESET}"
      echo -e -n "👉 ${BOLD_MAGENTA}Do you want to use the existing binary? (Y/n): ${RESET}"
      read use_existing
      if [[ -z "$use_existing" || "$use_existing" =~ ^[Yy]$ ]]; then
          skip_compile=true
          print_success "Skipping compilation."
      fi
  fi

  if [ "$skip_compile" = false ]; then
      echo -e "${CYAN}Cloning official MTProxy repository...${RESET}"
      if [ -d "MTProxy" ]; then
        rm -rf MTProxy
      fi
      git clone https://github.com/TelegramMessenger/MTProxy.git
      cd MTProxy
    
      # Patch for large PIDs (Fixes: Assertion `!(p & 0xffff0000)' failed)
      echo -e "${CYAN}Patching source for large PIDs...${RESET}"
      if [ -f "common/pid.c" ]; then
        sed -i 's/assert (!(p & 0xffff0000));/\/\/ assert (!(p \& 0xffff0000));/g' common/pid.c
      fi
    
      echo -e "${CYAN}Compiling source code...${RESET}"
      
      # Run make in background and show a counter
      make > /tmp/mtpulse_make.log 2>&1 &
      local make_pid=$!
      local counter=1
      
      # Hide cursor
      tput civis
      
      while kill -0 $make_pid 2>/dev/null; do
          printf "\r${BOLD_MAGENTA}Compiling... ${WHITE}[ %d ]${RESET}" "$counter"
          ((counter++))
          sleep 0.5
      done
      
      # Restore cursor
      tput cnorm
      echo ""
      
      wait $make_pid
      local make_status=$?
      
      if [ $make_status -ne 0 ] || [ ! -f "objs/bin/mtproto-proxy" ]; then
        print_error "Compilation failed. Check dependencies."
        echo -e "${YELLOW}--- Error Log ---${RESET}"
        tail -n 20 /tmp/mtpulse_make.log
        cd ..
      echo -e "${BOLD_MAGENTA}Press Enter to return...${RESET}"
  read
        return 1
      fi
    
      echo -e "${CYAN}Installing binary...${RESET}"
      sudo cp objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
      sudo chmod +x /usr/local/bin/mtproto-proxy
      cd ..
      rm -rf MTProxy
      print_success "MTProxy installed to /usr/local/bin/mtproto-proxy"
  fi

  # 2. Configuration Files
  echo -e "${CYAN}Setting up configuration files...${RESET}"
  sudo mkdir -p /etc/mtpulse
  
  # Download proxy-secret and proxy-multi.conf
  sudo curl -s https://core.telegram.org/getProxySecret -o /etc/mtpulse/proxy-secret
  sudo curl -s https://core.telegram.org/getProxyConfig -o /etc/mtpulse/proxy-multi.conf

  # 3. User Input
  echo ""
  echo -e "${CYAN}--- Configuration ---${RESET}"
  
  # Port
  local port
  while true; do
    echo -e -n "👉 ${BOLD_MAGENTA}Enter port (default 443): ${RESET}"
    read port
    port=${port:-443}
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
      break
    else
      print_error "Invalid port."
    fi
  done

  # Secret
  echo -e "${CYAN}Generating secret...${RESET}"
  local secret=$(head -c 16 /dev/urandom | xxd -ps)
  echo -e "Generated Secret: ${WHITE}$secret${RESET}"
  
  # 4. Create Service
  echo -e "${CYAN}Creating systemd service...${RESET}"
  
  local exec_start="/usr/local/bin/mtproto-proxy -u nobody -p 8888 -H $port -S $secret --aes-pwd /etc/mtpulse/proxy-secret /etc/mtpulse/proxy-multi.conf -M 1"
  
  cat <<EOF | sudo tee /etc/systemd/system/mtpulse.service
[Unit]
Description=MTPulse MTProto Proxy (Official)
After=network.target

[Service]
ExecStart=$exec_start
Restart=always
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable mtpulse
  sudo systemctl start mtpulse

  print_success "MTPulse service started!"
  
  # Show info
  local public_ip=$(curl -s https://api.ipify.org)
  echo ""
  draw_line "$GREEN" "=" 40
  echo -e "${BOLD_GREEN}     🚀 Proxy Details${RESET}"
  draw_line "$GREEN" "=" 40
  echo -e "IP: ${WHITE}$public_ip${RESET}"
  echo -e "Port: ${WHITE}$port${RESET}"
  echo -e "Secret: ${WHITE}$secret${RESET}"
  echo ""
  echo -e "${BOLD_CYAN}tg://proxy?server=$public_ip&port=$port&secret=$secret${RESET}"
  echo ""
  
  echo -e "${BOLD_MAGENTA}Press Enter to return...${RESET}"
  read
}

uninstall_mtpulse_action() {
  clear
  echo -e "${RED}⚠️ Are you sure you want to uninstall MTPulse? (y/N)${RESET}"
  read confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Stopping and disabling service...${RESET}"
    sudo systemctl stop mtpulse
    sudo systemctl disable mtpulse
    sudo rm /etc/systemd/system/mtpulse.service
    sudo systemctl daemon-reload
    
    echo -e "${CYAN}Removing binary and configs...${RESET}"
    sudo rm -f /usr/local/bin/mtproto-proxy
    sudo rm -rf /etc/mtpulse
    
    echo -e "${CYAN}Removing setup markers and temporary files...${RESET}"
    sudo rm -rf /var/lib/mtpulse
    
    # Remove source folder if it exists in current directory
    if [ -d "MTProxy" ]; then
        rm -rf MTProxy
    fi
    
    print_success "Uninstalled successfully. All files and services have been removed."
  fi
  echo -e "${BOLD_MAGENTA}Press Enter to return...${RESET}"
  read
}

service_management_menu() {
  while true; do
    clear
    draw_line "$CYAN" "=" 40
    echo -e "${BOLD_GREEN}     ⚙️ Service Management${RESET}"
    draw_line "$CYAN" "=" 40
    echo ""
    echo -e "  ${BOLD_CYAN}1)${RESET} ${WHITE}Status${RESET}"
    echo -e "  ${BOLD_CYAN}2)${RESET} ${WHITE}Start${RESET}"
    echo -e "  ${BOLD_CYAN}3)${RESET} ${WHITE}Stop${RESET}"
    echo -e "  ${BOLD_CYAN}4)${RESET} ${WHITE}Restart${RESET}"
    echo -e "  ${BOLD_CYAN}5)${RESET} ${WHITE}Logs${RESET}"
    echo -e "  ${BOLD_CYAN}0)${RESET} ${WHITE}Back${RESET}"
    echo ""
    echo -e -n "👉 ${BOLD_MAGENTA}Select an option: ${RESET}"
    read svc_choice
    case $svc_choice in
      1) sudo systemctl status mtpulse ; echo -e "${YELLOW}Press Enter...${RESET}" ; read ;;
      2) sudo systemctl start mtpulse ; print_success "Started" ; sleep 1 ;;
      3) sudo systemctl stop mtpulse ; print_success "Stopped" ; sleep 1 ;;
      4) sudo systemctl restart mtpulse ; print_success "Restarted" ; sleep 1 ;;
      5) sudo journalctl -u mtpulse -n 50 --no-pager ; echo -e "${YELLOW}Press Enter...${RESET}" ; read ;;
      0) break ;;
      *) print_error "Invalid option" ;;
    esac
  done
}

configure_sponsor_action() {
  clear
  echo -e "${BOLD_GREEN}--- Add Tag to Your Proxy ---${RESET}"
  
  if ! systemctl is-active --quiet mtpulse; then
    print_error "Proxy is NOT active. Please install and start the proxy first."
    echo -e "${BOLD_MAGENTA}Press Enter to return...${RESET}"
    read
    return
  fi
  
  if [ ! -f /etc/systemd/system/mtpulse.service ]; then
    print_error "Service file not found."
    echo -e "${BOLD_MAGENTA}Press Enter...${RESET}"
    read
    return
  fi
  
  # Extract current tag if exists
  local current_exec=$(grep "ExecStart=" /etc/systemd/system/mtpulse.service)
  local current_tag=""
  if [[ "$current_exec" =~ -P\ ([a-f0-9]+) ]]; then
    current_tag="${BASH_REMATCH[1]}"
    echo -e "Current Tag: ${BOLD_MAGENTA}$current_tag${RESET}"
    echo ""
    
    echo -e -n "👉 ${BOLD_MAGENTA}You already have a tag set. Do you want to remove it and set a new one? (y/N): ${RESET}"
    read replace_tag
    if [[ ! "$replace_tag" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Returning to main menu...${RESET}"
        return
    fi
  else
    echo -e "Current Tag: ${WHITE}None${RESET}"
    echo ""
  fi
  
  echo -e "${YELLOW}ℹ️  To get an AD Tag, you must use the official Telegram bot:${RESET} ${BOLD_BLUE}@MTProxybot${RESET}"
  echo -e "${YELLOW}    Register your proxy there and it will give you a 32-character hex tag.${RESET}"
  echo ""
  
  echo -e -n "👉 ${BOLD_MAGENTA}Enter new AD Tag (leave empty to remove): ${RESET}"
  read new_tag
  
  # Remove existing -P flag
  local new_exec=$(echo "$current_exec" | sed -E 's/ -P [a-f0-9]+//')
  
  # Add new tag if provided
  if [[ -n "$new_tag" ]]; then
    new_exec="$new_exec -P $new_tag"
    print_success "Sponsor tag updated to: $new_tag"
  else
    print_success "Sponsor tag removed."
  fi
  
  # Update service file
  # We use a temp file to avoid issues with sed in-place on system files sometimes
  local temp_service=$(mktemp)
  cp /etc/systemd/system/mtpulse.service "$temp_service"
  sed -i "s|^ExecStart=.*|$new_exec|" "$temp_service"
  sudo mv "$temp_service" /etc/systemd/system/mtpulse.service
  
  echo -e "${CYAN}Reloading and restarting service...${RESET}"
  sudo systemctl daemon-reload
  sudo systemctl restart mtpulse
  echo -e "${BOLD_MAGENTA}Press Enter to return...${RESET}"
  read
}


# --- Main Menu ---
# --- Main Menu ---
show_menu() {
  clear
  echo -e "${BOLD_CYAN}"
  figlet -f slant "MTPulse"
  echo -e "${RESET}"
  draw_line "$CYAN" "=" 60
  echo ""
  echo -e "Developed by ErfanXRay => ${BOLD_GREEN}https://github.com/Erfan-XRay/MTPulse${RESET}"
  echo -e "Telegram Channel => ${BOLD_GREEN}@Erfan_XRay${RESET}"
  echo -e "Script Version => ${BOLD_CYAN}$SCRIPT_VERSION${RESET}"
  echo -e "MTProto Proxy Manager for ${BOLD_CYAN}Ubuntu & Debian${RESET}"
  echo ""

  # Check status
  if systemctl is-active --quiet mtpulse; then
      echo -e "Proxy Status: ${GREEN}Active${RESET}"
      
      # Get details from service file
      if [ -f /etc/systemd/system/mtpulse.service ]; then
          local service_exec=$(grep "ExecStart=" /etc/systemd/system/mtpulse.service)
          local port=$(echo "$service_exec" | sed -n 's/.*-H \([0-9]*\).*/\1/p')
          local secret=$(echo "$service_exec" | sed -n 's/.*-S \([a-f0-9]*\).*/\1/p')
          local tag=$(echo "$service_exec" | sed -n 's/.*-P \([a-f0-9]*\).*/\1/p')
          
          # Get IP (cache it to avoid delay)
          local public_ip=""
          if [ -f /etc/mtpulse/public_ip ]; then
              public_ip=$(cat /etc/mtpulse/public_ip)
          else
              # Try to fetch with short timeout
              public_ip=$(curl -s --max-time 2 https://api.ipify.org)
              if [[ -n "$public_ip" ]]; then
                 # Save for next time if directory exists
                 [ -d /etc/mtpulse ] && echo "$public_ip" > /etc/mtpulse/public_ip
              fi
          fi
          
          if [[ -n "$public_ip" && -n "$port" && -n "$secret" ]]; then
              echo -e "Link: ${BOLD_CYAN}tg://proxy?server=$public_ip&port=$port&secret=$secret${RESET}"
              if [[ -n "$tag" ]]; then
                  echo -e "Sponsor Tag: ${BOLD_MAGENTA}$tag${RESET}"
              fi
          fi
      fi
  else
      echo -e "Proxy Status: ${RED}Inactive${RESET}"
  fi
  
  echo ""
  draw_line "$CYAN" "-" 60
  echo -e "  ${BOLD_CYAN}1)${RESET} ${WHITE}Install MTProto Proxy${RESET}"
  echo -e "  ${BOLD_CYAN}2)${RESET} ${WHITE}Service Management${RESET}"
  echo -e "  ${BOLD_CYAN}3)${RESET} ${WHITE}Add Tag to Your Proxy${RESET}"
  echo -e "  ${BOLD_CYAN}4)${RESET} ${WHITE}Uninstall MTPulse${RESET}"
  echo -e "  ${BOLD_CYAN}0)${RESET} ${WHITE}Exit${RESET}"
  echo ""
  draw_line "$CYAN" "-" 60
}

# --- Main Loop ---
perform_initial_setup

while true; do
  show_menu
  echo -e -n "👉 ${BOLD_MAGENTA}Select an option: ${RESET}"
  read choice
  case $choice in
    1) install_mtproxy_action ;;
    2) service_management_menu ;;
    3) configure_sponsor_action ;;
    4) uninstall_mtpulse_action ;;
    0) exit 0 ;;
    *) print_error "Invalid option" ; sleep 1 ;;
  esac
done
