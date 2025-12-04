#!/bin/bash
#==============================================================================
# Sunshine Remote Desktop Setup Script
# Description: Automated installation and configuration of Sunshine streaming
#              server with Cloudflare tunnel on Ubuntu 22.04
# Author: Noderhunterz
# Version: 2.0
#==============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

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

log_info() {
    echo -e "${GREEN}[INFO]${RESET} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

log_step() {
    echo -e "${CYAN}${BOLD}[STEP]${RESET} $1"
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should NOT be run as root. Run as normal user with sudo privileges."
        exit 1
    fi
}

create_log_dir() {
    sudo mkdir -p "$LOG_DIR"
    log_info "Log directory created at $LOG_DIR"
}

show_banner() {
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
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${RESET}"
}

#==============================================================================
# Installation Functions
#==============================================================================

install_dependencies() {
    log_step "Installing system dependencies..."
    sudo apt update -qq
    sudo apt install -y \
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
        > /dev/null 2>&1
    log_info "Dependencies installed successfully"
}

kill_existing_processes() {
    log_step "Cleaning up existing processes..."
    
    local processes=("sunshine" "cloudflared" "lxsession" "lxpanel" "openbox")
    
    for proc in "${processes[@]}"; do
        if pgrep -x "$proc" > /dev/null; then
            log_warn "Killing $proc processes..."
            pkill -9 "$proc" || true
        fi
    done
    
    # Kill Xorg specifically
    if pgrep Xorg > /dev/null; then
        log_warn "Killing Xorg processes..."
        pkill -9 -f "Xorg :0" || true
        pkill -9 -f "Xorg.*vt7" || true
    fi
    
    # Kill screen sessions
    for session in "$SCREEN_SESSION_SUNSHINE" "$SCREEN_SESSION_CLOUDFLARED"; do
        if screen -ls | grep -q "$session"; then
            log_warn "Terminating screen session: $session"
            screen -S "$session" -X quit 2>/dev/null || true
        fi
    done
    
    sleep 2
    log_info "Cleanup completed"
}

install_sunshine() {
    log_step "Installing Sunshine streaming server..."
    
    if command -v sunshine &>/dev/null; then
        log_info "Sunshine already installed. Skipping..."
        return 0
    fi
    
    local deb_file="/tmp/sunshine_${SUNSHINE_VERSION}.deb"
    local download_url="https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_VERSION}/sunshine-ubuntu-22.04-amd64.deb"
    
    wget -q --show-progress -O "$deb_file" "$download_url"
    sudo apt install -y "$deb_file" > /dev/null 2>&1
    rm -f "$deb_file"
    
    log_info "Sunshine v${SUNSHINE_VERSION} installed successfully"
}

configure_firewall() {
    log_step "Configuring UFW firewall..."
    
    local ports=(
        "22/tcp"      # SSH
        "47984/tcp"   # Sunshine HTTPS Web UI
        "47989/tcp"   # Sunshine HTTP Web UI
        "48010/tcp"   # Sunshine RTSP
        "47990/tcp"   # Sunshine Control
        "47998:48002/udp"  # Sunshine Video/Audio
    )
    
    for port in "${ports[@]}"; do
        sudo ufw allow "$port" > /dev/null 2>&1
    done
    
    sudo ufw --force enable > /dev/null 2>&1
    log_info "Firewall configured and enabled"
}

install_cloudflared() {
    log_step "Installing Cloudflared tunnel..."
    
    if command -v cloudflared &>/dev/null; then
        log_info "Cloudflared already installed. Skipping..."
        return 0
    fi
    
    local deb_file="/tmp/cloudflared-linux-amd64.deb"
    
    wget -q --show-progress \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
        -O "$deb_file"
    sudo apt install -y "$deb_file" > /dev/null 2>&1
    rm -f "$deb_file"
    
    log_info "Cloudflared installed successfully"
}

configure_xorg() {
    log_step "Configuring dummy Xorg display..."
    
    sudo mkdir -p /etc/X11/xorg.conf.d
    
    # Input devices configuration
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

    # Dummy display configuration
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

    log_info "Xorg configuration completed"
}

start_x_server() {
    log_step "Starting X Server..."
    
    export DISPLAY="$DISPLAY_NUM"
    
    sudo Xorg "$DISPLAY_NUM" \
        -config /etc/X11/xorg.conf.d/10-dummy.conf \
        -configdir /etc/X11/xorg.conf.d \
        vt7 > /dev/null 2>&1 &
    
    sleep 3
    
    if xdpyinfo -display "$DISPLAY_NUM" &>/dev/null; then
        log_info "X Server started successfully on display $DISPLAY_NUM"
    else
        log_error "Failed to start X Server"
        exit 1
    fi
}

start_lxde() {
    log_step "Starting LXDE desktop environment..."
    
    DISPLAY="$DISPLAY_NUM" lxsession > /dev/null 2>&1 &
    sleep 3
    
    log_info "LXDE started successfully"
}

start_sunshine() {
    log_step "Starting Sunshine in screen session..."
    
    screen -dmS "$SCREEN_SESSION_SUNSHINE" bash -c "DISPLAY=$DISPLAY_NUM sunshine"
    sleep 2
    
    if screen -ls | grep -q "$SCREEN_SESSION_SUNSHINE"; then
        log_info "Sunshine started in screen session: $SCREEN_SESSION_SUNSHINE"
    else
        log_error "Failed to start Sunshine"
        exit 1
    fi
}

start_cloudflared_tunnel() {
    log_step "Starting Cloudflare tunnel..."
    
    rm -f "$CLOUDFLARED_LOG"
    
    screen -dmS "$SCREEN_SESSION_CLOUDFLARED" bash -c \
        "cloudflared tunnel --no-tls-verify --url https://localhost:47990 > $CLOUDFLARED_LOG 2>&1"
    
    sleep 5
    
    if [[ -f "$CLOUDFLARED_LOG" ]]; then
        local tunnel_url=$(grep -oP 'https://[^\s]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n 1)
        
        if [[ -n "$tunnel_url" ]]; then
            log_info "Cloudflare tunnel started successfully"
            echo ""
            echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════${RESET}"
            echo -e "${CYAN}${BOLD}  Public Tunnel URL:${RESET} ${YELLOW}${tunnel_url}${RESET}"
            echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════${RESET}"
            echo ""
        else
            log_warn "Cloudflare tunnel started but URL not found yet. Check: $CLOUDFLARED_LOG"
        fi
    else
        log_error "Failed to start Cloudflare tunnel"
    fi
}

show_status() {
    echo ""
    log_step "Service Status Check"
    echo ""
    
    echo -e "${BOLD}Screen Sessions:${RESET}"
    screen -ls || echo "  No active screen sessions"
    
    echo ""
    echo -e "${BOLD}Process Status:${RESET}"
    pgrep -a sunshine || echo "  Sunshine: Not running"
    pgrep -a cloudflared || echo "  Cloudflared: Not running"
    pgrep -a Xorg || echo "  Xorg: Not running"
    
    echo ""
    echo -e "${CYAN}${BOLD}Access Instructions:${RESET}"
    echo "  1. Open the tunnel URL in your browser"
    echo "  2. Complete Sunshine initial setup"
    echo "  3. Use Moonlight client to connect"
    echo ""
    echo -e "${CYAN}Useful Commands:${RESET}"
    echo "  - View Sunshine logs: ${YELLOW}screen -r $SCREEN_SESSION_SUNSHINE${RESET}"
    echo "  - View Cloudflared logs: ${YELLOW}screen -r $SCREEN_SESSION_CLOUDFLARED${RESET}"
    echo "  - Exit screen: ${YELLOW}Ctrl+A then D${RESET}"
    echo ""
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    show_banner
    check_root
    create_log_dir
    
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
    show_status
    
    log_info "Setup completed successfully!"
}

# Run main function
main "$@"
