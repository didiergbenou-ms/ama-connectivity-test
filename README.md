# Azure Monitor Agent Connectivity Tests

A comprehensive set of tools to troubleshoot Azure Monitor Agent (AMA) connectivity issues on Linux systems.

## 🚀 Quick Start - Run from GitHub

```bash
# Interactive menu (choose your test)
curl -sSL https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install-and-run.sh | bash

# Quick connectivity test
curl -sSL https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install-and-run.sh | bash -s quick

# Comprehensive test (detailed diagnostics)
curl -sSL https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install-and-run.sh | bash -s comprehensive

# End-to-end data ingestion test
curl -sSL https://raw.githubusercontent.com/YOUR-USERNAME/YOUR-REPO/main/install-and-run.sh | bash -s data-sender
```

> **Note**: Replace `YOUR-USERNAME/YOUR-REPO` with your actual GitHub repository path

## 📋 What These Scripts Do

### 🔍 **Quick Test** (`quick-connectivity-test.sh`)
- ✅ Fast connectivity check (< 1 minute)
- ✅ Tests all configured AMA endpoints
- ✅ Simple pass/fail output
- ✅ Perfect for health monitoring

### 🔬 **Comprehensive Test** (`test-ama-connectivity.sh`)  
- ✅ Complete diagnostic analysis
- ✅ DNS, SSL, HTTP testing
- ✅ Proxy detection and support
- ✅ Multi-cloud environment detection (Gov/China)
- ✅ Detailed troubleshooting reports

### 🎯 **Data Sender Test** (`test-data-sender.sh`)
- ✅ End-to-end pipeline verification
- ✅ Sends actual test data to Log Analytics
- ✅ Verifies complete ingestion workflow
- ✅ Requires workspace ID and key

## 🛠️ Prerequisites

The installer automatically checks for required tools and provides installation instructions:

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install curl openssl jq dnsutils

# RHEL/CentOS/Fedora  
sudo yum install curl openssl jq bind-utils

# SLES
sudo zypper install curl openssl jq bind-utils
```

## 🔧 GitHub Setup Instructions

1. **Fork or create a repository** with these files
2. **Update the installer script**:
   - Edit `install-and-run.sh`
   - Change `YOUR-USERNAME/YOUR-REPO` to your repository path
3. **Upload all files** to your repository:
   - `install-and-run.sh` (main installer/runner)
   - `test-ama-connectivity.sh` (comprehensive test)
   - `quick-connectivity-test.sh` (quick test)
   - `test-data-sender.sh` (data ingestion test)
   - Documentation files

## 📊 Example Output

```bash
$ curl -sSL https://your-repo-url/install-and-run.sh | bash -s quick

Azure Monitor Agent - Quick Connectivity Test
==============================================
[INFO] Found 2 workspace(s), 3 region(s)

Global Handler                            PASS
Regional Handler (eastus)                 PASS  
Regional Handler (westus2)                PASS
Log Analytics (a1b2c3d4-e5f6-...)        PASS
Management Endpoint                       PASS

[SUCCESS] All endpoints are reachable!
```

## 📝 Verifying Test Data in Log Analytics

After running the data sender test, check Log Analytics with these queries:

```kusto
// Find your test messages
AMAConnectivityTest_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, Computer, TestMessage, Source

// Search across all tables  
search "AMA-ConnectivityTestScript"
| where TimeGenerated > ago(6h)
```

Expected data appears in 5-10 minutes after sending.

## 🌐 Supported Environments

- ✅ Azure Commercial (.com)
- ✅ Azure Government (.us) 
- ✅ Azure China (.cn)
- ✅ Proxy environments (authenticated & unauthenticated)
- ✅ All Linux distributions supported by AMA

## 🔍 Troubleshooting

| Issue | Quick Fix |
|-------|-----------|
| DNS failures | Check internet connectivity, DNS settings |
| SSL failures | Check firewall rules (port 443), proxy settings |
| Handler ping fails | Verify outbound HTTPS, check NSGs |
| No DCR configs | Ensure AMA is installed and configured |

## 📚 Files

- `install-and-run.sh` - GitHub installer/runner (interactive & command-line)
- `test-ama-connectivity.sh` - Comprehensive connectivity test  
- `quick-connectivity-test.sh` - Fast basic connectivity check
- `test-data-sender.sh` - End-to-end data ingestion test
- `AMA-CONNECTIVITY-TEST.md` - Detailed documentation
- `CONNECTIVITY-TESTING-README.md` - Complete reference guide

## 🤝 Contributing

These scripts are based on deep analysis of the Azure Monitor Agent source code. They replicate the same connectivity patterns the agent uses internally.

Areas for contribution:
- Additional cloud environment support
- Enhanced error reporting  
- New endpoint types as AMA evolves
- Integration with monitoring systems

## ⚡ Advanced Usage

```bash
# Download for offline use
curl -sSL https://your-repo-url/install-and-run.sh | bash -s download

# Custom data ingestion test
./test-data-sender.sh -w WORKSPACE_ID -k KEY -t MyCustomLog_CL -d '[{"msg":"test"}]'

# Comprehensive test with specific focus
sudo ./test-ama-connectivity.sh  # Detailed output and proxy detection
```

---

**Built for troubleshooting Azure Monitor Agent connectivity issues with confidence** 🚀