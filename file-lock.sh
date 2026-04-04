#!/bin/bash
#
# S3 Object Lock Extension Docker Script (OPTIMIZED)
# Extends object lock retention by +3 days for all objects without delete markers
# Designed to run weekly via cron
#
# Dependencies: aws-cli, jq
#
# OPTIMIZATIONS:
# - Pre-compute retention date once (was: per object)
# - Single-pass jq parsing with TSV output
# - Bash associative array for delete marker lookup
# - Removed unnecessary get_current_retention API calls
# - Parallel processing with configurable workers
#

set -euo pipefail

# ============================================================================
# CONFIGURATION (all values can be overridden via environment variables)
# ============================================================================

# Path to rclone.conf file
RCLONE_CONFIG="${RCLONE_CONFIG:-./rclone.conf}"

# Buckets to process (all buckets will use the same prefixes)
# Format: "rclone_config_name:bucket_name" (space-separated for multiple)
# Example: "test:my-backup-bucket" where [test] is the rclone config section
# For multiple buckets: "test:bucket1 test:bucket2 prod:bucket3"
BUCKETS_STRING="${BUCKETS:-test:test}"
read -ra BUCKETS <<< "$BUCKETS_STRING"

# Prefixes to process for each bucket (appropriate for restic backups)
# These folders contain the actual backup data that should be protected:
# - data/     : actual backup data chunks
# - keys/     : encryption keys (critical)
# - snapshots/: snapshot metadata
# - index/    : index files
# Note: locks/ is intentionally excluded as lock files are temporary
# Space-separated lists of prefixes
PREFIXES_STRING="${PREFIXES:-data/ keys/ snapshots/ index/}"
read -ra PREFIXES <<< "$PREFIXES_STRING"

# Retention settings
EXTEND_DAYS="${EXTEND_DAYS:-3}"
RETENTION_MODE="${RETENTION_MODE:-GOVERNANCE}"  # GOVERNANCE or COMPLIANCE

# AWS credentials and endpoint (populated from rclone.conf at runtime)
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_REGION="${AWS_REGION:-}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"

# AWS profile (optional - used if credentials not set above)
AWS_PROFILE="${AWS_PROFILE:-default}"

# Lock file to prevent concurrent runs
LOCK_FILE="/var/run/s3-object-lock-extension-docker.lock"
LOCK_TIMEOUT=3600  # 1 hour

# Dry run mode (set via --dry-run argument or environment)
DRY_RUN="${DRY_RUN:-false}"

# Uptime Kuma push URL (optional - for monitoring)
# The script will append ?status=up&msg=XXX&ping=XXX to the URL
UPTIME_KUMA_URL="${UPTIME_KUMA_URL:-}"

# Debug mode (set to true to enable DEBUG level logs)
DEBUG_MODE="${DEBUG_MODE:-false}"

# Parallel processing settings
PARALLEL_WORKERS="${PARALLEL_WORKERS:-5}"
PARALLEL_ENABLED="${PARALLEL_ENABLED:-true}"

# Rate limiting (ms between API calls per worker)
API_DELAY_MS="${API_DELAY_MS:-100}"

# Pre-computed retention date (set in main(), used globally)
NEW_RETAIN_DATE=""

# ============================================================================
# FUNCTIONS
# ============================================================================

# Format duration in seconds to human readable format (Xd Xh Xm Xs)
# Arguments: $1 = duration in seconds
format_duration() {
    local total_seconds=$1
    local days hours minutes seconds
    
    days=$((total_seconds / 86400))
    total_seconds=$((total_seconds % 86400))
    hours=$((total_seconds / 3600))
    total_seconds=$((total_seconds % 3600))
    minutes=$((total_seconds / 60))
    seconds=$((total_seconds % 60))
    
    local result=""
    [[ $days -gt 0 ]] && result="${days}d "
    [[ $hours -gt 0 ]] && result="${result}${hours}h "
    [[ $minutes -gt 0 ]] && result="${result}${minutes}m "
    result="${result}${seconds}s"
    
    echo "$result"
}

