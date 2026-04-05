#!/bin/bash
#
# S3 Permission Tester for Restic and Object Lock
# Tests rclone endpoints for required and dangerous permissions
#
# Usage: ./test-permissions.sh [rclone.conf path]
#

set -o pipefail

# Configuration
RCLONE_CONFIG="${RCLONE_CONFIG:-./rclone.conf}"

# Buckets to test (same format as file-lock.sh)
# Format: "rclone_config_name:bucket_name" (space-separated for multiple)
# Example: "test:my-backup-bucket" where [test] is the rclone config section
BUCKETS_STRING="${BUCKETS:-test:test}"
read -ra BUCKETS <<< "$BUCKETS_STRING"

TEST_PREFIX="s3-object-lock-test"
# Generate unique test file names with timestamp and random suffix
TEST_RUN_ID="$(date +%s)-$((RANDOM % 10000))"
TEST_FILE="permission-test-${TEST_RUN_ID}.txt"
RETENTION_TEST_FILE="retention-test-${TEST_RUN_ID}.txt"
BYPASS_TEST_FILE="bypass-test-${TEST_RUN_ID}.txt"
TEST_CONTENT="Permission test content - $(date -Iseconds)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Results storage
declare -a TEST_RESULTS

# ============================================================================
# FUNCTIONS
# ============================================================================

# Print colored message
log() {
    local level="$1"
    local message="$2"
    case "$level" in
        INFO)  echo -e "${BLUE}[INFO]${NC} $message" ;;
        OK)    echo -e "${GREEN}[OK]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        *)     echo "$message" ;;
    esac
}

# Parse rclone.conf and extract all section names
parse_rclone_sections() {
    local config_file="$1"
    local sections=()
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "rclone config file not found: $config_file"
        exit 1
    fi
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            sections+=("${BASH_REMATCH[1]}")
        fi
    done < "$config_file"
    
    echo "${sections[@]}"
}

# Parse rclone.conf for a specific section
parse_rclone_config() {
    local section="$1"
    local config_file="$2"
    
    local in_section=false
    local access_key=""
    local secret_key=""
    local endpoint=""
    local region=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$line" =~ ^\[([^\]]+)\] ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi
        
        if [[ "$in_section" == true ]]; then
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            
            if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%"${value##*[![:space:]]}"}"
                
                case "$key" in
                    access_key_id)     access_key="$value" ;;
                    secret_access_key) secret_key="$value" ;;
                    endpoint)          endpoint="$value" ;;
                    region)            region="$value" ;;
                esac
            fi
        fi
    done < "$config_file"
    
    if [[ -z "$access_key" || -z "$secret_key" ]]; then
        return 1
    fi
    
    echo "$access_key|$secret_key|${endpoint}|${region:-us-east-1}"
    return 0
}

# Run AWS CLI command and capture result
run_aws_cmd() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    shift 4
    local args=("$@")
    
    local result
    if result=$(AWS_ACCESS_KEY_ID="$access_key" \
                AWS_SECRET_ACCESS_KEY="$secret_key" \
                aws "${args[@]}" \
                --region "$region" \
                ${endpoint:+--endpoint-url "$endpoint"} \
                2>&1); then
        echo "SUCCESS|$result"
    else
        echo "FAILED|$result"
    fi
}

# Add test result to array
add_result() {
    local test_name="$1"
    local access="$2"
    local status="$3"
    TEST_RESULTS+=("$test_name|$access|$status")
}

# Print results table
print_results_table() {
    local section="$1"
    
    echo ""
    echo "========================================"
    echo "RESULTS FOR: $section"
    echo "========================================"
    printf "%-50s | %-15s | %-15s\n" "TEST NAME" "ACCESS" "STATUS"
    printf "%-50s-+-%-15s-+-%-15s\n" "--------------------------------------------------" "---------------" "---------------"
    
    for result in "${TEST_RESULTS[@]}"; do
        IFS='|' read -r name access status <<< "$result"
        
        local status_colored
        case "$status" in
            OK)        status_colored="${GREEN}OK${NC}" ;;
            DANGEROUS) status_colored="${RED}DANGEROUS${NC}" ;;
            REQUIRED)  status_colored="${RED}REQUIRED${NC}" ;;
            WARN)      status_colored="${YELLOW}WARN${NC}" ;;
            *)         status_colored="$status" ;;
        esac
        
        printf "%-50s | %-15s | " "$name" "$access"
        echo -e "$status_colored"
    done
    echo ""
}

# Check if bucket exists, create if not
ensure_test_bucket() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api head-bucket --bucket "$bucket")
    
    if [[ "$result" == SUCCESS* ]]; then
        return 0
    fi
    
    # Try to create bucket
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api create-bucket --bucket "$bucket")
    
    if [[ "$result" == SUCCESS* ]]; then
        log "INFO" "Created test bucket: $bucket"
        return 0
    fi
    
    return 1
}

# ============================================================================
# TEST FUNCTIONS
# ============================================================================

