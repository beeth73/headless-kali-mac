#!/bin/bash
set -e

KALI_USER="beeth"
KALI_IP="100.108.124.116"

echo "=== [1/3] Generating SSH Key if not present ==="
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

echo "=== [2/3] Installing SSH Key onto Kali (enter Kali password) ==="
ssh-copy-id ${KALI_USER}@${KALI_IP}

echo "=== [3/3] Adding rdp-kali alias to ~/.zshrc ==="
if ! grep -q "alias rdp-kali=" ~/.zshrc 2>/dev/null; then
    echo "alias rdp-kali='ssh -N -L 33389:localhost:3389 ${KALI_USER}@${KALI_IP}'" >> ~/.zshrc
fi

# Place launcher on Mac Desktop
cp mac/connect-kali.command ~/Desktop/Connect-Kali.command
chmod +x ~/Desktop/Connect-Kali.command

echo "=== Mac Setup Complete! Shortcut added to Desktop. ==="
