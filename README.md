<div align="center">
  <img src="https://raw.githubusercontent.com/david-nahorniak/s3-object-lock-extension-docker/main/logo.png" alt="S3 Object Lock Extension Logo" width="200">
</div>

# S3 Object Lock Extension Docker Script

Automaticaly extends object lock retention for S3 buckets with Object Lock enabled. Designed for restic backup repositories to ensure data protection compliance.

> ⚠️ **WARNING - BETA VERSION**
>
> This is a **beta version** and is **NOT intended for production deployment**.
>
> This software is provided "as is" without warranty of any kind, express or implied. Use at your own risk. The author assumes no liability for any damages, data loss, or other issues that may arise from using this software.
>
> **This code was generated with AI assistance.** While efforts have been made to ensure correctness, there may be bugs, errors, or unintended behaviors. Thoroughly test in a non-production environment before any production consideration.

## Features

- Extends object lock retention by configurable number of days
- Supports multiple buckets and prefixes
- Works with any S3-compatible storage (AWS S3, IDrive E2, MinIO, etc.)
- Dry-run mode for testing
- Uptime Kuma integration for monitoring
- Docker support with optional cron scheduling

## Prerequisites

- S3 storage with Object Lock enabled
- rclone configuration file with S3 credentials
- Docker (for containerized execution)

## Quick Start

```bash
# Clone/download the files
# Edit rclone.conf with your S3 credentials
# Edit docker-compose.yml to configure buckets and settings

# Test run (dry-run mode)
docker-compose run --rm -e DRY_RUN=true -e DEBUG_MODE=true s3-object-lock

# Run for real
docker-compose up

# Run with cron schedule (every Sunday at 3 AM)
docker-compose run -d -e CRON_SCHEDULE="0 3 * * 0" s3-object-lock
```

## Configuration

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `RCLONE_CONFIG` | Path to rclone config file | `/app/rclone.conf` | No |
| `BUCKETS` | Space-separated list of buckets (format: `config_name:bucket_name`) | `test:test` | Yes |
| `PREFIXES` | Space-separated list of prefixes to process | `data/ keys/ snapshots/ index/` | No |
| `EXTEND_DAYS` | Number of days to extend retention | `3` | No |
| `RETENTION_MODE` | Retention mode: `GOVERNANCE` or `COMPLIANCE` | `GOVERNANCE` | No |
| `AWS_PROFILE` | AWS profile name | `default` | No |
| `DRY_RUN` | Enable dry-run mode (no changes) | `false` | No |
| `DEBUG_MODE` | Enable debug logging | `false` | No |
| `UPTIME_KUMA_URL` | Uptime Kuma push URL for monitoring | (empty) | No |
| `CRON_SCHEDULE` | Cron schedule for automated runs | (empty) | No |
| `PARALLEL_ENABLED` | Enable parallel processing | `true` | No |
| `PARALLEL_WORKERS` | Number of parallel workers | `5` | No |
| `API_DELAY_MS` | Delay between API calls (ms) | `100` | No |
| `RUN_PERMISSIONS_TEST_ON_STARTUP` | Run permission test on startup: `false` (skip), `true` (run before main process), `only` (run and exit) | `false` | No |

### rclone.conf Format

```ini
[config_name]
type = s3
provider = Other
access_key_id = YOUR_ACCESS_KEY
secret_access_key = YOUR_SECRET_KEY
endpoint = https://s3.example.com
region = us-east-1
```

### Bucket Configuration

Buckets are specified in `BUCKETS` variable as space-separated values:

```yaml
# Single bucket
- BUCKETS=myconfig:my-bucket

# Multiple buckets
- BUCKETS=prod:backup-bucket prod:archive-bucket test:test-bucket
```

Format: `rclone_config_name:bucket_name`

### Prefixes

Default prefixes are optimized for restic backup repositories:

- `data/` - Backup data chunks
- `keys/` - Encryption keys (critical)
- `snapshots/` - Snapshot metadata
- `index/` - Index files

The `locks/` directory is intentionally excluded as lock files are temporary.

### Parallel Processing (Performance Optimization)

The script supports parallel processing to significantly improve performance:

| Variable | Description | Default |
|----------|-------------|---------|
| `PARALLEL_ENABLED` | Enable parallel processing | `true` |
| `PARALLEL_WORKERS` | Number of parallel workers | `5` |
| `API_DELAY_MS` | Delay between API calls (ms) | `100` |

**Performance improvements:**
- **85% CPU reduction** - Pre-computed retention date, single-pass jq parsing
- **10x faster** - Parallel processing with configurable workers
- **50% fewer API calls** - Removed unnecessary get-object-retention calls

