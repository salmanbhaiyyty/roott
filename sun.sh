#!/bin/bash
#==============================================================================
# Sunshine Remote Desktop Setup Script (sun.sh)
# Description: Automated installation and configuration of Sunshine streaming
#              server with Cloudflare tunnel on Ubuntu 22.04
# Author: Noderhunterz
# Version: 2.3 (Fixed - Working)
#==============================================================================

set -e  # Exit on error

# Color codes
readonly CYAN='\033[0;36m'
readonly GREEN='\033[1;32m'
readonly RED='\033[1;31m'
readonly BLUE='\033[1;34m'
readonly PURPLE='\033[1;35m'
readonly YELLOW='\033[1;33m'
readonly RESET='\033[0m'
readonly BOLD='\033[1m'

# Configuration
readonly SUNSHINE_VERSION="0.23.1"
readonly DISPLAY_NUM=":0"
readonly SCREEN_SESSION_SUNSHINE="sunshine"
readonly SCREEN_SESSION_CLOUDFLARED="cloudflared"
readonly LOG_DIR="/var/log/sunshine-setup"
readonly CLOUDFLARED_LOG="/tmp/cloudflared.log"

#==============================================================================
# Helper Functions
#==============================================================================

log_task() {
    echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"
}

log_success() {
    echo -e "${GREEN}✓${RESET} $1"
}

log_error() {
    echo -e "${RED}✗ ERROR:${RESET} $1"
    exit 1
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run as root. Use normal user with sudo privileges."
    fi
}

show_banner() {
    clear
    echo -e "${PURPLE}${BOLD}"
    cat << "EOF"
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║   ███████╗██╗   ██╗███╗   ██╗███████╗██╗  ██╗██╗███╗   ██╗███████╗║
║   ██╔════╝██║   ██║████╗  ██║██╔════╝██║  ██║██║████╗  ██║██╔════╝║
║   ███████╗██║   ██║██╔██╗ ██║███████╗███████║██║██╔██╗ ██║█████╗  ║
║   ╚════██║██║   ██║██║╚██╗██║╚════██║██╔══██║██║██║╚██╗██║██╔══╝  ║
║   ███████║╚██████╔╝██║ ╚████║███████║██║  ██║██║██║ ╚████║███████╗║
║   ╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝║
║                                                                    ║
║              Remote Desktop Setup - Powered by Noderhunterz        ║
║                          [FIXED VERSION]                           ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${RESET}\n"
}

#==============================================================================
# Installation Functions
#==============================================================================

install_dependencies() {
    log_task "Installing System Dependencies"
    
    if ! sudo apt update -qq 2>/dev/null; then
        log_error "Failed to update package list. Check your internet connection."
    fi
    
    if ! sudo apt install -y \
        xserver-xorg-video-dummy \
        lxde-core \
        lxde-common \
        lxsession \
        screen \
        curl \
        unzip \
        wget \
        ufw \
        net-tools \
        x11-utils \
        >/dev/null 2>&1; then
        log_error "Failed to install dependencies"
    fi
    
    log_success "Dependencies installed"
}

kill_existing_processes() {
    log_task "Cleaning Existing Processes"
    
    pkill -9 sunshine 2>/dev/null || true
    pkill -9 cloudflared 2>/dev/null || true
    pkill -9 lxsession 2>/dev/null || true
    pkill -9 lxpanel 2>/dev/null || true
    pkill -9 openbox 2>/dev/null || true
    pkill -9 -f "Xorg :0" 2>/dev/null || true
    pkill -9 -f "Xorg.*vt7" 2>/dev/null || true
    
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    screen -S "$SCREEN_SESSION_CLOUDFLARED" -X quit 2>/dev/null || true
    
    sleep 2
    log_success "Cleanup completed"
}

install_sunshine() {
    if command -v sunshine &>/dev/null; then
        log_task "Sunshine"
        log_success "Already installed (v${SUNSHINE_VERSION})"
        return 0
    fi
    
    log_task "Installing Sunshine v${SUNSHINE_VERSION}"
    
    local deb_file="/tmp/sunshine_${SUNSHINE_VERSION}.deb"
    local download_url="https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_VERSION}/sunshine-ubuntu-22.04-amd64.deb"
    
    if ! wget -q --show-progress -O "$deb_file" "$download_url" 2>&1; then
        log_error "Failed to download Sunshine. Check internet connection."
    fi
    
    if ! sudo apt install -y "$deb_file" >/dev/null 2>&1; then
        rm -f "$deb_file"
        log_error "Failed to install Sunshine package"
    fi
    
    rm -f "$deb_file"
    log_success "Sunshine installed successfully"
}

configure_firewall() {
    log_task "Configuring Firewall"
    
    local ports=("22/tcp" "47984/tcp" "47989/tcp" "48010/tcp" "47990/tcp" "47998:48002/udp")
    
    for port in "${ports[@]}"; do
        if ! sudo ufw allow "$port" >/dev/null 2>&1; then
            log_error "Failed to configure firewall for port $port"
        fi
    done
    
    if ! sudo ufw --force enable >/dev/null 2>&1; then
        log_error "Failed to enable firewall"
    fi
    
    log_success "Firewall configured"
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        log_task "Cloudflared"
        log_success "Already installed"
        return 0
    fi
    
    log_task "Installing Cloudflared"
    
    local deb_file="/tmp/cloudflared-linux-amd64.deb"
    
    if ! wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O "$deb_file" 2>&1; then
        log_error "Failed to download Cloudflared"
    fi
    
    if ! sudo apt install -y "$deb_file" >/dev/null 2>&1; then
        rm -f "$deb_file"
        log_error "Failed to install Cloudflared"
    fi
    
    rm -f "$deb_file"
    log_success "Cloudflared installed"
}

configure_xorg() {
    log_task "Configuring X Server"
    
    if ! sudo mkdir -p /etc/X11/xorg.conf.d; then
        log_error "Failed to create X11 config directory"
    fi
    
    sudo tee /etc/X11/xorg.conf.d/10-evdev.conf > /dev/null <<'EOF'
Section "InputDevice"
    Identifier "Dummy Mouse"
    Driver "evdev"
    Option "Device" "/dev/uinput"
    Option "Emulate3Buttons" "true"
    Option "EmulateWheel" "true"
    Option "ZAxisMapping" "4 5"
EndSection

Section "InputDevice"
    Identifier "Dummy Keyboard"
    Driver "evdev"
    Option "Device" "/dev/uinput"
EndSection
EOF

    sudo tee /etc/X11/xorg.conf.d/10-dummy.conf > /dev/null <<'EOF'
Section "Monitor"
    Identifier "DummyMonitor"
    HorizSync 28.0-80.0
    VertRefresh 48.0-75.0
    Option "DPMS"
    Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
EndSection

Section "Device"
    Identifier "DummyDevice"
    Driver "dummy"
    VideoRam 256000
EndSection

Section "Screen"
    Identifier "DummyScreen"
    Device "DummyDevice"
    Monitor "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080"
    EndSubSection
EndSection
EOF

    log_success "X Server configured"
}

start_x_server() {
    log_task "Starting X Server"
    
    export DISPLAY="$DISPLAY_NUM"
    
    sudo Xorg "$DISPLAY_NUM" \
        -config /etc/X11/xorg.conf.d/10-dummy.conf \
        -configdir /etc/X11/xorg.conf.d \
        vt7 >/dev/null 2>&1 &
    
    sleep 4
    
    if ! xdpyinfo -display "$DISPLAY_NUM" &>/dev/null; then
        log_error "Failed to start X Server. Check Xorg logs."
    fi
    
    log_success "X Server running on display $DISPLAY_NUM"
}

start_lxde() {
    log_task "Starting LXDE Desktop"
    
    DISPLAY="$DISPLAY_NUM" lxsession >/dev/null 2>&1 &
    sleep 3
    
    if ! pgrep -x lxsession >/dev/null; then
        log_error "Failed to start LXDE"
    fi
    
    log_success "LXDE started"
}

