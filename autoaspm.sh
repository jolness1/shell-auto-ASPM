#!/bin/bash
# Usage: sudo ./autoaspm.sh [--dry-run]

set -euo pipefail
# consts
readonly ASPM_DISABLED=0  # 0b00
readonly ASPM_L0S=1       # 0b01  
readonly ASPM_L1=2        # 0b10
readonly ASPM_L0S_L1=3    # 0b11

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

# logging
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# prerequisites check
check_prereqs() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This script only runs on Linux-based systems"
        exit 1
    fi
    
    if [[ $EUID -ne 0 && -z "${SUDO_UID:-}" ]]; then
        log_error "This script needs root privileges to run"
        exit 1
    fi
    
    if ! command -v lspci &>/dev/null; then
        log_error "lspci not detected. Please install pciutils"
        exit 1
    fi
    
    if ! command -v setpci &>/dev/null; then
        log_error "setpci not detected. Please install pciutils"
        exit 1
    fi
}

# read all bytes from device
read_all_bytes() {
    local device="$1"
    local all_bytes line hex_part
    local lspci_output
    lspci_output=$(lspci -s "$device" -xxx 2>/dev/null | sed '1d')

    all_bytes=""
    while IFS= read -r line; do
        if [[ "$line" == *": "* ]]; then
            hex_part="${line#*: }"
            hex_part="${hex_part// /}"
            all_bytes+="$hex_part"
        fi
    done <<< "$lspci_output"
    
    # check min length (256 bytes = 512 hex chars)
    if [[ ${#all_bytes} -lt 512 ]]; then
        log_error "Failed to read sufficient bytes from device $device (got ${#all_bytes} chars, need 512)"
        return 1
    fi
    
    echo "$all_bytes"
}

# convert hex string to decimal
hex_to_dec() {
    printf "%d" "0x$1"
}

find_byte_to_patch() {
    local hex_bytes="$1"
    local pos="$2"
    
    local byte_hex="${hex_bytes:$((pos * 2)):2}"
    local byte_dec
    byte_dec=$(hex_to_dec "$byte_hex")
    pos="$byte_dec"
    
    byte_hex="${hex_bytes:$((pos * 2)):2}"
    byte_dec=$(hex_to_dec "$byte_hex")
    
    if [[ $byte_dec -ne 16 ]]; then
        find_byte_to_patch "$hex_bytes" $((pos + 1))
    else
        echo $((pos + 16))
    fi
}

# patch byte
patch_byte() {
    local device="$1"
    local position="$2" 
    local value="$3"
    
    local hex_pos hex_val
    hex_pos=$(printf "%x" "$position")
    hex_val=$(printf "%x" "$value")
    
    setpci -s "$device" "${hex_pos}.B=${hex_val}" 2>/dev/null
}

# patch device
patch_device() {
    local addr="$1" 
    local aspm_value="$2"
    local dry_run="${3:-false}"
    
    local hex_bytes patch_pos byte_hex byte_dec current_aspm
    
    hex_bytes=$(read_all_bytes "$addr") || {
        log_error "Failed to read bytes from device $addr"
        return 1
    }
    
    patch_pos=$(find_byte_to_patch "$hex_bytes" 52) || {  # 0x34 = 52
        log_error "Failed to find patch position for device $addr"
        return 1
    }
    
    # get current byte value
    byte_hex="${hex_bytes:$((patch_pos * 2)):2}"
    byte_dec=$(hex_to_dec "$byte_hex")
    current_aspm=$((byte_dec & 3))
    
    if [[ $current_aspm -ne $aspm_value ]]; then
        local patched_byte=$(( ((byte_dec >> 2) << 2) | aspm_value ))
        
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] Would enable ASPM $(get_aspm_name "$aspm_value") for: $addr (current=$(get_aspm_name "$current_aspm"))"
        else
            patch_byte "$addr" "$patch_pos" "$patched_byte"
            log_info "$addr: Enabled ASPM $(get_aspm_name "$aspm_value")"
        fi
    else
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] Already has ASPM $(get_aspm_name "$aspm_value") enabled for: $addr"
        else
            log_info "$addr: Already has ASPM $(get_aspm_name "$aspm_value") enabled"
        fi
    fi
}

# ASPM name conversion
get_aspm_name() {
    case $1 in
        "$ASPM_DISABLED") echo "DISABLED" ;;
        "$ASPM_L0S") echo "L0s" ;;
        "$ASPM_L1") echo "L1" ;;
        "$ASPM_L0S_L1") echo "L0sL1" ;;
        *) echo "UNKNOWN($1)" ;;
    esac
}