# Parse rclone.conf and extract S3 configuration for a given section
# Arguments: $1 = section name (e.g., "test")
# Sets global variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, S3_ENDPOINT_URL
parse_rclone_config() {
    local section="$1"
    local config_file="$RCLONE_CONFIG"
    
    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: rclone config file not found: $config_file" >&2
        return 1
    fi
    
    # Parse the config file dynamically
    local in_section=false
    local access_key=""
    local secret_key=""
    local endpoint=""
    local region=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Check for section header [section_name]
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            local current_section="${BASH_REMATCH[1]}"
            if [[ "$current_section" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi
        
        # Parse key=value pairs within the target section
        if [[ "$in_section" == true ]]; then
            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            
            # Match key = value or key=value (with optional spaces around =)
            if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                # Trim whitespace from value
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%"${value##*[![:space:]]}"}"
                
                case "$key" in
                    access_key_id)
                        access_key="$value"
                        ;;
                    secret_access_key)
                        secret_key="$value"
                        ;;
                    endpoint)
                        endpoint="$value"
                        ;;
                    region)
                        region="$value"
                        ;;
                esac
            fi
        fi
    done < "$config_file"
    
    # Validate required fields
    if [[ -z "$access_key" ]]; then
        echo "ERROR: access_key_id not found in section [$section]" >&2
        return 1
    fi
    if [[ -z "$secret_key" ]]; then
        echo "ERROR: secret_access_key not found in section [$section]" >&2
        return 1
    fi
    
    # Set global variables
    AWS_ACCESS_KEY_ID="$access_key"
    AWS_SECRET_ACCESS_KEY="$secret_key"
    AWS_REGION="${region:-us-east-1}"  # Default region if not specified
    S3_ENDPOINT_URL="$endpoint"
    
    return 0
}

