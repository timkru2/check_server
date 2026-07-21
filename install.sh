#!/usr/bin/env bash

# Timurio Server Diagnostics
# Запуск: wget -qO- https://raw.githubusercontent.com/timkru2/check_server/main/install.sh | bash

set -uo pipefail

readonly SCRIPT_VERSION="1.1.2"
readonly TOTAL_STAGES=7
readonly SPEEDTEST_VERSION="1.2.0"
readonly SPEEDTEST_X86_SHA256="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
readonly SPEEDTEST_ARM_SHA256="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
readonly IPREGION_COMMIT="89a75849ab6c0490de893be0dbfea4902ddaac60"
readonly IPREGION_SHA256="23c792386e94e2fd62ba4274b1bcfab9be3ace8bb3b984539275bf371e25d8a8"
readonly IPREGION_URL="https://raw.githubusercontent.com/vernette/ipregion/${IPREGION_COMMIT}/ipregion.sh"
readonly GOOGLE_IPV4="8.8.8.8"
readonly GOOGLE_IPV6="2001:4860:4860::8888"

STRESS_SECONDS="${STRESS_SECONDS:-30}"
AUTO_INSTALL="${AUTO_INSTALL:-1}"
SKIP_STRESS="${SKIP_STRESS:-0}"
SKIP_IPREGION="${SKIP_IPREGION:-0}"

case "$STRESS_SECONDS" in
  ''|*[!0-9]*) STRESS_SECONDS=30 ;;
esac
if (( STRESS_SECONDS < 10 )); then STRESS_SECONDS=10; fi
if (( STRESS_SECONDS > 120 )); then STRESS_SECONDS=120; fi

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_GRAY=$'\033[0;90m'
else
  C_RESET=""
  C_BOLD=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_GRAY=""
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/timurio-diagnostics.XXXXXX")" || {
  printf 'Не удалось создать временный каталог.\n' >&2
  exit 1
}
LOAD_DIR=""
ACTIVE_PID=0
SYS_REPORT="$WORK_DIR/system.txt"
DEPS_LOG="$WORK_DIR/dependencies.log"
SPEED_REPORT="$WORK_DIR/speedtest.txt"
SPEED_ERROR="$WORK_DIR/speedtest.err"
MTR4_REPORT="$WORK_DIR/mtr4.txt"
MTR4_ERROR="$WORK_DIR/mtr4.err"
MTR6_REPORT="$WORK_DIR/mtr6.txt"
MTR6_ERROR="$WORK_DIR/mtr6.err"
PORTS_REPORT="$WORK_DIR/ports.txt"
STRESS_REPORT="$WORK_DIR/stress.txt"
STRESS_ERROR="$WORK_DIR/stress.err"
TEMP_MAX_FILE="$WORK_DIR/max-temperature.txt"
KERNEL_BEFORE="$WORK_DIR/kernel-before.txt"
KERNEL_AFTER="$WORK_DIR/kernel-after.txt"
KERNEL_NEW="$WORK_DIR/kernel-new.txt"
IPREGION_JSON="$WORK_DIR/ipregion.json"
IPREGION_ERROR="$WORK_DIR/ipregion.err"
IPREGION_REPORT="$WORK_DIR/ipregion-report.txt"
LOAD_DIR_FILE="$WORK_DIR/load-directory.txt"

declare -a CONCLUSIONS=()

cleanup() {
  local path
  if [[ "$ACTIVE_PID" =~ ^[0-9]+$ ]] && (( ACTIVE_PID > 0 )); then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  if [[ -s "$LOAD_DIR_FILE" ]]; then
    read -r LOAD_DIR <"$LOAD_DIR_FILE" || LOAD_DIR=""
  fi
  for path in "$LOAD_DIR" "$WORK_DIR"; do
    [[ -n "$path" && -d "$path" ]] || continue
    case "$path" in
      /tmp/timurio-*|/var/tmp/timurio-*|"${TMPDIR:-/tmp}"/timurio-*) rm -rf -- "$path" ;;
    esac
  done
}
trap cleanup EXIT
trap 'printf "\nДиагностика прервана.\n" >&2; exit 130' INT TERM

line() {
  printf '%s\n' '────────────────────────────────────────────────────────────────────────'
}

banner() {
  printf '\n%s%sСпасибо что запустили скрипт диагностики сервера - Timurio.%s\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '%sВерсия диагностики: %s%s\n' "$C_GRAY" "$SCRIPT_VERSION" "$C_RESET"
  line
}

stage() {
  local number="$1"
  local title="$2"
  printf '\n%s[%s/%s]%s %s%s%s\n' \
    "$C_CYAN" "$number" "$TOTAL_STAGES" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
}

ok() {
  printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"
}

warn() {
  printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
}

fail() {
  printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$1"
}

add_ok() {
  CONCLUSIONS+=("OK|$1")
}

add_warn() {
  CONCLUSIONS+=("WARN|$1")
}

add_fail() {
  CONCLUSIONS+=("FAIL|$1")
}

