#!/usr/bin/env bash
#
# system_health.sh - collect host health metrics and flag threshold breaches.
#
# Collects CPU, memory and disk usage (every real mounted filesystem), load average and the
# top 5 processes by memory. Appends a timestamped entry to a log file, rotating it when it
# grows too large, and exits with a code monitoring tools understand:
#
#   0 = healthy   1 = warning   2 = critical   3 = unknown (bad usage / unsupported host)
#
# Requires Linux (/proc) with GNU coreutils and procps, as on Amazon Linux, Ubuntu or Debian.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.1.0"

readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_UNKNOWN=3

# Defaults. Percentages; a metric strictly above the threshold triggers the alert.
cpu_warn=90
cpu_crit=98
mem_warn=85
mem_crit=95
disk_warn=80
disk_crit=95
output_json=false
log_file="${HEALTH_LOG_FILE:-health_log.txt}"
max_log_kb=1024
keep_logs=5
sample_seconds=1
webhook_url="${HEALTH_WEBHOOK_URL:-}"

status=$EXIT_OK
alerts=()

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Collect CPU, memory, disk, load and top-process data, print a report, append a
timestamped entry to a log file and exit with a monitoring-friendly code.

Thresholds (percent; alert when usage is strictly above the value):
  --cpu N           CPU warning threshold            (default: $cpu_warn)
  --cpu-crit N      CPU critical threshold           (default: $cpu_crit)
  --mem N           Memory warning threshold         (default: $mem_warn)
  --mem-crit N      Memory critical threshold        (default: $mem_crit)
  --disk N          Disk warning threshold, any fs   (default: $disk_warn)
  --disk-crit N     Disk critical threshold, any fs  (default: $disk_crit)

Output:
  --json            Print the report as JSON and log it as one JSON line
  --log-file PATH   Log file to append to            (default: $log_file, env HEALTH_LOG_FILE)
  --max-log-kb N    Rotate the log above this size   (default: $max_log_kb)
  --keep N          Rotated log files to keep        (default: $keep_logs)
  --interval N      Seconds to sample CPU usage over (default: $sample_seconds)

Other:
  -h, --help        Show this help and exit
  --version         Show the version and exit

Environment:
  HEALTH_WEBHOOK_URL  If set, a Slack/Discord-compatible message is POSTed there
                      whenever the status is WARNING or CRITICAL.

Exit codes: 0 healthy, 1 warning, 2 critical, 3 unknown (usage or environment error).

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME --disk 80 --cpu 90 --mem 85
  $SCRIPT_NAME --json --log-file /var/log/system-health/health_log.txt
EOF
}

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_UNKNOWN"
}

require_value() {
  # $1 = option name, $2 = number of remaining arguments
  if (($2 < 2)); then
    die "option $1 requires a value (see --help)"
  fi
}

require_int() {
  # $1 = option name, $2 = value, $3 = minimum, $4 = maximum
  if [[ ! $2 =~ ^[0-9]+$ ]] || (($2 < $3 || $2 > $4)); then
    die "$1 must be an integer between $3 and $4, got '$2'"
  fi
}

parse_args() {
  while (($# > 0)); do
    case $1 in
      --cpu | --cpu-crit | --mem | --mem-crit | --disk | --disk-crit)
        require_value "$1" $#
        require_int "$1" "$2" 0 100
        case $1 in
          --cpu) cpu_warn=$2 ;;
          --cpu-crit) cpu_crit=$2 ;;
          --mem) mem_warn=$2 ;;
          --mem-crit) mem_crit=$2 ;;
          --disk) disk_warn=$2 ;;
          --disk-crit) disk_crit=$2 ;;
        esac
        shift 2
        ;;
      --json)
        output_json=true
        shift
        ;;
      --log-file)
        require_value "$1" $#
        log_file=$2
        shift 2
        ;;
      --max-log-kb)
        require_value "$1" $#
        require_int "$1" "$2" 1 1048576
        max_log_kb=$2
        shift 2
        ;;
      --keep)
        require_value "$1" $#
        require_int "$1" "$2" 1 100
        keep_logs=$2
        shift 2
        ;;
      --interval)
        require_value "$1" $#
        require_int "$1" "$2" 1 60
        sample_seconds=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit "$EXIT_OK"
        ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit "$EXIT_OK"
        ;;
      *)
        die "unknown option '$1' (see --help)"
        ;;
    esac
  done

  local pair name warn crit
  for pair in "cpu:$cpu_warn:$cpu_crit" "mem:$mem_warn:$mem_crit" "disk:$disk_warn:$disk_crit"; do
    IFS=: read -r name warn crit <<<"$pair"
    if ((warn > crit)); then
      die "--$name ($warn) must not be greater than --$name-crit ($crit)"
    fi
  done
}

check_environment() {
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] ||
    die "this script needs Linux /proc (stat, meminfo, loadavg)"
  local cmd
  for cmd in awk df ps; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Succeeds when decimal $1 is strictly greater than integer $2.
above() {
  awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value > limit) }'
}

