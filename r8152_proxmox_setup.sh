#!/usr/bin/env bash
# r8152_proxmox_setup.sh
# Copyright (c) 2025 Tom Paine (https://github.com/aioue)
# Licensed under the MIT License. See https://opensource.org/licenses/MIT
#
# One-shot, safe installer for Realtek r8152 DKMS on Proxmox VE 9 (Secure Boot aware)
# - Uses awesometic .deb from /root/ or auto-fetches the latest from GitHub
# - Preserves access by temporarily moving vmbr0 to onboard NIC (enp3s0) if needed
# - Enrolls DKMS MOK for Secure Boot if not yet enrolled
# - Blacklists cdc_* drivers so r8152 binds automatically
# - Embeds r8152 in initramfs for early boot availability
# - Ensures USB device is in correct configuration mode (config 1)
# - Removes conflicting manual udev rules that can cause boot failures
# - Guides you to unplug/replug once if initial binding needed
# - Restores vmbr0 to the USB NIC and prints a concise report
#
# Requirements: PVE 9 with ifupdown2, onboard NIC cabled as backup (default: enp3s0)
# awesometic (https://github.com/awesometic/realtek-r8152-dkms) .deb at /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
# (or pass path), OR allow script to auto-download latest release. Brief ifreload flap.
# Secure Boot: will prompt to enroll MOK and reboot if enabled; rerun afterward.
# Customize ONBOARD_IF_DEFAULT variable below if your onboard NIC has a different name.
#
# Re-run this script after kernel updates to refresh initramfs and verify binding.

# TODO: TEST BEHAVIOUR AFTER UNINSTALL THE DEB

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

