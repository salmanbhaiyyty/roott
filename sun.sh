start_sunshine() {
    log_task "Starting Sunshine Server"
    
    # Kill any existing screen session first
    screen -S "$SCREEN_SESSION_SUNSHINE" -X quit 2>/dev/null || true
    sleep 1
    
    # Check if sunshine binary exists and is executable
    if ! command -v sunshine &>/dev/null; then
        log_error "Sunshine binary not found in PATH"
    fi
    
    # Start sunshine in screen - use single quotes to prevent premature expansion
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