test_list_buckets() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" s3 ls)
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "List All Buckets (s3:ListAllMyBuckets)" "GRANTED" "OK"
        return 0
    else
        add_result "List All Buckets (s3:ListAllMyBuckets)" "DENIED" "WARN"
        return 1
    fi
}

test_list_bucket() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # List bucket root (prefix may not exist yet)
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3 ls "s3://$bucket/")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "List Bucket Contents (s3:ListBucket)" "GRANTED" "OK"
        return 0
    else
        add_result "List Bucket Contents (s3:ListBucket)" "DENIED" "REQUIRED"
        return 1
    fi
}

test_put_object() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # Create temp file for upload
    local temp_file
    temp_file=$(mktemp)
    echo "$TEST_CONTENT" > "$temp_file"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api put-object \
             --bucket "$bucket" \
             --key "$TEST_PREFIX/$TEST_FILE" \
             --body "$temp_file")
    
    rm -f "$temp_file"
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Put Object (s3:PutObject)" "GRANTED" "OK"
        return 0
    else
        add_result "Put Object (s3:PutObject)" "DENIED" "REQUIRED"
        return 1
    fi
}

test_get_object() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api get-object \
             --bucket "$bucket" \
             --key "$TEST_PREFIX/$TEST_FILE" /dev/null)
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Get Object (s3:GetObject)" "GRANTED" "OK"
        return 0
    else
        add_result "Get Object (s3:GetObject)" "DENIED" "REQUIRED"
        return 1
    fi
}

test_delete_object() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api delete-object \
             --bucket "$bucket" \
             --key "$TEST_PREFIX/$TEST_FILE")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Delete Object (s3:DeleteObject)" "GRANTED" "OK"
        return 0
    else
        add_result "Delete Object (s3:DeleteObject)" "DENIED" "WARN"
        return 1
    fi
}

test_list_object_versions() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api list-object-versions \
             --bucket "$bucket" \
             --prefix "$TEST_PREFIX/")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "List Object Versions (s3:ListBucketVersions)" "GRANTED" "OK"
        return 0
    else
        add_result "List Object Versions (s3:ListBucketVersions)" "DENIED" "REQUIRED"
        return 1
    fi
}

test_put_object_retention() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # Create temp file for upload
    local temp_file
    temp_file=$(mktemp)
    echo "retention test" > "$temp_file"
    
    # First create a test object with unique name
    run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
        s3api put-object \
        --bucket "$bucket" \
        --key "$TEST_PREFIX/$RETENTION_TEST_FILE" \
        --body "$temp_file" >/dev/null
    
    rm -f "$temp_file"
    
    # Get version ID
    local version_result
    version_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
                     s3api list-object-versions \
                     --bucket "$bucket" \
                     --prefix "$TEST_PREFIX/$RETENTION_TEST_FILE")
    
    local version_id=""
    if [[ "$version_result" == SUCCESS* ]]; then
        version_id=$(echo "$version_result" | sed 's/SUCCESS|//' | jq -r '.Versions[0].VersionId // "null"' 2>/dev/null || echo "")
    fi
    
    # Calculate retention date (1 day from now)
    local retain_date
    retain_date=$(date -u -d "+1 day" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                  date -u -v+1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                  python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() + timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    
    local args=(
        s3api put-object-retention
        --bucket "$bucket"
        --key "$TEST_PREFIX/$RETENTION_TEST_FILE"
        --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$retain_date\"}"
    )
    [[ -n "$version_id" && "$version_id" != "null" ]] && args+=(--version-id "$version_id")
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" "${args[@]}")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Put Object Retention (s3:PutObjectRetention)" "GRANTED" "OK"
        return 0
    else
        add_result "Put Object Retention (s3:PutObjectRetention)" "DENIED" "REQUIRED"
        return 1
    fi
}

test_get_object_retention() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api get-object-retention \
             --bucket "$bucket" \
             --key "$TEST_PREFIX/$RETENTION_TEST_FILE")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Get Object Retention (s3:GetObjectRetention)" "GRANTED" "OK"
        return 0
    else
        add_result "Get Object Retention (s3:GetObjectRetention)" "DENIED" "WARN"
        return 1
    fi
}

