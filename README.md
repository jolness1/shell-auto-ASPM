# Shell Auto-ASPM

**_Now with 50% less dependencies!_**

## Requirements

- **Linux system** (any distribution - tested on Alpine, Debian and Arch)
- **Root privileges** (sudo access)
- **pciutils** installed (`lspci`, `setpci` commands)
  ```bash
  # Install on Ubuntu/Debian:
  sudo apt install pciutils
  
  # Install on RHEL/CentOS/Fedora:  
  sudo dnf install pciutils
  ```

## Quick Start

```bash
# 1. Make script executable
chmod +x autoaspm.sh 

# 2. Optional: Preview what will be changed (safe, no modifications)
sudo ./autoaspm.sh --dry-run

# 3. Apply ASPM settings
sudo ./autoaspm.sh
```

## Frequently Asked Questions

### **Q: Why not just use [AutoASPM](https://github.com/notthebee/AutoASPM) from Wolfgang?**
**A: There is nothing wrong with the python `autoaspm` script but I _try_ to avoid unneccesary packages. I am fine with essentials but having to install python when this is achievable via shell scripting is something I wanted to avoid.** 

### **Q: Do I have to run this after every reboot?**
**A: Yes, ASPM changes are runtime-only and reset on reboot.**

PCIe register modifications don't persist across reboots. You have several options — the two simplest are:

**Option 1: Create a systemd service (recommended)**

To apply ASPM automatically at boot, create a systemd unit using the provided sample `autoaspm.service.sample`.

Example steps to install the unit:

```bash
# Copy the autoaspm script to a safe location
sudo cp autoaspm.sh /usr/local/bin/autoaspm.sh
sudo chmod +x /usr/local/bin/autoaspm.sh

# Copy sample systemd unit to directory 
sudo cp autoaspm.service.sample /etc/systemd/system/auto-aspm.service

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

### **Q: How much power savings should I expect?**
**A: Typically 5-15% system power reduction, varies by hardware.**

**Factors affecting savings:**
- **PCIe device types**: Graphics cards, WiFi, storage controllers have different impact
- **System workload**: More apparent during idle or light usage
- **Hardware generation**: Newer devices generally have better ASPM implementation
- **Device usage patterns**: Devices that frequently idle see more benefit

## License

This project is released under the BSD 3-Clause License ("New BSD"). See the full text in the [LICENSE](./LICENSE) file in this repository.

## Credits

- **Original bash script**: [Luis R. Rodriguez](http://ftp.dei.uc.pt/pub/linux/kernel/people/mcgrof/aspm/enable-aspm)
- **Python rewrite**: [z8](https://github.com/0x666690/ASPM)
- **Automatic device detection**: [notthebee](https://github.com/notthebee/AutoASPM)  
- **Back in Bash**: [Jacob Olness](https://github.com/jolness1/shell-auto-ASPM)

## Additional Resources

- [PCIe ASPM Documentation](https://www.kernel.org/doc/Documentation/power/pci.rst)
- [Linux PCIe Power Management](https://www.kernel.org/doc/html/latest/power/pci.html)
- [PowerTOP for easy power savings and analysis](https://github.com/fenrus75/powertop)
- [PCIe Base Specification](https://pcisig.com/specifications)