run_spinner() {
  local label="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3
  local pid rc frame=0
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  "$@" </dev/null >"$stdout_file" 2>"$stderr_file" &
  pid=$!
  ACTIVE_PID=$pid

  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r%s%s%s %s' "$C_CYAN" "${frames[$frame]}" "$C_RESET" "$label"
      frame=$(( (frame + 1) % ${#frames[@]} ))
      sleep 0.15
    done
    printf '\r\033[K'
  else
    printf '%s...\n' "$label"
  fi

  wait "$pid"
  rc=$?
  ACTIVE_PID=0
  return "$rc"
}

timeout_run() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=10 "$seconds" "$@"
  else
    "$@"
  fi
}

command_missing() {
  ! command -v "$1" >/dev/null 2>&1
}

pkg_exec() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    return 126
  fi
}

install_dependencies() {
  local manager=""
  local need_core=0
  local need_ipregion=0
  local need_stress=0
  local rc=0
  local cmd

  : >"$DEPS_LOG"

  for cmd in wget tar sha256sum timeout awk sed grep ss mtr; do
    if command_missing "$cmd"; then need_core=1; fi
  done
  for cmd in curl jq nslookup column; do
    if command_missing "$cmd"; then need_ipregion=1; fi
  done
  if [[ "$SKIP_STRESS" != "1" ]] && command_missing stress-ng; then need_stress=1; fi

  if (( need_core == 0 && need_ipregion == 0 && need_stress == 0 )); then
    return 0
  fi
  if [[ "$AUTO_INSTALL" != "1" ]]; then
    return 1
  fi

  if command -v apt-get >/dev/null 2>&1; then manager="apt";
  elif command -v dnf >/dev/null 2>&1; then manager="dnf";
  elif command -v yum >/dev/null 2>&1; then manager="yum";
  elif command -v apk >/dev/null 2>&1; then manager="apk";
  elif command -v pacman >/dev/null 2>&1; then manager="pacman";
  elif command -v zypper >/dev/null 2>&1; then manager="zypper";
  else return 1
  fi

  case "$manager" in
    apt)
      pkg_exec apt-get update -qq >>"$DEPS_LOG" 2>&1 || rc=1
      if (( need_core || need_ipregion )); then
        pkg_exec env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr-tiny \
          jq dnsutils util-linux bsdextrautils >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      if (( need_stress )); then
        pkg_exec env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stress-ng \
          >>"$DEPS_LOG" 2>&1 || true
      fi
      ;;
    dnf|yum)
      if (( need_core || need_ipregion )); then
        pkg_exec "$manager" install -y -q \
          ca-certificates wget curl tar coreutils gawk sed grep iproute mtr \
          jq bind-utils util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      if (( need_stress )); then
        pkg_exec "$manager" install -y -q stress-ng >>"$DEPS_LOG" 2>&1 || true
      fi
      ;;
    apk)
      if (( need_core || need_ipregion )); then
        pkg_exec apk add --no-cache \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr \
          jq bind-tools util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      if (( need_stress )); then
        pkg_exec apk add --no-cache stress-ng >>"$DEPS_LOG" 2>&1 || true
      fi
      ;;
    pacman)
      if (( need_core || need_ipregion )); then
        pkg_exec pacman -Sy --noconfirm --needed \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr \
          jq bind util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      if (( need_stress )); then
        pkg_exec pacman -S --noconfirm --needed stress-ng >>"$DEPS_LOG" 2>&1 || true
      fi
      ;;
    zypper)
      if (( need_core || need_ipregion )); then
        pkg_exec zypper --non-interactive install \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr \
          jq bind-utils util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      if (( need_stress )); then
        pkg_exec zypper --non-interactive install stress-ng >>"$DEPS_LOG" 2>&1 || true
      fi
      ;;
  esac
  return "$rc"
}

collect_system_info() {
  local os="Не определена"
  local cpu="Не определён"
  local virt="Не определена"
  local ipv4="Нет"
  local ipv6="Нет"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    os="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")"
  fi
  if command -v lscpu >/dev/null 2>&1; then
    cpu="$(lscpu 2>/dev/null | awk -F: '/Model name|Имя модели/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')"
  fi
  if [[ -z "$cpu" && -r /proc/cpuinfo ]]; then
    cpu="$(awk -F: '/model name|Hardware/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || printf 'нет/не определена')"
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -4 route get "$GOOGLE_IPV4" >/dev/null 2>&1 && ipv4="Да"
    ip -6 route get "$GOOGLE_IPV6" >/dev/null 2>&1 && ipv6="Да"
  fi

  printf 'Дата:              %s\n' "$(date -Is 2>/dev/null || date)"
  printf 'Имя сервера:       %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'ОС:                %s\n' "$os"
  printf 'Ядро:              %s\n' "$(uname -srmo 2>/dev/null || uname -a)"
  printf 'Виртуализация:     %s\n' "$virt"
  printf 'Процессор:         %s\n' "${cpu:-Не определён}"
  printf 'Логических CPU:    %s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '?')"
  if command -v free >/dev/null 2>&1; then
    printf 'Оперативная память:\n'
    free -h
  fi
  printf 'Корневой раздел:\n'
  df -hT / 2>/dev/null || df -h / 2>/dev/null || true
  printf 'IPv4-маршрут:      %s\n' "$ipv4"
  printf 'IPv6-маршрут:      %s\n' "$ipv6"
  printf 'Время работы:      %s\n' "$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf '?')"
}

