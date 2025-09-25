#!/bin/bash

# Script for collecting infrastructure metrics and saving them to a CSV file
# It accepts two optional parameters: path to CSV file and disk device to monitor
# If not provided, sensible defaults are used

CSV_FILE="${1:-./infra_metrics.csv}"
DISK_DEVICE="${2:-sda}"  # Primary disk device (adjust as needed, e.g. nvme0n1)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' 

# --- log functions ---
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}


check_dependencies() {
    local deps=("kubectl" "iostat" "awk" "bc") # metrics-server is required in the cluster for 'kubectl top' to work
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "Missing dependency: $dep. The script cannot continue."
            if [ "$dep" = "iostat" ]; then
                log_info "To install: sudo apt-get install sysstat (Debian/Ubuntu) or sudo yum install sysstat (RHEL/CentOS)"
            fi
            exit 1
        fi
    done
}

# --- csv ---
init_csv() {
    if [ ! -f "$CSV_FILE" ]; then
        echo "timestamp,cpu_user,cpu_system,mem_used,mem_free,disk_root_used,disk_var_used,disk_optscale_used,top_pod_cpu,top_pod_mem,total_pods,total_pods_running,total_pods_completed,total_pods_pending,total_pods_other,rps,wps,avgqu_sz,r_await,w_await,disk_util" > "$CSV_FILE"
        if [ $? -eq 0 ]; then
            log_info "CSV file created successfully: $CSV_FILE"
        else
            log_error "Failed to create CSV file: $CSV_FILE. Check write permissions."
            exit 1
        fi
    fi
}

# --- metrics ---
get_cpu_metrics() {
    local vmstat_output
    vmstat_output=$(vmstat 1 2 | tail -1)
    local cpu_user
    local cpu_system
    cpu_user=$(echo "$vmstat_output" | awk '{print $13}')
    cpu_system=$(echo "$vmstat_output" | awk '{print $14}')
    echo "${cpu_user:-0},${cpu_system:-0}"
}

get_memory_metrics() {
    local mem_info
    mem_info=$(free -m | grep "^Mem:")
    local mem_used
    local mem_available
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    mem_available=$(echo "$mem_info" | awk '{print $7}')
    echo "$mem_used,${mem_available:-$(echo "$mem_info" | awk '{print $4}')}"
}

get_disk_usage() {
    local path=$1
    local usage=0
    if [ -d "$path" ]; then
        usage=$(df "$path" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    fi
    echo "${usage:-0}"
}

get_pod_metrics() {
    local top_cpu_pod="N/A"
    local top_mem_pod="N/A"
    local total_pods=0
    local total_pods_running=0
    local total_pods_completed=0
    local total_pods_pending=0
    local total_pods_other=0
    
    if kubectl cluster-info &> /dev/null; then
        # total pods
    total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
        
        # pods per status
    total_pods_running=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    total_pods_completed=$(kubectl get pods --all-namespaces --field-selector=status.phase=Succeeded --no-headers 2>/dev/null | wc -l)
    total_pods_pending=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
        
        # count pods in other states (failed, unknown, etc.)
    total_pods_other=$((total_pods - total_pods_running - total_pods_completed - total_pods_pending))
        

        if [ "$total_pods_other" -lt 0 ]; then
            total_pods_other=0
        fi

        # top pods by cpu and memory usage (requires metrics-server)
        if kubectl top pod --all-namespaces &> /dev/null; then
            top_cpu_pod=$(kubectl top pod --all-namespaces --no-headers --sort-by=cpu | tail -1 | awk '{print $1"/"$2}')
            top_mem_pod=$(kubectl top pod --all-namespaces --no-headers --sort-by=memory | tail -1 | awk '{print $1"/"$2}')
        else
            log_warning "'kubectl top' command failed. Metrics Server may not be installed or functioning."
        fi
    else
        log_warning "Kubernetes is not accessible; pod metrics will not be collected."
    fi
    
    echo "$top_cpu_pod,$top_mem_pod,$total_pods,$total_pods_running,$total_pods_completed,$total_pods_pending,$total_pods_other"
}

get_io_metrics() {
    local device=$1
    local iostat_output
    iostat_output=$(iostat -x 1 2 -d "$device" 2>/dev/null | grep "^$device" | tail -1)
    
    if [ -n "$iostat_output" ]; then

        local rps=$(echo "$iostat_output" | awk '{print $2}')      # r/s 
        local wps=$(echo "$iostat_output" | awk '{print $8}')      # w/s 
        local avgqu_sz=$(echo "$iostat_output" | awk '{print $(NF-1)}') # aqu-sz (average queue size)
        local r_await=$(echo "$iostat_output" | awk '{print $6}')  # r_await (ms)
        local w_await=$(echo "$iostat_output" | awk '{print $12}') # w_await (ms)
        local disk_util=$(echo "$iostat_output" | awk '{print $NF}')   # %util 
        
        echo "${rps:-0},${wps:-0},${avgqu_sz:-0},${r_await:-0},${w_await:-0},${disk_util:-0}"
    else
        log_warning "Unable to obtain I/O metrics for device '$device'." >&2
        echo "0,0,0,0,0,0"
    fi
}


collect_metrics() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    log_info "Collecting metrics..."
    
    local cpu_metrics=$(get_cpu_metrics)
    local mem_metrics=$(get_memory_metrics)
    local disk_root=$(get_disk_usage "/")
    local disk_var=$(get_disk_usage "/var")
    local disk_optscale=$(get_disk_usage "/optscale")
    local pod_metrics=$(get_pod_metrics)
    local io_metrics=$(get_io_metrics "$DISK_DEVICE")
    
    local csv_line="$timestamp,$cpu_metrics,$mem_metrics,$disk_root,$disk_var,$disk_optscale,$pod_metrics,$io_metrics"
    echo "$csv_line" >> "$CSV_FILE"
    log_info "Metrics collected and saved to $CSV_FILE"
}

# --- bottlenecks ---
analyze_bottlenecks() {
    log_info "Analyzing last collection for potential bottlenecks..."
    local last_line
    last_line=$(tail -1 "$CSV_FILE")
    IFS=',' read -r timestamp cpu_user cpu_system mem_used mem_free disk_root disk_var disk_optscale top_pod_cpu top_pod_mem total_pods total_pods_running total_pods_completed total_pods_pending total_pods_other rps wps avgqu_sz r_await w_await disk_util <<< "$last_line"


    if (( $(echo "$cpu_user + $cpu_system > 85" | bc -l) )); then
        log_warning "ALERT: High CPU usage detected: ${cpu_user}% user + ${cpu_system}% system. Total > 85%."
    fi
    

    local mem_total
    mem_total=$(free -m | grep "^Mem:" | awk '{print $2}')
    if [ "$mem_total" -gt 0 ]; then
        local mem_percent
        mem_percent=$(echo "scale=2; ($mem_used / $mem_total) * 100" | bc)
        if (( $(echo "$mem_percent > 90" | bc -l) )); then
            log_warning "ALERT: High memory usage detected: ${mem_percent}% used."
        fi
    fi
    

    if [ "$disk_root" -gt 85 ]; then
        log_warning "ALERT: Root disk low on space: ${disk_root}% used."
    fi
    

    if (( $(echo "$avgqu_sz > 5" | bc -l) )); then
        log_warning "ALERT: High I/O queue size: avgqu-sz=${avgqu_sz}. May indicate I/O saturation."
    fi
    if (( $(echo "$disk_util > 90" | bc -l) )); then
        log_warning "ALERT: Disk heavily utilized: ${disk_util}% utilization."
    fi
    

    if [ "$total_pods_other" -gt 0 ]; then
        log_warning "ALERT: ${total_pods_other} pod(s) in anomalous state detected (Failed, Unknown, etc.)."
    fi
    if [ "$total_pods_pending" -gt 0 ]; then
        log_warning "ALERT: ${total_pods_pending} pod(s) pending. May indicate resource starvation."
    fi
    

    log_info "Pod status - Total: $total_pods | Running: $total_pods_running | Completed: $total_pods_completed | Pending: $total_pods_pending | Other: $total_pods_other"
}

# --- main ---
main() {
    log_info "Starting single-run execution of the monitoring script."
    
    check_dependencies
    init_csv
    


    collect_metrics
    analyze_bottlenecks
    
    log_info "Execution completed."
}


main "$@"