start_sunshine() {
    log_task "Starting Sunshine Server"
    
    # Kill any existing screen session first
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    sleep 1
    
    # Check if sunshine binary exists and is executable
    if ! command -v sunshine &>/dev/null; then
        log_error "Sunshine binary not found in PATH"
    fi
    
    # ============================================
    # CRITICAL FIX: Single quotes prevent variable expansion issues
    # ============================================
    screen -dmS "$SCREEN_SESSION_SUNSHINE" bash -c 'DISPLAY=:0 sunshine'
    sleep 5
    
    # Check if screen session exists
    if ! screen -ls 2>/dev/null | grep -q "$SCREEN_SESSION_SUNSHINE"; then
        echo -e "${YELLOW}Debug Info:${RESET}"
        echo "Screen sessions:"
        screen -ls 2>/dev/null || echo "No screen sessions found"
        echo ""
        echo "Sunshine process:"
        pgrep -a sunshine || echo "No sunshine process found"
        log_error "Failed to start Sunshine in screen session"
    fi
    
    # Verify sunshine is actually running
    sleep 2
    if ! pgrep -x sunshine >/dev/null; then
        echo -e "${YELLOW}Trying alternative method...${RESET}"
        # Try direct background execution
        DISPLAY=:0 sunshine >/tmp/sunshine.log 2>&1 &
        sleep 3
        if ! pgrep -x sunshine >/dev/null; then
            echo "Sunshine error log:"
            cat /tmp/sunshine.log 2>/dev/null || echo "No log available"
            log_error "Failed to start Sunshine process"
        fi
    fi
    
    log_success "Sunshine running (PID: $(pgrep sunshine))"
}

start_cloudflared_tunnel() {
    log_task "Starting Cloudflare Tunnel"
    
    rm -f "$CLOUDFLARED_LOG"
    
    screen -dmS "$SCREEN_SESSION_CLOUDFLARED" bash -c \
        "cloudflared tunnel --no-tls-verify --url https://localhost:47990 > $CLOUDFLARED_LOG 2>&1"
    
    echo -e "${YELLOW}  Waiting for tunnel...${RESET}"
    
    local max_wait=15
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "$CLOUDFLARED_LOG" ]] && grep -q "trycloudflare.com" "$CLOUDFLARED_LOG"; then
            break
        fi
        sleep 1
        ((waited++))
    done
    
    if [[ ! -f "$CLOUDFLARED_LOG" ]]; then
        log_error "Cloudflared log file not created. Check screen session."
    fi
    
    local tunnel_url=$(grep -oP 'https://[^\s]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n 1)
    
    if [[ -z "$tunnel_url" ]]; then
        log_error "Failed to get tunnel URL. Check: $CLOUDFLARED_LOG"
    fi
    
    log_success "Tunnel established"
    
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║${RESET}                   ${BOLD}🌐 PUBLIC ACCESS URL${RESET}                       ${GREEN}${BOLD}║${RESET}"
    echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${GREEN}${BOLD}║${RESET}  ${YELLOW}${tunnel_url}${RESET}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

show_final_summary() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║                    ✓ SETUP COMPLETED ✓                        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Quick Commands:${RESET}"
    echo -e "  ${YELLOW}screen -r sunshine${RESET}      → View Sunshine logs"
    echo -e "  ${YELLOW}screen -r cloudflared${RESET}   → View Cloudflared logs"
    echo -e "  ${YELLOW}Ctrl+A then D${RESET}           → Exit screen"
    echo ""
    echo -e "${CYAN}${BOLD}Next Steps:${RESET}"
    echo -e "  ${GREEN}1.${RESET} Open tunnel URL in browser"
    echo -e "  ${GREEN}2.${RESET} Complete Sunshine setup (create username/password)"
    echo -e "  ${GREEN}3.${RESET} Connect via Moonlight client"
    echo ""
    echo -e "${CYAN}${BOLD}Troubleshooting:${RESET}"
    echo -e "  ${YELLOW}./sun.sh${RESET}                → Re-run this script"
    echo -e "  ${YELLOW}screen -ls${RESET}              → List all screen sessions"
    echo -e "  ${YELLOW}sudo reboot${RESET}             → Restart if needed"
    echo ""
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    show_banner
    check_root
    
    sudo mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    echo -e "${BOLD}${BLUE}Starting installation...${RESET}\n"
    
    install_dependencies
    kill_existing_processes
    install_sunshine
    configure_firewall
    install_cloudflared
    configure_xorg
    start_x_server
    start_lxde
    start_sunshine
    start_cloudflared_tunnel
    
    show_final_summary
    
    echo -e "${GREEN}${BOLD}Installation completed successfully!${RESET}\n"
}

# Error trap
trap 'echo -e "\n${RED}${BOLD}✗ Script failed at line $LINENO${RESET}\n"; exit 1' ERR

main "$@"║   ███████║╚██████╔╝██║ ╚████║███████║██║  ██║██║██║ ╚████║███████╗║
║   ╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝║
║                                                                    ║
║              Remote Desktop Setup - Powered by Noderhunterz        ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${RESET}\n"
}

#==============================================================================
# Installation Functions
#==============================================================================

install_dependencies() {
    log_task "Installing System Dependencies"
    
    if ! sudo apt update -qq 2>/dev/null; then
        log_error "Failed to update package list. Check your internet connection."
    fi
    
    if ! sudo apt install -y \
        xserver-xorg-video-dummy \
        lxde-core \
        lxde-common \
        lxsession \
        screen \
        curl \
        unzip \
        wget \
        ufw \
        net-tools \
        x11-utils \
        >/dev/null 2>&1; then
        log_error "Failed to install dependencies"
    fi
    
    log_success "Dependencies installed"
}

kill_existing_processes() {
    log_task "Cleaning Existing Processes"
    
    pkill -9 sunshine 2>/dev/null || true
    pkill -9 cloudflared 2>/dev/null || true
    pkill -9 lxsession 2>/dev/null || true
    pkill -9 lxpanel 2>/dev/null || true
    pkill -9 openbox 2>/dev/null || true
    pkill -9 -f "Xorg :0" 2>/dev/null || true
    pkill -9 -f "Xorg.*vt7" 2>/dev/null || true
    
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    screen -S "$SCREEN_SESSION_CLOUDFLARED" -X quit 2>/dev/null || true
    
    sleep 2
    log_success "Cleanup completed"
}

install_sunshine() {
    if command -v sunshine &>/dev/null; then
        log_task "Sunshine"
        log_success "Already installed (v${SUNSHINE_VERSION})"
        return 0
    fi
    
    log_task "Installing Sunshine v${SUNSHINE_VERSION}"
    
    local deb_file="/tmp/sunshine_${SUNSHINE_VERSION}.deb"
    local download_url="https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_VERSION}/sunshine-ubuntu-22.04-amd64.deb"
    
    if ! wget -q --show-progress -O "$deb_file" "$download_url" 2>&1; then
        log_error "Failed to download Sunshine. Check internet connection."
    fi
    
    if ! sudo apt install -y "$deb_file" >/dev/null 2>&1; then
        rm -f "$deb_file"
        log_error "Failed to install Sunshine package"
    fi
    
    rm -f "$deb_file"
    log_success "Sunshine installed successfully"
}

configure_firewall() {
    log_task "Configuring Firewall"
    
    local ports=("22/tcp" "47984/tcp" "47989/tcp" "48010/tcp" "47990/tcp" "47998:48002/udp")
    
    for port in "${ports[@]}"; do
        if ! sudo ufw allow "$port" >/dev/null 2>&1; then
            log_error "Failed to configure firewall for port $port"
        fi
    done
    
    if ! sudo ufw --force enable >/dev/null 2>&1; then
        log_error "Failed to enable firewall"
    fi
    
    log_success "Firewall configured"
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        log_task "Cloudflared"
        log_success "Already installed"
        return 0
    fi
    
    log_task "Installing Cloudflared"
    
    local deb_file="/tmp/cloudflared-linux-amd64.deb"
    
    if ! wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O "$deb_file" 2>&1; then
        log_error "Failed to download Cloudflared"
    fi
    
    if ! sudo apt install -y "$deb_file" >/dev/null 2>&1; then
        rm -f "$deb_file"
        log_error "Failed to install Cloudflared"
    fi
    
    rm -f "$deb_file"
    log_success "Cloudflared installed"
}

configure_xorg() {
    log_task "Configuring X Server"
    
    if ! sudo mkdir -p /etc/X11/xorg.conf.d; then
        log_error "Failed to create X11 config directory"
    fi
    
    sudo tee /etc/X11/xorg.conf.d/10-evdev.conf > /dev/null <<'EOF'
Section "InputDevice"
    Identifier "Dummy Mouse"
    Driver "evdev"
    Option "Device" "/dev/uinput"
    Option "Emulate3Buttons" "true"
    Option "EmulateWheel" "true"
    Option "ZAxisMapping" "4 5"
EndSection

Section "InputDevice"
    Identifier "Dummy Keyboard"
    Driver "evdev"
    Option "Device" "/dev/uinput"
EndSection
EOF

    sudo tee /etc/X11/xorg.conf.d/10-dummy.conf > /dev/null <<'EOF'
Section "Monitor"
    Identifier "DummyMonitor"
    HorizSync 28.0-80.0
    VertRefresh 48.0-75.0
    Option "DPMS"
    Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
EndSection

Section "Device"
    Identifier "DummyDevice"
    Driver "dummy"
    VideoRam 256000
EndSection

Section "Screen"
    Identifier "DummyScreen"
    Device "DummyDevice"
    Monitor "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080"
    EndSubSection
EndSection
EOF

    log_success "X Server configured"
}

start_x_server() {
    log_task "Starting X Server"
    
    export DISPLAY="$DISPLAY_NUM"
    
    sudo Xorg "$DISPLAY_NUM" \
        -config /etc/X11/xorg.conf.d/10-dummy.conf \
        -configdir /etc/X11/xorg.conf.d \
        vt7 >/dev/null 2>&1 &
    
    sleep 4
    
    if ! xdpyinfo -display "$DISPLAY_NUM" &>/dev/null; then
        log_error "Failed to start X Server. Check Xorg logs."
    fi
    
    log_success "X Server running on display $DISPLAY_NUM"
}

start_lxde() {
    log_task "Starting LXDE Desktop"
    
    DISPLAY="$DISPLAY_NUM" lxsession >/dev/null 2>&1 &
    sleep 3
    
    if ! pgrep -x lxsession >/dev/null; then
        log_error "Failed to start LXDE"
    fi
    
    log_success "LXDE started"
}

start_sunshine() {
    log_task "Starting Sunshine Server"
    
    # Kill any existing screen session first
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    sleep 1
    
    # Check if sunshine binary exists and is executable
    if ! command -v sunshine &>/dev/null; then
        log_error "Sunshine binary not found in PATH"
    fi
    
    # Start sunshine in screen with FIXED command (using single quotes)
    screen -dmS "$SCREEN_SESSION_SUNSHINE" bash -c 'DISPLAY=:0 sunshine'
    sleep 5
    
    # Check if screen session exists
    if ! screen -ls 2>/dev/null | grep -q "$SCREEN_SESSION_SUNSHINE"; then
        echo -e "${YELLOW}Debug Info:${RESET}"
        echo "Screen sessions:"
        screen -ls 2>/dev/null || echo "No screen sessions found"
        echo ""
        echo "Sunshine process:"
        pgrep -a sunshine || echo "No sunshine process found"
        log_error "Failed to start Sunshine in screen session"
    fi
    
    # Verify sunshine is actually running
    sleep 2
    if ! pgrep -x sunshine >/dev/null; then
        echo -e "${YELLOW}Trying alternative method...${RESET}"
        # Try direct background execution
        DISPLAY=:0 sunshine >/tmp/sunshine.log 2>&1 &
        sleep 3
        if ! pgrep -x sunshine >/dev/null; then
            echo "Sunshine error log:"
            cat /tmp/sunshine.log 2>/dev/null || echo "No log available"
            log_error "Failed to start Sunshine process"
        fi
    fi
    
    log_success "Sunshine running (PID: $(pgrep sunshine))"
}

