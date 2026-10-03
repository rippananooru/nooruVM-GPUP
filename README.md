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

## USB/IP Host

Run:

```text
USBIP-HOST.cmd
```

The script:

1. Checks for `usbipd-win`
2. Installs it if required
3. Detects the host's Tailscale IPv4 address
4. Detects shared USB devices
5. Writes the current host information to:

```text
config\usbip-host.xml
```

The XML contains information such as:

* Host name
* Tailscale IPv4 address
* USB/IP port
* Last-seen timestamp
* Exported USB devices

### Important

`config\usbip-host.xml` is a runtime-generated file and should **not** be committed to Git.

---

## USB/IP Mount

Run:

```text
USBIP-MOUNT.cmd
```

The script:

1. Reads the USB/IP host information from `config\usbip-host.xml`
2. Checks connectivity to TCP port `3240`
3. Queries the host for exported USB devices
4. Displays the available devices
5. Lets the user select a device
6. Attaches the selected device
7. Allows another device to be attached

The mount script does **not** modify the host configuration.

---

# GPU-P Code 43 Repair

## What it does

Hyper-V GPU-P can sometimes result in the guest GPU appearing with **Code 43** after a host restart or driver-related change.

This utility repairs the VM by copying the host's AMD GPU-P driver package into the guest's:

```text
Windows\System32\HostDriverStore\FileRepository
```

The basic workflow is:

```text
Stop VM
   │
   ▼
Mount VHDX
   │
   ▼
Locate Windows partition
   │
   ▼
Copy GPU driver package
   │
   ▼
Dismount VHDX
   │
   ▼
Start VM
```

## Running the repair

Run:

```text
Repair-GPUP-code43.cmd
```

The script requires Administrator privileges.

---

## VM Configuration

The GPU-P repair script first checks:

```text
config\gpu-p-repair.xml
```

If the file exists and contains the required values, those values are used automatically.

Example:

```xml
<?xml version="1.0" encoding="utf-8"?>
<GPUPRepair>
  <VMName>MyGamingVM</VMName>
  <VHDXPath>D:\VMs\MyGamingVM\MyGamingVM.vhdx</VHDXPath>
</GPUPRepair>
```

If the configuration file is missing or incomplete, the script asks the user for:

```text
Hyper-V VM name
VHDX path
```

This allows the same script to work on different machines without modifying the PowerShell file.

### Example configuration

A template is included:

```text
config\gpu-p-repair.example.xml
```

Copy it to:

```text
config\gpu-p-repair.xml
```

and change the values for your machine.

The personal configuration file is ignored by Git.

---

## Driver Package

The repair script expects the required GPU driver package to exist in the host's Windows DriverStore.

For example:

```text
C:\Windows\System32\DriverStore\FileRepository\<driver-package>
```

The exact driver package name is intentionally defined in the script so that the repair uses a known driver package rather than selecting an arbitrary package from the DriverStore.

If the required driver package is not present, the script stops instead of copying an unknown package.

---

# Configuration and Git

Personal configuration files are excluded from the repository:

```gitignore
config/usbip-host.xml
config/gpu-p-repair.xml
```

The repository therefore contains only reusable scripts and configuration examples.

Recommended structure:

```text
USBIP/
│
├── config/
│   └── gpu-p-repair.example.xml
│
├── USBIP-HOST.cmd
├── USBIP-HOST.ps1
│
├── USBIP-MOUNT.cmd
├── USBIP-MOUNT.ps1
│
├── Repair-GPUP-code43.cmd
└── Repair-GPUP-code43.ps1
```

Local-only files:

```text
config/
├── usbip-host.xml
└── gpu-p-repair.xml
```

These files should remain uncommitted.

---

# Security Notes

The scripts do not require passwords, API keys, tokens, or private keys.

USB/IP traffic uses TCP port `3240`. It should preferably be used over a trusted network or VPN such as Tailscale rather than exposing the USB/IP service directly to the public Internet.

The generated USB/IP configuration may contain:

* Machine name
* Tailscale IP address
* USB device information

For that reason, the runtime XML file is excluded from Git.

---

# Disclaimer

These scripts perform administrative operations on Windows, Hyper-V virtual machines, virtual disks, GPU drivers, and USB devices.

In particular, the GPU-P repair script intentionally stops the VM and mounts its VHDX directly. Make sure the VM is not performing important work before running the repair.

Use the scripts at your own discretion and verify your VM and driver configuration before making changes.
