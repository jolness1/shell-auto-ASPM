#!/bin/bash
# Auto-ASPM: Enable PCIe Active State Power Management on supported devices
# Reduces power consumption by 5-15% by allowing PCIe links to enter low-power states
# Usage: sudo ./autoaspm-compact.sh [--dry-run] [--backup-dir DIR] [--restore FILE]

set -euo pipefail

# Constants
readonly ASPM_DISABLED=0 ASPM_L0S=1 ASPM_L1=2 ASPM_L0S_L1=3
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
readonly BACKUP_DIR="${BACKUP_DIR:-/tmp/aspm_backup_$(date +%Y%m%d_%H%M%S)}"

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Prerequisites check
check_prereqs() {
    [[ "$(uname -s)" == "Linux" ]] || { log_error "Linux required"; exit 1; }
    [[ $EUID -eq 0 || -n "${SUDO_UID:-}" ]] || { log_error "Root privileges required. Use: sudo $0"; exit 1; }
    for tool in lspci setpci; do
        command -v "$tool" &>/dev/null || { log_error "$tool not found. Install pciutils"; exit 1; }
    done
}

# Device and register manipulation
get_device_name() { lspci -s "$1" | head -n1; }
hex_to_dec() { printf "%d" "0x$1"; }
read_device_bytes() { lspci -s "$1" -xxx | grep -v "$(get_device_name "$1")" | grep ": " | cut -d: -f2 | tr -d ' \n'; }

find_patch_position() {
    local hex_bytes="$1" pos="$2" current_dec
    current_dec=$(hex_to_dec "${hex_bytes:$((pos * 2)):2}")
    [[ $current_dec -eq 16 ]] && echo $((pos + 16)) || find_patch_position "$hex_bytes" $((pos + 1))
}

backup_and_patch() {
    local device="$1" aspm_value="$2" backup_file device_name endpoint_bytes
    
    device_name=$(get_device_name "$device")
    log_info "Processing: $device_name"
    
    # Create backup
    mkdir -p "$BACKUP_DIR"
    backup_file="$BACKUP_DIR/${device//:/_}.backup"
    lspci -s "$device" -xxx > "$backup_file"
    
    # Read and validate device configuration
    endpoint_bytes=$(read_device_bytes "$device")
    [[ ${#endpoint_bytes} -lt 512 ]] && { log_error "Failed to read device $device"; return 1; }
    
    # Find and patch ASPM register
    local patch_pos current_byte_hex current_byte_dec current_aspm
    patch_pos=$(find_patch_position "$endpoint_bytes" 52)  # 0x34 = 52
    current_byte_hex="${endpoint_bytes:$((patch_pos * 2)):2}"
    current_byte_dec=$(hex_to_dec "$current_byte_hex")
    current_aspm=$((current_byte_dec & 3))
    
    if [[ $current_aspm -ne $aspm_value ]]; then
        local patched_byte=$(( ((current_byte_dec >> 2) << 2) | aspm_value ))
        setpci -s "$device" "$(printf "%02x" $patch_pos).B=$(printf "%02x" $patched_byte)" 2>/dev/null
        log_info "$device: Enabled ASPM $(get_aspm_name $aspm_value)"
    else
        log_info "$device: Already has ASPM $(get_aspm_name $aspm_value)"
    fi
}

# ASPM mode conversion
get_aspm_name() {
    case $1 in
        $ASPM_DISABLED) echo "DISABLED" ;;
        $ASPM_L0S) echo "L0s" ;;  
        $ASPM_L1) echo "L1" ;;
        $ASPM_L0S_L1) echo "L0sL1" ;;
        *) echo "UNKNOWN" ;;
    esac
}

parse_aspm_mode() {
    case "$1" in
        "L0s") echo $ASPM_L0S ;;
        "L1") echo $ASPM_L1 ;;
        "L0sL1"|"L0s L1") echo $ASPM_L0S_L1 ;;
        *) [[ "$1" == *"L0s"* && "$1" == *"L1"* ]] && echo $ASPM_L0S_L1 || 
           [[ "$1" == *"L0s"* ]] && echo $ASPM_L0S ||
           [[ "$1" == *"L1"* ]] && echo $ASPM_L1 || echo $ASPM_DISABLED ;;
    esac
}

