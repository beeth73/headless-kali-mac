# Architecture & Engineering Guide: Headless Kali Linux via macOS

An architectural blueprint and automated toolset to convert an encrypted physical Kali Linux laptop into a 24/7 headless remote workstation accessible from a Mac anywhere in the world.

---

## 1. System Architecture

```text
+----------------------------------------------------------------------------------------------------+
|                                         PHYSICAL REALITY                                           |
|   [ Mac (Any Remote Network) ] <===== Public Internet =====> [ Kali Lenovo (Home Router / NAT) ]   |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼
+----------------------------------------------------------------------------------------------------+
| LAYER 1: NETWORK OVERLAY (Tailscale & WireGuard)                                                   |
| - Virtual L3 Interface: utun (macOS) <== Encrypted WireGuard UDP ==> tailscale0 (Linux)            |
| - Mesh Subnet: 100.64.0.0/10 (CGNAT RFC 6598)                                                     |
| - NAT Traversal via STUN hole-punching and DERP HTTPS (TCP/443) relay fallback                     |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼
+----------------------------------------------------------------------------------------------------+
| LAYER 2: TRANSPORT MULTIPLEXING (SSH Local Port Forwarding)                                        |
| - Client: 127.0.0.1:33389 (Mac local loopback socket)                                              |
| - Protocol: Encapsulated TCP payload piped through SSH-2.0 channel via port 22                     |
| - Destination: sshd routes to localhost:3389 (lo interface on Kali)                                 |
+----------------------------------------------------------------------------------------------------+
                                                  │
                                                  ▼
+----------------------------------------------------------------------------------------------------+
| LAYER 3: APPLICATION & PRESENTATION (XRDP & XFCE)                                                  |
| - Display Protocol: Remote Desktop Protocol (ITU-T T.125 / MCS / X.224)                            |
| - Session Daemon: xrdp-sesman forks Xorg with xorgxrdp on virtual Display :10                     |
| - Window Manager: xfce4-session rasterized via software 2D framebuffer                             |
+----------------------------------------------------------------------------------------------------+
```

---

## 2. Engineering Deep-Dive: How Every Layer Operates

### A. Network Layer (NAT Traversal via WireGuard)
* **The Problem:** The Kali host resides behind residential NAT (or Carrier-Grade NAT) where incoming unsolicited SYN packets are dropped by the router's stateful firewall. Neither machine has a static or public IPv4 address.
* **The Solution:** Tailscale negotiates a peer-to-peer overlay network using STUN (Session Traversal Utilities for NAT). Both endpoints transmit simultaneous UDP packets to mutually punch holes through stateful NAT translation tables.
* **Fallback (DERP):** If a strict firewall (such as enterprise or college Wi-Fi) blocks direct UDP, Tailscale automatically falls back to **DERP (Designated Encrypted Relay for Packets)**, routing traffic through encrypted HTTPS relays over standard TCP port 443.
* **Encryption:** Packets traversing the overlay network use the Noise Protocol Framework:
  * Key Exchange: **Curve25519**
  * Symmetric Cipher: **ChaCha20**
  * Authentication: **Poly1305**

### B. Transport Multiplexing (SSH Local Forwarding)
* **The Command:** `ssh -N -L 33389:localhost:3389 user@<Kali_Tailscale_IP>`
* **Why it was required:** Tailscale ACL policies or local host firewalls (`nftables`/`iptables`) frequently drop or reject direct incoming packets to port `3389` on external virtual interfaces (`tailscale0`).
* **The Mechanism:** 
  1. The OpenSSH client creates a local listening socket on `127.0.0.1:33389` on macOS.
  2. RDP traffic from the Windows App client is captured by OpenSSH and multiplexed into an encrypted SSH channel over port 22.
  3. On Kali, `sshd` unpacks the payload and creates a local loopback TCP connection to `127.0.0.1:3389`.
  4. To Kali's kernel and XRDP, the traffic originates locally from the loopback interface (`lo`), completely bypassing packet filtering on `tailscale0`.