test_bypass_governance_retention() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # Create a unique test object for bypass test
    local bypass_test_key="$TEST_PREFIX/$BYPASS_TEST_FILE"
    local temp_file
    temp_file=$(mktemp)
    echo "bypass governance test" > "$temp_file"
    
    # Upload object
    local upload_result
    upload_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
        s3api put-object \
        --bucket "$bucket" \
        --key "$bypass_test_key" \
        --body "$temp_file")
    rm -f "$temp_file"
    
    if [[ "$upload_result" != SUCCESS* ]]; then
        add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "SKIPPED" "WARN"
        return 1
    fi
    
    # Get version ID
    local version_id
    version_id=$(echo "$upload_result" | sed 's/SUCCESS|//' | jq -r '.VersionId // "null"' 2>/dev/null || echo "null")
    
    # Set GOVERNANCE retention on the object (1 day)
    local retain_date
    retain_date=$(date -u -d "+1 day" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                  date -u -v+1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                  python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() + timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    
    local retention_args=(
        s3api put-object-retention
        --bucket "$bucket"
        --key "$bypass_test_key"
        --retention "{\"Mode\":\"GOVERNANCE\",\"RetainUntilDate\":\"$retain_date\"}"
    )
    [[ -n "$version_id" && "$version_id" != "null" ]] && retention_args+=(--version-id "$version_id")
    
    local retention_result
    retention_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" "${retention_args[@]}")
    
    if [[ "$retention_result" != SUCCESS* ]]; then
        # Could not set retention - check if it's because object already has retention from bucket default
        # or because permission is denied
        if [[ "$retention_result" == *"AccessDenied"* || "$retention_result" == *"Unauthorized"* ]]; then
            add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "SKIPPED" "WARN"
            return 1
        fi
        # Object might already have retention from bucket default - that's fine for our test
    fi
    
    # First, try to delete WITHOUT bypass flag (should fail due to retention)
    local delete_args=(
        s3api delete-object
        --bucket "$bucket"
        --key "$bypass_test_key"
    )
    [[ -n "$version_id" && "$version_id" != "null" ]] && delete_args+=(--version-id "$version_id")
    
    local normal_delete_result
    normal_delete_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" "${delete_args[@]}")
    
    # If normal delete succeeded, object didn't have retention - test is invalid
    if [[ "$normal_delete_result" == SUCCESS* ]]; then
        add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "SKIPPED" "WARN"
        return 1
    fi
    
    # Now try to delete WITH bypass flag
    local bypass_args=(
        s3api delete-object
        --bucket "$bucket"
        --key "$bypass_test_key"
        --bypass-governance-retention
    )
    [[ -n "$version_id" && "$version_id" != "null" ]] && bypass_args+=(--version-id "$version_id")
    
    local bypass_result
    bypass_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" "${bypass_args[@]}")
    
    if [[ "$bypass_result" == SUCCESS* ]]; then
        add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "GRANTED" "DANGEROUS"
        return 0
    else
        # Check if it's an AccessDenied error (permission denied) or other error
        if [[ "$bypass_result" == *"AccessDenied"* ]]; then
            add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "DENIED" "OK"
            return 1
        else
            # Other error - might be provider not supporting the flag
            add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "ERROR" "WARN"
            return 1
        fi
    fi
}

test_delete_object_version() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # Get version ID of test object
    local version_result
    version_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
                     s3api list-object-versions \
                     --bucket "$bucket" \
                     --prefix "$TEST_PREFIX/")
    
    if [[ "$version_result" != SUCCESS* ]]; then
        add_result "Delete Object Version (s3:DeleteObjectVersion)" "SKIPPED" "WARN"
        return 1
    fi
    
    local version_id
    version_id=$(echo "$version_result" | sed 's/SUCCESS|//' | jq -r '.Versions[0].VersionId // "null"' 2>/dev/null || echo "")
    
    if [[ -z "$version_id" || "$version_id" == "null" ]]; then
        add_result "Delete Object Version (s3:DeleteObjectVersion)" "SKIPPED" "WARN"
        return 1
    fi
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api delete-object \
             --bucket "$bucket" \
             --key "$TEST_PREFIX/$TEST_FILE" \
             --version-id "$version_id")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Delete Object Version (s3:DeleteObjectVersion)" "GRANTED" "OK"
        return 0
    else
        add_result "Delete Object Version (s3:DeleteObjectVersion)" "DENIED" "WARN"
        return 1
    fi
}

test_put_bucket_versioning() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # Check current versioning status first
    local status_result
    status_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
                    s3api get-bucket-versioning --bucket "$bucket")
    
    if [[ "$status_result" == SUCCESS* ]]; then
        add_result "Get Bucket Versioning (s3:GetBucketVersioning)" "GRANTED" "OK"
    else
        add_result "Get Bucket Versioning (s3:GetBucketVersioning)" "DENIED" "WARN"
    fi
    
    # Try to enable versioning (this tests s3:PutBucketVersioning)
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api put-bucket-versioning \
             --bucket "$bucket" \
             --versioning-configuration Status=Enabled)
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Put Bucket Versioning (s3:PutBucketVersioning)" "GRANTED" "OK"
        return 0
    else
        add_result "Put Bucket Versioning (s3:PutBucketVersioning)" "DENIED" "WARN"
        return 1
    fi
}

test_get_bucket_object_lock() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api get-object-lock-configuration \
             --bucket "$bucket")
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Get Object Lock Config (s3:GetBucketObjectLockConfiguration)" "GRANTED" "OK"
        return 0
    else
        add_result "Get Object Lock Config (s3:GetBucketObjectLockConfiguration)" "DENIED" "WARN"
        return 1
    fi
}

