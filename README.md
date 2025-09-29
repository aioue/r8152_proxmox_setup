One-shot, safe installer for Realtek r8152 DKMS on Proxmox VE 9 (Secure Boot aware)

Uses [awesometic](https://github.com/awesometic/realtek-r8152-dkms/) package.

If you move to kernels ≥ 6.16 and hit API changes, consider the [wget fork](https://github.com/wget/realtek-r8152-linux) of r8152 DKMS. With MOK already enrolled, it should load cleanly as well.