# Compare a metric with its thresholds and record WARNING/CRITICAL alerts.
evaluate() {
  local label=$1 value=$2 warn=$3 crit=$4
  if above "$value" "$crit"; then
    alerts+=("[CRITICAL] $label is ${value}% (critical threshold ${crit}%)")
    status=$EXIT_CRITICAL
  elif above "$value" "$warn"; then
    alerts+=("[WARNING] $label is ${value}% (warning threshold ${warn}%)")
    if ((status < EXIT_WARNING)); then
      status=$EXIT_WARNING
    fi
  fi
}

join_alerts() {
  local joined=""
  if ((${#alerts[@]} > 0)); then
    joined=$(printf '%s; ' "${alerts[@]}")
  fi
  printf '%s' "${joined%; }"
}

human_kb() {
  awk -v kb="$1" 'BEGIN {
    split("KiB MiB GiB TiB", unit, " ")
    value = kb; i = 1
    while (value >= 1024 && i < 4) { value /= 1024; i++ }
    printf "%.1f %s", value, unit[i]
  }'
}

# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------

# Prints "<total_jiffies> <idle_jiffies>" from the aggregate cpu line of /proc/stat.
read_cpu_times() {
  local _label user nice system idle iowait irq softirq steal _rest
  read -r _label user nice system idle iowait irq softirq steal _rest </proc/stat
  printf '%s %s\n' \
    "$((user + nice + system + idle + iowait + irq + softirq + steal))" \
    "$((idle + iowait))"
}

collect_cpu() {
  local total1 idle1 total2 idle2
  read -r total1 idle1 < <(read_cpu_times)
  sleep "$sample_seconds"
  read -r total2 idle2 < <(read_cpu_times)
  awk -v dt="$((total2 - total1))" -v di="$((idle2 - idle1))" \
    'BEGIN { printf "%.1f", (dt > 0) ? (dt - di) * 100 / dt : 0 }'
}

# Prints "<used_pct> <total_kb> <available_kb>".
collect_memory() {
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END { printf "%.1f %d %d\n", (total > 0) ? (total - avail) * 100 / total : 0, total, avail }
  ' /proc/meminfo
}

# Prints one line per real filesystem: "<use_pct>\t<size_kb>\t<used_kb>\t<mountpoint>".
# Pseudo and read-only image filesystems (tmpfs, overlay, squashfs snaps, ...) are skipped:
# they are either not real disks or always 100% full, which would cause false alerts.
collect_disks() {
  local df_output
  if ! df_output=$(df -P -k -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null); then
    df_output=$(df -P -k 2>/dev/null) || true
  fi
  awk '
    NR == 1 { next }
    $1 ~ /^(tmpfs|devtmpfs|overlay|shm|udev|none|squashfs)$/ || $1 ~ /^\/dev\/loop/ { next }
    $2 == 0 { next }
    {
      mount = $6
      for (i = 7; i <= NF; i++) mount = mount " " $i
      pct = $5; sub(/%$/, "", pct)
      printf "%s\t%s\t%s\t%s\n", pct, $2, $3, mount
    }
  ' <<<"$df_output"
}

collect_top_processes() {
  # awk (not head) limits the output: it reads all input, so ps never gets SIGPIPE,
  # which would abort the script under `set -o pipefail`.
  ps -eo pid=,user=,pcpu=,pmem=,rss=,comm= --sort=-pmem | awk 'NR <= 5'
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

status_name() {
  case $1 in
    "$EXIT_OK") printf 'OK' ;;
    "$EXIT_WARNING") printf 'WARNING' ;;
    *) printf 'CRITICAL' ;;
  esac
}

rotate_log() {
  local file=$1 size i
  if [[ ! -f $file ]]; then
    return 0
  fi
  size=$(wc -c <"$file")
  if ((size < max_log_kb * 1024)); then
    return 0
  fi
  for ((i = keep_logs - 1; i >= 1; i--)); do
    if [[ -f "$file.$i" ]]; then
      mv -f -- "$file.$i" "$file.$((i + 1))"
    fi
  done
  mv -f -- "$file" "$file.1"
}

append_log() {
  local entry=$1 dir
  dir=$(dirname -- "$log_file")
  mkdir -p -- "$dir" || die "cannot create log directory $dir"
  rotate_log "$log_file"
  printf '%s\n' "$entry" >>"$log_file" || die "cannot write to $log_file"
}

send_webhook() {
  local message=$1 escaped
  if [[ -z $webhook_url || $status -eq $EXIT_OK ]]; then
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    printf '%s: curl not found; webhook alert not sent\n' "$SCRIPT_NAME" >&2
    return 0
  fi
  escaped=$(json_escape "$message")
  # "text" is read by Slack, "content" by Discord; each ignores the other field.
  if ! curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"text\":\"$escaped\",\"content\":\"$escaped\"}" "$webhook_url" >/dev/null; then
    printf '%s: failed to send webhook alert\n' "$SCRIPT_NAME" >&2
  fi
}

