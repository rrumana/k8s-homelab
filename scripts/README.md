# k8s-homelab Scripts

This directory contains utility scripts for managing your k8s-homelab cluster.

## 🔄 reboot.sh - Graceful Cluster Reboot Script

A comprehensive script for performing graceful maintenance reboots of your k3s cluster with proper Kubernetes cleanup, Longhorn storage synchronization, and ArgoCD verification.

### ✨ Features

- **Safety First**: Multiple confirmation prompts and comprehensive health checks
- **Kubernetes-Aware**: Proper pod eviction and node cordoning
- **Longhorn Integration**: Waits for volume detachment and verifies storage health
- **ArgoCD Verification**: Checks application sync status before proceeding
- **Comprehensive Logging**: Detailed timestamped logs with color-coded output
- **Dry-Run Mode**: Test the script logic without actually rebooting
- **Error Handling**: Automatic rollback on failures with cleanup mechanisms
- **Configurable Timeouts**: Customizable grace periods and force timeouts

### 🚀 Usage

```bash
# Standard graceful reboot
sudo ./reboot.sh

# Test run without actual reboot
sudo ./reboot.sh --dry-run

# Custom timeout settings
sudo ./reboot.sh --grace-period 60 --force-timeout 180

# Show help
./reboot.sh --help
```

### 📋 Options

| Option | Description | Default |
|--------|-------------|---------|
| `--grace-period SECONDS` | Pod termination grace period | 30 seconds |
| `--force-timeout SECONDS` | Force deletion timeout | 120 seconds |
| `--dry-run` | Show what would be done without executing | false |
| `--help` | Show usage information | - |

### 🔍 Execution Sequence

The script follows a carefully orchestrated sequence:

1. **Prerequisites Check**
   - Verify root privileges
   - Check kubectl connectivity
   - Validate cluster access

2. **User Confirmation**
   - Display warning messages
   - Show configuration settings
   - Require explicit confirmation

3. **Health Verification**
   - Check cluster node status
   - Verify pod health across namespaces
   - Validate system resources

4. **ArgoCD Sync Check**
   - Verify application sync status
   - Warn about out-of-sync applications
   - Optional continuation prompt

5. **Longhorn Storage Health**
   - Check storage system status
   - Verify volume health and robustness
   - Validate manager pod status

6. **Graceful Shutdown Sequence**
   - Cordon node to prevent new scheduling
   - Evict user pods with grace periods
   - Force delete remaining pods after timeout
   - Wait for Longhorn volume detachment

7. **System Cleanup**
   - Stop k3s services gracefully
   - Kill remaining k3s processes
   - Sync filesystems and flush buffers
   - Perform final verification

8. **Reboot Execution**
   - Log final status
   - Execute system reboot

### 📊 Logging

The script creates detailed logs in `/var/log/k8s-homelab/` with timestamps and color-coded output:

- **INFO** (Green): Normal operations and status updates
- **WARN** (Yellow): Warnings that don't block execution
- **ERROR** (Red): Critical errors that stop execution
- **STEP** (Blue): Major execution phases
- **SUCCESS** (Green): Successful completion of operations
- **DRY-RUN** (Purple): Actions that would be performed in dry-run mode

### ⚠️ Important Notes

#### Prerequisites
- Must be run as root or with sudo privileges
- Requires kubectl to be installed and configured
- Cluster must be accessible and healthy
- Recommended to backup critical data before running

#### Safety Features
- Multiple confirmation prompts prevent accidental execution
- Dry-run mode allows testing without actual reboot
- Automatic node uncordoning on script interruption
- Comprehensive error handling with cleanup

#### Timeout Configuration
- **Grace Period**: Time allowed for pods to terminate gracefully (min: 10s)
- **Force Timeout**: Time before force-deleting remaining pods (min: 30s)
- **Longhorn Wait**: Maximum time to wait for volume detachment (default: 60s)
- **ArgoCD Wait**: Time to wait for application sync (default: 5 minutes)

### 🛠️ Troubleshooting

#### Common Issues

**Script fails with "kubectl not found"**
```bash
# Ensure kubectl is in PATH
which kubectl
# If not found, add to PATH or install kubectl
```

**Permission denied errors**
```bash
# Run with sudo
sudo ./reboot.sh
```

**Pods fail to evict gracefully**
- Check pod disruption budgets
- Verify application health before reboot
- Consider increasing grace period: `--grace-period 60`

**Longhorn volumes won't detach**
- Check volume usage by other pods
- Verify Longhorn system health
- Review volume attachment status in Longhorn UI

**ArgoCD applications out of sync**
- Sync applications manually before reboot
- Review application configurations
- Check for pending changes in Git repository

#### Log Analysis

Check the latest log file for detailed execution information:
```bash
# View latest log
sudo tail -f /var/log/k8s-homelab/reboot-*.log

# List all reboot logs
sudo ls -la /var/log/k8s-homelab/reboot-*.log
```

### 🔄 Recovery Procedures

If the script is interrupted or fails:

1. **Check node cordon status**
   ```bash
   kubectl get nodes
   # If cordoned, uncordon manually
   kubectl uncordon $(hostname)
   ```

2. **Verify pod status**
   ```bash
   kubectl get pods --all-namespaces
   # Restart any pods in problematic states
   ```

3. **Check Longhorn volumes**
   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system
   # Verify volume states and attachments
   ```

4. **Review logs**
   ```bash
   sudo tail -50 /var/log/k8s-homelab/reboot-*.log
   ```

### 🧪 Testing

Always test the script before using in production:

```bash
# Test without actual reboot
sudo ./reboot.sh --dry-run

# Check help output
./reboot.sh --help

# Verify script permissions
ls -la reboot.sh
```

### 📝 Version History

- **v1.0.0**: Initial release with comprehensive graceful reboot functionality
  - Full k3s cluster support
  - Longhorn storage integration
  - ArgoCD sync verification
  - Dry-run mode
  - Comprehensive error handling

### 🤝 Contributing

When modifying the script:
1. Test thoroughly with `--dry-run` mode
2. Update documentation for any new features
3. Maintain backward compatibility
4. Add appropriate logging for new functionality

### 📄 License

This script is part of the k8s-homelab project and follows the same licensing terms.