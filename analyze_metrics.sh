#!/bin/bash

# Infrastructure Metrics Analysis Script
# Description: Analyze the CSV produced by `monitor.sh` to identify usage spikes and patterns

# --- Settings ---
CSV_FILE="${1:-./infra_metrics.csv}"
OUTPUT_REPORT="${2:-./analysis_report.txt}"

# Thresholds for peak detection (configurable)
CPU_THRESHOLD=80          # % total CPU (user + system)
MEM_THRESHOLD=85          # % Memory used
DISK_THRESHOLD=90         # % Disk usage
IO_UTIL_THRESHOLD=85      # % I/O utilization
IO_QUEUE_THRESHOLD=3      # I/O queue size
PODS_OTHER_THRESHOLD=1    # Number of pods in anomalous state

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# --- Log Functions ---
log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_analysis() {
    echo -e "${BLUE}[ANALYSIS]${NC} $1"
}

log_peak() {
    echo -e "${PURPLE}[PEAK]${NC} $1"
}

# --- Initial Checks ---
check_dependencies() {
    local deps=("awk" "bc" "sort" "uniq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "Missing dependency: $dep. The script cannot continue."
            exit 1
        fi
    done
}

validate_csv() {
    if [ ! -f "$CSV_FILE" ]; then
        log_error "CSV file not found: $CSV_FILE"
        exit 1
    fi
    
    local line_count=$(wc -l < "$CSV_FILE")
    if [ "$line_count" -le 1 ]; then
        log_error "CSV file is empty or contains only the header. At least 2 lines required."
        exit 1
    fi
    
    log_info "CSV validated: $line_count lines found"
}

# --- Funções de Análise ---

# Calcula estatísticas básicas para uma coluna
calculate_stats() {
    local column=$1
    local values=$2
    
    if [ -z "$values" ]; then
        echo "0,0,0,0"
        return
    fi
    
    local min max avg count
    min=$(echo "$values" | sort -n | head -1)
    max=$(echo "$values" | sort -n | tail -1)
    count=$(echo "$values" | wc -l)
    avg=$(echo "$values" | awk '{sum+=$1} END {if(NR>0) print sum/NR; else print 0}')
    
    echo "$min,$max,$avg,$count"
}

# Identifica picos baseado em limiar
find_peaks() {
    local metric_name=$1
    local column_index=$2
    local threshold=$3
    local comparison=${4:-"gt"}  # gt (greater than) ou lt (less than)
    
    log_analysis "Analyzing peaks for $metric_name (threshold: $threshold)"
    
    local peaks_found=0
    local peak_times=()
    local peak_intervals=()
    local last_peak_time=""
    
    # Processa cada linha do CSV (exceto cabeçalho)
    tail -n +2 "$CSV_FILE" | while IFS=',' read -r timestamp cpu_user cpu_system mem_used mem_free disk_root disk_var disk_optscale top_pod_cpu top_pod_mem total_pods total_pods_running total_pods_completed total_pods_pending total_pods_other rps wps avgqu_sz r_await w_await disk_util; do
        
        local value
        case $column_index in
            "cpu_total") 
                value=$(echo "$cpu_user + $cpu_system" | bc -l)
                ;;
            "mem_percent") 
                if [ "$mem_used" != "0" ] && [ "$mem_free" != "0" ]; then
                    local total=$((mem_used + mem_free))
                    value=$(echo "scale=2; ($mem_used / $total) * 100" | bc -l)
                else
                    value=0
                fi
                ;;
            "disk_root") value="$disk_root" ;;
            "disk_var") value="$disk_var" ;;
            "disk_optscale") value="$disk_optscale" ;;
            "disk_util") value="$disk_util" ;;
            "avgqu_sz") value="$avgqu_sz" ;;
            "total_pods_other") value="$total_pods_other" ;;
            *) value=0 ;;
        esac
        
    # Check if it's a peak
        local is_peak=false
        if [ "$comparison" = "gt" ]; then
            if (( $(echo "$value > $threshold" | bc -l) )); then
                is_peak=true
            fi
        else
            if (( $(echo "$value < $threshold" | bc -l) )); then
                is_peak=true
            fi
        fi
        
        if [ "$is_peak" = true ]; then
            echo "PEAK: $timestamp - $metric_name: $value"
            
            # Calcula intervalo desde o último pico
            if [ -n "$last_peak_time" ]; then
                local interval_seconds
                interval_seconds=$(( $(date -d "$timestamp" +%s) - $(date -d "$last_peak_time" +%s) ))
                local interval_minutes=$((interval_seconds / 60))
                echo "  → Interval since last peak: ${interval_minutes} minutes"
            fi
            
            last_peak_time="$timestamp"
            ((peaks_found++))
        fi
    done
    
    if [ $peaks_found -eq 0 ]; then
        echo "No peaks found for $metric_name"
    fi
}

# Analisa padrões temporais
analyze_time_patterns() {
    log_analysis "Analyzing time-based usage patterns"
    
    echo "=== ANALYSIS BY HOUR ==="
    
    # Agrupa por hora do dia
    tail -n +2 "$CSV_FILE" | awk -F',' '{
        split($1, dt, " ");
        split(dt[2], time, ":");
        hour = time[1];
        cpu_total = $2 + $3;
        mem_used = $4;
        mem_free = $5;
        if(mem_used + mem_free > 0) {
            mem_percent = (mem_used / (mem_used + mem_free)) * 100;
        } else {
            mem_percent = 0;
        }
        
        cpu_by_hour[hour] += cpu_total;
        mem_by_hour[hour] += mem_percent;
        count_by_hour[hour]++;
    }
    END {
        for(hour in cpu_by_hour) {
            avg_cpu = cpu_by_hour[hour] / count_by_hour[hour];
            avg_mem = mem_by_hour[hour] / count_by_hour[hour];
            printf "Hour %02d:00 - CPU: %.1f%% | Memory: %.1f%% | Samples: %d\n", hour, avg_cpu, avg_mem, count_by_hour[hour];
        }
    }' | sort
}

# Detecta tendências de crescimento
detect_trends() {
    log_analysis "Detecting growth/decline trends"
    
    # Analisa últimas 20 amostras vs primeiras 20 amostras
    local recent_data=$(tail -20 "$CSV_FILE" | tail -n +1)
    local old_data=$(head -21 "$CSV_FILE" | tail -20)
    
    if [ $(echo "$recent_data" | wc -l) -lt 10 ] || [ $(echo "$old_data" | wc -l) -lt 10 ]; then
        echo "Insufficient data for trend analysis (minimum 40 samples)"
        return
    fi
    
    # CPU
    local recent_cpu_avg=$(echo "$recent_data" | awk -F',' '{sum+=$2+$3} END {print sum/NR}')
    local old_cpu_avg=$(echo "$old_data" | awk -F',' '{sum+=$2+$3} END {print sum/NR}')
    local cpu_trend=$(echo "scale=2; $recent_cpu_avg - $old_cpu_avg" | bc)
    
    # Memória
    local recent_mem_avg=$(echo "$recent_data" | awk -F',' '{sum+=$4} END {print sum/NR}')
    local old_mem_avg=$(echo "$old_data" | awk -F',' '{sum+=$4} END {print sum/NR}')
    local mem_trend=$(echo "scale=2; $recent_mem_avg - $old_mem_avg" | bc)
    
    echo "=== TRENDS (Last 20 vs First 20 samples) ==="
    printf "CPU: "
    if (( $(echo "$cpu_trend > 5" | bc -l) )); then
        echo -e "${RED}↗ Significant increase (+${cpu_trend}%)${NC}"
    elif (( $(echo "$cpu_trend < -5" | bc -l) )); then
        echo -e "${GREEN}↘ Significant decrease (${cpu_trend}%)${NC}"
    else
        echo -e "${YELLOW}→ Stable (${cpu_trend}%)${NC}"
    fi
    
    printf "Memory: "
    if (( $(echo "$mem_trend > 100" | bc -l) )); then
        echo -e "${RED}↗ Significant increase (+${mem_trend}MB)${NC}"
    elif (( $(echo "$mem_trend < -100" | bc -l) )); then
        echo -e "${GREEN}↘ Significant decrease (${mem_trend}MB)${NC}"
    else
        echo -e "${YELLOW}→ Stable (${mem_trend}MB)${NC}"
    fi
}

# Gera estatísticas gerais
generate_statistics() {
    log_analysis "Generating general statistics"
    
    echo "=== GENERAL STATISTICS ==="
    
    # Período de análise
    local first_timestamp=$(tail -n +2 "$CSV_FILE" | head -1 | cut -d',' -f1)
    local last_timestamp=$(tail -1 "$CSV_FILE" | cut -d',' -f1)
    local total_samples=$(tail -n +2 "$CSV_FILE" | wc -l)
    
    echo "Analysis period: $first_timestamp to $last_timestamp"
    echo "Total samples: $total_samples"
    
    # Tempo total (aproximado)
    if command -v date >/dev/null 2>&1; then
        local start_epoch=$(date -d "$first_timestamp" +%s 2>/dev/null || echo 0)
        local end_epoch=$(date -d "$last_timestamp" +%s 2>/dev/null || echo 0)
        if [ $start_epoch -ne 0 ] && [ $end_epoch -ne 0 ]; then
            local duration_hours=$(( (end_epoch - start_epoch) / 3600 ))
            echo "Monitoring duration: ${duration_hours} hours"
        fi
    fi
    
    echo ""

    # CPU Statistics
    local cpu_values=$(tail -n +2 "$CSV_FILE" | awk -F',' '{print $2+$3}')
    local cpu_stats=$(calculate_stats "CPU" "$cpu_values")
    IFS=',' read -r cpu_min cpu_max cpu_avg cpu_count <<< "$cpu_stats"
    
    echo "CPU (User + System):"
    printf "  Min: %.1f%% | Max: %.1f%% | Avg: %.1f%%\n" "$cpu_min" "$cpu_max" "$cpu_avg"
    
    # Memory Statistics
    local mem_values=$(tail -n +2 "$CSV_FILE" | awk -F',' '{print $4}')
    local mem_stats=$(calculate_stats "Memory" "$mem_values")
    IFS=',' read -r mem_min mem_max mem_avg mem_count <<< "$mem_stats"
    
    echo "Memory Used (MB):"
    printf "  Min: %.0f MB | Max: %.0f MB | Avg: %.0f MB\n" "$mem_min" "$mem_max" "$mem_avg"
    
    # Disk I/O Statistics
    local io_values=$(tail -n +2 "$CSV_FILE" | awk -F',' '{print $(NF)}')  # última coluna (disk_util)
    local io_stats=$(calculate_stats "Disk_IO" "$io_values")
    IFS=',' read -r io_min io_max io_avg io_count <<< "$io_stats"
    
    echo "Disk I/O Utilization (%):"
    printf "  Min: %.1f%% | Max: %.1f%% | Avg: %.1f%%\n" "$io_min" "$io_max" "$io_avg"
    
    echo ""
}

# --- Main Function ---
main() {
    log_info "Starting metrics analysis for file: $CSV_FILE"
    
    # Initial checks
    check_dependencies
    validate_csv
    
    # Create/clear report file
    {
        echo "========================================"
        echo "  METRICS ANALYSIS REPORT"
        echo "========================================"
        echo "Generated on: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Analyzed file: $CSV_FILE"
        echo "========================================"
        echo ""
        
        # Run analyses
        generate_statistics
        echo ""
        
        analyze_time_patterns
        echo ""
        
        detect_trends
        echo ""
        
        echo "=== PEAK DETECTION ==="
        find_peaks "Total CPU" "cpu_total" $CPU_THRESHOLD
        echo ""
        
        find_peaks "Memory" "mem_percent" $MEM_THRESHOLD
        echo ""
        
        find_peaks "Disk Root" "disk_root" $DISK_THRESHOLD
        echo ""
        
        find_peaks "Disk /var" "disk_var" $DISK_THRESHOLD
        echo ""
        
        find_peaks "I/O Utilization" "disk_util" $IO_UTIL_THRESHOLD
        echo ""
        
        find_peaks "I/O Queue" "avgqu_sz" $IO_QUEUE_THRESHOLD
        echo ""
        
        find_peaks "Anomalous Pods" "total_pods_other" $PODS_OTHER_THRESHOLD
        echo ""
        
        echo "========================================"
        echo "Analysis completed!"
        echo "========================================"
        
    } | tee "$OUTPUT_REPORT"
    
    log_info "Report saved to: $OUTPUT_REPORT"
    log_info "Analysis completed successfully!"
}

# --- Help ---
show_help() {
    echo "Usage: $0 [CSV_FILE] [OUTPUT_REPORT]"
    echo ""
    echo "Parameters:"
    echo "  CSV_FILE       CSV file to analyze (default: ./infra_metrics.csv)"
    echo "  OUTPUT_REPORT  Output report file (default: ./analysis_report.txt)"
    echo ""
    echo "Configurable thresholds (edit the script):"
    echo "  CPU_THRESHOLD=$CPU_THRESHOLD%"
    echo "  MEM_THRESHOLD=$MEM_THRESHOLD%"
    echo "  DISK_THRESHOLD=$DISK_THRESHOLD%"
    echo "  IO_UTIL_THRESHOLD=$IO_UTIL_THRESHOLD%"
    echo "  IO_QUEUE_THRESHOLD=$IO_QUEUE_THRESHOLD"
    echo "  PODS_OTHER_THRESHOLD=$PODS_OTHER_THRESHOLD"
}

# --- Verificação de argumentos ---
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# --- Execução ---
main "$@"