test_put_bucket_object_lock() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    # Try to put object lock config (tests s3:PutBucketObjectLockConfiguration)
    local result
    result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
             s3api put-object-lock-configuration \
             --bucket "$bucket" \
             --object-lock-configuration '{"ObjectLockEnabled":"Enabled"}')
    
    if [[ "$result" == SUCCESS* ]]; then
        add_result "Put Object Lock Config (s3:PutBucketObjectLockConfiguration)" "GRANTED" "OK"
        return 0
    else
        add_result "Put Object Lock Config (s3:PutBucketObjectLockConfiguration)" "DENIED" "WARN"
        return 1
    fi
}

# ============================================================================
# IAM PERMISSION TESTS
# These test for dangerous permissions that could allow bypassing governance
# ============================================================================

test_iam_get_user() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    # Try to get IAM user info with timeout
    # Non-AWS providers will typically timeout or return connection errors
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam get-user \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124)
    if [[ $exit_code -eq 124 ]]; then
        add_result "Get IAM User (iam:GetUser)" "N/A" "WARN"
        echo "FAILED|timeout"
        return 1
    fi
    
    if [[ "$result" == *"UserName"* || "$result" == *"UserId"* ]]; then
        add_result "Get IAM User (iam:GetUser)" "GRANTED" "OK"
        echo "SUCCESS|$result"
        return 0
    elif [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Get IAM User (iam:GetUser)" "DENIED" "WARN"
        echo "FAILED|$result"
        return 1
    elif [[ "$result" =~ (InvalidClientTokenId|SignatureDoesNotMatch|connection refused|Could not connect|No route to host) ]]; then
        # Non-AWS provider - IAM not available or credentials not valid for IAM
        add_result "Get IAM User (iam:GetUser)" "N/A" "WARN"
        echo "FAILED|$result"
        return 1
    else
        add_result "Get IAM User (iam:GetUser)" "DENIED" "WARN"
        echo "FAILED|$result"
        return 1
    fi
}

test_iam_put_user_policy() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local username="$5"
    
    # Skip if no username (non-AWS or couldn't determine user)
    if [[ -z "$username" ]]; then
        add_result "Put User Policy (iam:PutUserPolicy)" "N/A" "WARN"
        return 1
    fi
    
    # Try to attach a harmless test policy (this tests the dangerous permission)
    local test_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]}'
    
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam put-user-policy \
             --user-name '$username' \
             --policy-name 's3-object-lock-test-policy' \
             --policy-document '$test_policy' \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124) or connection errors
    if [[ $exit_code -eq 124 || "$result" =~ (InvalidClientTokenId|connection refused|Could not connect|No route to host) ]]; then
        add_result "Put User Policy (iam:PutUserPolicy)" "N/A" "WARN"
        return 1
    fi
    
    if [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Put User Policy (iam:PutUserPolicy)" "DENIED" "OK"
        return 1
    elif [[ "$result" == "" || ! "$result" =~ (Error|error) ]]; then
        # Clean up - try to delete the policy we just created
        AWS_ACCESS_KEY_ID="$access_key" \
        AWS_SECRET_ACCESS_KEY="$secret_key" \
        aws iam delete-user-policy \
            --user-name "$username" \
            --policy-name "s3-object-lock-test-policy" \
            --region "$region" 2>/dev/null || true
        
        add_result "Put User Policy (iam:PutUserPolicy)" "GRANTED" "DANGEROUS"
        return 0
    else
        add_result "Put User Policy (iam:PutUserPolicy)" "UNKNOWN" "WARN"
        return 1
    fi
}

test_iam_attach_user_policy() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local username="$5"
    
    if [[ -z "$username" ]]; then
        add_result "Attach User Policy (iam:AttachUserPolicy)" "N/A" "WARN"
        return 1
    fi
    
    # Try to attach a policy by ARN (this tests the dangerous permission)
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam attach-user-policy \
             --user-name '$username' \
             --policy-arn 'arn:aws:iam::aws:policy/AWSS3ObjectLockTestPolicy' \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124) or connection errors
    if [[ $exit_code -eq 124 || "$result" =~ (InvalidClientTokenId|connection refused|Could not connect|No route to host) ]]; then
        add_result "Attach User Policy (iam:AttachUserPolicy)" "N/A" "WARN"
        return 1
    fi
    
    if [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Attach User Policy (iam:AttachUserPolicy)" "DENIED" "OK"
        return 1
    elif [[ "$result" =~ (NoSuchEntity|not found|does not exist) ]]; then
        # We got "not found" instead of "access denied" - permission is granted!
        add_result "Attach User Policy (iam:AttachUserPolicy)" "GRANTED" "DANGEROUS"
        return 0
    elif [[ "$result" == "" || ! "$result" =~ (Error|error) ]]; then
        add_result "Attach User Policy (iam:AttachUserPolicy)" "GRANTED" "DANGEROUS"
        return 0
    else
        add_result "Attach User Policy (iam:AttachUserPolicy)" "UNKNOWN" "WARN"
        return 1
    fi
}

