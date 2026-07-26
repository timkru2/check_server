#!/usr/bin/env bash

# Timurio Server Diagnostics
# Запуск: wget -qO- https://raw.githubusercontent.com/timkru2/check_server/main/install.sh | bash

set -uo pipefail

readonly SCRIPT_VERSION="1.3.0"
readonly TOTAL_STAGES=6
readonly SPEEDTEST_VERSION="1.2.0"
readonly SPEEDTEST_X86_SHA256="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
readonly SPEEDTEST_ARM_SHA256="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
readonly IPREGION_COMMIT="89a75849ab6c0490de893be0dbfea4902ddaac60"
readonly IPREGION_SHA256="23c792386e94e2fd62ba4274b1bcfab9be3ace8bb3b984539275bf371e25d8a8"
readonly IPREGION_URL="https://raw.githubusercontent.com/vernette/ipregion/${IPREGION_COMMIT}/ipregion.sh"
readonly GOOGLE_IPV4="8.8.8.8"
readonly GOOGLE_IPV6="2001:4860:4860::8888"

AUTO_INSTALL="${AUTO_INSTALL:-1}"
SKIP_IPREGION="${SKIP_IPREGION:-0}"

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
IPREGION_JSON="$WORK_DIR/ipregion.json"
IPREGION_ERROR="$WORK_DIR/ipregion.err"
IPREGION_REPORT="$WORK_DIR/ipregion-report.txt"
SSH_DATA="$WORK_DIR/ssh-data.txt"

declare -a CONCLUSIONS=()

cleanup() {
  if [[ "$ACTIVE_PID" =~ ^[0-9]+$ ]] && (( ACTIVE_PID > 0 )); then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  if [[ -d "$WORK_DIR" ]]; then
    case "$WORK_DIR" in
      /tmp/timurio-*|"${TMPDIR:-/tmp}"/timurio-*) rm -rf -- "$WORK_DIR" ;;
    esac
  fi
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
  local rc=0
  local cmd

  : >"$DEPS_LOG"

  for cmd in wget tar sha256sum timeout awk sed grep ss mtr; do
    if command_missing "$cmd"; then need_core=1; fi
  done
  for cmd in curl jq nslookup column; do
    if command_missing "$cmd"; then need_ipregion=1; fi
  done
  if (( need_core == 0 && need_ipregion == 0 )); then
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
      ;;
    dnf|yum)
      if (( need_core || need_ipregion )); then
        pkg_exec "$manager" install -y -q \
          ca-certificates wget curl tar coreutils gawk sed grep iproute mtr \
          jq bind-utils util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      ;;
    apk)
      if (( need_core || need_ipregion )); then
        pkg_exec apk add --no-cache \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr \
          jq bind-tools util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      ;;
    pacman)
      if (( need_core || need_ipregion )); then
        pkg_exec pacman -Sy --noconfirm --needed \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr \
          jq bind util-linux >>"$DEPS_LOG" 2>&1 || rc=1
      fi
      ;;
    zypper)
      if (( need_core || need_ipregion )); then
        pkg_exec zypper --non-interactive install \
          ca-certificates wget curl tar coreutils gawk sed grep iproute2 mtr \
          jq bind-utils util-linux >>"$DEPS_LOG" 2>&1 || rc=1
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
      add_warn "На сервере есть службы, которые завершились с ошибкой."
      {
        printf '\nНеисправные systemd-службы:\n'
        printf '%s\n' "$failed_units"
      } >>"$SYS_REPORT"
    else
      add_ok "Службы сервера работают без обнаруженных ошибок."
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
    add_warn "Тест скорости обнаружил потерю пакетов: ${packet_loss}%."
  else
    add_ok "Тест скорости завершён без потери пакетов."
  fi
  if [[ -n "$latency" ]] && awk -v value="$latency" 'BEGIN {exit !(value > 100)}'; then
    add_warn "Во время теста скорости обнаружена высокая задержка: ${latency} мс."
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
    add_warn "Не удалось обработать результат проверки ${family}."
    return
  fi
  loss="$(awk '{value=$(NF-6); gsub(/%/, "", value); print value}' <<<"$line")"
  average="$(awk '{print $(NF-3)}' <<<"$line")"
  if [[ "$loss" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v value="$loss" 'BEGIN {exit !(value >= 5)}'; then
      add_fail "Качество ${family}: потеря пакетов ${loss}%, средняя задержка ${average} мс."
    elif awk -v value="$loss" 'BEGIN {exit !(value > 0)}'; then
      add_warn "Качество ${family}: потеря пакетов ${loss}%, средняя задержка ${average} мс."
    else
      add_ok "Качество ${family}: потерь нет, средняя задержка ${average} мс."
    fi
  else
    add_warn "Проверка качества ${family} не дала пригодный результат."
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
  add_ok "Проверка сетевых портов завершена: найдено ${count}."
  if [[ -n "$sensitive" ]]; then
    add_warn "Потенциально чувствительные порты слушают на всех интерфейсах: ${sensitive}. Проверьте firewall и необходимость публикации."
  fi
}

ssh_data_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$SSH_DATA" 2>/dev/null | head -n 1
}