# ---------- Helper functions ----------
# Find the sysfs path for the Realtek USB device (0bda:8157)
find_realtek_usb_device() {
  local usb_dev vid pid
  for usb_dev in /sys/bus/usb/devices/*; do
    [[ -r "$usb_dev/idVendor" ]] || continue
    vid=$(cat "$usb_dev/idVendor" 2>/dev/null)
    pid=$(cat "$usb_dev/idProduct" 2>/dev/null)
    [[ "$vid:$pid" == "$USB_VENDOR:$USB_PRODUCT" ]] && { echo "$usb_dev"; return 0; }
  done
  return 1
}

# Get current bridge-port for vmbr0 from /etc/network/interfaces
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

# Set bridge-port for vmbr0 in /etc/network/interfaces
set_vmbr0_port() {
  local port="$1"
  awk -v p="$port" '
    BEGIN{inbr=0}
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ {inbr=1}
    inbr==1 && /^[[:space:]]*bridge-ports[[:space:]]+/ {$0="        bridge-ports " p}
    {print}
  ' "$IFCFG" > "${IFCFG}.tmp" && mv "${IFCFG}.tmp" "$IFCFG"
}

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
IFCFG="/etc/network/interfaces"

detect_usb_if() {
  # Find interface bound to r8152 whose USB device matches 0bda:8157
  for n in /sys/class/net/*; do
    IF="$(basename "$n")"
    [[ "$IF" =~ ^en.*|^eth[0-9]+$ ]] || continue
    [[ -e "$n/device" ]] || continue
    DEVLINK="$(readlink -f "$n"/device || true)"
    [[ "$DEVLINK" == *"/usb"* ]] || continue
    
    # USB device attributes (idVendor/idProduct) may be in parent directories
    # Walk up the tree (bounded to 3 levels) to find them
    USB_DEV="$DEVLINK"
    for _ in 1 2 3; do
      [[ -r "$USB_DEV/idVendor" ]] && break
      USB_DEV="$(dirname "$USB_DEV")"
    done
    
    if [[ -r "$USB_DEV/idVendor" && -r "$USB_DEV/idProduct" ]]; then
      v=$(cat "$USB_DEV/idVendor"); p=$(cat "$USB_DEV/idProduct")
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

# ---------- Early validation: onboard NIC must be available for failover ----------
say "Verifying onboard interface $ONBOARD_IF is available for failover"
[[ -e "/sys/class/net/$ONBOARD_IF" ]] || die "Onboard interface $ONBOARD_IF not found; adjust script variable."

# Check if onboard interface is configured as 'inet manual' (safe to bring up temporarily)
ONBOARD_CONFIG="$(grep -A 1 "^iface ${ONBOARD_IF}" "$IFCFG" 2>/dev/null | grep 'inet' | awk '{print $3}')"
if [[ "$ONBOARD_CONFIG" != "manual" ]]; then
  note "Warning: $ONBOARD_IF is configured as 'inet $ONBOARD_CONFIG' (not manual)"
  note "Skipping automatic link verification to avoid network conflicts"
  note "Ensure $ONBOARD_IF has link (cable plugged in) before running this script"
else
  # Bring interface up temporarily to check carrier (link state)
  # Safe because the interface is 'inet manual' (no IP assigned)
  ONBOARD_WAS_UP=false
  if ip link show "$ONBOARD_IF" | grep -q 'state UP'; then
    ONBOARD_WAS_UP=true
  fi

  if ! $ONBOARD_WAS_UP; then
    note "Bringing up $ONBOARD_IF temporarily to verify link"
    ip link set "$ONBOARD_IF" up
    sleep 1  # Allow link negotiation
  fi

  # Check link state - failover path must be viable if we need it
  if [[ -r "/sys/class/net/$ONBOARD_IF/carrier" ]]; then
    CARRIER="$(cat /sys/class/net/$ONBOARD_IF/carrier 2>/dev/null || echo 0)"
    if [[ "$CARRIER" != "1" ]]; then
      die "Onboard interface $ONBOARD_IF has no link (cable unplugged?). Cannot safely switch bridge if needed. Connect $ONBOARD_IF and rerun."
    fi
    note "Onboard interface $ONBOARD_IF has link - failover path available"
    
    # Keep it up since we verified link - we may need it for bridge failover
    note "Keeping $ONBOARD_IF up for potential failover use"
  else
    note "Warning: Cannot verify link state of $ONBOARD_IF"
    # Put it back down if we brought it up and couldn't verify
    if ! $ONBOARD_WAS_UP; then
      ip link set "$ONBOARD_IF" down
    fi
  fi
fi

current_usb_if="$(detect_usb_if || true)"

say "Detecting existing interfaces"
ip -br link | sed 's/^/    /'
if [[ -n "${current_usb_if:-}" ]]; then
  note "USB Realtek interface detected: $current_usb_if"
else
  note "USB Realtek interface not currently bound (will probe after install)."
fi

cp -a "$IFCFG" "${IFCFG}.r8152.backup.$(date +%Y%m%d_%H%M%S)"

# ---------- Install headers, DKMS package ----------
say "Installing headers, DKMS, and the r8152 DKMS package"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
apt-get install -y dkms build-essential "proxmox-headers-$KREL"
apt-get install -y "$DEB_PATH"

say "Verifying DKMS installation"
if ! dkms status | grep -E 'r8152|realtek-r8152' >/dev/null; then
  note "DKMS did not register r8152. Checking in-kernel module version:"
  modinfo r8152 2>/dev/null | sed -n '1,8p' | sed 's/^/    /' || true
  die "DKMS installation failed. See in-kernel module info above."
fi
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
    MOK_KEY="/var/lib/dkms/mok.pub"
    if [[ -f "$MOK_KEY" ]]; then
      say "Enrolling DKMS signing key now. You will be prompted to set a password."
      # Try to import; check if it actually needs enrollment
      MOK_OUTPUT="$(mokutil --import "$MOK_KEY" 2>&1)"
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
      note "DKMS signing key not found at $MOK_KEY"
      note "Consult DKMS package documentation to locate and enroll the signing key if needed."
    fi
  else
    note "Secure Boot enabled; DKMS MOK is enrolled."
  fi
else
  note "Secure Boot disabled or unsupported by mokutil."
fi

# ---------- Clean up udev rules created by old versions of this script ----------
say "Removing udev rules from previous script versions"
# Old versions of this script created manual binding rules that are unnecessary
# and can fail at boot. With awesometic's config-setting rule, blacklist, and
# initramfs, the kernel auto-binds r8152 without manual intervention.
OLD_SCRIPT_RULES=(
  "/etc/udev/rules.d/99-r8152-rtl8157-bind.rules"
)
for rule in "${OLD_SCRIPT_RULES[@]}"; do
  if [[ -f "$rule" ]]; then
    note "Removing old script rule: $rule"
    rm -f "$rule"
  fi
done
udevadm control --reload

# ---------- Fix USB configuration and establish binding ----------
fix_usb_configuration() {
  # Realtek USB adapters support multiple USB configurations (modes)
  # Configuration 1: r8152 proprietary mode (best performance, 5G support)
  # Configuration 2/3: CDC NCM/ECM mode (generic, lower performance)
  # The awesometic udev rules set this, but we need to ensure it's correct
  
  local usb_dev current_config
  usb_dev="$(find_realtek_usb_device)" || return 1
  
  current_config=$(cat "$usb_dev/bConfigurationValue" 2>/dev/null || echo "0")
  if [[ "$current_config" != "1" ]]; then
    note "Setting USB configuration to 1 for r8152 mode (was: $current_config)"
    echo 1 > "$usb_dev/bConfigurationValue" || true
    sleep 2  # Allow device to re-enumerate
  fi
  return 0
}

# ---------- Verify or establish r8152 binding ----------
say "Ensuring r8152 driver is loaded and device is bound"
modprobe r8152

# Fix USB configuration if needed
fix_usb_configuration || note "USB device not found or config already correct"

# Check if device is already properly bound to r8152
new_usb_if="$(detect_usb_if || true)"

if [[ -n "${new_usb_if:-}" ]]; then
  # Device already bound and working - skip replug AND bridge switching
  note "USB NIC already bound to r8152: $new_usb_if"
  note "Skipping replug and bridge switch (device is already working)"
else
  # Device not bound to r8152 - need replug for initial setup
  # Only now do we need to switch bridge to onboard for safety
  
  say "USB NIC not currently bound to r8152 - initial setup required"
  
  # Get current bridge port and switch to onboard if needed
  vmbr_port="$(get_vmbr0_port)"
  
  note "vmbr0 current bridge-port: ${vmbr_port:-<none>}"
  
  if [[ -n "${vmbr_port:-}" && "$vmbr_port" != "$ONBOARD_IF" ]]; then
    say "Temporarily switching vmbr0 bridge-port to $ONBOARD_IF for safety during replug"
    set_vmbr0_port "$ONBOARD_IF"
    ifreload -a || true
    sleep 2
    ip -br link | sed 's/^/    /'
  else
    note "vmbr0 already on $ONBOARD_IF (or no change needed)."
  fi
  
  # Ensure interface definitions exist
  grep -q "^iface ${ONBOARD_IF} inet" "$IFCFG" || printf "\niface %s inet manual\n" "$ONBOARD_IF" >>"$IFCFG"
  if [[ -n "${current_usb_if:-}" ]]; then
    grep -q "^iface ${current_usb_if} inet" "$IFCFG" || printf "\niface %s inet manual\n" "$current_usb_if" >>"$IFCFG"
  fi
  
  say "ACTION REQUIRED: Unplug and replug the Realtek USB 5G NIC now, then press Enter."
  read -r -p "Press Enter after replug..."
  
  # Detect USB NIC after replug with retry logic
  say "Detecting the USB NIC and verifying binding"
  lsusb -t | sed 's/^/    /'
  sleep 1
  
  # Retry up to 5 times with increasing delays to allow for binding and interface creation
  for attempt in 1 2 3 4 5; do
    new_usb_if="$(detect_usb_if || true)"
    [[ -n "${new_usb_if:-}" ]] && break
    
    if [[ $attempt -lt 5 ]]; then
      note "No interface shows driver=r8152 yet; retry $attempt/4 after ${attempt}s..."
      sleep "$attempt"
      lsusb -t | sed 's/^/    /'
    fi
  done
  
  if [[ -z "${new_usb_if:-}" ]]; then
    echo "ERROR: USB NIC did not bind to r8152 after replug." >&2
    echo "Possible causes:" >&2
    echo "  - Device not properly connected" >&2
    echo "  - Wrong USB port" >&2
    echo "  - Switch STP blocking port (bridge MAC appears on multiple ports)" >&2
    echo "  - Try waiting 30 seconds for STP convergence, then rerun" >&2
    exit 1
  fi
  
  say "USB NIC bound to r8152 on interface: $new_usb_if"
  ethtool -i "$new_usb_if" | sed 's/^/    /'
  
  # ---------- Restore vmbr0 to the USB NIC ----------
  say "Restoring vmbr0 bridge-port to $new_usb_if"
  set_vmbr0_port "$new_usb_if"
  
  VMAC="$(cat /sys/class/net/"$new_usb_if"/address)"
  # Only add hwaddress if not already present in vmbr0 block
  # Check for hwaddress in vmbr0 stanza only (between vmbr0 start and next blank line or next iface)
  if ! awk '
    /^iface[[:space:]]+vmbr0[[:space:]]+inet[[:space:]]+/ { in_vmbr=1; next }
    in_vmbr && /^[[:space:]]*hwaddress[[:space:]]+ether/ { found=1; exit 0 }
    in_vmbr && (/^[[:space:]]*$/ || /^iface[[:space:]]+/ || /^auto[[:space:]]+/) { exit 1 }
    END { exit (found ? 0 : 1) }
  ' "$IFCFG"; then
    sed -i "/^iface vmbr0 inet static/a\        hwaddress ether ${VMAC}" "$IFCFG"
  fi
  
  ifreload -a || true
  sleep 2
  ip link set "$new_usb_if" up || true
  ifreload -a || true
  sleep 1
fi

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
  echo "USB configuration mode:"
  if usb_dev="$(find_realtek_usb_device)"; then
    config=$(cat "$usb_dev/bConfigurationValue" 2>/dev/null || echo "unknown")
    echo "  RTL8157 config: $config (should be 1 for r8152 mode)"
  else
    echo "  RTL8157 device not found"
  fi
  echo
  echo "Initramfs modules (r8152 embedded):"
  grep -E '^\s*r8152(\s|$)' /etc/initramfs-tools/modules 2>/dev/null || echo "  (not embedded)"
  echo
  echo "Initramfs blacklist verification:"
  if command -v lsinitramfs >/dev/null 2>&1; then
    if lsinitramfs "/boot/initrd.img-$KREL" 2>/dev/null | grep 'modprobe.d/99-rtl815x-usb-blacklist.conf' >/dev/null; then
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