### C. Display Server (Why GNOME Failed & XFCE Succeeded)
* **Exit Code 134 (`SIGABRT`):** In Linux, exit code 134 signifies an abort signal (`128 + 6 = SIGABRT`). GNOME 40+ relies on **Mutter**, a 3D-compositing window manager that expects direct hardware acceleration (OpenGL/EGL via DRM/KMS). In a headless, virtual software display (`xorgxrdp`), hardware pipelines are absent, causing Mutter to fail runtime assertions.
* **D-Bus & systemd Collisions:** Modern GNOME uses `systemd --user` units to manage sessions. When XRDP initializes, inherited environment variables (`DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`) conflict with existing physical display targets (`:0`).
* **The XFCE Advantage:** XFCE uses **`xfwm4`**, a classic 2D window manager that writes directly to the X11 server framebuffer using software rasterization. It consumes ~70% less memory and bandwidth, operates without 3D compositing, and is immune to systemd user session collisions.

### D. Kernel ACPI & Power Management
* **Lid Close Sleep:** Closing a laptop lid triggers an ACPI interrupt to the kernel, forwarded to `systemd-logind`. By default, `systemd-logind` invokes `suspend.target`, dropping the CPU into an ACPI S3 sleep state and cutting power to the PCIe bus and wireless NIC.
* **The Fix:**
  1. `HandleLidSwitch=ignore` in `/etc/systemd/logind.conf` tells `systemd-logind` to discard the lid switch event.
  2. Masking sleep targets (`systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`) links the systemd unit files to `/dev/null`, preventing any service or ACPI signal from entering sleep states.
  3. Setting `wifi.powersave = 2` inside NetworkManager prevents the Linux kernel from dropping the wireless adapter into a D3 power-save state when display output is disabled.

### E. Data-at-Rest Security (LUKS Pre-Boot Protection)
* Kali uses **LUKS (Linux Unified Key Setup)** full-disk encryption via `dm-crypt`. 
* Decryption takes place within the minimal `initramfs` environment before the root filesystem is mounted and before networking daemons (`tailscaled`, `sshd`, `xrdp`) are loaded into RAM.
* **Security Guarantee:** If the laptop is physically stolen while powered down, the decryption keys are purged from memory, leaving the NVMe storage cryptographically unreadable (AES-XTS-PLAIN64).

---

## 3. Step-by-Step Replication

### Phase 1: Kali Linux Host Setup

1. **Install required packages:**
   ```bash
   sudo apt update && sudo apt install -y xrdp xfce4 xfce4-goodies autocutsel
   ```

2. **Prevent lid close suspend & mask sleep targets:**
   ```bash
   sudo sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
   sudo sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
   sudo sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   sudo systemctl restart systemd-logind
   ```

3. **Disable Wi-Fi power-saving:**
   ```bash
   echo -e "[connection]\nwifi.powersave = 2" | sudo tee /etc/NetworkManager/conf.d/disable-wifi-powersave.conf
   sudo systemctl restart NetworkManager
   ```

4. **Disable conflicting GNOME remote services & configure Polkit:**
   ```bash
   systemctl --user stop gnome-remote-desktop 2>/dev/null || true
   systemctl --user disable gnome-remote-desktop 2>/dev/null || true

   sudo adduser xrdp ssl-cert
   sudo mkdir -p /etc/polkit-1/rules.d
   sudo bash -c 'cat > /etc/polkit-1/rules.d/02-allow-colord.rules <<EOF
   polkit.addRule(function(action, subject) {
       if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
           return polkit.Result.YES;
       }
   });
   EOF'
   sudo systemctl restart polkit
   ```

5. **Configure session files & environment unsets:**
   * Edit `/etc/xrdp/startwm.sh` and add these lines right below `#!/bin/sh`:
     ```bash
     unset DBUS_SESSION_BUS_ADDRESS
     unset XDG_RUNTIME_DIR
     ```
   * Set user desktop environment:
     ```bash
     echo "autocutsel -fork" > ~/.xsession
     echo "xfce4-session" >> ~/.xsession
     chmod +x ~/.xsession
     ```

6. **Start and enable services:**
   ```bash
   sudo systemctl enable --now tailscaled
   sudo tailscale up
   sudo systemctl enable --now xrdp
   sudo systemctl restart xrdp
   ```
   *Note down the Tailscale IP:* `tailscale ip -4`

---

### Phase 2: macOS Client Setup

1. **Install Applications:**
   * **Tailscale** (Mac App Store) — Sign in with the same account.
   * **Windows App** (formerly Microsoft Remote Desktop, Mac App Store).

2. **Configure SSH key-based authentication:**
   ```bash
   # Generate key if you don't have one
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 2>/dev/null || true

   # Copy key to Kali (replace with your Kali user and Tailscale IP)
   ssh-copy-id <KALI_USERNAME>@<KALI_TAILSCALE_IP>
   ```

3. **Configure the Windows App:**
   * Click **+ Add PC**.
   * **PC Name:** `127.0.0.1:33389`
   * **Credentials:** Add user account with your Kali username and password.
   * **Settings (`⌘ + ,`) > General:** Check ✅ *"Use Mac shortcuts for copy, cut, paste and select all, undo, and find"*.
   * **Display Tab:** Check ✅ *"Update the session resolution on resize"*.

---

## 4. Daily Operation & Automation

### The 1-Click Desktop Launcher
Save the following script as `Connect-Kali.command` on your macOS Desktop and run `chmod +x Connect-Kali.command`:

```bash
#!/bin/bash
KALI_USER="<KALI_USERNAME>"
KALI_IP="<KALI_TAILSCALE_IP>"
LOCAL_PORT="33389"
REMOTE_PORT="3389"

# 1. Generate temp RDP profile
cat << RDP > /tmp/kali_session.rdp
full address:s:127.0.0.1:${LOCAL_PORT}
username:s:${KALI_USER}
prompt for credentials:i:0
administrative session:i:0
RDP

# 2. Start SSH tunnel in background if not already active
if ! lsof -i :${LOCAL_PORT} > /dev/null 2>&1; then
    ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${KALI_USER}@${KALI_IP}
    sleep 1
fi

# 3. Launch RDP client
open /tmp/kali_session.rdp

# 4. Close auxiliary terminal window
osascript -e 'tell application "Terminal" to close front window' > /dev/null 2>&1 &
```

### Manual Connection Steps
If not using the launcher:
1. Ensure Tailscale is connected on your Mac.
2. In Terminal, open the tunnel:
   ```bash
   ssh -N -L 33389:localhost:3389 <KALI_USERNAME>@<KALI_TAILSCALE_IP>
   ```
3. Open **Windows App** and double-click `127.0.0.1:33389`.

---

## 5. Troubleshooting & Bug Post-Mortems

| Symptom / Error | Root Cause | Engineering Resolution |
| :--- | :--- | :--- |
| **Error `0x204` on client** | RDP client cannot establish a TCP handshake on port 3389/33389. | Verify Tailscale connection and ensure the local SSH tunnel (`ssh -N -L ...`) is running. |
| **XRDP fails to bind port 3389** | `gnome-remote-desktop` is bound to `0.0.0.0:3389`. | Run `systemctl --user stop gnome-remote-desktop` and restart `xrdp`. |
| **Exit code 134 (`SIGABRT`)** | Mutter window manager crashes without hardware 3D acceleration or collides with D-Bus environment variables. | Add `unset DBUS_SESSION_BUS_ADDRESS` and `unset XDG_RUNTIME_DIR` to `/etc/xrdp/startwm.sh`, and use XFCE (`xfwm4`). |
| **Kali goes to sleep on lid close** | ACPI lid event triggers `suspend.target`. | Set `HandleLidSwitch=ignore` in `logind.conf` and run `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`. |
| **Wi-Fi disconnects on lid close** | NetworkManager power-saving triggers PCIe low-power state. | Add `wifi.powersave = 2` to `/etc/NetworkManager/conf.d/disable-wifi-powersave.conf`. |
| **Tiny UI / Retina scaling issues** | High resolution on Mac screen without DPI scaling. | Run `xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -s 2` inside Kali to enforce 2x integer scaling. |