start_cloudflared_tunnel() {
    log_task "Starting Cloudflare Tunnel"
    
    rm -f "$CLOUDFLARED_LOG"
    
    screen -dmS "$SCREEN_SESSION_CLOUDFLARED" bash -c \
        "cloudflared tunnel --no-tls-verify --url https://localhost:47990 > $CLOUDFLARED_LOG 2>&1"
    
    echo -e "${YELLOW}  Waiting for tunnel...${RESET}"
    
    local max_wait=15
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "$CLOUDFLARED_LOG" ]] && grep -q "trycloudflare.com" "$CLOUDFLARED_LOG"; then
            break
        fi
        sleep 1
        ((waited++))
    done
    
    if [[ ! -f "$CLOUDFLARED_LOG" ]]; then
        log_error "Cloudflared log file not created. Check screen session."
    fi
    
    local tunnel_url=$(grep -oP 'https://[^\s]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n 1)
    
    if [[ -z "$tunnel_url" ]]; then
        log_error "Failed to get tunnel URL. Check: $CLOUDFLARED_LOG"
    fi
    
    log_success "Tunnel established"
    
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║${RESET}                   ${BOLD}🌐 PUBLIC ACCESS URL${RESET}                       ${GREEN}${BOLD}║${RESET}"
    echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${GREEN}${BOLD}║${RESET}  ${YELLOW}${tunnel_url}${RESET}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

show_final_summary() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║                    ✓ SETUP COMPLETED ✓                        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Quick Commands:${RESET}"
    echo -e "  ${YELLOW}screen -r sunshine${RESET}      → View Sunshine logs"
    echo -e "  ${YELLOW}screen -r cloudflared${RESET}   → View Cloudflared logs"
    echo -e "  ${YELLOW}Ctrl+A then D${RESET}           → Exit screen"
    echo ""
    echo -e "${CYAN}${BOLD}Next Steps:${RESET}"
    echo -e "  ${GREEN}1.${RESET} Open tunnel URL in browser"
    echo -e "  ${GREEN}2.${RESET} Complete Sunshine setup (create username/password)"
    echo -e "  ${GREEN}3.${RESET} Connect via Moonlight client"
    echo ""
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    show_banner
    check_root
    
    sudo mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    echo -e "${BOLD}${BLUE}Starting installation...${RESET}\n"
    
    install_dependencies
    kill_existing_processes
    install_sunshine
    configure_firewall
    install_cloudflared
    configure_xorg
    start_x_server
    start_lxde
    start_sunshine
    start_cloudflared_tunnel
    
    show_final_summary
    
    echo -e "${GREEN}${BOLD}Installation completed successfully!${RESET}\n"
}

# Error trap
trap 'echo -e "\n${RED}${BOLD}✗ Script failed at line $LINENO${RESET}\n"; exit 1' ERR

main "$@"|_|   |_| \___/  \____| \____)|_| |_| \____||_| |_| \___)\____)|_|    (_____)

                      :: Powered by Noderhunterz ::
EOF
    echo -e "${RESET}\n"
}

#==============================================================================
# Installation Functions
#==============================================================================

install_dependencies() {
    log_task "Installing System Dependencies"
    
    if !  sudo apt update -qq 2>/dev/null; then
        log_error "Failed to update package list.  Check your internet connection."
    fi
    
    if ! sudo apt install -y \
        xserver-xorg-video-dummy \
        lxde-core \
        lxde-common \
        lxsession \
        screen \
        curl \
        unzip \
        wget \
        ufw \
        net-tools \
        x11-utils \
        >/dev/null 2>&1; then
        log_error "Failed to install dependencies"
    fi
    
    log_success "Dependencies installed"
}

kill_existing_processes() {
    log_task "Cleaning Existing Processes"
    
    # Kill all related processes
    pkill -9 sunshine 2>/dev/null || true
    pkill -9 cloudflared 2>/dev/null || true
    pkill -9 lxsession 2>/dev/null || true
    pkill -9 lxpanel 2>/dev/null || true
    pkill -9 openbox 2>/dev/null || true
    pkill -9 -f "Xorg :0" 2>/dev/null || true
    pkill -9 -f "Xorg.*vt7" 2>/dev/null || true
    
    # Kill screen sessions
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    screen -S "$SCREEN_SESSION_CLOUDFLARED" -X quit 2>/dev/null || true
    
    sleep 2
    log_success "Cleanup completed"
}