baseline_conclusions() {
  local disk_used=""
  local mem_total=""
  local mem_available=""
  local mem_available_pct=""
  local failed_units=""

  disk_used="$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
  if [[ "$disk_used" =~ ^[0-9]+$ ]]; then
    if (( disk_used >= 95 )); then
      add_fail "Корневой раздел заполнен на ${disk_used}%. Освободите место."
    elif (( disk_used >= 85 )); then
      add_warn "Корневой раздел заполнен на ${disk_used}%."
    else
      add_ok "Свободного места на корневом разделе достаточно."
    fi
  fi

  if command -v free >/dev/null 2>&1; then
    read -r mem_total mem_available < <(free -m | awk '/^Mem:/ {print $2, $7}')
    if [[ "$mem_total" =~ ^[0-9]+$ && "$mem_available" =~ ^[0-9]+$ && "$mem_total" -gt 0 ]]; then
      mem_available_pct=$(( mem_available * 100 / mem_total ))
      if (( mem_available_pct < 5 )); then
        add_fail "Доступно менее 5% оперативной памяти."
      elif (( mem_available_pct < 15 )); then
        add_warn "Доступно только ${mem_available_pct}% оперативной памяти."
      else
        add_ok "Критической нехватки оперативной памяти не обнаружено."
      fi
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 10)"
    if [[ -n "$failed_units" ]]; then
      add_warn "Есть неисправные systemd-службы; список приведён в системном разделе."
      {
        printf '\nНеисправные systemd-службы:\n'
        printf '%s\n' "$failed_units"
      } >>"$SYS_REPORT"
    else
      add_ok "Неисправные systemd-службы не обнаружены."
    fi
  fi
}

run_speedtest() {
  local arch url expected archive speed_dir
  arch="$(uname -m)"
  speed_dir="$WORK_DIR/speedtest"
  archive="$WORK_DIR/speedtest.tgz"
  mkdir -p "$speed_dir"

  case "$arch" in
    x86_64|amd64)
      url="https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VERSION}-linux-x86_64.tgz"
      expected="$SPEEDTEST_X86_SHA256"
      ;;
    aarch64|arm64)
      url="https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VERSION}-linux-aarch64.tgz"
      expected="$SPEEDTEST_ARM_SHA256"
      ;;
    *)
      printf 'Архитектура %s не поддерживается официальным пакетом в этом скрипте.\n' "$arch" >&2
      return 3
      ;;
  esac

  wget -qO "$archive" "$url" || return 10
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null 2>&1 || return 11
  tar -xzf "$archive" -C "$speed_dir" || return 12
  chmod +x "$speed_dir/speedtest" 2>/dev/null || true
  timeout_run 240 "$speed_dir/speedtest" \
    --accept-license --accept-gdpr --progress=no
}

analyze_speedtest() {
  local latency packet_loss
  if [[ ! -s "$SPEED_REPORT" ]]; then return; fi
  latency="$(sed -nE 's/.*Idle Latency:[[:space:]]*([0-9.]+).*/\1/p' "$SPEED_REPORT" | head -n 1)"
  packet_loss="$(sed -nE 's/.*Packet Loss:[[:space:]]*([0-9.]+)%.*/\1/p' "$SPEED_REPORT" | head -n 1)"
  if [[ -n "$packet_loss" ]] && awk -v value="$packet_loss" 'BEGIN {exit !(value > 0)}'; then
    add_warn "Speedtest обнаружил потерю пакетов: ${packet_loss}%."
  else
    add_ok "Speedtest завершён без зафиксированной потери пакетов."
  fi
  if [[ -n "$latency" ]] && awk -v value="$latency" 'BEGIN {exit !(value > 100)}'; then
    add_warn "Высокая задержка до сервера Speedtest: ${latency} мс."
  fi
}

run_mtr4() {
  timeout_run 180 mtr -4 -n -r -w -c 25 "$GOOGLE_IPV4"
}

run_mtr6() {
  timeout_run 180 mtr -6 -n -r -w -c 25 "$GOOGLE_IPV6"
}

has_ipv6_route() {
  command -v ip >/dev/null 2>&1 && ip -6 route get "$GOOGLE_IPV6" >/dev/null 2>&1
}

