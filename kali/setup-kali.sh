#!/bin/bash
set -e

echo "=== [1/6] Installing dependencies ==="
sudo apt update
sudo apt install -y xrdp xfce4 xfce4-goodies autocutsel

echo "=== [2/6] Preventing ACPI Sleep & Lid Close Suspend ==="
sudo sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo systemctl restart systemd-logind

echo "=== [3/6] Disabling Wi-Fi Power Saving ==="
echo -e "[connection]\nwifi.powersave = 2" | sudo tee /etc/NetworkManager/conf.d/disable-wifi-powersave.conf
sudo systemctl restart NetworkManager

echo "=== [4/6] Disabling Conflicting GNOME Remote Desktop ==="
systemctl --user stop gnome-remote-desktop 2>/dev/null || true
systemctl --user disable gnome-remote-desktop 2>/dev/null || true

echo "=== [5/6] Configuring Polkit for XRDP ==="
sudo adduser xrdp ssl-cert || true
sudo mkdir -p /etc/polkit-1/rules.d
sudo bash -c 'cat > /etc/polkit-1/rules.d/02-allow-colord.rules <<RULE
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
        return polkit.Result.YES;
    }
});
RULE'
sudo systemctl restart polkit

echo "=== [6/6] Configuring XRDP Session Environment ==="
# Add environment cleans to /etc/xrdp/startwm.sh
if ! grep -q "unset DBUS_SESSION_BUS_ADDRESS" /etc/xrdp/startwm.sh; then
    sudo sed -i '2i unset DBUS_SESSION_BUS_ADDRESS\nunset XDG_RUNTIME_DIR' /etc/xrdp/startwm.sh
fi

# Configure User Xsession
echo "autocutsel -fork" > ~/.xsession
echo "xfce4-session" >> ~/.xsession
chmod +x ~/.xsession

sudo systemctl enable --now tailscaled
sudo systemctl enable --now xrdp
sudo systemctl restart xrdp

echo "=== Setup Complete! Kali is ready for remote access. ==="