test_iam_put_group_policy() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    local test_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]}'
    
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam put-group-policy \
             --group-name 's3-object-lock-test-group' \
             --policy-name 'test-policy' \
             --policy-document '$test_policy' \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124) or connection errors
    if [[ $exit_code -eq 124 || "$result" =~ (InvalidClientTokenId|connection refused|Could not connect|No route to host) ]]; then
        add_result "Put Group Policy (iam:PutGroupPolicy)" "N/A" "WARN"
        return 1
    fi
    
    if [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Put Group Policy (iam:PutGroupPolicy)" "DENIED" "OK"
        return 1
    elif [[ "$result" =~ (NoSuchEntity|not found|does not exist) ]]; then
        add_result "Put Group Policy (iam:PutGroupPolicy)" "GRANTED" "DANGEROUS"
        return 0
    elif [[ "$result" == "" || ! "$result" =~ (Error|error) ]]; then
        add_result "Put Group Policy (iam:PutGroupPolicy)" "GRANTED" "DANGEROUS"
        return 0
    else
        add_result "Put Group Policy (iam:PutGroupPolicy)" "UNKNOWN" "WARN"
        return 1
    fi
}

test_iam_attach_group_policy() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam attach-group-policy \
             --group-name 's3-object-lock-test-group' \
             --policy-arn 'arn:aws:iam::aws:policy/AWSS3ObjectLockTestPolicy' \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124) or connection errors
    if [[ $exit_code -eq 124 || "$result" =~ (InvalidClientTokenId|connection refused|Could not connect|No route to host) ]]; then
        add_result "Attach Group Policy (iam:AttachGroupPolicy)" "N/A" "WARN"
        return 1
    fi
    
    if [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Attach Group Policy (iam:AttachGroupPolicy)" "DENIED" "OK"
        return 1
    elif [[ "$result" =~ (NoSuchEntity|not found|does not exist) ]]; then
        add_result "Attach Group Policy (iam:AttachGroupPolicy)" "GRANTED" "DANGEROUS"
        return 0
    elif [[ "$result" == "" || ! "$result" =~ (Error|error) ]]; then
        add_result "Attach Group Policy (iam:AttachGroupPolicy)" "GRANTED" "DANGEROUS"
        return 0
    else
        add_result "Attach Group Policy (iam:AttachGroupPolicy)" "UNKNOWN" "WARN"
        return 1
    fi
}

test_iam_put_role_policy() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    local test_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]}'
    
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam put-role-policy \
             --role-name 's3-object-lock-test-role' \
             --policy-name 'test-policy' \
             --policy-document '$test_policy' \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124) or connection errors
    if [[ $exit_code -eq 124 || "$result" =~ (InvalidClientTokenId|connection refused|Could not connect|No route to host) ]]; then
        add_result "Put Role Policy (iam:PutRolePolicy)" "N/A" "WARN"
        return 1
    fi
    
    if [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Put Role Policy (iam:PutRolePolicy)" "DENIED" "OK"
        return 1
    elif [[ "$result" =~ (NoSuchEntity|not found|does not exist) ]]; then
        add_result "Put Role Policy (iam:PutRolePolicy)" "GRANTED" "DANGEROUS"
        return 0
    elif [[ "$result" == "" || ! "$result" =~ (Error|error) ]]; then
        # Clean up
        AWS_ACCESS_KEY_ID="$access_key" \
        AWS_SECRET_ACCESS_KEY="$secret_key" \
        aws iam delete-role-policy \
            --role-name "s3-object-lock-test-role" \
            --policy-name "test-policy" \
            --region "$region" 2>/dev/null || true
        
        add_result "Put Role Policy (iam:PutRolePolicy)" "GRANTED" "DANGEROUS"
        return 0
    else
        add_result "Put Role Policy (iam:PutRolePolicy)" "UNKNOWN" "WARN"
        return 1
    fi
}

test_iam_attach_role_policy() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    local result
    local exit_code=0
    result=$(timeout 10 bash -c "AWS_ACCESS_KEY_ID='$access_key' \
             AWS_SECRET_ACCESS_KEY='$secret_key' \
             aws iam attach-role-policy \
             --role-name 's3-object-lock-test-role' \
             --policy-arn 'arn:aws:iam::aws:policy/AWSS3ObjectLockTestPolicy' \
             --region '$region'" 2>&1) || exit_code=$?
    
    # Check for timeout (exit code 124) or connection errors
    if [[ $exit_code -eq 124 || "$result" =~ (InvalidClientTokenId|connection refused|Could not connect|No route to host) ]]; then
        add_result "Attach Role Policy (iam:AttachRolePolicy)" "N/A" "WARN"
        return 1
    fi
    
    if [[ "$result" =~ (AccessDenied|Unauthorized|Forbidden) ]]; then
        add_result "Attach Role Policy (iam:AttachRolePolicy)" "DENIED" "OK"
        return 1
    elif [[ "$result" =~ (NoSuchEntity|not found|does not exist) ]]; then
        add_result "Attach Role Policy (iam:AttachRolePolicy)" "GRANTED" "DANGEROUS"
        return 0
    elif [[ "$result" == "" || ! "$result" =~ (Error|error) ]]; then
        add_result "Attach Role Policy (iam:AttachRolePolicy)" "GRANTED" "DANGEROUS"
        return 0
    else
        add_result "Attach Role Policy (iam:AttachRolePolicy)" "UNKNOWN" "WARN"
        return 1
    fi
}