analyze_mtr() {
  local family="$1"
  local report="$2"
  local line loss average
  line="$(awk 'NF >= 8 && $1 ~ /^[0-9]+\./ {last=$0} END {print last}' "$report" 2>/dev/null)"
  if [[ -z "$line" ]]; then
    add_warn "Не удалось разобрать итог MTR для ${family}."
    return
  fi
  loss="$(awk '{value=$(NF-6); gsub(/%/, "", value); print value}' <<<"$line")"
  average="$(awk '{print $(NF-3)}' <<<"$line")"
  if [[ "$loss" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v value="$loss" 'BEGIN {exit !(value >= 5)}'; then
      add_fail "MTR ${family}: потеря пакетов до конечного узла ${loss}% (средняя задержка ${average} мс)."
    elif awk -v value="$loss" 'BEGIN {exit !(value > 0)}'; then
      add_warn "MTR ${family}: потеря пакетов до конечного узла ${loss}% (средняя задержка ${average} мс)."
    else
      add_ok "MTR ${family}: потерь до конечного узла нет, средняя задержка ${average} мс."
    fi
  else
    add_warn "MTR ${family}: конечный узел не дал пригодный для анализа результат."
  fi
}

collect_ports() {
  if command -v ss >/dev/null 2>&1; then
    {
      printf 'Сетевые TCP-порты в состоянии LISTEN и привязанные UDP-порты:\n'
      printf '%-6s %-12s %-8s %-8s %-30s %-30s %s\n' \
        'Proto' 'State' 'Recv-Q' 'Send-Q' 'Local address' 'Peer address' 'Process'
      ss -H -lntup 2>/dev/null | sort -k1,1 -k5,5
    } >"$PORTS_REPORT"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntup >"$PORTS_REPORT" 2>&1
  else
    printf 'Команды ss и netstat отсутствуют.\n' >"$PORTS_REPORT"
    return 1
  fi
}

analyze_ports() {
  local count sensitive
  count="$(awk 'NR > 2 && NF {count++} END {print count+0}' "$PORTS_REPORT")"
  sensitive="$(awk '
    NR > 2 {
      local_addr=$5
      port=local_addr
      sub(/^.*:/, "", port)
      if (local_addr ~ /^(0[.]0[.]0[.]0|\[::\]|[*]):/ &&
          port ~ /^(21|23|111|137|138|139|445|2375|3306|5432|6379|9200|11211|27017)$/) {
        print local_addr
      }
    }
  ' "$PORTS_REPORT" | sort -u | paste -sd ', ' -)"
  add_ok "Найдено локально открытых TCP/UDP-сокетов: ${count}."
  if [[ -n "$sensitive" ]]; then
    add_warn "Потенциально чувствительные порты слушают на всех интерфейсах: ${sensitive}. Проверьте firewall и необходимость публикации."
  fi
}

read_max_temperature() {
  local sensor raw celsius max=0
  for sensor in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
    [[ -r "$sensor" ]] || continue
    read -r raw <"$sensor" || continue
    [[ "$raw" =~ ^[0-9]+$ ]] || continue
    if (( raw > 1000 )); then celsius=$(( raw / 1000 )); else celsius=$raw; fi
    if (( celsius > max && celsius < 200 )); then max=$celsius; fi
  done
  printf '%s\n' "$max"
}

run_stress_test() {
  local available_kb hdd_mb=0 max_temp=0 current_temp=0 stress_pid=0 rc
  local -a args

  command -v stress-ng >/dev/null 2>&1 || {
    printf 'stress-ng не установлен.\n' >&2
    return 127
  }

  LOAD_DIR="$(mktemp -d /var/tmp/timurio-load.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/timurio-load.XXXXXX")" || return 1
  printf '%s\n' "$LOAD_DIR" >"$LOAD_DIR_FILE"
  available_kb="$(df -Pk "$LOAD_DIR" | awk 'NR==2 {print $4}')"
  if [[ "$available_kb" =~ ^[0-9]+$ ]] && (( available_kb >= 1048576 )); then
    hdd_mb=256
  fi

  args=(--cpu 0 --cpu-method all --vm 1 --vm-bytes 25% --timeout "${STRESS_SECONDS}s" --metrics-brief --verify)
  if (( hdd_mb > 0 )); then
    args+=(--hdd 1 --hdd-bytes "${hdd_mb}M" --temp-path "$LOAD_DIR")
  fi

  stress-ng "${args[@]}" >"$WORK_DIR/stress-raw.txt" 2>&1 &
  stress_pid=$!
  trap 'if (( stress_pid > 0 )); then kill "$stress_pid" 2>/dev/null || true; wait "$stress_pid" 2>/dev/null || true; fi; case "$LOAD_DIR" in /tmp/timurio-*|/var/tmp/timurio-*) rm -rf -- "$LOAD_DIR" ;; esac; exit 130' INT TERM
  while kill -0 "$stress_pid" 2>/dev/null; do
    current_temp="$(read_max_temperature)"
    if [[ "$current_temp" =~ ^[0-9]+$ ]] && (( current_temp > max_temp )); then
      max_temp=$current_temp
    fi
    sleep 1
  done
  wait "$stress_pid"
  rc=$?
  printf '%s\n' "$max_temp" >"$TEMP_MAX_FILE"

  printf 'Параметры: CPU=%s потоков, RAM=25%%, диск=%s MiB, время=%s сек.\n\n' \
    "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '?')" "$hdd_mb" "$STRESS_SECONDS"
  cat "$WORK_DIR/stress-raw.txt"
  case "$LOAD_DIR" in
    /tmp/timurio-*|/var/tmp/timurio-*) rm -rf -- "$LOAD_DIR" ;;
  esac
  LOAD_DIR=""
  : >"$LOAD_DIR_FILE"
  trap - INT TERM
  return "$rc"
}

capture_dmesg() {
  local target="$1"
  if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null >"$target" || : >"$target"
  else
    : >"$target"
  fi
}

analyze_stress() {
  local stress_rc="${1:-0}"
  local max_temp=0 before_lines=0
  if [[ -s "$TEMP_MAX_FILE" ]]; then read -r max_temp <"$TEMP_MAX_FILE"; fi
  if [[ "$max_temp" =~ ^[0-9]+$ ]] && (( max_temp > 0 )); then
    if (( max_temp >= 95 )); then
      add_fail "Во время нагрузки температура достигла ${max_temp}°C — возможен перегрев."
    elif (( max_temp >= 85 )); then
      add_warn "Во время нагрузки температура достигла ${max_temp}°C. Проверьте охлаждение."
    else
      add_ok "Максимальная зафиксированная температура под нагрузкой: ${max_temp}°C."
    fi
  else
    add_warn "Датчики температуры недоступны внутри этой ВМ."
  fi

  if grep -Eqi 'fail(ed|ure)?|error|miscompare|out of memory|oom|killed process|hardware error|i/o error' "$STRESS_REPORT" "$STRESS_ERROR" 2>/dev/null; then
    add_fail "Нагрузочный тест сообщил об ошибке; подробности приведены в его разделе."
  elif [[ "$stress_rc" == "0" ]]; then
    add_ok "Контролируемая нагрузка CPU/RAM/диска завершилась без ошибок stress-ng."
  fi

  capture_dmesg "$KERNEL_AFTER"
  before_lines="$(wc -l <"$KERNEL_BEFORE" 2>/dev/null || printf '0')"
  if [[ "$before_lines" =~ ^[0-9]+$ ]] && (( before_lines > 0 )); then
    tail -n "+$((before_lines + 1))" "$KERNEL_AFTER" >"$KERNEL_NEW" 2>/dev/null || : >"$KERNEL_NEW"
  else
    : >"$KERNEL_NEW"
  fi
  if grep -Eqi 'out of memory|oom-killer|killed process|hardware error|i/o error|segfault|mce:' "$KERNEL_NEW" 2>/dev/null; then
    add_fail "Во время нагрузки ядро зафиксировало серьёзную ошибку; сообщения приведены ниже."
  fi
}

curl_supports_json() {
  curl --help all 2>/dev/null | grep -q -- '--json'
}

patch_ipregion_for_legacy_curl() {
  local script="$1"
  # shellcheck disable=SC2016
  local old_line='curl_args+=(--json "$json")'
  # shellcheck disable=SC2016
  local new_line='curl_args+=(-H "Content-Type: application/json" --data "$json")'

  grep -Fq -- "$old_line" "$script" || return 1
  sed -i "s|${old_line}|${new_line}|" "$script" || return 1
  grep -Fq -- "$new_line" "$script"
}

run_ipregion() {
  local script="$WORK_DIR/ipregion.sh"
  local cmd
  for cmd in bash wget curl jq column nslookup; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf 'Для ipregion отсутствует команда: %s\n' "$cmd" >&2
      return 127
    }
  done
  wget -qO "$script" "$IPREGION_URL" || return 10
  printf '%s  %s\n' "$IPREGION_SHA256" "$script" | sha256sum -c - >/dev/null 2>&1 || return 12
  if ! curl_supports_json; then
    patch_ipregion_for_legacy_curl "$script" || return 13
  fi
  bash -n "$script" || return 11
  timeout_run 360 bash "$script" --json
}

format_ipregion() {
  jq -r '
    def value:
      if . == null or . == "" or . == "null" then "нет данных" else . end;
    "Внешний IPv4: \((.ipv4 | value) // "не определён")",
    "Внешний IPv6: \((.ipv6 | value) // "не определён")",
    "",
    "Основные GeoIP-проверки:",
    (.results.primary[]? | "  \(.service): IPv4=\(.ipv4 | value), IPv6=\(.ipv6 | value)"),
    "",
    "Доступность популярных сервисов:",
    (.results.custom[]? | "  \(.service): IPv4=\(.ipv4 | value), IPv6=\(.ipv6 | value)"),
    "",
    "CDN и сетевые сервисы:",
    (.results.cdn[]? | "  \(.service): IPv4=\(.ipv4 | value), IPv6=\(.ipv6 | value)")
  ' "$IPREGION_JSON" >"$IPREGION_REPORT"
}

ipregion_has_runtime_errors() {
  [[ -s "$IPREGION_ERROR" ]] &&
    grep -Eqi 'curl:|unknown option|not found|error|failed|timed out' "$IPREGION_ERROR"
}

