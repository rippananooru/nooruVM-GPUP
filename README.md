# rippananooru-GPUP

Windows utilities for:

* GPU-P setup and Code 43 repair
* USB/IP device sharing and mounting

## Requirements

* Windows 10/11 Pro
* PowerShell
* Administrator access
* Hyper-V + GPU-P capable GPU for GPU-P
* `usbipd-win` on the USB/IP host
* `usbip-win2` on the USB/IP client
* Network/Tailscale connectivity between host and client

> **GPU-P has only been tested with AMD GPUs.**

> For USB/IP, keep the **entire `rippananooru-GPUP` folder on both machines**.

<!-- ## Structure

```text
nooruVM-GPUP\
├── Add-GPUP.cmd
├── scripts\
│   ├── Add-GPUP-Addconfig.ps1
│   ├── Add-GPUP.ps1
│   ├── Repair-GPUP-Code43.ps1
│   ├── Get-GPUPStatus.ps1
│   ├── USBIP-HOST.ps1
│   └── USBIP-MOUNT.ps1
└── config\
    ├── gpup.example.xml
    ├── usbip.example.xml
    ├── gpup.xml
    └── usbip.xml
``` -->
