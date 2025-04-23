# 🚀 ESXi Upgrade Readiness Check

[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![VMware PowerCLI](https://img.shields.io/badge/VMware-PowerCLI-green.svg)](https://developer.vmware.com/powercli)
[![Made with PowerShell](https://img.shields.io/badge/Made%20with-PowerShell-1f425f.svg)](https://github.com/yourusername)

> 🔍 Comprehensive assessment tool for ESXi host upgrade readiness with detailed reporting and recommendations!

---

## ✨ Features

🏗️ **Comprehensive Analysis**
- CPU compatibility verification
- Storage capacity assessment
- Upgrade path determination
- System readiness evaluation

📊 **Advanced Reporting**
- Interactive HTML reporting with filtering
- Detailed CSV export for data analysis
- Clear status categorization
- Actionable upgrade recommendations

🔄 **Efficient Processing**
- Parallel host processing
- Configurable concurrency
- Progress tracking
- Detailed logging and error handling

🛡️ **Version Intelligence**
- Precise version and build tracking
- Target version specification
- Upgrade path validation
- Already up-to-date detection

## 🎯 Prerequisites

Before you begin your upgrade assessment, ensure you have:

- 💻 PowerShell 5.1 or higher
- 🔌 VMware PowerCLI module installed
- 🔑 ESXi host credentials with administrative access
- 📄 (Optional) CSV file with host inventory

## 🚀 Quick Start

### 1️⃣ Setup

<details>
<summary>Click to expand PowerCLI setup instructions</summary>

#### Install PowerCLI 🔌
```powershell
# Install VMware PowerCLI module if not already installed
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
```

#### Configure PowerCLI Settings 🔧
```powershell
# Set PowerCLI configuration
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false
```
</details>

### 2️⃣ Configuration

Create a `config.json` file in the same directory as the script:

<details>
<summary>Click to see full config.json template</summary>

```json
{
    "Username": "administrator@vsphere.local",
    "Password": "YourSecurePassword",
    "TargetESXiVersion": "8.0.3",
    "MinimumRequiredSpaceGB": 10,
    "MinimumBootbankFreePercentage": 90
}
```
</details>

### 3️⃣ Run the Assessment

```powershell
# Check specific servers
.\ESXi-Upgrade-ReadinessCheck.ps1 -Servers "esxi01.domain.com","esxi02.domain.com"

# Check servers from CSV file with parallel processing
.\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -Parallel -MaxConcurrentJobs 10
```

## ⚙️ Usage Options

```powershell
# Show help and parameter information
.\ESXi-Upgrade-ReadinessCheck.ps1 -Help

# Check specific ESXi hosts
.\ESXi-Upgrade-ReadinessCheck.ps1 -Servers "esxi01.domain.com","esxi02.domain.com"

# Process hosts from CSV file
.\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv"

# Specify output locations
.\ESXi-Upgrade-ReadinessCheck.ps1 -Servers "esxi01.domain.com" -OutputCsv "results.csv" -ReportPath "report.html"

# Process multiple hosts in parallel
.\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -Parallel -MaxConcurrentJobs 10

# Specify target ESXi version
.\ESXi-Upgrade-ReadinessCheck.ps1 -ServerListFile "servers.csv" -UpgradeVersion "8.0.3"
```

## 📊 Report Output

The script produces two main outputs:

### 1️⃣ Interactive HTML Report
- Filterable host list
- Status categorization
- Detailed host information
- Visual status indicators
- Upgrade recommendations

![HTML Report Example](https://via.placeholder.com/800x400?text=HTML+Report+Example)

### 2️⃣ Detailed CSV Export
- Complete assessment data
- Sortable and filterable in Excel
- Perfect for inventory management
- Integration with other systems

## 🔍 Host Categories

Hosts are categorized for easy assessment:

- ✅ **Ready for Upgrade**: Meets all requirements
- 🔄 **Already Up-To-Date**: Running target version
- ❌ **CPU Incompatible**: CPU not supported
- ⚠️ **Storage Issues**: Insufficient space
- 🔄 **Requires Intermediate Upgrade**: Multi-step upgrade needed
- ❓ **Multiple Issues**: Multiple requirements not met
- ⚠️ **Failed to Check**: Connection or assessment error

## 🛠️ Troubleshooting

<details>
<summary>🔌 Connection Issues</summary>

- ✓ Verify hostname/IP is correct
- ✓ Check network connectivity
- ✓ Verify credentials
- ✓ Ensure ESXi host is online
- ✓ Check firewall rules
</details>

<details>
<summary>📈 Performance Issues</summary>

- ✓ Reduce MaxConcurrentJobs
- ✓ Check host resource utilization
- ✓ Process smaller batches of hosts
</details>

<details>
<summary>📋 CSV Import Issues</summary>

- ✓ Verify CSV format
- ✓ Ensure "Host Name" column exists
- ✓ Check for valid ESXi hostnames
</details>

## 📜 Security Considerations

- 🔒 Store credentials securely
- 🔑 Use least-privilege accounts
- 📝 Review logs regularly
- 🔐 Don't hardcode credentials in script

## 📋 License

This project is made available under the MIT License.

## 💬 Support

Have questions or feedback? Found a bug? Please open an issue in the repository.

---

<p align="center">
Made with ❤️ for VMware administrators
</p>

---

<p align="center">
⭐ Star this repository if you find it helpful! ⭐
</p>