ipregion_has_suspicious_values() {
  jq -e '
    [
      .results[][]?
      | (.ipv4 // empty), (.ipv6 // empty)
      | select(type == "string" and test("^null"; "i"))
    ]
    | length > 0
  ' "$IPREGION_JSON" >/dev/null 2>&1
}

print_section() {
  local title="$1"
  local file="$2"
  printf '\n%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
  line
  if [[ -s "$file" ]]; then
    cat "$file"
  else
    printf 'Нет данных.\n'
  fi
}

print_stress_summary() {
  local max_temp=""
  printf '\n%s%s%s\n' "$C_BOLD" '6. Нагрузочный тест' "$C_RESET"
  line

  if [[ "$SKIP_STRESS" == "1" ]]; then
    printf 'Результат: тест отключён.\n'
    return
  fi
  if grep -q 'successful run completed' "$STRESS_REPORT" 2>/dev/null; then
    printf 'Результат: успешно, отклонений stress-ng не обнаружено.\n'
  else
    printf 'Результат: тест не завершился успешно. Смотрите итог диагностики выше.\n'
  fi
  printf 'Нагрузка: все доступные CPU, 25%% RAM, до 256 MiB диска.\n'
  printf 'Продолжительность: %s секунд.\n' "$STRESS_SECONDS"

  max_temp="$(cat "$TEMP_MAX_FILE" 2>/dev/null || true)"
  if [[ "$max_temp" =~ ^[0-9]+$ ]] && (( max_temp > 0 )); then
    printf 'Максимальная температура: %s°C.\n' "$max_temp"
  else
    printf 'Температура: датчик недоступен внутри ВМ.\n'
  fi

  if grep -Eqi 'out of memory|oom-killer|killed process|hardware error|i/o error|segfault|mce:' "$KERNEL_NEW" 2>/dev/null; then
    printf 'Сообщения ядра: обнаружена критическая ошибка; описание приведено в итоге диагностики.\n'
  else
    printf 'Сообщения ядра: критических ошибок во время нагрузки не обнаружено.\n'
  fi
}

print_conclusions() {
  local item type text wanted
  local ok_count=0 warn_count=0 fail_count=0
  printf '\n%s%sИТОГ ДИАГНОСТИКИ%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  for item in "${CONCLUSIONS[@]}"; do
    case "${item%%|*}" in
      OK) ok_count=$((ok_count + 1)) ;;
      WARN) warn_count=$((warn_count + 1)) ;;
      FAIL) fail_count=$((fail_count + 1)) ;;
    esac
  done
  printf 'Статус: %sуспешно — %s%s  |  %sвнимание — %s%s  |  %sошибки — %s%s\n' \
    "$C_GREEN" "$ok_count" "$C_RESET" \
    "$C_YELLOW" "$warn_count" "$C_RESET" \
    "$C_RED" "$fail_count" "$C_RESET"
  printf '\n'

  for wanted in FAIL WARN OK; do
    for item in "${CONCLUSIONS[@]}"; do
      type="${item%%|*}"
      [[ "$type" == "$wanted" ]] || continue
      text="${item#*|}"
      case "$type" in
        OK) ok "$text" ;;
        WARN) warn "$text" ;;
        FAIL) fail "$text" ;;
      esac
    done
  done
}

print_dashboard() {
  local os="" cpu_count="" mem_total="" mem_available="" disk_used=""
  local latency="" download="" upload="" packet_loss=""
  local mtr4_line="" mtr4_loss="" mtr4_avg="" mtr6_line="" mtr6_loss="" mtr6_avg=""
  local port_count="" public_ports="" stress_status="" max_temp="" external_ipv4="" external_ipv6=""

  os="$(sed -nE 's/^ОС:[[:space:]]+//p' "$SYS_REPORT" | head -n 1)"
  cpu_count="$(sed -nE 's/^Логических CPU:[[:space:]]+//p' "$SYS_REPORT" | head -n 1)"
  read -r mem_total mem_available < <(awk '/^Mem:/ {print $2, $7; exit}' "$SYS_REPORT")
  disk_used="$(awk '$NF == "/" {print $(NF-1); exit}' "$SYS_REPORT")"

  if [[ -s "$SPEED_REPORT" ]]; then
    latency="$(sed -nE 's/.*Idle Latency:[[:space:]]*([0-9.]+).*/\1/p' "$SPEED_REPORT" | head -n 1)"
    download="$(sed -nE 's/.*Download:[[:space:]]*([0-9.]+)[[:space:]]+Mbps.*/\1/p' "$SPEED_REPORT" | head -n 1)"
    upload="$(sed -nE 's/.*Upload:[[:space:]]*([0-9.]+)[[:space:]]+Mbps.*/\1/p' "$SPEED_REPORT" | head -n 1)"
    packet_loss="$(sed -nE 's/.*Packet Loss:[[:space:]]*([0-9.]+)%.*/\1/p' "$SPEED_REPORT" | head -n 1)"
  fi

  mtr4_line="$(awk 'NF >= 8 && $1 ~ /^[0-9]+\./ {last=$0} END {print last}' "$MTR4_REPORT" 2>/dev/null)"
  mtr6_line="$(awk 'NF >= 8 && $1 ~ /^[0-9]+\./ {last=$0} END {print last}' "$MTR6_REPORT" 2>/dev/null)"
  if [[ -n "$mtr4_line" ]]; then
    mtr4_loss="$(awk '{v=$(NF-6); gsub(/%/, "", v); print v}' <<<"$mtr4_line")"
    mtr4_avg="$(awk '{print $(NF-3)}' <<<"$mtr4_line")"
  fi
  if [[ -n "$mtr6_line" ]]; then
    mtr6_loss="$(awk '{v=$(NF-6); gsub(/%/, "", v); print v}' <<<"$mtr6_line")"
    mtr6_avg="$(awk '{print $(NF-3)}' <<<"$mtr6_line")"
  fi

  if grep -q '^Сетевые TCP-порты' "$PORTS_REPORT" 2>/dev/null; then
    port_count="$(awk 'NR > 2 && NF {count++} END {print count+0}' "$PORTS_REPORT" 2>/dev/null)"
    public_ports="$(awk '
      NR > 2 {
        address=$5
        if (address ~ /^(0[.]0[.]0[.]0|\[::\]|[*]):/) {
          sub(/^.*:/, "", address)
          if (address ~ /^[0-9]+$/) print address
        }
      }
    ' "$PORTS_REPORT" 2>/dev/null | sort -nu | paste -sd, -)"
  else
    port_count=""
    public_ports=""
  fi

  if grep -q 'successful run completed' "$STRESS_REPORT" 2>/dev/null; then
    stress_status="успешно, ${STRESS_SECONDS} сек."
  elif [[ "$SKIP_STRESS" == "1" ]]; then
    stress_status="отключён"
  else
    stress_status="нет успешного результата"
  fi
  max_temp="$(cat "$TEMP_MAX_FILE" 2>/dev/null || true)"

  if jq -e . "$IPREGION_JSON" >/dev/null 2>&1; then
    external_ipv4="$(jq -r '.ipv4 // "нет"' "$IPREGION_JSON")"
    external_ipv6="$(jq -r '.ipv6 // "нет"' "$IPREGION_JSON")"
  else
    external_ipv4="нет данных"
    external_ipv6="нет данных"
  fi

  printf '\n%s%sКЛЮЧЕВЫЕ ПОКАЗАТЕЛИ%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  printf '%-20s %s\n' 'Система:' "${os:-нет данных}"
  printf '%-20s %s vCPU | RAM %s, доступно %s | диск %s\n' \
    'Ресурсы:' "${cpu_count:-?}" "${mem_total:-?}" "${mem_available:-?}" "${disk_used:-?}"
  if [[ -n "$download" ]]; then
    printf '%-20s ↓ %s Mbps | ↑ %s Mbps | ping %s ms | потери %s%%\n' \
      'Speedtest:' "$download" "${upload:-?}" "${latency:-?}" "${packet_loss:-?}"
  else
    printf '%-20s %s\n' 'Speedtest:' 'нет результата'
  fi
  if [[ -n "${mtr4_avg:-}" ]]; then
    printf '%-20s %s ms | потери %s%% | 25 пакетов\n' 'MTR IPv4:' "$mtr4_avg" "$mtr4_loss"
  else
    printf '%-20s %s\n' 'MTR IPv4:' 'нет результата'
  fi
  if [[ -n "${mtr6_avg:-}" ]]; then
    printf '%-20s %s ms | потери %s%% | 25 пакетов\n' 'MTR IPv6:' "$mtr6_avg" "$mtr6_loss"
  else
    printf '%-20s %s\n' 'MTR IPv6:' 'маршрут отсутствует или тест не выполнен'
  fi
  if [[ "$port_count" =~ ^[0-9]+$ ]]; then
    printf '%-20s %s сокетов | на всех интерфейсах: %s\n' \
      'Порты:' "$port_count" "${public_ports:-нет}"
  else
    printf '%-20s %s\n' 'Порты:' 'нет результата'
  fi
  if [[ "$max_temp" =~ ^[0-9]+$ ]] && (( max_temp > 0 )); then
    printf '%-20s %s | максимум %s°C\n' 'Нагрузка:' "$stress_status" "$max_temp"
  else
    printf '%-20s %s | температура недоступна\n' 'Нагрузка:' "$stress_status"
  fi
  printf '%-20s IPv4 %s | IPv6 %s\n' 'Внешние адреса:' "$external_ipv4" "$external_ipv6"
}

