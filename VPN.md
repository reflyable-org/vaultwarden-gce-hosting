# Connecting a phone to the VPN

How to get a phone onto the WireGuard VPN running on the Vaultwarden VM, so its
traffic exits from the VM's US IP address.

Endpoint: **`34.83.148.68:51820`** · Tunnel subnet: `10.8.0.0/24`

---

## Connect the phone

### 1. Install the app

**WireGuard**, by *WireGuard Development Team* — free, no account required.

- iOS: [App Store](https://apps.apple.com/app/wireguard/id1441195209)
- Android: [Play Store](https://play.google.com/store/apps/details?id=com.wireguard.android)

### 2. Get the QR code

The phone peer already exists. Generate its QR code and copy it to your Desktop:

```bash
gcloud compute ssh vaultwarden --project alex-pass --zone us-west1-a \
  --tunnel-through-iap --command 'sudo /bin/bash /etc/vaultwarden/wg-peer.sh qr phone'

gcloud compute scp vaultwarden:/tmp/phone-qr.png ~/Desktop/phone-qr.png \
  --project alex-pass --zone us-west1-a --tunnel-through-iap
```

Open `~/Desktop/phone-qr.png` on your screen. The QR **must** be displayed as an
image — the ANSI version printed in a terminal usually will not scan.

For a brand new device, use `add <name>` instead (see
[Adding another device](#adding-another-device)); it prints the config and writes
the PNG in one step.

### 3. Scan it

In the WireGuard app:

1. Tap **+** (top right)
2. **Create from QR code**
3. Point the camera at the PNG on your screen
4. Name it (e.g. `US VPN`) and tap **Save**
5. Approve the VPN configuration prompt when iOS/Android asks

### 4. Turn it on

Toggle the tunnel on. A **VPN** indicator appears in the status bar.

### 5. Verify it works

Open a browser on the phone and visit **https://ifconfig.me**.

It should show **`34.83.148.68`**. If it shows your Australian carrier or home
IP, the tunnel is not carrying traffic — see [Troubleshooting](#troubleshooting).

Worth confirming while connected:

- A few normal HTTPS sites load (DNS is working)
- The vault at https://34-83-148-68.sslip.io still loads

---

## Daily use

Toggle the VPN on when you need a US IP; toggle it off otherwise. There is no
need to leave it on — Vaultwarden is reachable either way, over public HTTPS.

Leaving it on costs battery and counts against the free egress allowance (see
[Cost](#cost)). It is a full tunnel: **all** traffic goes through the VM while
enabled.

Switching between Wi-Fi and mobile data is handled automatically;
`PersistentKeepalive = 25` re-establishes the tunnel within a few seconds.

---

## Adding another device

Each device needs its own key pair. Never share one config between two devices —
they will fight over the same tunnel address and both will misbehave.

```bash
gcloud compute ssh vaultwarden --project alex-pass --zone us-west1-a \
  --tunnel-through-iap --command 'sudo /bin/bash /etc/vaultwarden/wg-peer.sh add laptop'
```

This prints the config, allocates the next free address (`10.8.0.3`, `.4`, …) and
writes `/tmp/laptop-qr.png` on the VM. Copy it down with the `scp` command the
script prints, then scan as above.

---

## Managing peers

All commands run on the VM. Prefix with:

```bash
gcloud compute ssh vaultwarden --project alex-pass --zone us-west1-a \
  --tunnel-through-iap --command '<command>'
```

| Command | What it does |
| --- | --- |
| `sudo /bin/bash /etc/vaultwarden/wg-peer.sh list` | Peers, tunnel IPs, last handshake |
| `sudo /bin/bash /etc/vaultwarden/wg-peer.sh show <name>` | Reprint a config as text |
| `sudo /bin/bash /etc/vaultwarden/wg-peer.sh qr <name>` | Write a scannable PNG |
| `sudo /bin/bash /etc/vaultwarden/wg-peer.sh add <name>` | Add a device |
| `sudo /bin/bash /etc/vaultwarden/wg-peer.sh remove <name>` | **Revoke** a device |
| `sudo systemctl restart wireguard` | Restart the tunnel |
| `sudo systemctl status wireguard` | Service state |

A **last handshake** within the last couple of minutes means the device is
genuinely connected. `list` showing a peer only means it is configured.

### Revoking a lost phone

```bash
sudo /bin/bash /etc/vaultwarden/wg-peer.sh remove phone
```

Deletes the key and reloads the tunnel without it. The device cannot reconnect —
its config is now useless. To re-issue, `add phone` again and scan the new QR;
the old QR will never work again.

### Rotating keys

`remove <name>` then `add <name>`. Same effect as revoking, then re-issuing.

---

## Troubleshooting

**Connects, but `ifconfig.me` still shows the Australian IP.** The tunnel is not
carrying traffic. Check the phone's config has `AllowedIPs = 0.0.0.0/0, ::/0` —
anything narrower is a split tunnel. Re-scan the QR if unsure.

**Very slow, or nothing loads at all.** Almost always means there is no
handshake — every request is hanging and timing out rather than transferring
slowly. Check first:

```bash
sudo /bin/bash /etc/vaultwarden/wg-peer.sh list
```

`latest handshake` within the last couple of minutes and a non-zero `transfer`
means the tunnel is genuinely up. **No handshake line at all** means the phone's
packets are not reaching WireGuard. There are two firewalls in the path and both
must allow the port:

```bash
# 1. GCP firewall — should list vaultwarden-allow-wireguard / udp:51820
gcloud compute firewall-rules list --project alex-pass --filter='network:vaultwarden-vpc'

# 2. The VM's OWN iptables — COS defaults INPUT to DROP.
#    Expect a line matching "udp dpt:51820"; if it is missing, that is the bug.
sudo iptables -L INPUT -n | grep 51820
```

The second one is the easy one to miss: HTTP and HTTPS work regardless, because
Docker's published ports bypass the INPUT chain entirely.

Watch the counter to confirm packets are actually arriving:

```bash
sudo iptables -L INPUT -n -v | grep 51820   # run twice; the count should climb
```

Also confirm the service and interface are up:

```bash
sudo systemctl is-active wireguard
sudo ip -brief addr show wg0        # expect: wg0 UNKNOWN 10.8.0.1/24
```

A handful of restrictive mobile networks and corporate Wi-Fi block outbound UDP
entirely. Test on a different network before assuming the server is at fault.

**Handshake works, small pages load, large ones stall.** MTU. `wg0` must be
**1380** on GCP — the NIC is 1460 rather than the usual 1500, and WireGuard's
header costs 80 bytes:

```bash
ip link show wg0 | grep -o 'mtu [0-9]*'    # expect: mtu 1380
```

**Connects but no websites load.** DNS is not resolving. The config sets
`1.1.1.1`; some networks hijack DNS. Try `8.8.8.8` in the app's DNS field.

**Everything broke after a change on the VM.** WireGuard state is rebuilt from
`/mnt/disks/data/wireguard/peers/` on every start, so a restart is safe and
non-destructive to existing devices:

```bash
sudo systemctl restart wireguard
```

If the VM itself becomes unreachable, `gcloud compute instances reset vaultwarden
--zone us-west1-a` clears all runtime network state; peers survive.

---

## What the phone can and cannot reach

While connected, the phone can reach **the public internet only**. It cannot
reach:

- The GCP VPC subnet (`10.10.0.0/24`)
- The GCP metadata server (`169.254.169.254`) — this one matters, since it would
  otherwise hand out the VM's service-account credentials
- Other RFC1918 private ranges
- Other VPN peers

Each peer is pinned to a single `/32` tunnel address, so no device can
impersonate another.

Private keys are generated on the VM, stored at `/mnt/disks/data/wireguard/`
(mode 0600), and never appear in Terraform state, instance metadata, or Git.

**The QR code and `.conf` file are credentials.** Anyone who scans that QR gets
full VPN access as that device. Delete the downloaded PNG once scanned:

```bash
rm ~/Desktop/phone-qr.png ~/Desktop/wireguard-phone.conf
```

---

## Cost

No additional charge — the VPN reuses the existing always-free VM and its already
attached static IP.

The one thing to watch is **egress**: 200 GB/month to North America is free, and
a full tunnel carries every byte the phone browses. Ordinary use is nowhere near
that; heavy video streaming over the VPN could approach it. The existing $1
budget alert is the backstop.

---

## Where this is configured

| Thing | Where |
| --- | --- |
| Firewall rule (`udp:51820`) | [network.tf](network.tf) |
| `can_ip_forward`, `wg-*` metadata | [compute.tf](compute.tf) |
| Port, subnet, image | [variables.tf](variables.tf) |
| Scripts + systemd unit | [files/cloud-init.yaml](files/cloud-init.yaml) |
| Keys and peer files | `/mnt/disks/data/wireguard/` on the VM (not in Git) |

Port and subnet are runtime metadata: `terraform apply` plus
`systemctl restart wireguard` applies them without rebuilding the VM. Changing
anything in `files/cloud-init.yaml` needs a rebuild — see [README.md](README.md).