# parse ASPM mode from string to numeric
parse_aspm_mode() {
    local mode="$1"
    mode="${mode// /}"
    
    case "$mode" in
        "L0s") echo $ASPM_L0S ;;
        "L1") echo $ASPM_L1 ;;
        "L0sL1") echo $ASPM_L0S_L1 ;;
        *) 
            log_warn "Unknown ASPM mode: '$mode', defaulting to DISABLED"
            echo $ASPM_DISABLED 
            ;;
    esac
}

# list supported devices
list_supported_devices() {
    local lspci_output
    
    # full lspci output
    lspci_output=$(lspci -vv 2>/dev/null)
    echo "$lspci_output" | awk '
    BEGIN { 
        device = ""
        device_block = ""
    }
    
    # Match device address line
    /^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]/ { 
        # Process previous device block if we have one
        if (device != "" && device_block != "") {
            process_device(device, device_block)
        }
        
        # Start new device
        device = $1 
        device_block = $0
        next
    }
    
    # Accumulate lines for current device
    device != "" {
        device_block = device_block "\n" $0
    }
    
    # Process final device at end
    END {
        if (device != "" && device_block != "") {
            process_device(device, device_block)
        }
    }
    
    function process_device(dev_addr, block_text) {
        # Skip if no ASPM or ASPM not supported - matches Python logic
        if (block_text !~ /ASPM/ || block_text ~ /ASPM not supported/) {
            return
        }
        
        # Find ASPM support - matches Python regex r"ASPM (L[L0-1s ]*),?"
        if (match(block_text, /ASPM (L[L0-9s ]*)/)) {
            aspm_text = substr(block_text, RSTART+5, RLENGTH-5)
            # Remove trailing comma if present
            gsub(/,$/, "", aspm_text)
            # extract first line (header) for a short device description
            first_nl = index(block_text, "\n")
            if (first_nl > 0) {
                header = substr(block_text, 1, first_nl-1)
            } else {
                header = block_text
            }
            # remove the leading device address and whitespace from header
            sub(/^[^ ]+ +/, "", header)
            print dev_addr "|" aspm_text "|" header
        }
    }'
}

show_help() {
    cat << 'EOF'
Usage: ./autoaspm_fixed.sh [OPTIONS]

Enable PCIe ASPM on supported devices to reduce power consumption.
Rewritten to match Python version exactly with corrected logic.

OPTIONS:
  -h, --help          Show this help
  -n, --dry-run       Preview changes without applying

Examples:
    sudo ./autoaspm_fixed.sh --dry-run     # Safe preview
    sudo ./autoaspm_fixed.sh               # Apply ASPM settings
EOF
}

main() {
    local dry_run=false
    
    # parse args
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_help; exit 0 ;;
            -n|--dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
    
    check_prereqs
    
    # get supported devices
    mapfile -t devices < <(list_supported_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log_warn "No ASPM-capable devices found"
        exit 0
    fi
    
    log_info "Found ${#devices[@]} ASPM-capable device(s)"
    
    # process each device
    for device_info in "${devices[@]}"; do
        if [[ -z "$device_info" ]]; then
            continue
        fi
        
    IFS='|' read -r device_addr aspm_mode_text device_desc <<< "$device_info"
        
        if [[ -z "$device_addr" || -z "$aspm_mode_text" ]]; then
            log_warn "Skipping malformed device info: '$device_info'"
            continue
        fi
        
        local aspm_numeric
        aspm_numeric=$(parse_aspm_mode "$aspm_mode_text")
        
    log_info "Processing $device_addr ($aspm_mode_text) - ${device_desc:-Unknown device}"
        patch_device "$device_addr" "$aspm_numeric" "$dry_run"
    done
    
    if [[ "$dry_run" == "false" ]]; then
        log_info "ASPM configuration completed successfully"
    fi
}

# only run main if script is executed directly
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"