#!/bin/bash
#==============================================================================
# Sunshine Remote Desktop Setup Script
# Description: Automated installation and configuration of Sunshine streaming
#              server with Cloudflare tunnel on Ubuntu 22.04
# Author: Noderhunterz
# Version: 2.1
#==============================================================================

set -euo pipefail

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

# Spinner animation
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [${CYAN}%c${RESET}]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r${CYAN}["
    printf "%${completed}s" | tr ' ' '█'
    printf "%${remaining}s" | tr ' ' '░'
    printf "]${RESET} ${BOLD}%3d%%${RESET}" $percentage
}

log_task() {
    echo -e "\n${CYAN}▶${RESET} ${BOLD}$1${RESET}"
}

log_success() {
    echo -e "${GREEN}✓${RESET} $1"
}

log_error() {
    echo -e "${RED}✗${RESET} $1"
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run as root. Use normal user with sudo privileges."
        exit 1
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
    
    (
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
            x11-utils \
            > /dev/null 2>&1
    ) &
    
    spinner $!
    log_success "Dependencies installed"
}

kill_existing_processes() {
    log_task "Cleaning Existing Processes"
    
    local processes=("sunshine" "cloudflared" "lxsession" "lxpanel" "openbox")
    
    for proc in "${processes[@]}"; do
        pkill -9 "$proc" 2>/dev/null || true
    done
    
    pkill -9 -f "Xorg :0" 2>/dev/null || true
    pkill -9 -f "Xorg.*vt7" 2>/dev/null || true
    
    for session in "$SCREEN_SESSION_SUNSHINE" "$SCREEN_SESSION_CLOUDFLARED"; do
        screen -S "$session" -X quit 2>/dev/null || true
    done
    
    sleep 1
    log_success "Cleanup completed"
}

install_sunshine() {
    if command -v sunshine &>/dev/null; then
        log_task "Sunshine"
        log_success "Already installed"
        return 0
    fi
    
    log_task "Installing Sunshine v${SUNSHINE_VERSION}"
    
    local deb_file="/tmp/sunshine_${SUNSHINE_VERSION}.deb"
    local download_url="https://github.com/LizardByte/Sunshine/releases/download/v${SUNSHINE_VERSION}/sunshine-ubuntu-22.04-amd64.deb"
    
    (
        wget -q -O "$deb_file" "$download_url"
        sudo apt install -y "$deb_file" > /dev/null 2>&1
        rm -f "$deb_file"
    ) &
    
    spinner $!
    log_success "Sunshine installed"
}

configure_firewall() {
    log_task "Configuring Firewall"
    
    (
        local ports=("22/tcp" "47984/tcp" "47989/tcp" "48010/tcp" "47990/tcp" "47998:48002/udp")
        for port in "${ports[@]}"; do
            sudo ufw allow "$port" > /dev/null 2>&1
        done
        sudo ufw --force enable > /dev/null 2>&1
    ) &
    
    spinner $!
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
    
    (
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O "$deb_file"
        sudo apt install -y "$deb_file" > /dev/null 2>&1
        rm -f "$deb_file"
    ) &
    
    spinner $!
    log_success "Cloudflared installed"
}

configure_xorg() {
    log_task "Configuring X Server"
    
    sudo mkdir -p /etc/X11/xorg.conf.d
    
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
        vt7 > /dev/null 2>&1 &
    
    sleep 3
    
    if xdpyinfo -display "$DISPLAY_NUM" &>/dev/null 2>&1; then
        log_success "X Server running on $DISPLAY_NUM"
    else
        log_error "Failed to start X Server"
        exit 1
    fi
}

start_lxde() {
    log_task "Starting LXDE Desktop"
    
    DISPLAY="$DISPLAY_NUM" lxsession > /dev/null 2>&1 &
    sleep 2
    
    log_success "LXDE started"
}

start_sunshine() {
    log_task "Starting Sunshine Server"
    
    screen -dmS "$SCREEN_SESSION_SUNSHINE" bash -c "DISPLAY=$DISPLAY_NUM sunshine"
    sleep 2
    
    if screen -ls | grep -q "$SCREEN_SESSION_SUNSHINE"; then
        log_success "Sunshine running"
    else
        log_error "Failed to start Sunshine"
        exit 1
    fi
}

start_cloudflared_tunnel() {
    log_task "Starting Cloudflare Tunnel"
    
    rm -f "$CLOUDFLARED_LOG"
    
    screen -dmS "$SCREEN_SESSION_CLOUDFLARED" bash -c \
        "cloudflared tunnel --no-tls-verify --url https://localhost:47990 > $CLOUDFLARED_LOG 2>&1"
    
    # Wait for tunnel URL with animation
    local max_wait=10
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        if [[ -f "$CLOUDFLARED_LOG" ]] && grep -q "trycloudflare.com" "$CLOUDFLARED_LOG"; then
            break
        fi
        sleep 1
        ((waited++))
        printf "\r${CYAN}  Establishing tunnel... %d/%d${RESET}" $waited $max_wait
    done
    printf "\n"
    
    if [[ -f "$CLOUDFLARED_LOG" ]]; then
        local tunnel_url=$(grep -oP 'https://[^\s]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n 1)
        
        if [[ -n "$tunnel_url" ]]; then
            log_success "Tunnel established"
            echo ""
            echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
            echo -e "${GREEN}${BOLD}║${RESET}                    ${BOLD}🌐 PUBLIC ACCESS URL${RESET}                      ${GREEN}${BOLD}║${RESET}"
            echo -e "${GREEN}${BOLD}╠════════════════════════════════════════════════════════════════╣${RESET}"
            echo -e "${GREEN}${BOLD}║${RESET}  ${YELLOW}${tunnel_url}${RESET}"
            echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
            echo ""
        else
            log_error "Tunnel URL not found. Check: $CLOUDFLARED_LOG"
        fi
    else
        log_error "Failed to start tunnel"
    fi
}

show_final_summary() {
    echo ""
    echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║                      SETUP COMPLETED ✓                         ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Quick Access Commands:${RESET}"
    echo -e "  ${YELLOW}screen -r sunshine${RESET}      - View Sunshine logs"
    echo -e "  ${YELLOW}screen -r cloudflared${RESET}   - View Cloudflared logs"
    echo -e "  ${YELLOW}Ctrl+A then D${RESET}           - Exit screen session"
    echo ""
    echo -e "${CYAN}${BOLD}Next Steps:${RESET}"
    echo -e "  ${GREEN}1.${RESET} Open the tunnel URL in your browser"
    echo -e "  ${GREEN}2.${RESET} Complete Sunshine initial setup"
    echo -e "  ${GREEN}3.${RESET} Connect using Moonlight client"
    echo ""
}

show_progress_bar() {
    local total_steps=10
    local step=0
    
    echo ""
    for func in \
        install_dependencies \
        kill_existing_processes \
        install_sunshine \
        configure_firewall \
        install_cloudflared \
        configure_xorg \
        start_x_server \
        start_lxde \
        start_sunshine \
        start_cloudflared_tunnel
    do
        ((step++))
        show_progress $step $total_steps
        sleep 0.2
    done
    echo -e "\n"
}

#==============================================================================
# Main Execution
#==============================================================================

main() {
    show_banner
    check_root
    
    sudo mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    echo -e "${BOLD}${BLUE}Starting installation process...${RESET}\n"
    
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
}

main "$@"
