#!/bin/bash

# Configuration: Change this to your Kali Tailscale IP and User
KALI_USER="<KALI_USERNAME>"
KALI_IP="<KALI_TAILSCALE_IP>"
LOCAL_PORT="33389"
REMOTE_PORT="3389"

# 1. Create temporary .rdp profile for Microsoft Remote Desktop / Windows App
cat << RDP > /tmp/kali_session.rdp
full address:s:127.0.0.1:${LOCAL_PORT}
username:s:${KALI_USER}
prompt for credentials:i:0
administrative session:i:0
RDP

# 2. Check if the SSH tunnel is already listening; start it if not
if ! lsof -i :${LOCAL_PORT} > /dev/null 2>&1; then
    echo "Starting background SSH tunnel to ${KALI_IP}..."
    ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${KALI_USER}@${KALI_IP}
    sleep 1
fi

# 3. Launch the RDP Client directly into the session
open /tmp/kali_session.rdp

# 4. Gracefully close the terminal window
osascript -e 'tell application "Terminal" to close front window' > /dev/null 2>&1 &
