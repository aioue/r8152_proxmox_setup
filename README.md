One-shot, safe installer for Realtek r8152 DKMS on Proxmox VE 9 (Secure Boot aware).

Gets USB dongles like the Wisdpi WP-UT5 (RTL8157) 5GbE running cleanly on PVE 9 using the [awesometic](https://github.com/awesometic/realtek-r8152-dkms/) r8152 DKMS driver (`.deb` package), with Secure Boot MOK enrollment and automatic cdc_* blacklisting.

If you move to kernels ≥ 6.16 and hit API changes, consider the [wget fork](https://github.com/wget/realtek-r8152-linux) of r8152 DKMS. With MOK already enrolled, it should load cleanly as well.
