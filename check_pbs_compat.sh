#!/bin/bash

##############################################################################
# check_pbs_compat.sh - Proxmox Backup Server Compatibility Diagnostic Tool
#
# Purpose: Perform a passive diagnosis of missing libraries and build 
#          dependencies on Proxmox Backup Server systems
#
# Usage: ./check_pbs_compat.sh
#
# This script checks for:
# - Required system libraries
# - Build tools and development headers
# - Kernel headers compatibility
# - Network driver dependencies
##############################################################################

set -o pipefail

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters for summary
PASSED=0
FAILED=0
WARNINGS=0

##############################################################################
# Helper Functions
##############################################################################

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

print_status() {
    local status=$1
    local message=$2
    
    if [ "$status" = "OK" ]; then
        echo -e "${GREEN}[✓]${NC} $message"
        ((PASSED++))
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}[✗]${NC} $message"
        ((FAILED++))
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}[⚠]${NC} $message"
        ((WARNINGS++))
    fi
}

check_command() {
    local cmd=$1
    local display_name=${2:-$cmd}
    
    if command -v "$cmd" &> /dev/null; then
        local version=$("$cmd" --version 2>&1 | head -n1)
        print_status "OK" "$display_name: $version"
        return 0
    else
        print_status "FAIL" "$display_name: NOT FOUND"
        return 1
    fi
}

check_package() {
    local package=$1
    local display_name=${2:-$package}
    
    if dpkg -l | grep -q "^ii  $package"; then
        local version=$(dpkg -l | grep "^ii  $package" | awk '{print $3}')
        print_status "OK" "$display_name (version: $version)"
        return 0
    else
        print_status "FAIL" "$display_name: NOT INSTALLED"
        return 1
    fi
}

check_library() {
    local lib=$1
    local display_name=${2:-$lib}
    
    if ldconfig -p | grep -q "$lib"; then
        local path=$(ldconfig -p | grep "$lib" | awk '{print $NF}')
        print_status "OK" "$display_name: $path"
        return 0
    else
        print_status "FAIL" "$display_name: NOT FOUND"
        return 1
    fi
}

check_header() {
    local header=$1
    local display_name=${2:-$header}
    
    if [ -f "/usr/include/$header" ]; then
        print_status "OK" "$display_name: found at /usr/include/$header"
        return 0
    else
        print_status "FAIL" "$display_name: NOT FOUND"
        return 1
    fi
}

check_file() {
    local file=$1
    local display_name=${2:-$file}
    
    if [ -f "$file" ]; then
        print_status "OK" "$display_name: exists"
        return 0
    else
        print_status "FAIL" "$display_name: NOT FOUND"
        return 1
    fi
}

##############################################################################
# System Information
##############################################################################

print_header "System Information"

# Get Proxmox version
if [ -f /etc/proxmox-release ]; then
    echo "Proxmox Release:"
    cat /etc/proxmox-release
    echo ""
fi

# Get kernel info
echo "Kernel Information:"
uname -r
echo ""

# Get OS info
echo "Operating System:"
cat /etc/os-release | grep "PRETTY_NAME"
echo ""

# Check if running on Proxmox Backup Server
if [ -f /etc/pbs-release ] || grep -q "Proxmox Backup" /etc/issue 2>/dev/null; then
    print_status "OK" "Proxmox Backup Server detected"
else
    print_status "WARN" "Proxmox Backup Server not definitively detected"
fi

##############################################################################
# Build Tools
##############################################################################

print_header "Build Tools and Compilers"

check_command "gcc" "GCC"
check_command "make" "Make"
check_command "pkg-config" "pkg-config"
check_command "curl" "curl"
check_command "wget" "wget"
check_command "git" "Git"
check_command "tar" "tar"

##############################################################################
# Development Headers and Libraries
##############################################################################

print_header "Development Headers and Libraries"

check_package "build-essential" "build-essential"
check_package "linux-headers-$(uname -r)" "Kernel headers (current)"
check_package "dkms" "DKMS"

check_header "linux/kernel.h" "Linux kernel headers"
check_header "linux/ethtool.h" "Ethtool headers"
check_header "linux/mii.h" "MII headers"
check_header "sys/socket.h" "Socket headers"

