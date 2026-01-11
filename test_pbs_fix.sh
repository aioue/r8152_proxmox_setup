#!/bin/bash

# PBS Compatibility DKMS Build Fix Script
# This script attempts to install missing dependencies and retry the DKMS build
# for PBS (Proxmox Backup Server) compatibility with r8152 driver

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

log_info "Starting PBS compatibility DKMS build fix"
log_info "Current date/time: $(date)"

# Step 1: Update package lists
log_info "Updating package lists..."
apt-get update || log_warning "apt-get update encountered issues"

# Step 2: Install essential build dependencies
log_info "Installing essential build dependencies..."
DEPENDENCIES=(
    "build-essential"
    "linux-headers-$(uname -r)"
    "dkms"
    "gcc"
    "make"
    "perl"
    "pkg-config"
)

for dep in "${DEPENDENCIES[@]}"; do
    log_info "Installing $dep..."
    if apt-get install -y "$dep" 2>&1 | grep -q "Unable to locate package"; then
        log_warning "Package $dep not found in repositories"
    else
        log_success "Successfully processed $dep"
    fi
done

# Step 3: Check for kernel headers mismatch
log_info "Checking kernel configuration..."
KERNEL_VERSION=$(uname -r)
HEADERS_PATH="/usr/src/linux-headers-${KERNEL_VERSION}"

if [ ! -d "$HEADERS_PATH" ]; then
    log_warning "Kernel headers not found at $HEADERS_PATH"
    log_info "Attempting to install correct headers..."
    apt-get install -y "linux-headers-${KERNEL_VERSION}" || log_warning "Could not install matching headers"
else
    log_success "Kernel headers found at $HEADERS_PATH"
fi

# Step 4: Verify DKMS is installed and functional
log_info "Verifying DKMS installation..."
if command -v dkms &> /dev/null; then
    log_success "DKMS is installed"
    dkms --version || log_warning "Could not verify DKMS version"
else
    log_error "DKMS is not installed"
    exit 1
fi

# Step 5: Find r8152 module if present
log_info "Searching for r8152 DKMS module..."
if dkms status | grep -i r8152 > /dev/null 2>&1; then
    log_success "r8152 module found in DKMS"
    
    # Step 6: Attempt to rebuild the module
    log_info "Attempting to rebuild r8152 module..."
    
    MODULE_VERSION=$(dkms status | grep -i r8152 | head -1 | cut -d',' -f2 | xargs)
    
    if [ -z "$MODULE_VERSION" ]; then
        log_warning "Could not determine r8152 module version"
    else
        log_info "Found r8152 version: $MODULE_VERSION"
        
        log_info "Removing previous build artifacts..."
        dkms remove -m r8152 -v "$MODULE_VERSION" -k "$KERNEL_VERSION" --all || log_warning "dkms remove encountered issues"
        
        log_info "Adding module back to DKMS..."
        dkms add -m r8152 -v "$MODULE_VERSION" || log_warning "dkms add encountered issues"
        
        log_info "Building module for kernel $KERNEL_VERSION..."
        if dkms build -m r8152 -v "$MODULE_VERSION" -k "$KERNEL_VERSION"; then
            log_success "Module build successful"
            
            log_info "Installing module..."
            if dkms install -m r8152 -v "$MODULE_VERSION" -k "$KERNEL_VERSION"; then
                log_success "Module installation successful"
            else
                log_error "Module installation failed"
                exit 1
            fi
        else
            log_error "Module build failed"
            exit 1
        fi
    fi
else
    log_warning "r8152 module not found in DKMS"
    log_info "Ensure the r8152 module is properly registered in DKMS"
fi

# Step 7: Verify module is loaded
log_info "Verifying module status..."
if lsmod | grep -i r8152 > /dev/null 2>&1; then
    log_success "r8152 module is currently loaded"
else
    log_warning "r8152 module is not currently loaded"
    log_info "Attempting to load module..."
    modprobe r8152 || log_warning "Could not load r8152 module"
fi

# Step 8: Summary and PBS compatibility check
log_info "====== PBS Compatibility Build Fix Summary ======"
log_info "Kernel version: $KERNEL_VERSION"
log_info "DKMS status:"
dkms status | grep -i r8152 || echo "  No r8152 entries found"
log_info "Loaded modules:"
lsmod | grep -i r8152 || echo "  r8152 not currently loaded"

log_success "PBS compatibility DKMS build fix script completed"
log_info "If build still fails, check system logs with: journalctl -xe"