# Run IAM tests
run_iam_tests() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    
    log "INFO" "Testing IAM permissions..."
    
    # Note: IAM tests are run regardless of provider
    # Non-AWS providers will typically return connection errors or AccessDenied
    # This is still valuable information for security assessment
    
    # First, try to get current user
    local user_result
    user_result=$(test_iam_get_user "$endpoint" "$region" "$access_key" "$secret_key")
    
    local username=""
    if [[ "$user_result" == SUCCESS* ]]; then
        username=$(echo "$user_result" | sed 's/SUCCESS|//' | jq -r '.User.UserName // .User.UserId // ""' 2>/dev/null || echo "")
    fi
    
    if [[ -n "$username" ]]; then
        log "INFO" "Detected username: $username"
    else
        log "WARN" "Could not determine username - using access key ID"
        username=""
    fi
    
    # Test user-level permissions
    test_iam_put_user_policy "$endpoint" "$region" "$access_key" "$secret_key" "$username"
    test_iam_attach_user_policy "$endpoint" "$region" "$access_key" "$secret_key" "$username"
    
    # Test group and role permissions
    test_iam_put_group_policy "$endpoint" "$region" "$access_key" "$secret_key"
    test_iam_attach_group_policy "$endpoint" "$region" "$access_key" "$secret_key"
    test_iam_put_role_policy "$endpoint" "$region" "$access_key" "$secret_key"
    test_iam_attach_role_policy "$endpoint" "$region" "$access_key" "$secret_key"
}

# Cleanup test objects - delete entire folder contents at once
# Uses bypass-governance-retention for objects with retention
# Ignores failures (some objects may not be deletable due to retention)
cleanup_test_objects() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    log "INFO" "Cleaning up test objects in $TEST_PREFIX/..."
    
    # List all object versions in the test prefix
    local list_result
    list_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
                  s3api list-object-versions \
                  --bucket "$bucket" \
                  --prefix "$TEST_PREFIX/")
    
    if [[ "$list_result" != SUCCESS* ]]; then
        log "WARN" "Could not list test objects for cleanup"
        return 0
    fi
    
    local objects_json
    objects_json=$(echo "$list_result" | sed 's/SUCCESS|//')
    
    # Collect all objects to delete (versions and markers)
    local delete_objects="[]"
    
    # Add versions to delete list
    local versions_json
    versions_json=$(echo "$objects_json" | jq -c '.Versions[]? // empty' 2>/dev/null)
    if [[ -n "$versions_json" ]]; then
        while IFS= read -r version; do
            local key version_id
            key=$(echo "$version" | jq -r '.Key')
            version_id=$(echo "$version" | jq -r '.VersionId // "null"')
            if [[ -n "$key" && "$key" != "null" ]]; then
                if [[ -n "$version_id" && "$version_id" != "null" ]]; then
                    delete_objects=$(echo "$delete_objects" | jq --arg k "$key" --arg v "$version_id" '. + [{"Key": $k, "VersionId": $v}]')
                else
                    delete_objects=$(echo "$delete_objects" | jq --arg k "$key" '. + [{"Key": $k}]')
                fi
            fi
        done <<< "$versions_json"
    fi
    
    # Add delete markers to delete list
    local markers_json
    markers_json=$(echo "$objects_json" | jq -c '.DeleteMarkers[]? // empty' 2>/dev/null)
    if [[ -n "$markers_json" ]]; then
        while IFS= read -r marker; do
            local key version_id
            key=$(echo "$marker" | jq -r '.Key')
            version_id=$(echo "$marker" | jq -r '.VersionId // "null"')
            if [[ -n "$key" && "$key" != "null" ]]; then
                if [[ -n "$version_id" && "$version_id" != "null" ]]; then
                    delete_objects=$(echo "$delete_objects" | jq --arg k "$key" --arg v "$version_id" '. + [{"Key": $k, "VersionId": $v}]')
                else
                    delete_objects=$(echo "$delete_objects" | jq --arg k "$key" '. + [{"Key": $k}]')
                fi
            fi
        done <<< "$markers_json"
    fi
    
    # If there are objects to delete, use delete-objects with bypass
    local object_count
    object_count=$(echo "$delete_objects" | jq 'length')
    
    if [[ "$object_count" -gt 0 ]]; then
        log "INFO" "Deleting $object_count object versions/markers..."
        
        # Create JSON for delete-objects API
        local delete_json
        delete_json=$(jq -n --argjson objects "$delete_objects" '{"Objects": $objects, "Quiet": true}')
        
        # Try delete with bypass-governance-retention first (for retained objects)
        local delete_result
        delete_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
            s3api delete-objects \
            --bucket "$bucket" \
            --delete "$delete_json" \
            --bypass-governance-retention 2>/dev/null)
        
        # If bypass failed (permission denied), try without bypass
        if [[ "$delete_result" != SUCCESS* ]]; then
            delete_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
                s3api delete-objects \
                --bucket "$bucket" \
                --delete "$delete_json" 2>/dev/null)
        fi
        
        # Report results (don't fail on errors - some objects may have COMPLIANCE retention)
        if [[ "$delete_result" == SUCCESS* ]]; then
            local deleted errors
            deleted=$(echo "$delete_result" | sed 's/SUCCESS|//' | jq -r '.Deleted | length // 0')
            errors=$(echo "$delete_result" | sed 's/SUCCESS|//' | jq -r '.Errors | length // 0')
            log "INFO" "Cleanup: $deleted deleted, $errors errors (may have retention)"
        else
            log "WARN" "Some test objects could not be deleted (may have retention)"
        fi
    else
        log "INFO" "No test objects to clean up"
    fi
    
    return 0
}

# Detect bucket configuration (versioning, object lock, retention mode)
detect_bucket_config() {
    local endpoint="$1"
    local region="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    
    local versioning_enabled=false
    local object_lock_enabled=false
    local retention_mode=""
    
    # Check versioning status
    local versioning_result
    versioning_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
        s3api get-bucket-versioning --bucket "$bucket" 2>/dev/null)
    
    if [[ "$versioning_result" == SUCCESS* ]]; then
        local status
        status=$(echo "$versioning_result" | sed 's/SUCCESS|//' | jq -r '.Status // "Disabled"')
        if [[ "$status" == "Enabled" ]]; then
            versioning_enabled=true
        fi
    fi
    
    # Check object lock configuration
    local lock_result
    lock_result=$(run_aws_cmd "$endpoint" "$region" "$access_key" "$secret_key" \
        s3api get-object-lock-configuration --bucket "$bucket" 2>/dev/null)
    
    if [[ "$lock_result" == SUCCESS* ]]; then
        local lock_config
        lock_config=$(echo "$lock_result" | sed 's/SUCCESS|//')
        local lock_enabled
        lock_enabled=$(echo "$lock_config" | jq -r '.ObjectLockConfiguration.ObjectLockEnabled // ""')
        
        if [[ "$lock_enabled" == "Enabled" ]]; then
            object_lock_enabled=true
            # Get default retention mode if configured
            retention_mode=$(echo "$lock_config" | jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Mode // ""')
        fi
    fi
    
    # Return configuration as pipe-separated values
    echo "${versioning_enabled}|${object_lock_enabled}|${retention_mode}"
}