collect_ssh_info() {
  local sshd_bin="" effective="" ports="" config_ports=""
  local pubkey="неизвестно" password="неизвестно" keyboard="неизвестно"
  local root_login="неизвестно" auth_methods="неизвестно" auth_mode="Не удалось определить"
  local key_count=0 root_home="/root"

  ports="$(awk '
    NR > 2 && /sshd|dropbear/ {
      address=$5
      sub(/^.*:/, "", address)
      if (address ~ /^[0-9]+$/) print address
    }
  ' "$PORTS_REPORT" 2>/dev/null | sort -nu | paste -sd, -)"

  if command -v sshd >/dev/null 2>&1; then
    sshd_bin="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  fi

  if [[ -n "$sshd_bin" ]]; then
    effective="$("$sshd_bin" -T -C "user=root,host=$(hostname 2>/dev/null || printf localhost),addr=127.0.0.1" 2>/dev/null || "$sshd_bin" -T 2>/dev/null || true)"
    config_ports="$(awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}' <<<"$effective" | sort -nu | paste -sd, -)"
    [[ -n "$ports" ]] || ports="$config_ports"
    pubkey="$(awk '$1 == "pubkeyauthentication" {print $2; exit}' <<<"$effective")"
    password="$(awk '$1 == "passwordauthentication" {print $2; exit}' <<<"$effective")"
    keyboard="$(awk '$1 == "kbdinteractiveauthentication" {print $2; exit}' <<<"$effective")"
    [[ -n "$keyboard" ]] || keyboard="$(awk '$1 == "challengeresponseauthentication" {print $2; exit}' <<<"$effective")"
    root_login="$(awk '$1 == "permitrootlogin" {print $2; exit}' <<<"$effective")"
    auth_methods="$(awk '$1 == "authenticationmethods" {print $2; exit}' <<<"$effective")"
    pubkey="${pubkey:-неизвестно}"
    password="${password:-неизвестно}"
    keyboard="${keyboard:-неизвестно}"
    root_login="${root_login:-неизвестно}"
    auth_methods="${auth_methods:-неизвестно}"
  fi

  if command -v getent >/dev/null 2>&1; then
    root_home="$(getent passwd 0 2>/dev/null | awk -F: '{print $6; exit}')"
  fi
  root_home="${root_home:-/root}"
  if [[ -r "$root_home/.ssh/authorized_keys" ]]; then
    key_count="$(awk '!/^[[:space:]]*(#|$)/ {count++} END {print count+0}' "$root_home/.ssh/authorized_keys")"
  fi

  if [[ "$pubkey" == "yes" && "$password" == "no" && "$keyboard" != "yes" ]]; then
    auth_mode="Только вход по ключу"
  elif [[ "$auth_methods" != "any" && "$auth_methods" != "неизвестно" && "$auth_methods" == *publickey* ]]; then
    auth_mode="Ключ обязателен для входа"
  elif [[ "$pubkey" == "yes" && ( "$password" == "yes" || "$keyboard" == "yes" ) ]]; then
    auth_mode="Разрешены ключ и пароль"
  elif [[ "$pubkey" == "yes" ]]; then
    auth_mode="Вход по ключу включён"
  elif [[ "$password" == "yes" || "$keyboard" == "yes" ]]; then
    auth_mode="Разрешён вход по паролю"
  fi

  {
    printf 'ports=%s\n' "${ports:-не найден}"
    printf 'auth_mode=%s\n' "$auth_mode"
    printf 'pubkey=%s\n' "$pubkey"
    printf 'password=%s\n' "$password"
    printf 'keyboard=%s\n' "$keyboard"
    printf 'root_login=%s\n' "$root_login"
    printf 'key_count=%s\n' "$key_count"
  } >"$SSH_DATA"
}

analyze_ssh() {
  local ports auth_mode root_login key_count
  ports="$(ssh_data_value ports)"
  auth_mode="$(ssh_data_value auth_mode)"
  root_login="$(ssh_data_value root_login)"
  key_count="$(ssh_data_value key_count)"

  if [[ -z "$ports" || "$ports" == "не найден" ]]; then
    add_warn "SSH-порт не найден: служба может быть выключена или недоступна для проверки."
    return
  fi

  case "$auth_mode" in
    "Только вход по ключу"|"Ключ обязателен для входа")
      add_ok "SSH работает на порту ${ports}; вход защищён ключом."
      ;;
    "Разрешены ключ и пароль"|"Разрешён вход по паролю")
      add_warn "SSH работает на порту ${ports}, но вход по паролю разрешён. Для защиты сервера лучше оставить только ключи."
      ;;
    *)
      add_ok "SSH работает на порту ${ports}; режим входа: ${auth_mode}."
      ;;
  esac

  if [[ "$root_login" == "yes" && ( "$auth_mode" == *парол* || "$auth_mode" == "Разрешены ключ и пароль" ) ]]; then
    add_warn "Для root разрешён удалённый вход по SSH; проверьте, что парольный вход действительно необходим."
  fi
  if [[ "$key_count" =~ ^[0-9]+$ ]] && (( key_count > 0 )); then
    add_ok "Для root найдено SSH-ключей: ${key_count}."
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

print_ssh_summary() {
  local ports auth_mode root_login key_count root_text
  ports="$(ssh_data_value ports)"
  auth_mode="$(ssh_data_value auth_mode)"
  root_login="$(ssh_data_value root_login)"
  key_count="$(ssh_data_value key_count)"

  case "$root_login" in
    no) root_text="вход root отключён" ;;
    prohibit-password|without-password) root_text="root может входить только по ключу" ;;
    forced-commands-only) root_text="для root разрешены только заданные команды" ;;
    yes) root_text="вход root разрешён" ;;
    *) root_text="режим root не удалось определить" ;;
  esac

  printf '\n%s%sПРОВЕРКА SSH%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  printf 'Порт SSH: %s\n' "${ports:-не найден}"
  printf 'Способ входа: %s.\n' "${auth_mode:-не удалось определить}"
  if [[ "$key_count" =~ ^[0-9]+$ ]] && (( key_count > 0 )); then
    printf 'SSH-ключи root: найдены (%s).\n' "$key_count"
  else
    printf 'SSH-ключи root: не найдены.\n'
  fi
  printf 'Доступ root: %s.\n' "$root_text"
}

friendly_service_value() {
  local value="$1"
  case "$value" in
    Yes|Allowed|Available) printf 'доступен' ;;
    No|Denied|Blocked) printf 'недоступен или ограничен' ;;
    Rate-limit|"Rate limit") printf 'временно ограничен' ;;
    ""|null|N/A) printf 'нет данных' ;;
    [A-Z][A-Z]) printf 'определяемый регион: %s' "$value" ;;
    *) printf '%s' "$value" ;;
  esac
}