# Initialize script
init() {
    # Check dependencies
    command -v aws >/dev/null 2>&1 || { echo "ERROR: AWS CLI not installed" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not installed" >&2; exit 1; }
    
    # Export AWS credentials if set in script (not placeholder values)
    if [[ "$AWS_ACCESS_KEY_ID" != "YOUR_ACCESS_KEY_ID" && -n "$AWS_ACCESS_KEY_ID" ]]; then
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
        export AWS_REGION
        # Clear AWS_PROFILE to use credentials directly
        unset AWS_PROFILE
    fi
    
    # Add https:// to endpoint URL if missing scheme
    if [[ -n "$S3_ENDPOINT_URL" && ! "$S3_ENDPOINT_URL" =~ ^https?:// ]]; then
        S3_ENDPOINT_URL="https://$S3_ENDPOINT_URL"
    fi
    
    # Pre-compute the retention date ONCE (major CPU optimization)
    # This was previously called for every object
    NEW_RETAIN_DATE=$(compute_retention_date)
    log "INFO" "Pre-computed retention date: $NEW_RETAIN_DATE (extends by +${EXTEND_DAYS} days)"
}

# Compute retention date once (called from init())
compute_retention_date() {
    # Try GNU date first, then BSD date, then Python
    if date -u -d "+${EXTEND_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
        return 0
    elif date -u -v+${EXTEND_DAYS}d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
        return 0
    else
        # Fallback: use Python if available
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() + timedelta(days=$EXTEND_DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
        elif command -v python >/dev/null 2>&1; then
            python -c "from datetime import datetime, timedelta; print((datetime.utcnow() + timedelta(days=$EXTEND_DAYS)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
        else
            log "ERROR" "Cannot calculate date - no compatible date utility found"
            return 1
        fi
    fi
}

# Acquire lock to prevent concurrent runs
acquire_lock() {
    # Create lock directory if needed
    local lock_dir
    lock_dir=$(dirname "$LOCK_FILE")
    [[ -d "$lock_dir" ]] || mkdir -p "$lock_dir" 2>/dev/null || LOCK_FILE="/tmp/s3-object-lock-extension-docker.lock"
    
    # Check for existing lock
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            # Check if lock is stale (older than timeout)
            local lock_age
            lock_age=$(($(date +%s) - $(stat -c%Y "$LOCK_FILE" 2>/dev/null || stat -f%m "$LOCK_FILE" 2>/dev/null || echo 0)))
            if [[ "$lock_age" -lt "$LOCK_TIMEOUT" ]]; then
                log "ERROR" "Another instance is running (PID: $lock_pid)"
                exit 1
            else
                log "WARN" "Removing stale lock file"
                rm -f "$LOCK_FILE"
            fi
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Create lock file
    echo $$ > "$LOCK_FILE"
    trap 'release_lock' EXIT
}

# Release lock on exit
release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

# Logging function - outputs to stdout/stderr (Docker handles logging)
log() {
    local level="$1"
    local message="$2"
    
    # Skip DEBUG messages if DEBUG_MODE is false
    if [[ "$level" == "DEBUG" && "$DEBUG_MODE" != "true" ]]; then
        return 0
    fi
    
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
    
    # Output to stdout for INFO/WARN/DEBUG, stderr for ERROR
    if [[ "$level" == "ERROR" ]]; then
        echo "$log_line" >&2
    else
        echo "$log_line"
    fi
}

# Send ping to Uptime Kuma
send_uptime_kuma() {
    local status="$1"
    local message="$2"
    
    if [[ -z "$UPTIME_KUMA_URL" ]]; then
        return 0
    fi
    
    # Build URL with parameters (URL encode message)
    local encoded_message
    encoded_message=$(printf '%s' "$message" | jq -sRr @uri 2>/dev/null || echo "$message")
    local url="${UPTIME_KUMA_URL}?status=${status}&msg=${encoded_message}"
    
    # Send ping (silent, fail gracefully)
    curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true
}

# Get current retention info for an object (ONLY called in DEBUG mode)
# Arguments: bucket, key, version_id
get_current_retention() {
    local bucket="$1"
    local key="$2"
    local version_id="$3"
    
    local args=(
        s3api get-object-retention
        --bucket "$bucket"
        --key "$key"
        --version-id "$version_id"
    )
    
    # Add endpoint URL if configured
    [[ -n "$S3_ENDPOINT_URL" ]] && args+=(--endpoint-url "$S3_ENDPOINT_URL")
    
    # Add authentication
    if [[ -z "${AWS_PROFILE:-}" ]]; then
        args+=(--region "$AWS_REGION")
    else
        args+=(--profile "$AWS_PROFILE" --region "$AWS_REGION")
    fi
    
    local retention
    if retention=$(aws "${args[@]}" 2>/dev/null); then
        echo "$retention"
    else
        echo ""
    fi
}

# Apply retention to a single object (used for parallel processing)
# Arguments: bucket, key, version_id
# Uses global variables: NEW_RETAIN_DATE, RETENTION_MODE, S3_ENDPOINT_URL, AWS_REGION, DRY_RUN
apply_retention_single() {
    local bucket="$1"
    local key="$2"
    local version_id="$3"
    
    # Apply rate limiting delay
    if [[ "$API_DELAY_MS" -gt 0 ]]; then
        sleep "$((API_DELAY_MS / 1000)).$((API_DELAY_MS % 1000))"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY-RUN: Would extend: s3://$bucket/$key -> $NEW_RETAIN_DATE"
        return 0
    fi
    
    local put_args=(
        s3api put-object-retention
        --bucket "$bucket"
        --key "$key"
        --version-id "$version_id"
        --retention "{\"Mode\":\"$RETENTION_MODE\",\"RetainUntilDate\":\"$NEW_RETAIN_DATE\"}"
    )
    
    # Add bypass-governance-retention for GOVERNANCE mode
    [[ "$RETENTION_MODE" == "GOVERNANCE" ]] && put_args+=(--bypass-governance-retention)
    
    # Add endpoint URL if configured
    [[ -n "$S3_ENDPOINT_URL" ]] && put_args+=(--endpoint-url "$S3_ENDPOINT_URL")
    
    # Add authentication
    if [[ -z "${AWS_PROFILE:-}" ]]; then
        put_args+=(--region "$AWS_REGION")
    else
        put_args+=(--profile "$AWS_PROFILE" --region "$AWS_REGION")
    fi
    
    if aws "${put_args[@]}" 2>&1; then
        echo "OK: s3://$bucket/$key"
        return 0
    else
        echo "ERROR: Failed to extend: s3://$bucket/$key" >&2
        return 1
    fi
}

# Export function and variables for parallel processing
export -f apply_retention_single
export -f log
export NEW_RETAIN_DATE RETENTION_MODE S3_ENDPOINT_URL AWS_REGION DRY_RUN API_DELAY_MS

# Process single bucket and prefix combination (OPTIMIZED)
process_bucket_prefix() {
    local bucket="$1"
    local prefix="$2"
    
    log "INFO" "Processing: s3://$bucket/$prefix"
    
    local total_objects=0
    local total_extended=0
    local total_skipped=0
    local total_errors=0
    local api_list=0
    
    local key_marker=""
    local version_marker=""
    
    # Temporary file for parallel processing
    local objects_file
    objects_file=$(mktemp)
    trap "rm -f '$objects_file'" RETURN
    
    # Pagination loop
    while true; do
        local args=(
            s3api list-object-versions
            --bucket "$bucket"
            --prefix "$prefix"
            --max-keys 1000
        )
        
        # Add endpoint URL if configured
        [[ -n "$S3_ENDPOINT_URL" ]] && args+=(--endpoint-url "$S3_ENDPOINT_URL")
        
        # Add authentication (profile or credentials)
        if [[ -z "${AWS_PROFILE:-}" ]]; then
            args+=(--region "$AWS_REGION")
        else
            args+=(--profile "$AWS_PROFILE" --region "$AWS_REGION")
        fi
        
        [[ -n "$key_marker" ]] && args+=(--key-marker "$key_marker")
        [[ -n "$version_marker" ]] && args+=(--version-id-marker "$version_marker")
        
        local response
        if ! response=$(aws "${args[@]}" 2>&1); then
            log "ERROR" "Failed to list objects: $response"
            total_errors=$((total_errors + 1))
            break
        fi
        api_list=$((api_list + 1))
        
        # OPTIMIZATION: Single-pass extraction of delete markers into associative array
        declare -A delete_markers_cache
        while IFS= read -r marker_key; do
            [[ -n "$marker_key" ]] && delete_markers_cache["$marker_key"]=1
        done < <(echo "$response" | jq -r '.DeleteMarkers[]? | select(.IsLatest == true) | .Key' 2>/dev/null)
        
        # OPTIMIZATION: Single-pass jq to TSV for object parsing
        # Extract Key, VersionId, IsLatest in one pass
        while IFS=$'\t' read -r key version_id is_latest; do
            # Skip if not latest version
            [[ "$is_latest" != "true" ]] && continue
            
            # OPTIMIZATION: O(1) lookup in associative array instead of jq per object
            if [[ -n "${delete_markers_cache[$key]:-}" ]]; then
                total_skipped=$((total_skipped + 1))
                log "DEBUG" "Skipped (has delete marker): s3://$bucket/$key"
                continue
            fi
            
            total_objects=$((total_objects + 1))
            
            # OPTIMIZATION: Only call get_current_retention in DEBUG mode
            if [[ "$DEBUG_MODE" == "true" ]]; then
                local current_retention current_mode current_retain_date
                current_retention=$(get_current_retention "$bucket" "$key" "$version_id")
                
                if [[ -n "$current_retention" ]]; then
                    current_mode=$(echo "$current_retention" | jq -r '.Retention.Mode // "NONE"')
                    current_retain_date=$(echo "$current_retention" | jq -r '.Retention.RetainUntilDate // "NONE"')
                    log "DEBUG" "Current retention: s3://$bucket/$key | Mode: $current_mode | RetainUntil: $current_retain_date | Extending by: +${EXTEND_DAYS} days"
                else
                    log "DEBUG" "No current retention: s3://$bucket/$key | Setting new: +${EXTEND_DAYS} days | Mode: $RETENTION_MODE"
                fi
            fi
            
            # Write to temp file for batch processing
            printf '%s\t%s\t%s\n' "$bucket" "$key" "$version_id" >> "$objects_file"
            
        done < <(echo "$response" | jq -r '.Versions[]? | [.Key, .VersionId, .IsLatest] | @tsv' 2>/dev/null)
        
        # Pagination: get next markers
        key_marker=$(echo "$response" | jq -r '.NextKeyMarker // empty')
        version_marker=$(echo "$response" | jq -r '.NextVersionIdMarker // empty')
        
        # Exit if no more pages
        [[ -z "$key_marker" ]] || [[ "$key_marker" == "null" ]] && break
    done
    
    # Process objects (parallel or sequential)
    local processed=0
    local failed=0
    
    if [[ "$PARALLEL_ENABLED" == "true" && -s "$objects_file" ]]; then
        log "INFO" "Processing ${total_objects} objects with $PARALLEL_WORKERS parallel workers..."
        
        # Export all needed variables for parallel workers
        export RETENTION_MODE NEW_RETAIN_DATE S3_ENDPOINT_URL AWS_REGION AWS_PROFILE DRY_RUN API_DELAY_MS
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY DEBUG_MODE EXTEND_DAYS
        export -f apply_retention_single log get_current_retention
        
        # Create temp directory for job tracking (works in non-interactive shells)
        local job_dir
        job_dir=$(mktemp -d)
        local results_file="$job_dir/results"
        touch "$results_file"
        
        # Counter for job IDs
        local job_id=0
        local active_jobs=0
        
        # Process with background jobs using file-based semaphore
        while IFS=$'\t' read -r b k v; do
            # Wait if we have too many active jobs (file-based counting)
            while true; do
                # Count running jobs by checking which PID files still have running processes
                active_jobs=0
                for pid_file in "$job_dir"/pid_*; do
                    [[ -f "$pid_file" ]] || continue
                    local pid
                    pid=$(cat "$pid_file" 2>/dev/null)
                    # Check if process is still running
                    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                        active_jobs=$((active_jobs + 1))
                    else
                        # Clean up stale PID file
                        rm -f "$pid_file" 2>/dev/null
                    fi
                done
                
                if [[ $active_jobs -lt $PARALLEL_WORKERS ]]; then
                    break
                fi
                sleep 0.05
            done
            
            # Run in background and track with PID file
            (
                if apply_retention_single "$b" "$k" "$v"; then
                    echo "OK" >> "$results_file"
                else
                    echo "FAIL" >> "$results_file"
                fi
            ) &
            
            # Store PID for tracking
            echo $! > "$job_dir/pid_$job_id"
            job_id=$((job_id + 1))
            
        done < "$objects_file"
        
        # Wait for all background jobs to complete
        wait
        
        # Count results
        processed=$(grep -c "^OK$" "$results_file" 2>/dev/null || echo 0)
        failed=$(grep -c "^FAIL$" "$results_file" 2>/dev/null || echo 0)
        rm -rf "$job_dir"
        
        log "INFO" "Parallel processing complete: $processed succeeded, $failed failed"
        
    elif [[ -s "$objects_file" ]]; then
        log "INFO" "Processing ${total_objects} objects sequentially..."
        
        while IFS=$'\t' read -r b k v; do
            if apply_retention_single "$b" "$k" "$v"; then
                processed=$((processed + 1))
            else
                failed=$((failed + 1))
            fi
            
            # Progress logging every 100 objects
            if [[ $(((processed + failed) % 100)) -eq 0 && $((processed + failed)) -gt 0 ]]; then
                log "INFO" "Progress: $((processed + failed)) / $total_objects objects processed"
            fi
        done < "$objects_file"
    fi
    
    # INTEGRITY CHECK: Verify all objects were processed
    local total_processed=$((processed + failed))
    if [[ $total_processed -ne $total_objects ]]; then
        log "WARNING" "INTEGRITY CHECK FAILED: Expected $total_objects objects, but processed $total_processed (succeeded: $processed, failed: $failed)"
        log "WARNING" "This indicates a bug in parallel processing - some objects may have been missed or duplicated!"
    else
        log "INFO" "Integrity check passed: $total_processed objects processed as expected"
    fi
    
    total_extended=$processed
    total_errors=$((total_errors + failed))
    
    log "INFO" "===== s3://$bucket/$prefix ====="
    log "INFO" "Objects: $total_objects | Extended: $total_extended | Skipped: $total_skipped | Errors: $total_errors"
    log "INFO" "API calls: list=$api_list | put=$total_extended | TOTAL=$((api_list + total_extended))"
    
    # Return values for aggregation (via global variables)
    PROCESS_OBJECTS=$total_objects
    PROCESS_EXTENDED=$total_extended
    PROCESS_SKIPPED=$total_skipped
    PROCESS_ERRORS=$total_errors
}

# Show usage
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

S3 Object Lock Extension Docker Script (OPTIMIZED)
Extends object lock retention by +${EXTEND_DAYS} days for all objects without delete markers.

OPTIMIZATIONS:
- Pre-computed retention date (was: per object)
- Single-pass jq parsing with TSV output
- Bash associative array for delete marker lookup
- Removed unnecessary get_current_retention API calls
- Parallel processing with configurable workers

Options:
    -n, --dry-run         Show what would be done without making changes
    -h, --help            Show this help message
    -c, --config FILE     Path to rclone.conf file (default: ~/.config/rclone/rclone.conf)

Environment variables:
    RCLONE_CONFIG         Path to rclone.conf file (overrides default)
    AWS_PROFILE           AWS profile to use (default: default)
    PARALLEL_WORKERS      Number of parallel workers (default: 5)
    PARALLEL_ENABLED      Enable parallel processing (default: true)
    API_DELAY_MS          Delay between API calls in ms (default: 100)

Bucket format in BUCKETS array:
    "rclone_config_name:bucket_name"
    Example: "test:my-backup-bucket" where [test] is the rclone config section

rclone.conf example:
    [test]
    type = s3
    provider = Other
    access_key_id = YOUR_ACCESS_KEY
    secret_access_key = YOUR_SECRET_KEY
    endpoint = s3.example.com
    region = eu-central-2

Cron example (weekly run):
    0 2 * * 0 /usr/local/bin/s3-object-lock-extension-docker.sh >> /var/log/s3-object-lock-extension-docker.log 2>&1

EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -c|--config)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --config requires a file path" >&2
                    exit 1
                fi
                RCLONE_CONFIG="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
    
    init
    acquire_lock
    
    # Record start time
    local start_time end_time duration_seconds
    start_time=$(date +%s)
    
    log "INFO" "========== START (OPTIMIZED VERSION) =========="
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "Running in DRY-RUN mode"
    fi
    
    log "INFO" "Configuration: EXTEND_DAYS=$EXTEND_DAYS, RETENTION_MODE=$RETENTION_MODE"
    log "INFO" "Parallel: enabled=$PARALLEL_ENABLED, workers=$PARALLEL_WORKERS"
    log "INFO" "rclone.conf: $RCLONE_CONFIG"
    
    # Aggregate totals across all bucket/prefix combinations
    local grand_objects=0
    local grand_extended=0
    local grand_skipped=0
    local grand_errors=0
    
    # Process each bucket with all prefixes
    # Bucket format: "rclone_config_name:bucket_name"
    for bucket_entry in "${BUCKETS[@]}"; do
        # Parse bucket entry
        local rclone_section bucket_name
        if [[ "$bucket_entry" == *":"* ]]; then
            rclone_section="${bucket_entry%%:*}"
            bucket_name="${bucket_entry#*:}"
        else
            # Legacy format: treat entire entry as bucket name with no rclone config
            echo "ERROR: Invalid bucket format '$bucket_entry'. Use 'rclone_config_name:bucket_name'" >&2
            exit 1
        fi
        
        # Parse rclone.conf for this section
        if ! parse_rclone_config "$rclone_section"; then
            log "ERROR" "Failed to parse rclone config for section [$rclone_section]"
            exit 1
        fi
        
        # Export AWS credentials
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
        export AWS_REGION
        unset AWS_PROFILE
        
        # Add https:// to endpoint URL if missing scheme
        if [[ -n "$S3_ENDPOINT_URL" && ! "$S3_ENDPOINT_URL" =~ ^https?:// ]]; then
            S3_ENDPOINT_URL="https://$S3_ENDPOINT_URL"
        fi
        
        log "INFO" "AWS: endpoint=$S3_ENDPOINT_URL, region=$AWS_REGION, bucket=$bucket_name"
        
        for prefix in "${PREFIXES[@]}"; do
            # Remove trailing slash from prefix
            prefix="${prefix%/}"
            process_bucket_prefix "$bucket_name" "$prefix"
            
            # Aggregate results
            grand_objects=$((grand_objects + PROCESS_OBJECTS))
            grand_extended=$((grand_extended + PROCESS_EXTENDED))
            grand_skipped=$((grand_skipped + PROCESS_SKIPPED))
            grand_errors=$((grand_errors + PROCESS_ERRORS))
        done
    done
    
    # Record end time and calculate duration
    end_time=$(date +%s)
    duration_seconds=$((end_time - start_time))
    
    local duration_formatted
    duration_formatted=$(format_duration "$duration_seconds")
    
    log "INFO" "========== SUMMARY =========="
    log "INFO" "Total objects: $grand_objects | Extended: $grand_extended | Skipped: $grand_skipped | Errors: $grand_errors"
    log "INFO" "Duration: $duration_formatted"
    
    # Send Uptime Kuma ping if configured
    if [[ -n "$UPTIME_KUMA_URL" && "$DRY_RUN" != "true" ]]; then
        local message
        if [[ $grand_errors -gt 0 ]]; then
            # Errors occurred - report down
            message="ERRORS: ${grand_errors} errors, extended ${grand_extended} objects in $duration_formatted"
            send_uptime_kuma "down" "$message"
            log "WARN" "Uptime Kuma ping sent (down): $message"
        elif [[ $grand_extended -eq 0 ]]; then
            # No objects extended - report down (possible issue)
            message="WARNING: No objects extended (processed: ${grand_objects}, skipped: ${grand_skipped}) in $duration_formatted"
            send_uptime_kuma "down" "$message"
            log "WARN" "Uptime Kuma ping sent (down): $message"
        else
            # Success - report up
            message="Extended ${grand_extended} objects in $duration_formatted"
            send_uptime_kuma "up" "$message"
            log "INFO" "Uptime Kuma ping sent (up): $message"
        fi
    fi
    
    # Exit with error code if there were errors
    if [[ $grand_errors -gt 0 ]]; then
        exit 1
    fi

    log "INFO" "========== END =========="
}

main "$@"
