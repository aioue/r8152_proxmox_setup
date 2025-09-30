#!/usr/bin/env bash
# r8152_proxmox_setup.sh
# Copyright (c) 2025 Tom Paine (https://github.com/aioue)
# Licensed under the MIT License. See https://opensource.org/licenses/MIT
#
# One-shot, safe installer for Realtek r8152 DKMS on Proxmox VE 9 (Secure Boot aware)
# - Uses awesometic .deb from /root/ or auto-fetches the latest from GitHub
# - Preserves access by temporarily moving vmbr0 to onboard NIC (enp3s0) if needed
# - Enrolls DKMS MOK for Secure Boot if not yet enrolled
# - Blacklists cdc_* drivers so r8152 binds
# - Guides you to unplug/replug once to trigger binding
# - Restores vmbr0 to the USB NIC and prints a concise report
# - Installs udev rule for deterministic r8152 binding at boot
# - Embeds r8152 in initramfs to prevent boot-time driver races
#
# Requirements: PVE 9 with ifupdown2, onboard NIC cabled as backup (default: enp3s0)
# awesometic (https://github.com/awesometic/realtek-r8152-dkms) .deb at /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
# (or pass path), OR allow script to auto-download latest release. Brief ifreload flap.
# Secure Boot: will prompt to enroll MOK and reboot if enabled; rerun afterward.
# Customize ONBOARD_IF_DEFAULT variable below if your onboard NIC has a different name.
#
# Re-run this script after kernel updates to refresh initramfs and verify binding.

set -euo pipefail

# Verify running as root
[[ $EUID -eq 0 ]] || { echo "ERROR: This script must be run as root" >&2; exit 1; }

DEB_DEFAULT="/root/realtek-r8152-dkms_2.20.1-1_amd64.deb"
DEB_PATH="${1:-$DEB_DEFAULT}"
ONBOARD_IF_DEFAULT="enp3s0"   # Adjust if your onboard NIC name differs
ONBOARD_IF="${ONBOARD_IF_DEFAULT}"
REPORT="/root/r8152_setup_report_$(date +%Y%m%d_%H%M%S).txt"
KREL="$(uname -r)"