# Read the current enabled ASPM bits from the device config space.
# Returns 0/1/2/3 on stdout (matching ASPM_* constants) or non-zero on failure.
get_current_aspm() {
    local device="$1" endpoint_bytes patch_pos current_byte_hex current_byte_dec
    endpoint_bytes=$(read_device_bytes "$device") || return 1
    [[ ${#endpoint_bytes} -lt 512 ]] && return 1
    patch_pos=$(find_patch_position "$endpoint_bytes" 52) || return 1
    current_byte_hex="${endpoint_bytes:$((patch_pos * 2)):2}"
    current_byte_dec=$(hex_to_dec "$current_byte_hex")
    echo $(( current_byte_dec & 3 ))
}

# Device discovery using AWK for reliable parsing
find_aspm_devices() {
    lspci -vv 2>/dev/null | awk '
    /^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]/ { device = $1 }
    /^[[:space:]]*LnkCap:.*ASPM/ && device != "" && !/ASPM not supported/ { 
        if (match($0, /ASPM (L[0-9s ]+)/)) {
            aspm = substr($0, RSTART+5, RLENGTH-5)
            gsub(/,.*$/, "", aspm)
            gsub(/^[ \t]+|[ \t]+$/, "", aspm)
            print device "|" aspm
        }
        device = ""
    }'
}

# Note: restore functionality moved to restoreaspmbackup.sh

# Usage information
show_help() {
    cat << 'EOF'
Usage: ./autoaspm.sh [OPTIONS]

Enable PCIe ASPM on supported devices to reduce power consumption.

OPTIONS:
  -h, --help          Show this help
  -n, --dry-run       Preview changes without applying
  -b, --backup-dir    Custom backup directory  
    (Restore functionality is provided by ./restoreaspmbackup.sh)

Examples:
    sudo ./autoaspm.sh --dry-run        # Safe preview
    sudo ./autoaspm.sh                  # Apply ASPM settings
EOF
}

# Main execution
format_device_text() {
    # $1 = raw lspci line, $2 = verbose flag (true/false)
    local raw="$1" verbose="$2" short
    if [[ "$verbose" == true ]]; then
        # full cleaned line (strip leading id)
        echo "$raw" | sed -E 's/^[[:space:]]*[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f][[:space:]]*//' | tr -s '[:space:]' ' '
        return
    fi
    # short: try to extract "class: vendor" or vendor + short model
    # common lspci format: "04:00.0 Class: Vendor Device (rev 03)"
    short=$(echo "$raw" | sed -E 's/^[[:space:]]*[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f][[:space:]]*//')
    # try vendor and short name (first 40 chars)
    short=$(echo "$short" | sed -E 's/\(rev .*\)//' | awk -F": " '{ if (NF>1) { print $2 } else { print $0 } }' | cut -c1-60)
    echo "$short"
}

main() {
    local dry_run=false restore_file="" verbose=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -n|--dry-run) dry_run=true; shift ;;
            -b|--backup-dir) BACKUP_DIR="$2"; shift 2 ;;
            -r|--restore) restore_file="$2"; shift 2 ;;
            -v|--verbose) verbose=true; shift ;;
            *) log_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
    
    # Restores are handled by the separate `restoreaspmbackup.sh` utility
    
    # Main execution
    check_prereqs
    log_info "Checking prerequisites... OK"
    
    # Discover and process ASPM devices
    mapfile -t devices < <(find_aspm_devices)
    [[ ${#devices[@]} -eq 0 ]] && { log_warn "No ASPM-capable devices found"; exit 0; }
    
    log_info "Found ${#devices[@]} ASPM-capable device(s)"
    
    for device_info in "${devices[@]}"; do
        IFS='|' read -r device_addr aspm_mode_text <<< "$device_info"
        local aspm_numeric
        aspm_numeric=$(parse_aspm_mode "$aspm_mode_text")
        
        # Fetch a human readable device string once (single-line, tolerant of failure)
    # Get lspci short description, strip leading PCI address if present
    raw_desc=$( { lspci -s "$device_addr" 2>/dev/null || echo "$device_addr"; } | head -n1 )
    device_text=$(format_device_text "$raw_desc" "$verbose")
        # Truncate long descriptions to keep output tidy
        if [[ ${#device_text} -gt 100 ]]; then
            device_text="${device_text:0:97}..."
        fi
        if [[ "$dry_run" == true ]]; then
            # check current enabled ASPM and only propose changes if different
            current=$(get_current_aspm "$device_addr" 2>/dev/null || echo "")
            if [[ -z "$current" ]]; then
                log_info "[DRY RUN] Would enable ASPM $(get_aspm_name $aspm_numeric) for: $device_addr - $device_text (unable to read current state)"
            elif [[ "$current" -eq "$aspm_numeric" ]]; then
                log_info "[DRY RUN] Already has ASPM $(get_aspm_name $aspm_numeric) enabled for: $device_addr - $device_text"
            else
                log_info "[DRY RUN] Would enable ASPM $(get_aspm_name $aspm_numeric) for: $device_addr - $device_text (current=$(get_aspm_name $current))"
            fi
        else
            log_info "Processing $device_addr - $device_text"
            backup_and_patch "$device_addr" "$aspm_numeric"
        fi
    done
    
    [[ "$dry_run" == false ]] && {
        log_info "ASPM configuration completed successfully"
        log_info "Backups saved to: $BACKUP_DIR"
        log_info "To restore: sudo ./restoreaspmbackup.sh $BACKUP_DIR"
    }
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"