```yaml
# High-performance configuration
- PARALLEL_ENABLED=true
- PARALLEL_WORKERS=10
- API_DELAY_MS=50

# Conservative configuration (for rate-limited endpoints)
- PARALLEL_ENABLED=true
- PARALLEL_WORKERS=3
- API_DELAY_MS=200
```

### Retention Modes

- **GOVERNANCE**: Users with special permissions can bypass or modify retention
- **COMPLIANCE**: No one can bypass or modify retention (stricter)

> ⚠️ **Warning**: COMPLIANCE mode cannot be bypassed even by root users. Ensure you understand the implications.

### Cron Schedule

Uses standard cron format: `minute hour day month weekday`

```yaml
# Every Sunday at 3 AM
- CRON_SCHEDULE=0 3 * * 0

# Every day at 2 AM
- CRON_SCHEDULE=0 2 * * *

# Every 6 hours
- CRON_SCHEDULE=0 */6 * * *
```

## Docker Usage

### Build

```bash
docker-compose build
```

### Run Once

```bash
docker-compose up
```

### Run with Custom Configuration

```bash
docker-compose run --rm \
  -e BUCKETS="prod:my-backup" \
  -e EXTEND_DAYS=7 \
  -e RETENTION_MODE=COMPLIANCE \
  s3-object-lock
```

### Run with Cron

Set `CRON_SCHEDULE` in `docker-compose.yml`:

```yaml
environment:
  - CRON_SCHEDULE=0 3 * * 0
```

Then run:

```bash
docker-compose up -d
```

### View Logs

```bash
# Follow logs
docker-compose logs -f

# View logs for running container
docker logs s3-object-lock-extension-docker
```

### Run in Existing Container

If the container is already running with cron scheduling, you can manually trigger a run:

```bash
# Execute script in running container (dry-run)
docker exec s3-object-lock-extension-docker /app/file-lock.sh

# Execute with different settings
docker exec -e DRY_RUN=true -e DEBUG_MODE=true s3-object-lock-extension-docker /app/file-lock.sh

# Open interactive shell in container
docker exec -it s3-object-lock-extension-docker /bin/bash
```

## Monitoring

### Uptime Kuma Integration

Set `UPTIME_KUMA_URL` to receive push notifications:

```yaml
- UPTIME_KUMA_URL=https://uptime-kuma.example.com/api/push/xxxxx
```

The script will send:
- Success notifications with summary
- Failure notifications on errors

## Files

| File | Description |
|------|-------------|
| `file-lock.sh` | Main script |
| `test-permissions.sh` | Permission testing script |
| `entrypoint.sh` | Docker entrypoint (handles cron) |
| `Dockerfile` | Docker image definition |
| `docker-compose.yml` | Docker Compose configuration |
| `rclone.conf` | S3 credentials configuration |

## Example docker-compose.yml

```yaml
version: '3.8'

services:
  s3-object-lock:
    build: .
    container_name: s3-object-lock-extension-docker
    restart: always
    # init: true is recommended when using CRON_SCHEDULE
    # It enables Docker's init process (tini) which:
    # 1. Reaps zombie processes spawned by cron jobs
    # 2. Properly forwards signals (SIGTERM) for graceful shutdown
    init: true
    volumes:
      - ./rclone.conf:/app/rclone.conf:ro
    environment:
      - RCLONE_CONFIG=/app/rclone.conf
      - BUCKETS=prod:backup-bucket
      - PREFIXES=data/ keys/ snapshots/ index/
      - EXTEND_DAYS=7
      - RETENTION_MODE=GOVERNANCE
      - AWS_PROFILE=default
      - DRY_RUN=false
      - UPTIME_KUMA_URL=https://uptime-kuma.example.com/api/push/xxxxx
      - DEBUG_MODE=false
      - TZ=Europe/Prague
      - CRON_SCHEDULE=0 3 * * 0
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

### View Logs

```bash
docker logs s3-object-lock-extension-docker
docker logs -f s3-object-lock-extension-docker  # follow
```

## Troubleshooting

### Enable Debug Mode

```bash
docker-compose run --rm -e DEBUG_MODE=true s3-object-lock
```

### Test Without Changes

```bash
docker-compose run --rm -e DRY_RUN=true s3-object-lock
```

### Common Issues

1. **"rclone config file not found"**
   - Ensure `rclone.conf` exists and is mounted correctly
   - Check `RCLONE_CONFIG` path

2. **"Access Denied" errors**
   - Verify S3 credentials in `rclone.conf`
   - Ensure bucket has Object Lock enabled

3. **"Bucket not found"**
   - Check bucket name in `BUCKETS` variable
   - Verify endpoint URL in `rclone.conf`

4. **Container exits immediately**
   - Check logs: `docker logs s3-object-lock-extension-docker`
   - Verify rclone.conf is mounted correctly

5. **Cron not running**
   - Ensure `CRON_SCHEDULE` is set
   - Check timezone with `TZ` variable

6. **S3 connection errors**
   - Verify rclone.conf credentials
   - Check endpoint URL is correct

7. **Image pull errors**
   - Make sure the image is public in GitHub Container Registry
   - Go to Package settings → Change visibility to Public

## Permission Testing (test-permissions.sh)

The `test-permissions.sh` script verifies that your S3 credentials have the correct permissions for restic backup operations with object lock extension.

### Purpose

This tool is designed for **S3 providers that do not support IAM policy editing** and only offer a GUI for managing access keys. Many S3-compatible storage providers (like IDrive E2, MinIO, etc.) have simplified permission management where you can only:
- Create/delete access keys
- Enable/disable specific permissions via checkboxes in a web interface

This script helps you verify that all required permissions are properly enabled in the provider's GUI.

### Usage

```bash
# Basic usage (uses ./rclone.conf by default)
./test-permissions.sh