main() {
  local rc
  banner

  printf '%sПодготовка необходимых утилит%s\n' "$C_BOLD" "$C_RESET"
  if install_dependencies; then
    ok "Зависимости готовы; подтверждения не требуются."
  else
    warn "Не все утилиты удалось установить. Недоступные тесты будут пропущены."
  fi

  stage 1 "Основные параметры ВМ"
  collect_system_info >"$SYS_REPORT" 2>&1
  baseline_conclusions
  ok "Системная информация собрана."

  stage 2 "Ookla Speedtest"
  if command_missing wget || command_missing tar || command_missing sha256sum; then
    printf 'Необходимы wget, tar и sha256sum.\n' >"$SPEED_ERROR"
    add_fail "Speedtest пропущен: отсутствуют wget, tar или sha256sum."
    fail "Speedtest пропущен."
  else
    if run_spinner "Измеряем скорость сети" "$SPEED_REPORT" "$SPEED_ERROR" run_speedtest; then
      ok "Speedtest завершён."
      analyze_speedtest
    else
      rc=$?
      fail "Speedtest завершился с ошибкой (код $rc)."
      add_fail "Ookla Speedtest не завершился успешно (код $rc)."
    fi
  fi

  stage 3 "Маршрут IPv4 до Google — 25 пакетов"
  if command -v mtr >/dev/null 2>&1; then
    if run_spinner "Проверяем маршрут IPv4" "$MTR4_REPORT" "$MTR4_ERROR" run_mtr4; then
      ok "MTR IPv4 завершён."
      analyze_mtr "IPv4" "$MTR4_REPORT"
    else
      rc=$?
      fail "MTR IPv4 завершился с ошибкой (код $rc)."
      add_fail "MTR IPv4 не завершился успешно."
    fi
  else
    printf 'Команда mtr отсутствует.\n' >"$MTR4_ERROR"
    add_fail "MTR IPv4 пропущен: команда mtr отсутствует."
  fi

  stage 4 "Маршрут IPv6 до Google — 25 пакетов"
  if ! has_ipv6_route; then
    printf 'На сервере отсутствует рабочий маршрут IPv6 до %s.\n' "$GOOGLE_IPV6" >"$MTR6_REPORT"
    warn "IPv6-маршрут отсутствует; тест пропущен."
    add_warn "IPv6 не настроен или маршрут до Google IPv6 недоступен."
  elif command -v mtr >/dev/null 2>&1; then
    if run_spinner "Проверяем маршрут IPv6" "$MTR6_REPORT" "$MTR6_ERROR" run_mtr6; then
      ok "MTR IPv6 завершён."
      analyze_mtr "IPv6" "$MTR6_REPORT"
    else
      rc=$?
      fail "MTR IPv6 завершился с ошибкой (код $rc)."
      add_fail "MTR IPv6 не завершился успешно при наличии IPv6-маршрута."
    fi
  else
    printf 'Команда mtr отсутствует.\n' >"$MTR6_ERROR"
    add_fail "MTR IPv6 пропущен: команда mtr отсутствует."
  fi

  stage 5 "Локально открытые сетевые порты"
  if collect_ports; then
    ok "Список TCP/UDP-портов собран."
    analyze_ports
  else
    fail "Не удалось получить список портов."
    add_fail "Проверка локально открытых портов не выполнена."
  fi

  stage 6 "Контролируемая нагрузка CPU, RAM и диска"
  if [[ "$SKIP_STRESS" == "1" ]]; then
    printf 'Тест отключён переменной SKIP_STRESS=1.\n' >"$STRESS_REPORT"
    warn "Нагрузочный тест отключён."
    add_warn "Нагрузочный тест был отключён пользователем."
  elif ! command -v stress-ng >/dev/null 2>&1; then
    printf 'stress-ng отсутствует.\n' >"$STRESS_ERROR"
    warn "stress-ng установить не удалось; нагрузка пропущена."
    add_warn "Нагрузочный тест пропущен: stress-ng недоступен."
  else
    capture_dmesg "$KERNEL_BEFORE"
    if run_spinner "Нагружаем ВМ ${STRESS_SECONDS} секунд" "$STRESS_REPORT" "$STRESS_ERROR" run_stress_test; then
      ok "Нагрузочный тест завершён."
      analyze_stress 0
    else
      rc=$?
      fail "Нагрузочный тест завершился с ошибкой (код $rc)."
      add_fail "stress-ng завершился с ненулевым кодом $rc."
      analyze_stress "$rc"
    fi
  fi

  stage 7 "IP-регион и доступность интернет-сервисов"
  if [[ "$SKIP_IPREGION" == "1" ]]; then
    printf 'Тест отключён переменной SKIP_IPREGION=1.\n' >"$IPREGION_REPORT"
    warn "Тест ipregion отключён."
    add_warn "Тест ipregion был отключён пользователем."
  else
    if run_spinner "Запускаем полный ipregion-тест" "$IPREGION_JSON" "$IPREGION_ERROR" run_ipregion; then
      if jq -e . "$IPREGION_JSON" >/dev/null 2>&1 && format_ipregion; then
        if ipregion_has_runtime_errors || ipregion_has_suspicious_values; then
          warn "IP-регион проверен частично; есть ошибки отдельных запросов."
          add_warn "Часть запросов ipregion завершилась ошибкой; ненадёжные значения отмечены в подробностях."
        else
          ok "IP-регион и сервисы проверены."
          add_ok "Проверка IP-региона и доступности сервисов завершена без ошибок."
        fi
      else
        fail "ipregion вернул некорректный JSON."
        cp "$IPREGION_JSON" "$IPREGION_REPORT"
        add_fail "Результат ipregion не удалось обработать."
      fi
    else
      rc=$?
      fail "ipregion завершился с ошибкой (код $rc)."
      {
        printf 'ipregion завершился с кодом %s.\n' "$rc"
        cat "$IPREGION_JSON" "$IPREGION_ERROR" 2>/dev/null || true
      } >"$IPREGION_REPORT"
      add_fail "Тест IP-региона и доступности сервисов не завершился успешно."
    fi
  fi

  printf '\n%s%sФИНАЛЬНЫЙ ОТЧЁТ TIMURIO%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  print_conclusions
  print_dashboard

  printf '\n%s%sПОДРОБНЫЕ РЕЗУЛЬТАТЫ%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  print_section "1. Система" "$SYS_REPORT"
  print_section "2. Ookla Speedtest" "$SPEED_REPORT"
  if [[ -s "$SPEED_ERROR" ]]; then print_section "Ошибки Speedtest" "$SPEED_ERROR"; fi
  print_section "3. MTR IPv4 — $GOOGLE_IPV4" "$MTR4_REPORT"
  if [[ -s "$MTR4_ERROR" ]]; then print_section "Ошибки MTR IPv4" "$MTR4_ERROR"; fi
  print_section "4. MTR IPv6 — $GOOGLE_IPV6" "$MTR6_REPORT"
  if [[ -s "$MTR6_ERROR" ]]; then print_section "Ошибки MTR IPv6" "$MTR6_ERROR"; fi
  print_section "5. Локально открытые порты" "$PORTS_REPORT"
  print_stress_summary
  print_section "7. IP-регион и доступность сервисов" "$IPREGION_REPORT"
  if [[ -s "$IPREGION_ERROR" ]]; then print_section "Сообщения ipregion" "$IPREGION_ERROR"; fi

  printf '\n%sДиагностика завершена. Временные файлы будут удалены.%s\n' "$C_CYAN" "$C_RESET"
}

if [[ "${TIMURIO_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
