One-shot, safe installer for Realtek r8152 DKMS on Proxmox VE 9 (Secure Boot aware).

Gets USB dongles like the Wisdpi WP-UT5 (RTL8157) 5GbE running cleanly on PVE 9 using the [awesometic](https://github.com/awesometic/realtek-r8152-dkms/) r8152 DKMS driver (`.deb` package), with Secure Boot MOK enrollment and automatic cdc_* blacklisting.

If you move to kernels ≥ 6.16 and hit API changes, consider the [wget fork](https://github.com/wget/realtek-r8152-linux) of r8152 DKMS. With MOK already enrolled, it should load cleanly as well.

<details>
  <summary>Script output</summary>
  ```bash
  # ./r8152_proxmox_setup.sh 

  ==> Proxmox r8152 setup (kernel 6.14.11-2-pve)
      - Initial package path: /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
  
  ==> Local .deb not found: /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
      - Attempting to fetch latest awesometic release .deb from GitHub
      - Repo: https://github.com/awesometic/realtek-r8152-dkms
      - Query: https://api.github.com/repos/awesometic/realtek-r8152-dkms/releases/latest
      - jq not found; installing jq
      <snip apt sources, dependency resolution, and install output>
      - Latest .deb asset: https://github.com/awesometic/realtek-r8152-dkms/releases/download/2.20.1-1/realtek-r8152-dkms_2.20.1-1_amd64.deb
  
  ==> Downloading to /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
      <snip curl progress>
      - Using downloaded file: /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
  
  ==> Detecting existing interfaces
      lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP> 
      enp3s0           UP             <MAC_1> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      wlp4s0           DOWN           <MAC_2> <BROADCAST,MULTICAST> 
      vmbr0            UP             <MAC_3> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      <IF_EN_USB>      UP             <MAC_3> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      - USB Realtek interface not currently bound (will probe after install).
  
  ==> Ensuring vmbr0 can use enp3s0 during driver switch
      - vmbr0 current bridge-port: <IF_EN_USB>
  
  ==> Temporarily switching vmbr0 bridge-port to enp3s0 for safety
      lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP> 
      enp3s0           UP             <MAC_1> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      wlp4s0           DOWN           <MAC_2> <BROADCAST,MULTICAST> 
      vmbr0            UP             <MAC_3> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      <IF_EN_USB>      UP             <MAC_3> <BROADCAST,MULTICAST,UP,LOWER_UP> 
  
  ==> Installing headers, DKMS, and the r8152 DKMS package
      <snip apt output showing packages already installed>
  
  ==> Verifying DKMS installation
  realtek-r8152/2.20.1, 6.14.11-2-pve, amd64: installed (Original modules exist)
  realtek-r8152/2.20.1, 6.14.11-2-pve, x86_64: built
      filename:       /lib/modules/6.14.11-2-pve/updates/dkms/r8152.ko
      version:        v2.20.1 (2025/05/13)
      license:        GPL
      description:    Realtek RTL8152/RTL8153 Based USB Ethernet Adapters
      author:         Realtek nic sw <nic_swsd@realtek.com>
      srcversion:     <snip>
      alias:          usb:<snip>
      alias:          usb:<snip>
  
  ==> Blacklisting competing drivers and updating initramfs
      <snip initramfs and grub generation output>
  
  ==> Checking Secure Boot/MOK status
      - Secure Boot enabled; DKMS MOK is enrolled.
  
  ==> Loading r8152 and preparing for device rebind
  
  ==> ACTION REQUIRED: Unplug and replug the Realtek USB 5G NIC now, then press Enter.
  Press Enter after replug...
  
  ==> Detecting the USB NIC and verifying binding
      /:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 480M
      /:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/2p, 10000M
          |__ Port 002: Dev 002, If 0, Class=Mass Storage, Driver=uas, 5000M
      /:  Bus 003.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 480M
          |__ Port 002: Dev 002, If 0, Class=Hub, Driver=hub/4p, 480M
              |__ Port 001: Dev 003, If 0, Class=Wireless, Driver=btusb, 12M
              |__ Port 001: Dev 003, If 1, Class=Wireless, Driver=btusb, 12M
      /:  Bus 004.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/2p, 10000M
          |__ Port 001: Dev 006, If 0, Class=Vendor Specific Class, Driver=r8152, 5000M
  
  ==> USB NIC bound to r8152 on interface: <IF_EN_USB>
      driver: r8152
      version: v2.20.1 (2025/05/13)
      firmware-version: 
      expansion-rom-version: 
      bus-info: <snip>
      supports-statistics: yes
      supports-test: no
      supports-eeprom-access: no
      supports-register-dump: no
      supports-priv-flags: no
  
  ==> Restoring vmbr0 bridge-port to <IF_EN_USB>
  
  ==> Summary
      Kernel: 6.14.11-2-pve
      Repo: https://github.com/awesometic/realtek-r8152-dkms
      Package used: /root/realtek-r8152-dkms_2.20.1-1_amd64.deb
      
      DKMS:
      realtek-r8152/2.20.1, 6.14.11-2-pve, amd64: installed (Original modules exist)
      realtek-r8152/2.20.1, 6.14.11-2-pve, x86_64: built
      
      USB tree:
      /:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 480M
      /:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/2p, 10000M
          |__ Port 002: Dev 002, If 0, Class=Mass Storage, Driver=uas, 5000M
      /:  Bus 003.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/4p, 480M
          |__ Port 002: Dev 002, If 0, Class=Hub, Driver=hub/4p, 480M
              |__ Port 001: Dev 003, If 0, Class=Wireless, Driver=btusb, 12M
              |__ Port 001: Dev 003, If 1, Class=Wireless, Driver=btusb, 12M
      /:  Bus 004.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/2p, 10000M
          |__ Port 001: Dev 006, If 0, Class=Vendor Specific Class, Driver=r8152, 5000M
      
      Interfaces:
      lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP> 
      enp3s0           UP             <MAC_1> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      wlp4s0           DOWN           <MAC_2> <BROADCAST,MULTICAST> 
      vmbr0            UP             <MAC_3> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      <IF_EN_USB>      UP             <MAC_3> <BROADCAST,MULTICAST,UP,LOWER_UP> 
      
      Bridge config (vmbr0):
      iface vmbr0 inet static
              hwaddress ether <MAC_3>
          hwaddress ether <MAC_3>
          address 192.168.1.129/24
          gateway 192.168.1.1
              bridge-ports <IF_EN_USB>
          bridge-stp off
          bridge-fd 0
      
      Driver details (<IF_EN_USB>):
      driver: r8152
      version: v2.20.1 (2025/05/13)
      firmware-version: 
      expansion-rom-version: 
      bus-info: <snip>
      supports-statistics: yes
      supports-test: no
      supports-eeprom-access: no
      supports-register-dump: no
      supports-priv-flags: no
      
      Link (<IF_EN_USB>):
      Settings for <IF_EN_USB>:
          Supported ports: [ MII ]
          Supported link modes:   10baseT/Half 10baseT/Full
                                  100baseT/Half 100baseT/Full
                                  1000baseT/Full
                                  2500baseT/Full
                                  5000baseT/Full
          Supported pause frame use: No
          Supports auto-negotiation: Yes
          Supported FEC modes: Not reported
          Advertised link modes:  10baseT/Half 10baseT/Full
                                  100baseT/Half 100baseT/Full
                                  1000baseT/Full
                                  2500baseT/Full
                                  5000baseT/Full
          Advertised pause frame use: No
          Advertised auto-negotiation: Yes
          Advertised FEC modes: Not reported
          Link partner advertised link modes:  100baseT/Half 100baseT/Full
                                               1000baseT/Full
                                               10000baseT/Full
                                               2500baseT/Full
                                               5000baseT/Full
          Link partner advertised pause frame use: No
          Link partner advertised auto-negotiation: Yes
          Link partner advertised FEC modes: Not reported
          Speed: 5000Mb/s
          Duplex: Full
          Auto-negotiation: on
          Port: MII
          PHYAD: 32
          Transceiver: internal
          Supports Wake-on: pumbg
          Wake-on: d
              Current message level: 0x00007fff (32767)
                                     drv probe link timer ifdown ifup rx_err tx_err tx_queued intr tx_done rx_status pktdata hw wol
          Link detected: yes
  
  ==> Done. Report saved to: /root/r8152_setup_report_<snip>.txt
      - If you later upgrade to kernels >= 6.16 and hit build issues, consider the wget r8152 DKMS fork (MOK already enrolled).
  root@pve:~#
  ```
</details>