# Run all tests for a section
run_all_tests() {
    local section="$1"
    local bucket="$2"
    local config_data="$3"
    
    IFS='|' read -r access_key secret_key endpoint region <<< "$config_data"
    
    # Add https:// to endpoint if missing
    if [[ -n "$endpoint" && ! "$endpoint" =~ ^https?:// ]]; then
        endpoint="https://$endpoint"
    fi
    
    log "INFO" "Testing section: [$section], bucket: [$bucket]"
    log "INFO" "Endpoint: ${endpoint:-AWS S3}, Region: $region"
    
    # Reset results array
    TEST_RESULTS=()
    
    # Ensure bucket exists
    if ! ensure_test_bucket "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"; then
        log "WARN" "Could not access or create bucket: $bucket"
    fi
    
    # Detect bucket configuration
    log "INFO" "Detecting bucket configuration..."
    local bucket_config
    bucket_config=$(detect_bucket_config "$endpoint" "$region" "$access_key" "$secret_key" "$bucket")
    
    IFS='|' read -r versioning_enabled object_lock_enabled retention_mode <<< "$bucket_config"
    
    # Display bucket configuration
    echo ""
    echo "========================================"
    echo "BUCKET CONFIGURATION"
    echo "========================================"
    echo "Versioning:    $([ "$versioning_enabled" == true ] && echo "✓ Enabled" || echo "✗ Disabled")"
    echo "Object Lock:   $([ "$object_lock_enabled" == true ] && echo "✓ Enabled" || echo "✗ Disabled")"
    if [[ "$object_lock_enabled" == true && -n "$retention_mode" ]]; then
        echo "Retention Mode: $retention_mode"
    elif [[ "$object_lock_enabled" == true ]]; then
        echo "Retention Mode: (no default retention)"
    fi
    echo "========================================"
    echo ""
    
    # Run tests
    log "INFO" "Running permission tests..."
    
    # 1. List buckets (optional)
    test_list_buckets "$endpoint" "$region" "$access_key" "$secret_key"
    
    # 2. Bucket operations (always relevant)
    test_list_bucket "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    test_put_object "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    test_get_object "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    test_delete_object "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    
    # 3. Versioning operations (only if versioning is enabled)
    if [[ "$versioning_enabled" == true ]]; then
        test_list_object_versions "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
        test_put_bucket_versioning "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    else
        log "WARN" "Skipping versioning tests - versioning not enabled on bucket"
        add_result "List Object Versions (s3:ListBucketVersions)" "SKIPPED" "WARN"
        add_result "Put Bucket Versioning (s3:PutBucketVersioning)" "SKIPPED" "WARN"
    fi
    
    # 4. Object Lock operations (only if object lock is enabled)
    if [[ "$object_lock_enabled" == true ]]; then
        test_get_bucket_object_lock "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
        test_put_object_retention "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
        test_get_object_retention "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    else
        log "WARN" "Skipping object lock tests - object lock not enabled on bucket"
        add_result "Get Object Lock Config (s3:GetBucketObjectLockConfiguration)" "SKIPPED" "WARN"
        add_result "Put Object Retention (s3:PutObjectRetention)" "SKIPPED" "WARN"
        add_result "Get Object Retention (s3:GetObjectRetention)" "SKIPPED" "WARN"
    fi
    
    # 5. DANGEROUS - Bypass test (only relevant for GOVERNANCE mode)
    if [[ "$object_lock_enabled" == true ]]; then
        if [[ "$retention_mode" == "GOVERNANCE" ]]; then
            test_bypass_governance_retention "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
        elif [[ "$retention_mode" == "COMPLIANCE" ]]; then
            log "INFO" "Bucket uses COMPLIANCE mode - bypass governance retention test not applicable"
            add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "N/A" "OK"
        else
            # No default retention mode - still test as objects can have individual retention
            test_bypass_governance_retention "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
        fi
    else
        add_result "Bypass Governance Retention (s3:BypassGovernanceRetention)" "SKIPPED" "WARN"
    fi
    
    # 6. IAM permission tests (AWS only)
    run_iam_tests "$endpoint" "$region" "$access_key" "$secret_key"
    
    # Cleanup
    cleanup_test_objects "$endpoint" "$region" "$access_key" "$secret_key" "$bucket"
    
    # Print results
    print_results_table "$section:$bucket"
}

# Print summary for all sections
print_summary() {
    echo ""
    echo "========================================"
    echo "SUMMARY"
    echo "========================================"
    echo ""
    echo "Legend:"
    echo "  - OK: Permission is correctly configured"
    echo "  - REQUIRED: Permission is required but denied (needs to be granted)"
    echo "  - DANGEROUS: Permission should be denied but is granted (security risk)"
    echo "  - WARN: Permission is optional but recommended"
    echo ""
    echo "For restic + object lock extension, ensure:"
    echo "  ✓ All REQUIRED permissions are GRANTED"
    echo "  ✓ s3:BypassGovernanceRetention is DENIED"
    echo ""
    echo "For secure governance mode, also ensure:"
    echo "  ✓ All IAM policy modification permissions are DENIED:"
    echo "    - iam:PutUserPolicy"
    echo "    - iam:AttachUserPolicy"
    echo "    - iam:PutGroupPolicy"
    echo "    - iam:AttachGroupPolicy"
    echo "    - iam:PutRolePolicy"
    echo "    - iam:AttachRolePolicy"
    echo ""
    echo "These IAM permissions could allow an attacker to grant themselves"
    echo "s3:BypassGovernanceRetention and bypass the object lock protection."
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                RCLONE_CONFIG="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $(basename "$0") [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -c, --config FILE  Path to rclone.conf file (default: ./rclone.conf)"
                echo "  -h, --help         Show this help message"
                echo ""
                echo "Environment variables:"
                echo "  RCLONE_CONFIG      Path to rclone.conf file"
                echo "  BUCKETS            Space-separated list of buckets (format: config:bucket)"
                echo "                     Default: test:test"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done
    
    # Check dependencies
    command -v aws >/dev/null 2>&1 || { log "ERROR" "AWS CLI not installed"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log "ERROR" "jq not installed"; exit 1; }
    
    log "INFO" "S3 Permission Tester for Restic and Object Lock"
    log "INFO" "Using rclone config: $RCLONE_CONFIG"
    log "INFO" "Testing buckets: ${BUCKETS[*]}"
    echo ""
    
    # Test each bucket entry (format: rclone_config_name:bucket_name)
    for bucket_entry in "${BUCKETS[@]}"; do
        # Parse bucket entry
        local rclone_section bucket_name
        if [[ "$bucket_entry" == *":"* ]]; then
            rclone_section="${bucket_entry%%:*}"
            bucket_name="${bucket_entry#*:}"
        else
            log "ERROR" "Invalid bucket format '$bucket_entry'. Use 'rclone_config_name:bucket_name'"
            exit 1
        fi
        
        log "INFO" "Processing: config=[$rclone_section], bucket=[$bucket_name]"
        
        # Parse rclone.conf for this section
        local config_data
        if config_data=$(parse_rclone_config "$rclone_section" "$RCLONE_CONFIG"); then
            run_all_tests "$rclone_section" "$bucket_name" "$config_data"
        else
            log "ERROR" "Failed to parse rclone config for section [$rclone_section]"
            exit 1
        fi
    done
    
    print_summary
}

main "$@"
