## AI notes for r8152_proxmox_setup

This document captures practical behavior observed on Proxmox VE 9 hosts and the design assumptions behind the install/uninstall scripts for Realtek RTL815x USB NICs (e.g., RTL8157) using the awesometic DKMS `realtek-r8152-dkms` package.

### Networking model on Proxmox
- Proxmox typically assigns the node IP to a Linux bridge `vmbr0`; physical NICs are members via `bridge-ports`. Physical NICs are commonly configured as `inet manual` so they carry no IPs directly; only `vmbr0` has an IP/gateway.
- Switching `vmbr0` from one physical NIC to another does not change the node IP; it changes the uplink under the bridge.
- Setting a fixed `hwaddress ether` on the bridge pins the bridge MAC. This avoids MAC flapping when you swap underlying ports. It is not default, but is helpful when toggling between interfaces. Removing it later returns to default behavior (bridge uses first enslaved port’s MAC).
- STP: Proxmox often sets `bridge-stp off` by default. `bridge-fd` (forwarding delay) defaults to 15s; many users set `bridge-fd 0` for faster convergence, but it is not default. The scripts avoid forcing `bridge-fd` changes.

### Safe failover requirements
- To safely switch `vmbr0` away from the USB NIC, an onboard NIC (default variable `ONBOARD_IF_DEFAULT=enp3s0`) must be cabled and able to carry traffic.
- The script checks link via `/sys/class/net/<if>/carrier`. On interfaces configured as `inet manual`, it may bring the port administratively UP briefly to verify link, then leave it UP so failover will work.
- If the onboard interface is not `manual` (e.g., `dhcp` or `static`), the script will not bring it up automatically to avoid IP conflicts; it warns and expects the operator to ensure link.

### USB NIC and drivers
- Realtek USB devices can enumerate in multiple configurations; the awesometic rules ensure configuration 1 (r8152 mode). The installer double-checks and sets it if needed.
- The DKMS package provides an up-to-date `r8152` driver. The in-kernel `r8152` also exists, but may be older and often negotiates lower speeds.
- The installer blacklists `cdc_ncm`, `cdc_ether`, and `r8153_ecm` so the preferred `r8152` binds first. It also embeds `r8152` into initramfs to make the device available earlier during boot.

### Secure Boot / MOK
- If Secure Boot is enabled, DKMS modules must be signed. The installer guides MOK enrollment via `mokutil --import`, requiring one reboot. Re-running the script post-reboot completes the flow.
- Uninstall does not attempt to revoke MOK; this is typically a manual, host policy decision.

### Idempotency and backups
- The installer backs up `/etc/network/interfaces` to `interfaces.r8152.backup.<timestamp>` before editing.
- Network edits are minimal and focused:
  - Temporarily switch `vmbr0` `bridge-ports` from the USB NIC to the onboard interface for safety when replugging.
  - Optionally add `hwaddress ether` to `vmbr0` if absent to stabilize the MAC across port switches.
  - Avoid adding or removing `bridge-fd`.

### Uninstall strategy (high level)
- Preserve access: ensure onboard link; switch `vmbr0` uplink to onboard if currently on USB.
- Undo kernel changes: remove the custom blacklist file; remove `r8152` from initramfs modules; update initramfs.
- Optionally remove the `hwaddress` line if it was added for the USB NIC (i.e., it matches the USB NIC MAC) to return to default behavior. If uncertain, prefer leaving it in place to avoid disruptive MAC changes.
- Uninstall the DKMS `.deb` (`realtek-r8152-dkms`) via apt.
- Do not modify Secure Boot MOK.

### Defaults and safety notes
- Default Proxmox bridge config: `bridge-stp off`, `bridge-fd` not explicitly set (defaults to 15).
- Bringing up a `manual` interface administratively (`ip link set <if> up`) does not assign IP and is safe against conflicts.
- Avoid changing multiple variables at once during rollback; switch the bridge first, then adjust kernel modules/blacklists.

### Recovery
- If the USB NIC no longer binds post-uninstall, the in-kernel `r8152` usually still binds. If it does not, removing the blacklist file restores `cdc_*` fallbacks.
- Keep a recent backup of `/etc/network/interfaces` for manual restore if needed.


