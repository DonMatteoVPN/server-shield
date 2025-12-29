#!/bin/bash
#
# utils.sh - Общие функции и переменные
#

# Цвета
export RED=$'\e[0;31m'
export GREEN=$'\e[0;32m'
export YELLOW=$'\e[1;33m'
export BLUE=$'\e[0;34m'
export PURPLE=$'\e[0;35m'
export CYAN=$'\e[0;36m'
export WHITE=$'\e[1;37m'
export NC=$'\e[0m' # No Color

# Директории
export SHIELD_DIR="/opt/server-shield"
export BACKUP_DIR="$SHIELD_DIR/backups"
export CONFIG_DIR="$SHIELD_DIR/config"
export LOG_DIR="$SHIELD_DIR/logs"

# Конфиг файл
export SHIELD_CONFIG="$CONFIG_DIR/shield.conf"

# Функция вывода заголовка
print_header() {
    local version="2.1.0"
    if [[ -f "$SHIELD_DIR/VERSION" ]]; then
        version=$(cat "$SHIELD_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')
    fi
    clear
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       🛡️  SERVER SECURITY SHIELD v${version}  🛡️           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Функция вывода секции
print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Функции логирования
log_info() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[→]${NC} $1"
}

# Функция проверки root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от root!"
        exit 1
    fi
}

# Функция проверки ОС
check_os() {
    if [[ -f /etc/debian_version ]]; then
        export OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        export OS="rhel"
        log_error "RHEL/CentOS пока не поддерживается"
        exit 1
    else
        log_error "Неподдерживаемая ОС"
        exit 1
    fi
}

# Функция создания директорий
init_directories() {
    mkdir -p "$SHIELD_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
}

# Функция сохранения конфига
save_config() {
    local key="$1"
    local value="$2"
    
    # Создаём файл если не существует
    touch "$SHIELD_CONFIG"
    
    # Удаляем старое значение если есть
    sed -i "/^${key}=/d" "$SHIELD_CONFIG"
    
    # Добавляем новое
    echo "${key}=${value}" >> "$SHIELD_CONFIG"
}

# Функция чтения конфига
get_config() {
    local key="$1"
    local default="$2"
    
    if [[ -f "$SHIELD_CONFIG" ]]; then
        local value=$(grep "^${key}=" "$SHIELD_CONFIG" | cut -d'=' -f2-)
        if [[ -n "$value" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

# Функция подтверждения
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# Функция ожидания нажатия клавиши
press_any_key() {
    echo ""
    read -n 1 -s -r -p "Нажмите любую клавишу для продолжения..."
    echo ""
}

# Функция проверки IP адреса
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Функция проверки порта
validate_port() {
    local port="$1"
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
        return 0
    fi
    return 1
}

# Функция получения внешнего IP
get_external_ip() {
    curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "N/A"
}

# Функция получения hostname
get_hostname() {
    hostname -f 2>/dev/null || hostname
}

# Функция получения имени сервера (пользовательское или hostname)
get_server_name() {
    local custom_name=$(get_config "SERVER_NAME" "")
    if [[ -n "$custom_name" ]]; then
        echo "$custom_name"
    else
        get_hostname
    fi
}
