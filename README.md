# Shell Auto-ASPM

**Automatic PCIe ASPM (Active State Power Management) enabler - Pure shell script, no Python dependency**

## Overview

Enable PCIe Active State Power Management (ASPM) on compatible devices to reduce system power consumption. The script scans PCIe devices, and enables supported ASPM link states (L0s/L1) in device configuration space. It does not change CPU governors or BIOS settings.


## Requirements

- **Linux system** (any distribution)
- **Root privileges** (sudo access)
- **pciutils** installed (`lspci`, `setpci` commands)
  ```bash
  # Install on Ubuntu/Debian:
  sudo apt install pciutils
  
  # Install on RHEL/CentOS/Fedora:  
  sudo dnf install pciutilsshell-auto-aspm
  ```

## Quick Start

```bash

# 1. Make scripts executable
chmod +x autoaspm.sh 

# 2. Preview what will be changed (safe, no modifications)
sudo ./autoaspm.sh --dry-run

# 3. Apply ASPM settings
sudo ./autoaspm.sh

## Persistence (run at boot)

ASPM register writes performed by this script are runtime-only and do not persist across reboot. To apply ASPM automatically at boot, create a systemd unit using the provided sample `autoaspm.service.sample`.

Example steps to install the unit:

```bash
# Copy the script to a safe location
sudo cp autoaspm.sh /usr/local/bin/autoaspm.sh
sudo chmod +x /usr/local/bin/autoaspm.sh

# Install sample systemd unit
sudo cp autoaspm.service.sample /etc/systemd/system/auto-aspm.service
sudo systemctl daemon-reload
sudo systemctl enable --now auto-aspm.service
```

Notes:
- If some PCIe devices are not probed by the time the unit runs, add a small delay with `ExecStartPre=/bin/sleep 3` or tune `After=` to wait for relevant services. Alternatively, run the script from a udev rule when devices appear.
- Test with `--dry-run` before enabling the unit.

## Expected Results

### Power Savings
- **Laptops**: 5-15% battery life improvement in typical usage
- **Desktops**: 5-10W reduction in idle power consumption  
- **Servers**: Varies by workload, significant for low-utilization systems

### Performance Impact
- **Negligible**: ASPM only activates during idle periods
- **Latency**: Microsecond-level increase in PCIe wake-up time
- **Throughput**: No impact on sustained data transfer rates

### Compatibility
- **Modern systems** (2015+): Excellent compatibility
- **Older systems**: May have limited ASPM support
- **Specific hardware**: Some devices may not support all ASPM modes

## Troubleshooting

### Common Issues

**"No PCIe devices with ASPM support found"**
```bash
# Check if devices actually support ASPM
sudo lspci -vv | grep -i aspm
# If empty, your hardware may not support ASPM
```

**"Permission denied" / "Access denied"**
```bash
# Ensure running with root privileges
sudo ./autoaspm.sh --dry-run
```

**"lspci/setpci not detected"**
```bash
# Install pciutils package
sudo apt install pciutils          # Ubuntu/Debian
sudo dnf install pciutils          # Fedora/RHEL
```

### Recovery Procedures

**System instability after changes (rare)**
```bash

# Method 1: Reboot (resets to BIOS defaults)
sudo reboot

# Method 2: Disable ASPM via kernel parameter
# Add to GRUB: pcie_aspm=off
```

**Boot issues (super rare)**
```bash
# Boot with kernel parameter to disable ASPM
# In GRUB, add: pcie_aspm=off pci=noaer
```

## Frequently Asked Questions

### **Q: Do I have to run this after every reboot?**
**A: Yes, ASPM changes are runtime-only and reset on reboot.**

PCIe register modifications don't persist across reboots. You have several options:

**Option 1: Create a systemd service (recommended)**
```bash
# Create service file
sudo tee /etc/systemd/system/auto-aspm.service << EOF
[Unit]
Description=Enable PCIe ASPM power management
After=network.target

[Service]
Type=oneshot
ExecStart=/path/to/your/autoaspm.sh
User=root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable auto-aspm.service
sudo systemctl start auto-aspm.service
```

**Option 2: Add to startup scripts**
```bash
# Add to /etc/rc.local (if available)
/path/to/your/autoaspm.sh

# Or add to cron
echo "@reboot root /path/to/your/autoaspm.sh" | sudo tee -a /etc/crontab
```

### **Q: Are we just enabling ASPM, or setting it to powersave mode?**
**A: We enable ASPM hardware capability, not changing power profiles.**

The script enables ASPM at the **hardware register level** by:
- Setting the ASPM Control field in PCIe Link Control registers
- Allowing devices to enter L0s and L1 power states during idle periods
- This is **independent** of system power profiles (powersave/performance)

**What this means:**
- Enables hardware power management features that are often disabled by default
- Allows PCIe links to automatically save power when not actively transferring data

**What this doesn't mean:**
- Does NOT change CPU frequency scaling or system performance profiles
- Does NOT modify Linux power governors or system power policies

### **Q: Is this safe? What are the risks?**
**A: Generally safe, but some devices may have compatibility issues. Serious issues are rare and can be solved with troubleshooting steps above**

### **Q: How much power savings should I expect?**
**A: Typically 5-15% system power reduction, varies by hardware.**

**Factors affecting savings:**
- **PCIe device types**: Graphics cards, WiFi, storage controllers have different impact
- **System workload**: More apparent during idle or light usage
- **Hardware generation**: Newer devices generally have better ASPM implementation
- **Device usage patterns**: Devices that frequently idle see more benefit

### **Q: My system crashed/hung after enabling ASPM. How do I recover?**
**A: Reboot or disable via kernel parameter.**

#### **Disable the systemd unit or other boot application of it**

**Method 1: Reboot**

**Method 2: Kernel parameter (if system won't boot normally)**
```bash
# Add to kernel command line during boot
pcie_aspm=off

# Or disable ASPM in BIOS/UEFI if available
```

## License

This project is released under the BSD 3-Clause License ("New BSD"). See the full text in the [LICENSE](./LICENSE) file in this repository.

This software doesn't come with any guarentees and [Author](https://github.com/jolness1) accepts no liability. The script is designed to be safe and uses built-in PCIe power management functions but any issues are the sole responsibility of the end-user. 

## Credits

- **Original bash script**: Luis R. Rodriguez
- **Python rewrite**: z8
- **Automatic device detection**: notthebee  
- **Shell conversion to avoid more dependencies**: This project

## Additional Resources

- [PCIe ASPM Documentation](https://www.kernel.org/doc/Documentation/power/pci.rst)
- [PowerTOP for power analysis](https://01.org/powertop)
- [PCIe Base Specification](https://pcisig.com/specifications)
- [Linux PCIe Power Management](https://www.kernel.org/doc/html/latest/power/pci.html)