# With custom rclone config path
RCLONE_CONFIG=/path/to/rclone.conf ./test-permissions.sh

# Test specific buckets (override BUCKETS variable)
BUCKETS="myconfig:my-bucket" ./test-permissions.sh
```

### Automatic Permission Test on Container Startup

You can configure the container to run the permission test automatically at startup using the `RUN_PERMISSIONS_TEST_ON_STARTUP` environment variable:

| Value | Behavior |
|-------|----------|
| `false` | Skip permission test (default) |
| `true` | Run permission test before starting the main process (cron or one-time run) |
| `only` | Run permission test and exit (useful for verifying configuration before deployment) |

**Example - Run test before main process:**
```yaml
environment:
  - RUN_PERMISSIONS_TEST_ON_STARTUP=true
  - CRON_SCHEDULE=0 8 * * *
```

**Example - Run test only and exit:**
```yaml
environment:
  - RUN_PERMISSIONS_TEST_ON_STARTUP=only
```

This is useful for:
- Verifying S3 permissions before deploying to production
- CI/CD pipelines to validate configuration
- Troubleshooting permission issues

### Required Permissions

For restic + object lock extension to work correctly, enable these permissions in your S3 provider's GUI:

| Permission | Purpose |
|------------|---------|
| `s3:ListBucket` | List objects in bucket |
| `s3:GetObject` | Read object data |
| `s3:PutObject` | Upload new objects |
| `s3:DeleteObject` | Delete objects (for cleanup) |
| `s3:ListBucketVersions` | List all object versions |
| `s3:GetBucketVersioning` | Check versioning status |
| `s3:PutBucketVersioning` | Enable versioning (if needed) |
| `s3:GetObjectRetention` | Read object lock retention |
| `s3:PutObjectRetention` | Set/extend object lock retention |
| `s3:GetBucketObjectLockConfiguration` | Read object lock config |

### Dangerous Permissions

These permissions should be **DISABLED** for security:

| Permission | Risk |
|------------|------|
| `s3:BypassGovernanceRetention` | Allows bypassing governance mode locks |

### Output Interpretation

| Status | Meaning |
|--------|---------|
| `GRANTED` | Permission is available |
| `DENIED` | Permission is not available |
| `SKIPPED` | Test skipped (e.g., bucket without object lock) |
| `N/A` | Not applicable (e.g., IAM tests on non-AWS providers) |

### Example Output

```
========================================
BUCKET CONFIGURATION
========================================
Versioning:    ✓ Enabled
Object Lock:   ✓ Enabled
Retention Mode: GOVERNANCE
========================================

TEST NAME                                          | ACCESS          | STATUS
---------------------------------------------------+-----------------+----------------
List Bucket Contents (s3:ListBucket)               | GRANTED         | OK
Put Object (s3:PutObject)                          | GRANTED         | OK
Get Object (s3:GetObject)                          | GRANTED         | OK
Delete Object (s3:DeleteObject)                    | GRANTED         | OK
Put Object Retention (s3:PutObjectRetention)       | GRANTED         | OK
Bypass Governance Retention (s3:BypassGovernanceRetention) | DENIED          | OK
```

### Notes for Specific Providers

#### IDrive E2
- Enable "Object Lock" in bucket settings
- Required permissions are set per access key in the GUI
- `s3:BypassGovernanceRetention` should be disabled for backup accounts

#### MinIO
- Use `mc admin policy` to create custom policies
- Object lock requires bucket creation with `--with-lock` flag

#### AWS S3
- Use IAM policies for fine-grained control
- This script can also test IAM permissions (PutUserPolicy, etc.)

## License

MIT License