main() {
  parse_args "$@"
  check_environment

  local lock_fd
  if command -v flock >/dev/null 2>&1; then
    mkdir -p -- "$(dirname -- "$log_file")"
    exec {lock_fd}>"$log_file.lock"
    flock -n "$lock_fd" || die "another instance is already running (lock: $log_file.lock)"
  fi

  local timestamp host cpu mem_pct mem_total_kb mem_avail_kb load1 load5 load15 cpus
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  host=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')

  cpu=$(collect_cpu)
  read -r mem_pct mem_total_kb mem_avail_kb < <(collect_memory)
  read -r load1 load5 load15 _ </proc/loadavg

  local -a disks=()
  mapfile -t disks < <(collect_disks)
  local -a procs=()
  mapfile -t procs < <(collect_top_processes)

  evaluate "CPU usage" "$cpu" "$cpu_warn" "$cpu_crit"
  evaluate "Memory usage" "$mem_pct" "$mem_warn" "$mem_crit"
  local line pct size used mount
  for line in "${disks[@]}"; do
    IFS=$'\t' read -r pct size used mount <<<"$line"
    evaluate "Disk usage on $mount" "$pct" "$disk_warn" "$disk_crit"
  done

  local overall
  overall=$(status_name "$status")

  local pid user pcpu pmem rss comm
  if [[ $output_json == true ]]; then
    local json disk_json="" proc_json="" alert_json="" alert
    for line in "${disks[@]}"; do
      IFS=$'\t' read -r pct size used mount <<<"$line"
      disk_json+="${disk_json:+,}{\"mount\":\"$(json_escape "$mount")\",\"used_percent\":$pct,\"size_kb\":$size,\"used_kb\":$used}"
    done
    for line in "${procs[@]}"; do
      read -r pid user pcpu pmem rss comm <<<"$line"
      proc_json+="${proc_json:+,}{\"pid\":$pid,\"user\":\"$(json_escape "$user")\",\"cpu_percent\":$pcpu,\"mem_percent\":$pmem,\"rss_kb\":$rss,\"command\":\"$(json_escape "$comm")\"}"
    done
    for alert in "${alerts[@]}"; do
      alert_json+="${alert_json:+,}\"$(json_escape "$alert")\""
    done
    json="{\"timestamp\":\"$timestamp\",\"host\":\"$(json_escape "$host")\",\"status\":\"$overall\",\"exit_code\":$status,"
    json+="\"cpu\":{\"used_percent\":$cpu,\"cores\":$cpus},"
    json+="\"memory\":{\"used_percent\":$mem_pct,\"total_kb\":$mem_total_kb,\"available_kb\":$mem_avail_kb},"
    json+="\"load_average\":{\"1m\":$load1,\"5m\":$load5,\"15m\":$load15},"
    json+="\"disks\":[$disk_json],\"top_processes_by_memory\":[$proc_json],\"alerts\":[$alert_json]}"

    printf '%s\n' "$json"
    # Keep stdout pure JSON for machines; humans still see alerts on stderr.
    if ((${#alerts[@]} > 0)); then
      printf '%s\n' "${alerts[@]}" >&2
    fi
    append_log "$json"
  else
    printf '=== System health report: %s at %s ===\n' "$host" "$timestamp"
    printf '%-14s %s%%\n' "CPU usage:" "$cpu"
    printf '%-14s %s%% (%s used of %s)\n' "Memory usage:" "$mem_pct" \
      "$(human_kb "$((mem_total_kb - mem_avail_kb))")" "$(human_kb "$mem_total_kb")"
    printf '%-14s %s %s %s (1m 5m 15m, %s CPUs)\n' "Load average:" "$load1" "$load5" "$load15" "$cpus"
    printf 'Disk usage:\n'
    for line in "${disks[@]}"; do
      IFS=$'\t' read -r pct size used mount <<<"$line"
      printf '  %-24s %3s%%  (%s of %s)\n' "$mount" "$pct" "$(human_kb "$used")" "$(human_kb "$size")"
    done
    printf 'Top 5 processes by memory:\n'
    printf '  %-8s %-12s %6s %6s %10s  %s\n' PID USER %CPU %MEM RSS COMMAND
    for line in "${procs[@]}"; do
      read -r pid user pcpu pmem rss comm <<<"$line"
      printf '  %-8s %-12s %6s %6s %10s  %s\n' "$pid" "$user" "$pcpu" "$pmem" "$(human_kb "$rss")" "$comm"
    done
    printf 'Status: %s\n' "$overall"
    if ((${#alerts[@]} > 0)); then
      printf '%s\n' "${alerts[@]}"
    fi

    local summary="$timestamp status=$overall cpu=${cpu}% mem=${mem_pct}% load1=$load1"
    for line in "${disks[@]}"; do
      IFS=$'\t' read -r pct size used mount <<<"$line"
      summary+=" disk[$mount]=${pct}%"
    done
    if ((${#alerts[@]} > 0)); then
      summary+=" alerts=\"$(join_alerts)\""
    fi
    append_log "$summary"
  fi

  send_webhook "$host health $overall: $(join_alerts)"
  return "$status"
}

main "$@"
