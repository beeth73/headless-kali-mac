# Reference Links & Deep-Dive Architecture

This document covers the official resources, internal design of XRDP, and the low-level networking mechanics that enable session persistence across varying physical network gateways.

---

## 1. Official Resources & Software Links

| Tool | Purpose | Official Resource |
| :--- | :--- | :--- |
| **Tailscale** | Mesh VPN & NAT Traversal Engine | [Official Site](https://tailscale.com) • [Download Page](https://tailscale.com/download) |
| **Windows App** | Official Microsoft RDP Client for macOS | [Mac App Store Link](https://apps.apple.com/app/windows-app/id1295203466) • [Documentation](https://learn.microsoft.com/en-us/windows-app/) |
| **XRDP** | Open-Source X11 Remote Desktop Protocol Server | [GitHub Repository](https://github.com/neutrinolabs/xrdp) • [Official Documentation](https://www.xrdp.org) |
| **XFCE** | Lightweight Desktop Environment for UNIX-like OS | [Official Site](https://www.xfce.org) • [GitLab](https://gitlab.xfce.org/xfce) |
| **WireGuard** | Modern, Fast, and Secure Kernel VPN Protocol | [WireGuard Technical Whitepaper](https://www.wireguard.com/papers/wireguard.pdf) |

---

## 2. XRDP Architecture: How It Actually Works

XRDP is not just a simple screen-sharing server (like VNC). It is an open-source implementation of Microsoft's **Remote Desktop Protocol (RDP)** built on top of the Linux **X11 Display Server**.

XRDP is divided into three distinct, cooperating processes:

```text
[ macOS RDP Client ]
         │ (RDP Wire Protocol over TCP)
         ▼
+──────────────────────────────────────────────+
| 1. xrdp (Listener Daemon)                    |
|    - Handles TLS / SSL handshakes            |
|    - Negotiates RDP capabilities (T.125 MCS) |
|    - Compresses/encodes bitmap rectangles    |
+──────────────────────────────────────────────+
         │ (UNIX Domain Socket: /tmp/.xrdp/xrdp_display_*)
         ▼
+──────────────────────────────────────────────+
| 2. xrdp-sesman (Session Manager)             |
|    - Handles PAM authentication (user/pass)  |
|    - Manages lifecycle of user sessions      |
|    - Allocates virtual display numbers (:10) |
+──────────────────────────────────────────────+
         │ (Forks child process)
         ▼
+──────────────────────────────────────────────+
| 3. xorgxrdp (Virtual Display Driver)         |
|    - A headless Xorg driver running in RAM   |
|    - Acts as a virtual GPU / video card      |
|    - Captures draw events into shared memory |
+──────────────────────────────────────────────+
         │ (X11 Protocol)
         ▼
[ Window Manager: xfce4-session ]
```

### The Three Components:
1. **`xrdp` (Front-end Proxy):**
   * Listens on TCP port `3389`.
   * Accepts the incoming connection, negotiates RDP encryption, and translates client mouse clicks and keystrokes into X11 input events.
2. **`xrdp-sesman` (Session Manager):**
   * When you log in, `xrdp` talks to `sesman` via a local UNIX socket.
   * `sesman` verifies your Linux credentials via **PAM (Pluggable Authentication Modules)**.
   * If credentials are valid, it allocates an unused display number (typically `:10`) and spawns the virtual X server.
3. **`xorgxrdp` (The Virtual Video Driver):**
   * Unlike a physical display that outputs to an HDMI/DisplayPort port, `xorgxrdp` is a video driver module loaded inside an Xorg instance.
   * It creates a virtual frame buffer in system RAM. When an app (like Firefox or Terminal) draws a window, `xorgxrdp` calculates which rectangular regions changed (*dirty rectangles*), compresses them, and passes them to `xrdp` to stream to your Mac.

---

## 3. Network Mobility: How SSH & RDP Survive Wi-Fi / Gateway Changes

A classic problem in computer networking:
> *If you are connected via SSH and your laptop changes Wi-Fi networks (e.g., switching from home Wi-Fi to a phone hotspot), your IP address changes. Standard TCP connections break immediately. Why does our connection stay alive?*

### The Fundamental TCP Invalidation Problem
A standard TCP socket is uniquely identified across the internet by a **4-tuple**:
$$\text{Socket} = (\text{Source IP}, \text{Source Port}, \text{Destination IP}, \text{Destination Port})$$

If your Mac disconnects from your home Wi-Fi (`192.168.1.45`) and joins a college Wi-Fi or phone hotspot (`172.20.10.2`), your public NAT IP changes. The 4-tuple breaks, the server sends a `TCP RST` (reset), and the connection dies with:
`client_loop: send disconnect: Broken pipe`

---

### How WireGuard & Tailscale Solve This: Cryptokey Routing & Endpoint Roaming

Tailscale runs **WireGuard** under the hood. WireGuard is deliberately **connectionless** at Layer 4 (it uses UDP, not TCP).

```text
+────────────────────────────────────────────────────────────────────────────+
|                           UNDERLYING PHYSICAL LAYER                        |
|  Mac Physical IP: 172.20.10.2:51820  ──(Roaming UDP)──>  Home Router (NAT) |
+────────────────────────────────────────────────────────────────────────────+
                                      │
                                      ▼
+────────────────────────────────────────────────────────────────────────────+
|                      OVERLAY LAYER (VIRTUAL INTERFACES)                    |
|  Mac Overlay IP: 100.x.x.x  <════ Persistent TCP ════>  Kali: 100.108.124.116 |
|                                                                            |
|  - The SSH Socket 4-tuple NEVER CHANGES:                                   |
|    (100.x.x.x, 52144, 100.108.124.116, 22)                                |
+────────────────────────────────────────────────────────────────────────────+
```

#### Step-by-Step Breakdown of an IP Roam:

1. **Overlay IP Stability:**
   * Your Mac’s virtual interface (`utun`) is assigned an unchanging Tailscale IP (e.g., `100.x.x.x`).
   * Kali’s virtual interface (`tailscale0`) is assigned `100.108.124.116`.
   * **Your SSH tunnel and RDP session bind strictly to these 100.x overlay IPs.** As far as macOS and Linux TCP stacks are concerned, the IP addresses never changed.

2. **WireGuard Endpoint Roaming:**
   * Every WireGuard packet is wrapped in an outer UDP packet containing an authenticated cryptographic header (Noise Protocol).
   * In Kali’s kernel WireGuard table, each peer's public key is mapped to an **endpoint** (the physical IP and port where packets were last received):
     ```text
     Peer: [Mac's Public Key]
     Endpoint: 203.0.113.50:41234 (Old Public IP from Home Wi-Fi)
     ```
3. **The Gateway Switch:**
   * You switch your Mac to a phone hotspot. Your Mac gets a completely new public IP: `198.51.100.80:58210`.
   * The Mac transmits its next encrypted WireGuard packet from this new physical IP.
   * Kali receives the packet. Before reading the payload, it verifies the **Poly1305 Message Authentication Code (MAC)** using your Mac's public key.
   * Because the cryptographic signature is valid, Kali knows this packet genuinely came from your Mac.
   * Kali **instantly updates its internal routing table**:
     ```text
     Peer: [Mac's Public Key]
     Endpoint: 198.51.100.80:58210 (New Public IP from Hotspot!)
     ```
   * Kali immediately directs all future return packets to the new physical address.

4. **Result at the User Level:**
   * The inner TCP connection (your SSH tunnel and Remote Desktop session) experiences a split-second pause while the network switches.
   * Because TCP has built-in retry and retransmission timeouts (typically several seconds), **the TCP session does not drop**.
   * Packets resume flowing across the updated UDP path, and your Kali desktop stays active on your screen.

---

## 4. Summary

* **XRDP** bridges Linux to modern desktop standards by running a headless Xorg instance in RAM and streaming compressed frame differentials via Microsoft RDP.
* **WireGuard’s Cryptokey Routing** decouples logical session identities (cryptographic public keys) from physical network locations (IP:Port endpoints).
* **The SSH Tunnel** multiplexes Layer 7 desktop data across Layer 4 stream sockets, allowing transparent traversal across any NAT, gateway, or dynamic IP change.



Run this in your Mac terminal inside `~/headless-kali-mac`:
