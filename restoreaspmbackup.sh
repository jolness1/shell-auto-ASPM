#!/bin/bash

# ASPM Backup Restore Script
# Restores PCIe ASPM configurations from backup files created by autoaspm.sh

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [BACKUP_DIR_OR_FILE]

Restore PCIe ASPM configurations from autoaspm.sh backup files.

OPTIONS:
    -h, --help          Show this help message
    -l, --list          List available backup directories and files
    -f, --force         Skip confirmation prompts
    -d, --device ADDR   Restore specific device only (e.g., 00:1f.2)

ARGUMENTS:
    BACKUP_DIR_OR_FILE  Path to backup directory or specific backup file
                        If not provided, will show available backups

EXAMPLES:
    $0 --list                                    # List available backups
    $0 /tmp/aspm_backup_20250925_143022         # Restore from directory
    $0 /tmp/aspm_backup_*/001f2.backup          # Restore specific device
    $0 --device 00:1f.2 /tmp/aspm_backup_*     # Restore one device from backup

EOF
}

check_prerequisites() {
    if [[ $EUID -ne 0 && -z "${SUDO_UID:-}" ]]; then
        log_error "This script needs root privileges to run"
        exit 1
    fi
    
    for tool in lspci setpci; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool not detected. Please install pciutils"
            exit 1
        fi
    done
}

list_backups() {
    log_info "Available ASPM backup directories:"
    
    local backup_dirs=(/tmp/aspm_backup_*)
    if [[ ! -e "${backup_dirs[0]}" ]]; then
        log_warn "No ASPM backup directories found in /tmp/"
        return 0
    fi
    
    for dir in "${backup_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local backup_count=$(find "$dir" -name "*.backup" 2>/dev/null | wc -l)
            local timestamp=$(basename "$dir" | sed 's/asmp_backup_//')
            echo "  📁 $dir ($backup_count device backups, created: $timestamp)"
            
            # Show device list if not too many
            if [[ $backup_count -le 10 ]]; then
                find "$dir" -name "*.backup" 2>/dev/null | while read -r backup_file; do
                    local device_id=$(basename "$backup_file" .backup | sed 's/_/:/g')
                    echo "     └── $device_id"
                done
            fi
        fi
    done
}

parse_backup_file() {
    local backup_file="$1"
    local device_addr=""
    local patch_data=()
    
    # Extract device address from filename
    device_addr=$(basename "$backup_file" .backup | sed 's/_/:/g')
    
    # Parse lspci -xxx output to extract register values
    while IFS= read -r line; do
        if [[ $line =~ ^[0-9a-f]+:[[:space:]]([0-9a-f[:space:]]+) ]]; then
            local offset="${line%%:*}"
            local hex_data="${BASH_REMATCH[1]}"
            # Convert to array of register offset:value pairs for restoration
            local pos=0
            for byte in $hex_data; do
                local reg_offset=$((0x$offset + pos))
                patch_data+=("$(printf "%02x" $reg_offset):$byte")
                ((pos++))
            done
        fi
    done < "$backup_file"
    
    echo "$device_addr"
    printf '%s\n' "${patch_data[@]}"
}

restore_device() {
    local backup_file="$1"
    local device_addr="$2"
    local force="${3:-false}"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    # Verify device exists
    if ! lspci -s "$device_addr" &>/dev/null; then
        log_error "Device $device_addr not found in system"
        return 1
    fi
    
    local device_name
    device_name=$(lspci -s "$device_addr" | head -n1)
    log_info "Restoring configuration for: $device_name"
    
    # Show current vs backup comparison
    log_info "Current PCIe configuration:"
    lspci -s "$device_addr" -xxx | head -5 | sed 's/^/  /'
    
    echo
    log_info "Backup configuration (from $(stat -c %y "$backup_file" | cut -d. -f1)):"
    head -5 "$backup_file" | sed 's/^/  /'
    
    if [[ "$force" != true ]]; then
        echo
        read -p "Continue with restore? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Restore cancelled"
            return 0
        fi
    fi
    
    # Create current state backup before restore
    local current_backup="/tmp/pre_restore_$(basename "$backup_file")"
    lspci -s "$device_addr" -xxx > "$current_backup"
    log_info "Current state backed up to: $current_backup"
    
    # Parse and apply restore data
    local restore_data
    mapfile -t restore_data < <(parse_backup_file "$backup_file" | tail -n +2)
    
    log_info "Applying restore data..."
    local restored_count=0
    
    # Focus on critical ASPM registers (typically around 0x50-0x60 range)
    for data_pair in "${restore_data[@]}"; do
        if [[ $data_pair =~ ^([0-9a-f]+):([0-9a-f]+)$ ]]; then
            local offset="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Only restore PCIe capability registers (0x40-0xFF range typically)
            local offset_dec=$((0x$offset))
            if [[ $offset_dec -ge 64 && $offset_dec -le 255 ]]; then
                setpci -s "$device_addr" "${offset}.B=${value}" 2>/dev/null || {
                    log_warn "Failed to restore register $offset (may be read-only)"
                }
                ((restored_count++))
            fi
        fi
    done
    
    log_info "Restored $restored_count register values"
    
    # Verify restoration
    echo
    log_info "Post-restore configuration:"
    lspci -s "$device_addr" -xxx | head -5 | sed 's/^/  /'
}

restore_directory() {
    local backup_dir="$1"
    local target_device="${2:-}"
    local force="${3:-false}"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory not found: $backup_dir"
        return 1
    fi
    
    local backup_files=("$backup_dir"/*.backup)
    if [[ ! -e "${backup_files[0]}" ]]; then
        log_error "No backup files found in: $backup_dir"
        return 1
    fi
    
    log_info "Found ${#backup_files[@]} device backup(s) in: $backup_dir"
    
    for backup_file in "${backup_files[@]}"; do
        local device_addr
        device_addr=$(basename "$backup_file" .backup | sed 's/_/:/g')
        
        # Skip if specific device requested and this isn't it
        if [[ -n "$target_device" && "$device_addr" != "$target_device" ]]; then
            continue
        fi
        
        echo
        restore_device "$backup_file" "$device_addr" "$force"
    done
}

main() {
    local list_mode=false
    local force_mode=false
    local target_device=""
    local backup_path=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) show_usage; exit 0 ;;
            -l|--list) list_mode=true; shift ;;
            -f|--force) force_mode=true; shift ;;
            -d|--device) target_device="$2"; shift 2 ;;
            -*) log_error "Unknown option: $1"; show_usage; exit 1 ;;
            *) backup_path="$1"; shift ;;
        esac
    done
    
    check_prerequisites
    
    if [[ "$list_mode" == true ]]; then
        list_backups
        exit 0
    fi
    
    if [[ -z "$backup_path" ]]; then
        log_info "No backup path specified. Showing available backups:"
        echo
        list_backups
        echo
        log_info "Use: $0 <backup_path> to restore"
        exit 0
    fi
    
    # Handle glob patterns
    if [[ "$backup_path" == *"*"* ]]; then
        local expanded_paths=($backup_path)
        if [[ ${#expanded_paths[@]} -eq 1 && -e "${expanded_paths[0]}" ]]; then
            backup_path="${expanded_paths[0]}"
        else
            log_error "Glob pattern matched ${#expanded_paths[@]} paths. Please be more specific."
            exit 1
        fi
    fi
    
    if [[ -f "$backup_path" ]]; then
        # Single file restore
        local device_addr
        device_addr=$(basename "$backup_path" .backup | sed 's/_/:/g')
        restore_device "$backup_path" "$device_addr" "$force_mode"
    elif [[ -d "$backup_path" ]]; then
        # Directory restore
        restore_directory "$backup_path" "$target_device" "$force_mode"
    else
        log_error "Backup path not found: $backup_path"
        exit 1
    fi
    
    echo
    log_info "Restore completed. You may want to reboot to ensure all changes take effect."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi