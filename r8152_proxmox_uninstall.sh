#!/usr/bin/env bash
# r8152_proxmox_uninstall.sh
# Safely roll back changes made by r8152_proxmox_setup.sh on Proxmox VE 9
# - Preserves access by moving vmbr0 to onboard NIC if currently on USB NIC
# - Removes DKMS package and kernel customizations (blacklist, initramfs module)
# - Optionally removes vmbr0 hwaddress only if it matches USB NIC MAC
#
# Notes:
# - Does not attempt to revoke Secure Boot MOK
# - Expects ifupdown2 (ifreload) and root privileges

set -euo pipefail

# Keep running if SSH disconnects during brief network flaps
trap '' SIGHUP

[[ $EUID -eq 0 ]] || { echo "ERROR: Must run as root" >&2; exit 1; }

say() { printf "\n==> %s\n" "$*"; }
note() { printf "    - %s\n" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

ONBOARD_IF_DEFAULT="enp3s0"
ONBOARD_IF="${ONBOARD_IF_DEFAULT}"
IFCFG="/etc/network/interfaces"
KREL="$(uname -r)"

USB_VENDOR="0bda"
USB_PRODUCT="8157"

detect_usb_if() {
  for n in /sys/class/net/*; do
    IF="$(basename "$n")"
    [[ "$IF" =~ ^en.*|^eth[0-9]+$ ]] || continue
    [[ -e "$n/device" ]] || continue
    DEVLINK="$(readlink -f "$n"/device || true)"
    [[ "$DEVLINK" == *"/usb"* ]] || continue

    USB_DEV="$DEVLINK"
    for _ in 1 2 3; do
      [[ -r "$USB_DEV/idVendor" ]] && break
      USB_DEV="$(dirname "$USB_DEV")"
    done

    if [[ -r "$USB_DEV/idVendor" && -r "$USB_DEV/idProduct" ]]; then
      v=$(cat "$USB_DEV/idVendor"); p=$(cat "$USB_DEV/idProduct")
      if [[ "$v:$p" == "$USB_VENDOR:$USB_PRODUCT" ]]; then
        if [[ -e "$n/device/driver/module" ]]; then
          mod="$(basename "$(readlink -f "$n/device/driver/module")")"
          [[ "$mod" == "r8152" ]] && { echo "$IF"; return 0; }
        fi
      fi
    fi
  done
  return 1
}

get_vmbr0_port() {
  awk '
    BEGIN{inbr=0;port=""}
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ {inbr=1; next}
    inbr==1 && /^[[:space:]]*bridge-ports[[:space:]]+/ {
       for (i=2;i<=NF;i++) if ($i!="bridge-ports") {port=$i; break}
       print port; exit
    }
  ' "$IFCFG"
}

set_vmbr0_port() {
  local port="$1"
  awk -v p="$port" '
    BEGIN{inbr=0}
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ {inbr=1}
    inbr==1 && /^[[:space:]]*bridge-ports[[:space:]]+/ {$0="        bridge-ports " p}
    {print}
  ' "$IFCFG" > "${IFCFG}.tmp" && mv "${IFCFG}.tmp" "$IFCFG"
}

ensure_onboard_failover_ready() {
  say "Verifying onboard interface $ONBOARD_IF for failover"
  [[ -e "/sys/class/net/$ONBOARD_IF" ]] || die "Onboard interface $ONBOARD_IF not found"

  local cfg
  # Read the ipv4 method from the iface line for the onboard interface (field 4)
  cfg="$(awk -v ifc="$ONBOARD_IF" '$1=="iface" && $2==ifc && $3=="inet" {print $4; exit}' "$IFCFG" 2>/dev/null || true)"
  if [[ "$cfg" != "manual" ]]; then
    note "Warning: $ONBOARD_IF configured as 'inet $cfg' (not manual). Skipping auto bring-up."
  else
    if ! ip link show "$ONBOARD_IF" | grep -q 'state UP'; then
      note "Bringing up $ONBOARD_IF temporarily to verify link"
      ip link set "$ONBOARD_IF" up
      sleep 1
    fi
  fi

  if [[ -r "/sys/class/net/$ONBOARD_IF/carrier" ]]; then
    local CARRIER
    CARRIER="$(cat /sys/class/net/"$ONBOARD_IF"/carrier 2>/dev/null || echo 0)"
    [[ "$CARRIER" == "1" ]] || die "$ONBOARD_IF has no link; cannot failover safely. Plug cable and retry."
  else
    note "Warning: Cannot verify link state of $ONBOARD_IF"
  fi
}

switch_vmbr0_to_onboard_if_needed() {
  local cur_port
  cur_port="$(get_vmbr0_port)"
  note "vmbr0 current bridge-port: ${cur_port:-<none>}"
  if [[ -n "$cur_port" && "$cur_port" != "$ONBOARD_IF" ]]; then
    say "Switching vmbr0 bridge-port to $ONBOARD_IF for safe rollback"
    # Backup before editing
    cp -a "$IFCFG" "${IFCFG}.r8152.uninstall.backup.$(date +%Y%m%d_%H%M%S)"
    set_vmbr0_port "$ONBOARD_IF"
    ifreload -a || true
    sleep 2
    ip -br link | sed 's/^/    /'
  else
    note "vmbr0 already on $ONBOARD_IF (or no change needed)"
  fi
}

remove_vmbr0_hwaddress_if_usb_mac() {
  # If vmbr0 hwaddress equals the USB interface MAC, remove it to restore default behavior
  local usb_if usb_mac
  usb_if="$(detect_usb_if || true)"
  [[ -n "${usb_if:-}" ]] || { note "USB NIC not bound to r8152; skipping hwaddress cleanup"; return 0; }
  usb_mac="$(cat /sys/class/net/"$usb_if"/address 2>/dev/null || echo "")"
  [[ -n "$usb_mac" ]] || { note "Could not read USB NIC MAC; skipping hwaddress cleanup"; return 0; }

  if awk -v mac="$usb_mac" '
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ { in_vmbr=1; next }
    in_vmbr && /^[[:space:]]*hwaddress[[:space:]]+ether[[:space:]]+.*$/ { print $0; if ($NF==mac) exit 0; else exit 2 }
    in_vmbr && (/^[[:space:]]*$/ || /^iface[[:space:]]+/ || /^auto[[:space:]]+/) { exit 1 }
  ' "$IFCFG"; then
    note "Removing vmbr0 hwaddress ether $usb_mac"
    sed -i "/^[[:space:]]*hwaddress[[:space:]]\+ether[[:space:]]\+$usb_mac/d" "$IFCFG"
    ifreload -a || true
  else
    note "vmbr0 hwaddress either absent or not equal to USB MAC; leaving as-is"
  fi
}

remove_kernel_customizations() {
  say "Removing kernel customizations and refreshing initramfs"
  local bl="/etc/modprobe.d/99-rtl815x-usb-blacklist.conf"
  if [[ -f "$bl" ]]; then
    note "Deleting $bl"
    rm -f "$bl"
  else
    note "Blacklist file not present"
  fi

  local imod="/etc/initramfs-tools/modules"
  if grep -qE '^\s*r8152(\s|$)' "$imod" 2>/dev/null; then
    note "Removing r8152 entry from $imod"
    sed -i '/^\s*r8152\(\s\|$\)/d' "$imod"
  else
    note "r8152 not listed in initramfs modules"
  fi
  # Rebuild initramfs for ALL installed kernels, not just the current one.
  # Rationale: On reboot the system may select a different kernel; ensuring
  # every initramfs contains consistent ZFS/net state avoids boot stalls like
  # dropped ZFS imports (you saw needing `zpool import rpool` in initramfs).
  update-initramfs -u -k all

  # Refresh bootloader entries/ESPs for Proxmox-managed systems so the new
  # initramfs images are propagated. Safe no-op if tool is missing.
  if command -v proxmox-boot-tool >/dev/null 2>&1; then
    note "Refreshing Proxmox boot entries (proxmox-boot-tool)"
    proxmox-boot-tool refresh || true
  fi
}

wait_for_connectivity_gate() {
  # Wait until vmbr0 is UP and default gateway is reachable before proceeding
  say "Verifying connectivity on vmbr0 after failover"
  local timeout=30
  local t=0
  while ! ip -br link show vmbr0 | grep -q 'UP' ; do
    ((t++))
    ((t>timeout)) && die "vmbr0 did not come UP after failover"
    sleep 1
  done

  # Detect default gw and ping
  local gw
  gw="$(ip route | awk '/default/ {print $3; exit}')"
  if [[ -n "$gw" ]]; then
    note "Pinging default gateway $gw to confirm reachability"
    if ! ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then
      note "Warning: gateway not reachable yet; waiting up to 30s"
      t=0
      until ping -c 1 -W 2 "$gw" >/dev/null 2>&1; do
        ((t++))
        ((t>30)) && die "Gateway $gw not reachable after failover"
        sleep 1
      done
    fi
  else
    note "No default gateway detected; skipping gateway check"
  fi
  note "Connectivity checks passed"
}

uninstall_dkms_package() {
  say "Uninstalling realtek-r8152 DKMS package"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y realtek-r8152-dkms || apt-get remove -y realtek-r8152-dkms || true
}

# ---------- Optional: Switch bridge back to USB NIC with safety checks ----------
pin_vmbr0_mac_to_current() {
  # Ensure vmbr0 keeps its current MAC to avoid ARP churn when switching ports
  local cur_mac
  cur_mac="$(ip -br link show vmbr0 | awk '{print $3}')"
  [[ -n "$cur_mac" ]] || { note "Could not determine vmbr0 MAC"; return 0; }
  if ! awk '
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ { in_vmbr=1; next }
    in_vmbr && /^[[:space:]]*hwaddress[[:space:]]+ether/ { found=1; exit 0 }
    in_vmbr && (/^[[:space:]]*$/ || /^iface[[:space:]]+/ || /^auto[[:space:]]+/) { exit 1 }
    END { exit (found ? 0 : 1) }
  ' "$IFCFG"; then
    note "Pinning vmbr0 MAC to $cur_mac"
    sed -i "/^iface vmbr0 inet static/a\\        hwaddress ether ${cur_mac}" "$IFCFG"
  else
    note "vmbr0 hwaddress already present"
  fi
}

ensure_iface_manual_stanza() {
  local ifname="$1"
  if ! grep -q "^iface ${ifname} inet" "$IFCFG"; then
    note "Adding manual stanza for ${ifname}"
    printf "\niface %s inet manual\n" "$ifname" >>"$IFCFG"
  fi
}

get_default_gw() {
  ip route | awk '/default/ {print $3; exit}'
}

check_gateway_reachable() {
  local gw="$1"; local timeout="${2:-30}"; local t=0
  [[ -n "$gw" ]] || { note "No default gateway detected"; return 0; }
  note "Pinging default gateway $gw to confirm reachability"
  until ping -c 1 -W 2 "$gw" >/dev/null 2>&1; do
    ((t++))
    ((t>timeout)) && return 1
    sleep 1
  done
  return 0
}

switch_back_to_usb_with_checks() {
  say "Switching vmbr0 back to USB NIC (opt-in)"
  local usb_if gw revert_needed=false

  usb_if="$(detect_usb_if || true)"
  [[ -n "${usb_if:-}" ]] || die "USB NIC not detected with r8152 driver; cannot switch back"

  if ! ethtool -i "$usb_if" 2>/dev/null | grep -qi '^driver: r8152'; then
    die "USB NIC $usb_if is not using r8152 driver"
  fi

  if [[ ! -r "/sys/class/net/$usb_if/carrier" ]] || [[ "$(cat /sys/class/net/"$usb_if"/carrier 2>/dev/null || echo 0)" != 1 ]]; then
    die "USB NIC $usb_if has no link; aborting switch back"
  fi
  if ! ethtool "$usb_if" 2>/dev/null | grep -qi 'Link detected: yes'; then
    die "USB NIC $usb_if link not detected by ethtool; aborting"
  fi

  ensure_iface_manual_stanza "$usb_if"
  pin_vmbr0_mac_to_current

  # Backup then switch
  cp -a "$IFCFG" "${IFCFG}.r8152.switchback.backup.$(date +%Y%m%d_%H%M%S)"
  say "Switching vmbr0 bridge-port to $usb_if"
  set_vmbr0_port "$usb_if"
  ifreload -a || true
  sleep 2
  ip -br link | sed 's/^/    /'

  # Connectivity verification
  gw="$(get_default_gw)"
  if ! check_gateway_reachable "$gw" 30; then
    note "Gateway not reachable after switch; reverting to $ONBOARD_IF"
    revert_needed=true
  fi

  if $revert_needed; then
    set_vmbr0_port "$ONBOARD_IF"
    ifreload -a || true
    sleep 2
    die "Switch back failed; reverted to $ONBOARD_IF"
  fi
  note "Switch back to USB NIC completed"
}

print_summary() {
  say "Summary"
  {
    echo "Kernel: $KREL"
    echo
    echo "USB tree:"
    lsusb -t || true
    echo
    echo "Interfaces:"
    ip -br link || true
    echo
    echo "Bridge config (vmbr0):"
    awk 'BEGIN { inblk=0 } /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ { inblk=1; next } inblk && NF==0 { inblk=0 } inblk { print }' "$IFCFG"
    echo
    local usb_if
    usb_if="$(detect_usb_if || true)"
    if [[ -n "${usb_if:-}" ]]; then
      echo "Driver details ($usb_if):"
      ethtool -i "$usb_if" || true
      echo
      echo "Link ($usb_if):"
      ethtool "$usb_if" | sed -n '1,40p'
    fi
  } | sed 's/^/    /'
}

main() {
  local switch_back=false

  # Arg parsing
  for arg in "$@"; do
    case "$arg" in
      --switch-back-to-usb)
        switch_back=true
        ;;
      --onboard-if=*)
        ONBOARD_IF="${arg#*=}"
        ;;
      *)
        ;;
    esac
  done

  say "Proxmox r8152 uninstall (kernel $KREL)"
  ensure_onboard_failover_ready
  switch_vmbr0_to_onboard_if_needed
  wait_for_connectivity_gate
  remove_vmbr0_hwaddress_if_usb_mac
  # Uninstall DKMS package first so the final initramfs we build below reflects
  # the post-uninstall state across ALL kernels.
  uninstall_dkms_package
  # Revert blacklist and initramfs module entries, then rebuild all initramfs
  # and refresh Proxmox boot entries to propagate the changes to ESPs.
  remove_kernel_customizations
  if $switch_back; then
    switch_back_to_usb_with_checks
  fi

  say "Rollback complete"
  note "If USB NIC still binds to in-kernel r8152, bridge can be moved back if desired."
  print_summary
}

main "$@"