##############################################################################
# Common Libraries
##############################################################################

print_header "Common Required Libraries"

check_library "libc.so" "libc"
check_library "libpthread.so" "libpthread"
check_library "libm.so" "libm (math)"
check_library "libdl.so" "libdl (dynamic linker)"

##############################################################################
# Network and USB Related Libraries
##############################################################################

print_header "Network and USB Related Libraries"

check_library "libusb" "libusb"
check_library "libnl" "libnl (netlink)"
check_package "libusb-1.0-0-dev" "libusb development"

##############################################################################
# Package Manager and Utilities
##############################################################################

print_header "Package Manager and Utilities"

check_command "apt" "apt"
check_command "dpkg" "dpkg"
check_command "lsmod" "lsmod"
check_command "modprobe" "modprobe"
check_command "ethtool" "ethtool"

##############################################################################
# Kernel Module Environment
##############################################################################

print_header "Kernel Module Build Environment"

# Check if kernel module directory exists
if [ -d "/lib/modules/$(uname -r)" ]; then
    print_status "OK" "Kernel modules directory exists: /lib/modules/$(uname -r)"
else
    print_status "FAIL" "Kernel modules directory not found"
fi

# Check if kernel build directory exists
if [ -d "/lib/modules/$(uname -r)/build" ]; then
    print_status "OK" "Kernel build directory exists"
else
    print_status "FAIL" "Kernel build directory not found"
fi

# Check if kernel source directory exists
if [ -d "/lib/modules/$(uname -r)/source" ]; then
    print_status "OK" "Kernel source directory exists"
else
    print_status "WARN" "Kernel source directory not found (may be required for some builds)"
fi

# Check Kconfig and Makefile
check_file "/lib/modules/$(uname -r)/build/Makefile" "Kernel Makefile"
check_file "/lib/modules/$(uname -r)/build/Kconfig" "Kernel Kconfig"

##############################################################################
# R8152 Specific Dependencies
##############################################################################

print_header "R8152 Driver Specific Dependencies"

# Check for realtek driver existence
if lsmod | grep -q "r8152"; then
    print_status "OK" "R8152 driver currently loaded"
else
    print_status "WARN" "R8152 driver not currently loaded"
fi

# Check network interfaces
echo ""
echo "Available network interfaces:"
if command -v ip &> /dev/null; then
    ip link show | grep -E "^[0-9]+:" | grep -v "lo:"
else
    ifconfig 2>/dev/null | grep -E "^[a-z]" || echo "  (unable to list interfaces)"
fi

##############################################################################
# System Permissions
##############################################################################

print_header "System Permissions"

if [ "$EUID" -eq 0 ]; then
    print_status "OK" "Running as root"
else
    print_status "WARN" "Not running as root (some operations may require elevated privileges)"
fi

# Check if /dev/null is writable (basic permission test)
if [ -w /dev/null ]; then
    print_status "OK" "Device access available"
else
    print_status "FAIL" "Device access restricted"
fi

##############################################################################
# Optional but Recommended
##############################################################################

print_header "Optional but Recommended Tools"

check_command "dmesg" "dmesg"
check_command "lsusb" "lsusb"
check_command "lspci" "lspci"

##############################################################################
# Summary Report
##############################################################################

print_header "Diagnostic Summary"

TOTAL=$((PASSED + FAILED + WARNINGS))
echo "Total checks performed: $TOTAL"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ All checks passed! System appears compatible for r8152 driver compilation.${NC}"
    else
        echo -e "${YELLOW}⚠ Checks passed with minor warnings. System should be compatible, but verify warnings.${NC}"
    fi
else
    echo -e "${RED}✗ Some checks failed. System may not be fully compatible for r8152 driver compilation.${NC}"
    echo ""
    echo "Recommended actions:"
    echo "1. Run: sudo apt update && sudo apt upgrade"
    echo "2. Install build tools: sudo apt install build-essential linux-headers-\$(uname -r)"
    echo "3. For additional dependencies, check the installation documentation"
fi

echo ""
exit 0