say() { printf "\n==> %s\n" "$*"; }
note() { printf "    - %s\n" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

# ---------- fetch latest .deb from GitHub ----------
fetch_latest_deb_if_needed() {
  if [[ -f "$DEB_PATH" ]]; then
    return 0
  fi

  say "Local .deb not found: $DEB_PATH"
  note "Attempting to fetch latest awesometic release .deb from GitHub"
  REPO_URL="https://github.com/awesometic/realtek-r8152-dkms"
  API_URL="https://api.github.com/repos/awesometic/realtek-r8152-dkms/releases/latest"
  note "Repo: $REPO_URL"
  note "Query: $API_URL"

  command -v curl >/dev/null 2>&1 || die "curl is required to fetch latest release"
  command -v jq >/dev/null 2>&1 || { note "jq not found; installing jq"; apt-get update -y || true; apt-get install -y jq || die "failed to install jq"; }

  JSON="$(curl -fsSL "$API_URL")" || die "Failed to query GitHub API"
  # Prefer amd64 .deb asset
  ASSET_URL="$(echo "$JSON" | jq -r '.assets[] | select(.name|test("amd64\\.deb$")) | .browser_download_url' | head -n1)"
  [[ -n "$ASSET_URL" && "$ASSET_URL" != "null" ]] || die "No amd64 .deb asset found in latest release"

  note "Latest .deb asset: $ASSET_URL"
  DEB_BASENAME="/root/$(basename "$ASSET_URL")"
  say "Downloading to $DEB_BASENAME"
  curl -fL --output "$DEB_BASENAME" "$ASSET_URL" || die "Download failed"
  chmod 0644 "$DEB_BASENAME"
  DEB_PATH="$DEB_BASENAME"
  note "Using downloaded file: $DEB_PATH"
}

# ---------- Preflight ----------
say "Proxmox r8152 setup (kernel $KREL)"
note "Initial package path: $DEB_PATH"

command -v ifreload >/dev/null 2>&1 || die "ifreload (ifupdown2) required; PVE should have it."

# Try to fetch latest if the provided file is missing
fetch_latest_deb_if_needed

USB_VENDOR="0bda"
USB_PRODUCT="8157"

detect_usb_if() {
  # Find interface bound to r8152 whose USB device matches 0bda:8157
  for n in /sys/class/net/*; do
    IF="$(basename "$n")"
    [[ "$IF" =~ ^en.*|^eth[0-9]+$ ]] || continue
    [[ -e "$n/device" ]] || continue
    DEVLINK="$(readlink -f "$n"/device || true)"
    [[ "$DEVLINK" == *"/usb"* ]] || continue
    if [[ -r "$DEVLINK/idVendor" && -r "$DEVLINK/idProduct" ]]; then
      v=$(cat "$DEVLINK/idVendor"); p=$(cat "$DEVLINK/idProduct")
      if [[ "$v:$p" == "$USB_VENDOR:$USB_PRODUCT" ]]; then
        # Verify it's actually bound to r8152
        if [[ -e "$n/device/driver/module" ]]; then
          mod="$(basename "$(readlink -f "$n/device/driver/module")")"
          [[ "$mod" == "r8152" ]] && { echo "$IF"; return 0; }
        fi
      fi
    fi
  done
  return 1
}

current_usb_if="$(detect_usb_if || true)"

say "Detecting existing interfaces"
ip -br link | sed 's/^/    /'
if [[ -n "${current_usb_if:-}" ]]; then
  note "USB Realtek interface detected: $current_usb_if"
else
  note "USB Realtek interface not currently bound (will probe after install)."
fi

# ---------- Safety: ensure vmbr0 can fail over to onboard during driver switch ----------
say "Ensuring vmbr0 can use $ONBOARD_IF during driver switch"
[[ -e "/sys/class/net/$ONBOARD_IF" ]] || die "Onboard interface $ONBOARD_IF not found; adjust script variable."

IFCFG="/etc/network/interfaces"
cp -a "$IFCFG" "${IFCFG}.r8152.backup.$(date +%Y%m%d_%H%M%S)"

vmbr_port="$(awk '
  BEGIN{inbr=0;port=""}
  /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ {inbr=1; next}
  inbr==1 && /^[[:space:]]*bridge-ports[[:space:]]+/ {
     for (i=2;i<=NF;i++) if ($i!="bridge-ports") {port=$i; break}
     print port; exit
  }
' "$IFCFG")"

note "vmbr0 current bridge-port: ${vmbr_port:-<none>}"

if [[ -n "${vmbr_port:-}" && "$vmbr_port" != "$ONBOARD_IF" ]]; then
  say "Temporarily switching vmbr0 bridge-port to $ONBOARD_IF for safety"
  awk -v onb="$ONBOARD_IF" '
    BEGIN{inbr=0}
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ {inbr=1}
    inbr==1 && /^[[:space:]]*bridge-ports[[:space:]]+/ {$0="        bridge-ports " onb}
    {print}
  ' "$IFCFG" > "${IFCFG}.tmp" && mv "${IFCFG}.tmp" "$IFCFG"
  ifreload -a || true
  sleep 2
  ip -br link | sed 's/^/    /'
else
  note "vmbr0 already on $ONBOARD_IF (or no change needed)."
fi

grep -q "^iface ${ONBOARD_IF} inet" "$IFCFG" || printf "\niface %s inet manual\n" "$ONBOARD_IF" >>"$IFCFG"
if [[ -n "${current_usb_if:-}" ]]; then
  grep -q "^iface ${current_usb_if} inet" "$IFCFG" || printf "\niface %s inet manual\n" "$current_usb_if" >>"$IFCFG"
fi

# ---------- Install headers, DKMS package ----------
say "Installing headers, DKMS, and the r8152 DKMS package"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
apt-get install -y dkms build-essential "proxmox-headers-$KREL"
apt-get install -y "$DEB_PATH"

say "Verifying DKMS installation"
dkms status | grep -E 'r8152|realtek-r8152' || die "DKMS did not register r8152"
modinfo r8152 | sed -n '1,8p' | sed 's/^/    /' || true

# ---------- Blacklist competing USB net drivers and refresh initramfs ----------
say "Blacklisting competing drivers and updating initramfs"
# Consolidated blacklist file with install directives to prevent explicit module loads
tee /etc/modprobe.d/99-rtl815x-usb-blacklist.conf >/dev/null <<'EOF'
# Prevent generic/alternate drivers from binding RTL815x USB NICs
blacklist cdc_ncm
blacklist cdc_ether
blacklist r8153_ecm
# Block explicit module loading attempts
install cdc_ncm /bin/false
install cdc_ether /bin/false
install r8153_ecm /bin/false
EOF

# Ensure r8152 is embedded in initramfs for early availability at boot
IMOD="/etc/initramfs-tools/modules"
if ! grep -qE '^\s*r8152(\s|$)' "$IMOD" 2>/dev/null; then
  note "Adding r8152 to initramfs modules"
  echo "r8152" >> "$IMOD"
fi

update-initramfs -u

# ---------- Secure Boot handling (MOK) ----------
say "Checking Secure Boot/MOK status"
if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  if ! mokutil --list-enrolled 2>/dev/null | grep -qi 'DKMS module signing key'; then
    note "Secure Boot is enabled and DKMS MOK not enrolled."
    say "Enrolling DKMS signing key now. You will be prompted to set a password."
    # Try to import; check if it actually needs enrollment
    MOK_OUTPUT="$(mokutil --import /var/lib/dkms/mok.pub 2>&1)"
    if echo "$MOK_OUTPUT" | grep -qi 'already enrolled'; then
      note "MOK key already enrolled (detection issue resolved)."
    elif echo "$MOK_OUTPUT" | grep -qi 'password'; then
      # Actual enrollment happened, reboot needed
      say "Reboot required to complete MOK enrollment. After reboot, re-run this script with the same parameters."
      exit 0
    else
      note "MOK import status: $MOK_OUTPUT"
    fi
  else
    note "Secure Boot enabled; DKMS MOK is enrolled."
  fi
else
  note "Secure Boot disabled or unsupported by mokutil."
fi

# ---------- Install udev rule for deterministic binding ----------
say "Installing udev rule for deterministic r8152 binding at boot"
UDEV_RULE="/etc/udev/rules.d/99-r8152-rtl8157-bind.rules"
if [[ ! -f "$UDEV_RULE" ]]; then
  # Force r8152 driver binding when the RTL8157 USB interface is added
  # Sets driver_override, loads r8152 module, and explicitly binds the device
  # Targets the network interface function (bInterfaceNumber 00) of the 0bda:8157 device
  tee "$UDEV_RULE" >/dev/null <<'RULE'
# Force r8152 driver binding for Realtek RTL8157 (0bda:8157) at device enumeration
# Eliminates boot-time races where generic USB Ethernet drivers might bind first
# Sets driver_override, ensures r8152 is loaded, and binds the device immediately
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", \
  ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8157", ATTR{bInterfaceNumber}=="00", \
  RUN+="/bin/sh -c 'echo r8152 > /sys$devpath/driver_override; /sbin/modprobe r8152; if [ -e /sys$devpath/driver/bind ]; then echo $devpath > /sys/bus/usb/drivers/r8152/bind; fi'"
RULE
  note "Created $UDEV_RULE"
  udevadm control --reload
else
  note "udev rule already exists: $UDEV_RULE"
fi

# ---------- Load r8152 and guide replug ----------
say "Loading r8152 and preparing for device rebind"
modprobe -r r8152 2>/dev/null || true
modprobe r8152

say "ACTION REQUIRED: Unplug and replug the Realtek USB 5G NIC now, then press Enter."
read -r -p "Press Enter after replug..."

# ---------- Detect USB NIC and verify binding ----------
say "Detecting the USB NIC and verifying binding"
lsusb -t | sed 's/^/    /'
sleep 1

# Use the same detection function for consistency (verifies both VID/PID and driver)
new_usb_if="$(detect_usb_if || true)"

if [[ -z "${new_usb_if:-}" ]]; then
  note "No interface shows driver=r8152 yet; trying once more after 2s..."
  sleep 2
  lsusb -t | sed 's/^/    /'
  new_usb_if="$(detect_usb_if || true)"
fi

[[ -n "${new_usb_if:-}" ]] || die "USB NIC did not bind to r8152. Check cabling/port and rerun."

say "USB NIC bound to r8152 on interface: $new_usb_if"
ethtool -i "$new_usb_if" | sed 's/^/    /'

# ---------- Restore vmbr0 to the USB NIC ----------
say "Restoring vmbr0 bridge-port to $new_usb_if"
awk -v usb="$new_usb_if" '
  BEGIN{inbr=0}
  /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ {inbr=1}
  inbr==1 && /^[[:space:]]*bridge-ports[[:space:]]+/ {$0="        bridge-ports " usb}
  {print}
' "$IFCFG" > "${IFCFG}.tmp" && mv "${IFCFG}.tmp" "$IFCFG"

VMAC="$(cat /sys/class/net/"$new_usb_if"/address)"
# Only add hwaddress if not already present in vmbr0 block
if ! awk '/^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/,/^iface[[:space:]]+/ {if (/hwaddress ether/) exit 0} END {exit 1}' "$IFCFG"; then
  sed -i "/^iface vmbr0 inet static/a\        hwaddress ether ${VMAC}" "$IFCFG"
fi

ifreload -a || true
sleep 2
ip link set "$new_usb_if" up || true
ifreload -a || true
sleep 1

# ---------- Summary report ----------
say "Summary"
{
  echo "Kernel: $KREL"
  echo "Repo: https://github.com/awesometic/realtek-r8152-dkms"
  echo "Package used: $DEB_PATH"
  echo
  echo "DKMS:"
  dkms status | grep -E 'r8152|realtek-r8152' || true
  echo
  echo "udev rule (persistent binding):"
  ls -l /etc/udev/rules.d/99-r8152-rtl8157-bind.rules 2>/dev/null || echo "  (not found)"
  echo
  echo "Initramfs modules (r8152 embedded):"
  grep -E '^\s*r8152(\s|$)' /etc/initramfs-tools/modules 2>/dev/null || echo "  (not embedded)"
  echo
  echo "Initramfs blacklist verification:"
  if command -v lsinitramfs >/dev/null 2>&1; then
    if lsinitramfs "/boot/initrd.img-$KREL" 2>/dev/null | grep -q 'modprobe.d/99-rtl815x-usb-blacklist.conf'; then
      echo "  ✓ Blacklist file present in initramfs"
    else
      echo "  ✗ Blacklist file NOT found in initramfs"
    fi
  else
    echo "  (lsinitramfs not available)"
  fi
  echo
  echo "USB tree:"
  lsusb -t || true
  echo
  echo "Interfaces:"
  ip -br link || true
  echo
  echo "Bridge config (vmbr0):"
  awk '
  BEGIN { inblk=0 }
  /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ { inblk=1 }
  inblk && NF==0 { inblk=0 }
  inblk { print }
  ' "$IFCFG"
  echo
  echo "Driver details ($new_usb_if):"
  ethtool -i "$new_usb_if" || true
  echo
  echo "Link ($new_usb_if):"
  ethtool "$new_usb_if" | sed -n '1,40p'
} | tee "$REPORT" | sed 's/^/    /'

say "Done. Report saved to: $REPORT"
note "Re-run this script after kernel updates to refresh initramfs and verify binding."