install_sunshine() {
    if command -v sunshine &>/dev/null; then
        log_task "Sunshine"
        log_success "Already installed (v${SUNSHINE_VERSION})"
        return 0
    fi
    
    log_task "Installing Sunshine v${SUNSHINE_VERSION}"
    
    local deb_file="/tmp/sunshine_${SUNSHINE_VERSION}. deb"
    local download_url="https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_VERSION}/sunshine-ubuntu-22.04-amd64. deb"
    
    if !  wget -q --show-progress -O "$deb_file" "$download_url" 2>&1; then
        log_error "Failed to download Sunshine.  Check internet connection."
    fi
    
    if ! sudo apt install -y "$deb_file" >/dev/null 2>&1; then
        rm -f "$deb_file"
        log_error "Failed to install Sunshine package"
    fi
    
    rm -f "$deb_file"
    log_success "Sunshine installed successfully"
}

configure_firewall() {
    log_task "Configuring Firewall"
    
    local ports=("22/tcp" "47984/tcp" "47989/tcp" "48010/tcp" "47990/tcp" "47998:48002/udp")
    
    for port in "${ports[@]}"; do
        if ! sudo ufw allow "$port" >/dev/null 2>&1; then
            log_error "Failed to configure firewall for port $port"
        fi
    done
    
    if ! sudo ufw --force enable >/dev/null 2>&1; then
        log_error "Failed to enable firewall"
    fi
    
    log_success "Firewall configured"
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        log_task "Cloudflared"
        log_success "Already installed"
        return 0
    fi
    
    log_task "Installing Cloudflared"
    
    local deb_file="/tmp/cloudflared-linux-amd64. deb"
    
    if ! wget -q --show-progress https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O "$deb_file" 2>&1; then
        log_error "Failed to download Cloudflared"
    fi
    
    if ! sudo apt install -y "$deb_file" >/dev/null 2>&1; then
        rm -f "$deb_file"
        log_error "Failed to install Cloudflared"
    fi
    
    rm -f "$deb_file"
    log_success "Cloudflared installed"
}

configure_xorg() {
    log_task "Configuring X Server"
    
    if ! sudo mkdir -p /etc/X11/xorg. conf.d; then
        log_error "Failed to create X11 config directory"
    fi
    
    # Input device configuration
    sudo tee /etc/X11/xorg.conf.d/10-evdev. conf > /dev/null <<'EOF'
Section "InputDevice"
    Identifier "Dummy Mouse"
    Driver "evdev"
    Option "Device" "/dev/uinput"
    Option "Emulate3Buttons" "true"
    Option "EmulateWheel" "true"
    Option "ZAxisMapping" "4 5"
EndSection

Section "InputDevice"
    Identifier "Dummy Keyboard"
    Driver "evdev"
    Option "Device" "/dev/uinput"
EndSection
EOF

    # Display configuration
    sudo tee /etc/X11/xorg.conf.d/10-dummy.conf > /dev/null <<'EOF'
Section "Monitor"
    Identifier "DummyMonitor"
    HorizSync 28. 0-80.0
    VertRefresh 48.0-75.0
    Option "DPMS"
    Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
EndSection

Section "Device"
    Identifier "DummyDevice"
    Driver "dummy"
    VideoRam 256000
EndSection

Section "Screen"
    Identifier "DummyScreen"
    Device "DummyDevice"
    Monitor "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080"
    EndSubSection
EndSection
EOF

    log_success "X Server configured"
}

start_x_server() {
    log_task "Starting X Server"
    
    export DISPLAY="$DISPLAY_NUM"
    
    sudo Xorg "$DISPLAY_NUM" \
        -config /etc/X11/xorg. conf.d/10-dummy. conf \
        -configdir /etc/X11/xorg.conf.d \
        vt7 >/dev/null 2>&1 &
    
    sleep 4
    
    if ! xdpyinfo -display "$DISPLAY_NUM" &>/dev/null; then
        log_error "Failed to start X Server.  Check Xorg logs."
    fi
    
    log_success "X Server running on display $DISPLAY_NUM"
}

start_lxde() {
    log_task "Starting LXDE Desktop"
    
    DISPLAY="$DISPLAY_NUM" lxsession >/dev/null 2>&1 &
    sleep 3
    
    if ! pgrep -x lxsession >/dev/null; then
        log_error "Failed to start LXDE"
    fi
    
    log_success "LXDE started"
}

start_sunshine() {
    log_task "Starting Sunshine Server"
    
    # Kill any existing screen session first
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    sleep 1
    
    # Check if sunshine binary exists
    if !  command -v sunshine &>/dev/null; then
        log_error "Sunshine binary not found in PATH"
    fi
    
    # Get the full path to sunshine binary
    local sunshine_path=$(which sunshine)
    
    # Start sunshine in screen with proper environment
    rm -f "$SUNSHINE_LOG"
    screen -dmS "$SCREEN_SESSION_SUNSHINE" bash -c "export DISPLAY=$DISPLAY_NUM; $sunshine_path > $SUNSHINE_LOG 2>&1"
    
    sleep 5
    
    # Verify screen session exists
    if ! screen -ls 2>/dev/null | grep -q "$SCREEN_SESSION_SUNSHINE"; then
        echo -e "${YELLOW}Debug Info:${RESET}"
        echo "Screen sessions:"
        screen -ls 2>/dev/null || echo "No screen sessions found"
        echo ""
        if [[ -f "$SUNSHINE_LOG" ]]; then
            echo "Sunshine log:"
            cat "$SUNSHINE_LOG"
        fi
        log_error "Failed to start Sunshine in screen session"
    fi
    
    # Double-check that the process is actually running
    sleep 2
    if ! pgrep -x sunshine >/dev/null; then
        log_error "Sunshine process not found after startup"
    fi
    
    log_success "Sunshine running (PID: $(pgrep sunshine))"
}

start_cloudflared_tunnel() {
    log_task "Starting Cloudflare Tunnel"
    
    rm -f "$CLOUDFLARED_LOG"
    
    screen -dmS "$SCREEN_SESSION_CLOUDFLARED" bash -c \
        "cloudflared tunnel --no-tls-verify --url https://localhost:47990 > $CLOUDFLARED_LOG 2>&1"
    
    echo -e "${YELLOW}  Waiting for tunnel... ${RESET}"
    
    local max_wait=15
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "$CLOUDFLARED_LOG" ]] && grep -q "trycloudflare. com" "$CLOUDFLARED_LOG"; then
            break
        fi
        sleep 1
        ((waited++))
    done
    
    if [[ !  -f "$CLOUDFLARED_LOG" ]]; then
        log_error "Cloudflared log file not created.  Check screen session."
    fi
    
    local tunnel_url=$(grep -oP 'https://[^\s]+\. trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n 1)
    
    if [[ -z "$tunnel_url" ]]; then
        log_error "Failed to get tunnel URL.  Check: $CLOUDFLARED_LOG"
    fi
    
    log_success "Tunnel established"
    
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║${RESET}                   ${BOLD}🌐 PUBLIC ACCESS URL${RESET}                       ${GREEN}${BOLD}║${RESET}"
    echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${GREEN}${BOLD}║${RESET}  ${YELLOW}${tunnel_url}${RESET}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

show_final_summary() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║                    ✓ SETUP COMPLETED ✓                        ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Quick Commands:${RESET}"
    echo -e "  ${YELLOW}screen -r sunshine${RESET}      → View Sunshine logs"
    echo -e "  ${YELLOW}screen -r cloudflared${RESET}   → View Cloudflared logs"
    echo -e "  ${YELLOW}Ctrl+A then D${RESET}           → Exit screen"
    echo ""
    echo -e "${CYAN}${BOLD}Next Steps:${RESET}"
    echo -e "  ${GREEN}1. ${RESET} Open tunnel URL in browser"
    echo -e "  ${GREEN}2.${RESET} Complete Sunshine setup (create username/password)"
    echo -e "  ${GREEN}3.${RESET} Connect via Moonlight client"
    echo ""
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    show_banner
    check_root
    
    sudo mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    echo -e "${BOLD}${BLUE}Starting installation... ${RESET}\n"
    
    install_dependencies
    kill_existing_processes
    install_sunshine
    configure_firewall
    install_cloudflared
    configure_xorg
    start_x_server
    start_lxde
    start_sunshine
    start_cloudflared_tunnel
    
    show_final_summary
    
    echo -e "${GREEN}${BOLD}Installation completed successfully!${RESET}\n"
}

# Error trap
trap 'echo -e "\n${RED}${BOLD}✗ Script failed at line $LINENO${RESET}\n"; exit 1' ERR

main "$@"