print_services_summary() {
  local service value friendly
  printf '\n%s%sДОСТУПНОСТЬ ПОПУЛЯРНЫХ СЕРВИСОВ%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  if ! jq -e . "$IPREGION_JSON" >/dev/null 2>&1; then
    printf 'Результат получить не удалось.\n'
    return
  fi
  while IFS=$'\t' read -r service value; do
    [[ -n "$service" ]] || continue
    value="${value%$'\r'}"
    friendly="$(friendly_service_value "$value")"
    printf '• %s — %s\n' "$service" "$friendly"
  done < <(jq -r '.results.custom[]? | [.service, (.ipv4 // "нет данных")] | @tsv' "$IPREGION_JSON")
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
  local port_count="" public_ports="" external_ipv4="" external_ipv6=""

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

  if jq -e . "$IPREGION_JSON" >/dev/null 2>&1; then
    external_ipv4="$(jq -r '.ipv4 // "нет"' "$IPREGION_JSON")"
    external_ipv6="$(jq -r '.ipv6 // "нет"' "$IPREGION_JSON")"
  else
    external_ipv4="нет данных"
    external_ipv6="нет данных"
  fi

  printf '\n%s%sКЛЮЧЕВЫЕ ПОКАЗАТЕЛИ%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  printf 'Система: %s\n' "${os:-нет данных}"
  printf 'Ресурсы: %s процессоров | память %s, свободно %s | диск занят на %s\n' \
    "${cpu_count:-?}" "${mem_total:-?}" "${mem_available:-?}" "${disk_used:-?}"
  if [[ -n "$download" ]]; then
    printf 'Скорость интернета: скачивание %s Мбит/с | отправка %s Мбит/с | задержка %s мс | потери %s%%\n' \
      "$download" "${upload:-?}" "${latency:-?}" "${packet_loss:-?}"
  else
    printf 'Скорость интернета: нет результата\n'
  fi
  if [[ -n "${mtr4_avg:-}" ]]; then
    printf 'Качество IPv4: средняя задержка %s мс | потери %s%%\n' "$mtr4_avg" "$mtr4_loss"
  else
    printf 'Качество IPv4: нет результата\n'
  fi
  if [[ -n "${mtr6_avg:-}" ]]; then
    printf 'Качество IPv6: средняя задержка %s мс | потери %s%%\n' "$mtr6_avg" "$mtr6_loss"
  else
    printf 'Качество IPv6: подключение отсутствует или тест не выполнен\n'
  fi
  if [[ "$port_count" =~ ^[0-9]+$ ]]; then
    printf 'Сетевые порты: найдено %s | слушают на всех адресах: %s\n' \
      "$port_count" "${public_ports:-нет}"
  else
    printf 'Сетевые порты: нет результата\n'
  fi
  printf 'Внешний адрес: IPv4 %s | IPv6 %s\n' "$external_ipv4" "$external_ipv6"
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

  stage 2 "Проверка скорости интернета"
  if command_missing wget || command_missing tar || command_missing sha256sum; then
    printf 'Необходимы wget, tar и sha256sum.\n' >"$SPEED_ERROR"
    add_fail "Тест скорости пропущен: необходимые утилиты недоступны."
    fail "Тест скорости пропущен."
  else
    if run_spinner "Измеряем скорость сети" "$SPEED_REPORT" "$SPEED_ERROR" run_speedtest; then
      ok "Тест скорости завершён."
      analyze_speedtest
    else
      rc=$?
      fail "Тест скорости завершился с ошибкой (код $rc)."
      add_fail "Тест скорости интернета не завершился успешно."
    fi
  fi

  stage 3 "Маршрут IPv4 до Google — 25 пакетов"
  if command -v mtr >/dev/null 2>&1; then
    if run_spinner "Проверяем маршрут IPv4" "$MTR4_REPORT" "$MTR4_ERROR" run_mtr4; then
      ok "Маршрут IPv4 проверен."
      analyze_mtr "IPv4" "$MTR4_REPORT"
    else
      rc=$?
      fail "Проверка IPv4 завершилась с ошибкой (код $rc)."
      add_fail "Не удалось проверить качество подключения IPv4."
    fi
  else
    printf 'Команда mtr отсутствует.\n' >"$MTR4_ERROR"
    add_fail "Проверка качества IPv4 пропущена: необходимая утилита недоступна."
  fi

  stage 4 "Маршрут IPv6 до Google — 25 пакетов"
  if ! has_ipv6_route; then
    printf 'На сервере отсутствует рабочий маршрут IPv6 до %s.\n' "$GOOGLE_IPV6" >"$MTR6_REPORT"
    warn "IPv6-маршрут отсутствует; тест пропущен."
    add_warn "IPv6 не настроен или маршрут до Google IPv6 недоступен."
  elif command -v mtr >/dev/null 2>&1; then
    if run_spinner "Проверяем маршрут IPv6" "$MTR6_REPORT" "$MTR6_ERROR" run_mtr6; then
      ok "Маршрут IPv6 проверен."
      analyze_mtr "IPv6" "$MTR6_REPORT"
    else
      rc=$?
      fail "Проверка IPv6 завершилась с ошибкой (код $rc)."
      add_fail "Не удалось проверить качество подключения IPv6."
    fi
  else
    printf 'Команда mtr отсутствует.\n' >"$MTR6_ERROR"
    add_fail "Проверка качества IPv6 пропущена: необходимая утилита недоступна."
  fi

  stage 5 "Сетевые порты и безопасность SSH"
  if collect_ports; then
    ok "Список сетевых портов собран."
    analyze_ports
  else
    fail "Не удалось получить список портов."
    add_fail "Проверка локально открытых портов не выполнена."
  fi
  collect_ssh_info
  analyze_ssh

  stage 6 "IP-регион и доступность интернет-сервисов"
  if [[ "$SKIP_IPREGION" == "1" ]]; then
    printf 'Тест отключён переменной SKIP_IPREGION=1.\n' >"$IPREGION_REPORT"
    warn "Проверка региона и сервисов отключена."
    add_warn "Проверка региона и сервисов была отключена пользователем."
  else
    if run_spinner "Проверяем регион и популярные сервисы" "$IPREGION_JSON" "$IPREGION_ERROR" run_ipregion; then
      if jq -e . "$IPREGION_JSON" >/dev/null 2>&1 && format_ipregion; then
        if ipregion_has_runtime_errors || ipregion_has_suspicious_values; then
          warn "IP-регион проверен частично; есть ошибки отдельных запросов."
          add_warn "Некоторые проверки региона и доступности сервисов завершились ошибкой."
        else
          ok "IP-регион и сервисы проверены."
          add_ok "Регион и доступность популярных сервисов проверены без ошибок."
        fi
      else
        fail "Получен некорректный результат проверки сервисов."
        cp "$IPREGION_JSON" "$IPREGION_REPORT"
        add_fail "Не удалось обработать результат проверки региона и сервисов."
      fi
    else
      rc=$?
      fail "Проверка региона и сервисов завершилась с ошибкой (код $rc)."
      {
        printf 'ipregion завершился с кодом %s.\n' "$rc"
        cat "$IPREGION_JSON" "$IPREGION_ERROR" 2>/dev/null || true
      } >"$IPREGION_REPORT"
      add_fail "Проверка региона и доступности сервисов не завершилась успешно."
    fi
  fi

  printf '\n%s%sФИНАЛЬНЫЙ ОТЧЁТ TIMURIO%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  line
  print_conclusions
  print_dashboard
  print_ssh_summary
  print_services_summary

  printf '\n%sДиагностика завершена. Временные файлы будут удалены.%s\n' "$C_CYAN" "$C_RESET"
}

if [[ "${TIMURIO_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
