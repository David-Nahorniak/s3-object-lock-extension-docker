# S3 Object Lock Extension Docker Script

Automaticaly extends object lock retention for S3 buckets with Object Lock enabled. Designed for restic backup repositories to ensure data protection compliance.

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
| `entrypoint.sh` | Docker entrypoint (handles cron) |
| `Dockerfile` | Docker image definition |
| `docker-compose.yml` | Docker Compose configuration |
| `rclone.conf` | S3 credentials configuration |

## Example docker-compose.yml

```yaml
version: '3.8'

services:
  s3-object-lock:
    build:
      context: .
      dockerfile: Dockerfile
    image: s3-object-lock-extension-docker:latest
    container_name: s3-object-lock-extension-docker
    restart: "no"
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
      - CRON_SCHEDULE=0 3 * * 0
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

## TrueNAS SCALE Installation

### Prerequisites

1. Push this repository to GitHub
2. GitHub Actions will automatically build and publish the Docker image to GitHub Container Registry
3. Image will be available at: `ghcr.io/david-nahorniak/s3-object-lock-extension-docker:latest`

### Option 1: Custom App YAML (Recommended for 24.10+)

In TrueNAS SCALE 24.10+, you can deploy docker-compose directly using the Custom App YAML function:

1. Go to **Apps** → **Discover Apps** → **Custom App**
2. Switch to **YAML mode** (toggle at the top)
3. Paste the following docker-compose configuration:

```yaml
version: '3.8'

services:
  s3-object-lock:
    image: ghcr.io/david-nahorniak/s3-object-lock-extension-docker:latest
    container_name: s3-object-lock-extension-docker
    restart: always
    volumes:
      - /mnt/tank/apps/s3-object-lock/rclone.conf:/app/rclone.conf:ro
    environment:
      - RCLONE_CONFIG=/app/rclone.conf
      - BUCKETS=default:my-bucket
      - PREFIXES=data/ keys/ snapshots/ index/
      - EXTEND_DAYS=3
      - RETENTION_MODE=GOVERNANCE
      - AWS_PROFILE=default
      - DRY_RUN=false
      - UPTIME_KUMA_URL=
      - DEBUG_MODE=false
      - TZ=Europe/Prague
      - CRON_SCHEDULE=0 8 * * *
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

4. Modify the values as needed (especially `BUCKETS`, `TZ`, and volume path)
5. Click **Install**

### Option 2: Docker Compose via SSH

Run directly via docker-compose:

1. SSH into TrueNAS
2. Create directory:
```bash
mkdir -p /mnt/tank/apps/s3-object-lock
cd /mnt/tank/apps/s3-object-lock
```

3. Create `docker-compose.yml`:
```yaml
version: '3.8'

services:
  s3-object-lock:
    image: ghcr.io/david-nahorniak/s3-object-lock-extension-docker:latest
    container_name: s3-object-lock-extension-docker
    restart: always
    volumes:
      - ./rclone.conf:/app/rclone.conf:ro
    environment:
      - RCLONE_CONFIG=/app/rclone.conf
      - BUCKETS=default:my-bucket
      - PREFIXES=data/ keys/ snapshots/ index/
      - EXTEND_DAYS=3
      - RETENTION_MODE=GOVERNANCE
      - AWS_PROFILE=default
      - DRY_RUN=false
      - UPTIME_KUMA_URL=
      - DEBUG_MODE=false
      - TZ=Europe/Prague
      - CRON_SCHEDULE=0 8 * * *
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

4. Create `rclone.conf` with your S3 credentials:
```ini
[default]
type = s3
provider = Other
env_auth = false
access_key_id = YOUR_ACCESS_KEY
secret_access_key = YOUR_SECRET_KEY
endpoint = https://s3.example.com
```

5. Run:
```bash
docker-compose up -d
```

### Option 3: TrueNAS Cron Job

Run as a scheduled task instead of container cron:

1. Set up docker-compose without `CRON_SCHEDULE` (leave empty or remove)
2. Go to **Tasks** → **Cron Jobs** → **Add**
3. Configure:
   - **Command**: `cd /mnt/tank/apps/s3-object-lock && docker-compose up && docker-compose down`
   - **User**: `root`
   - **Schedule**: Custom or select `0 8 * * *` for daily at 8:00

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

## License

MIT License
