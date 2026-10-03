# Windows USB/IP & GPU-P Utilities

A small collection of PowerShell utilities for Windows Hyper-V and USB/IP workflows.

The scripts are designed to be portable and reusable across different machines. Personal machine configuration is kept outside the repository.

## Features

* Share USB devices from a Windows host using `usbipd-win`
* Discover and attach shared USB devices from another Windows machine
* Automatically use a Tailscale IPv4 address for the USB/IP host
* Store runtime USB/IP host information in a local XML configuration
* Repair Hyper-V GPU-P **Code 43** by copying the required GPU driver package into the VM's `HostDriverStore`
* Support custom Hyper-V VM names and VHDX paths without modifying the scripts

---

## Requirements

### USB/IP

**Host**

* Windows
* [usbipd-win](https://github.com/dorssel/usbipd-win)
* Tailscale or another reachable network between host and client
* TCP port `3240` reachable from the client

**Client**

* Windows
* [usbip-win2](https://github.com/vadimgrn/usbip-win2)
* Administrator privileges

The host and client do not need to be the same machine.

### GPU-P Code 43 Repair

* Windows with Hyper-V
* Administrator privileges
* A Hyper-V VM using GPU Partitioning (GPU-P)
* Access to the VM's VHDX
* The required GPU driver package installed on the Hyper-V host

---

# USB/IP

## Architecture

```text
Physical USB Device
        │
        ▼
Windows USB/IP Host
        │
        │ TCP 3240
        │
        ▼
Network / Tailscale
        │
        ▼
Windows VM / Client
        │
        ▼
USB/IP Device
```

The host is the machine physically connected to the USB device.

The client is the machine or VM that wants to use that device.

---

##
