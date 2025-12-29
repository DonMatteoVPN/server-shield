#!/bin/bash
#
# monitor.sh - Мониторинг ресурсов и автоочистка
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"
source "$(dirname "$0")/telegram.sh" 2>/dev/null || source "/opt/server-shield/modules/telegram.sh"

# Конфиги
MONITOR_SCRIPT="/opt/server-shield/scripts/monitor-check.sh"
CLEANUP_SCRIPT="/opt/server-shield/scripts/auto-cleanup.sh"
MONITOR_CRON="/etc/cron.d/shield-monitor"
CLEANUP_CRON="/etc/cron.d/shield-cleanup"
MONITOR_LOG="/opt/server-shield/logs/monitor.log"

# ============================================
# ФУНКЦИИ ПРОВЕРКИ РЕСУРСОВ
# ============================================

# Получить использование диска (%)
get_disk_usage() {
    df -h / | awk 'NR==2 {gsub(/%/,""); print $5}'
}

# Получить использование RAM (%)
get_ram_usage() {
    free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}'
}

# Получить использование CPU (%)
get_cpu_usage() {
    # Средняя загрузка за последние 5 секунд
    top -bn2 -d0.5 | grep "Cpu(s)" | tail -1 | awk '{print int($2 + $4)}'
}

# Получить свободное место на диске
get_disk_free() {
    df -h / | awk 'NR==2 {print $4}'
}

# Получить свободную RAM
get_ram_free() {
    free -h | awk '/^Mem:/ {print $7}'
}

# ============================================
# TELEGRAM АЛЕРТЫ
# ============================================

send_resource_alert() {
    local resource="$1"
    local current="$2"
    local threshold="$3"
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local emoji=""
    local desc=""
    local extra=""
    
    case "$resource" in
        "disk")
            emoji="💾"
            desc="ДИСК"
            extra="Свободно: $(get_disk_free)"
            ;;
        "ram")
            emoji="🧠"
            desc="RAM"
            extra="Свободно: $(get_ram_free)"
            ;;
        "cpu")
            emoji="⚡"
            desc="CPU"
            extra="Load average: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
            ;;
    esac
    
    local message="$emoji ВНИМАНИЕ: $desc > ${threshold}%

Сервер: ${hostname}
IP: ${server_ip}

Использовано: ${current}%
Порог: ${threshold}%
$extra

Время: ${date}"
    
    send_telegram "$message"
    
    # Логируем
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ALERT | $resource: ${current}% > ${threshold}%" >> "$MONITOR_LOG"
}

send_cleanup_report() {
    local freed="$1"
    local disk_before="$2"
    local disk_after="$3"
    local hostname=$(hostname -f 2>/dev/null || hostname)
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🧹 Автоочистка выполнена

Сервер: ${hostname}

Диск до: ${disk_before}%
Диск после: ${disk_after}%
Освобождено: ${freed}

Время: ${date}"
    
    send_telegram "$message"
}

# ============================================
# АВТООЧИСТКА
# ============================================

# Очистка логов
cleanup_logs() {
    local freed=0
    
    log_step "Очистка логов..."
    
    # Системные логи старше 7 дней
    if [[ -d /var/log ]]; then
        find /var/log -name "*.log" -mtime +7 -type f -exec truncate -s 0 {} \; 2>/dev/null
        find /var/log -name "*.log.*" -mtime +7 -type f -delete 2>/dev/null
        find /var/log -name "*.gz" -mtime +7 -type f -delete 2>/dev/null
        find /var/log -name "*.old" -mtime +3 -type f -delete 2>/dev/null
    fi
    
    # Journal логи (systemd)
    if command -v journalctl &> /dev/null; then
        journalctl --vacuum-time=7d --vacuum-size=100M 2>/dev/null
    fi
    
    # Логи Docker
    if [[ -d /var/lib/docker/containers ]]; then
        find /var/lib/docker/containers -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
    fi
    
    # Логи Shield
    if [[ -d /opt/server-shield/logs ]]; then
        find /opt/server-shield/logs -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null
    fi
    
    # Логи Fail2Ban
    if [[ -f /var/log/fail2ban.log ]]; then
        if [[ $(stat -f%z /var/log/fail2ban.log 2>/dev/null || stat -c%s /var/log/fail2ban.log 2>/dev/null) -gt 104857600 ]]; then
            truncate -s 10M /var/log/fail2ban.log
        fi
    fi
    
    log_info "Логи очищены"
}

# Очистка кэша
cleanup_cache() {
    log_step "Очистка кэша..."
    
    # APT кэш
    apt-get clean 2>/dev/null
    apt-get autoclean 2>/dev/null
    
    # Старые ядра (оставляем текущее)
    apt-get autoremove --purge -y 2>/dev/null
    
    # Temp файлы
    find /tmp -type f -atime +3 -delete 2>/dev/null
    find /var/tmp -type f -atime +7 -delete 2>/dev/null
    
    # Thumbnails
    rm -rf /root/.cache/thumbnails/* 2>/dev/null
    
    # Pip кэш
    rm -rf /root/.cache/pip/* 2>/dev/null
    
    # npm/yarn кэш
    rm -rf /root/.npm/_cacache/* 2>/dev/null
    rm -rf /root/.cache/yarn/* 2>/dev/null
    
    log_info "Кэш очищен"
}

# Очистка Docker
cleanup_docker() {
    if command -v docker &> /dev/null; then
        log_step "Очистка Docker..."
        
        # Неиспользуемые образы
        docker image prune -f 2>/dev/null
        
        # Остановленные контейнеры
        docker container prune -f 2>/dev/null
        
        # Неиспользуемые volumes
        docker volume prune -f 2>/dev/null
        
        # Build cache
        docker builder prune -f 2>/dev/null
        
        log_info "Docker очищен"
    fi
}

# Полная очистка
full_cleanup() {
    local disk_before=$(get_disk_usage)
    local space_before=$(df / | awk 'NR==2 {print $4}')
    
    echo ""
    log_step "Запуск полной очистки..."
    echo ""
    
    cleanup_logs
    cleanup_cache
    cleanup_docker
    
    # Синхронизируем диск
    sync
    
    local disk_after=$(get_disk_usage)
    local space_after=$(df / | awk 'NR==2 {print $4}')
    
    # Считаем освобождённое место
    local freed_kb=$((space_after - space_before))
    local freed=""
    
    if [[ $freed_kb -gt 1048576 ]]; then
        freed="$((freed_kb / 1048576)) GB"
    elif [[ $freed_kb -gt 1024 ]]; then
        freed="$((freed_kb / 1024)) MB"
    else
        freed="${freed_kb} KB"
    fi
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ Очистка завершена!                               ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Диск до: ${YELLOW}${disk_before}%${NC}"
    echo -e "  Диск после: ${GREEN}${disk_after}%${NC}"
    echo -e "  Освобождено: ${CYAN}${freed}${NC}"
    echo ""
    
    # Логируем
    echo "$(date '+%Y-%m-%d %H:%M:%S') | CLEANUP | Before: ${disk_before}% | After: ${disk_after}% | Freed: ${freed}" >> "$MONITOR_LOG"
    
    return 0
}

# ============================================
# СКРИПТЫ ДЛЯ CRON
# ============================================

# Создать скрипт мониторинга
create_monitor_script() {
    local disk_threshold=$(get_config "MONITOR_DISK_THRESHOLD" "90")
    local ram_threshold=$(get_config "MONITOR_RAM_THRESHOLD" "90")
    local cpu_threshold=$(get_config "MONITOR_CPU_THRESHOLD" "90")
    local auto_cleanup=$(get_config "MONITOR_AUTO_CLEANUP" "true")
    local cleanup_threshold=$(get_config "MONITOR_CLEANUP_THRESHOLD" "80")
    
    mkdir -p /opt/server-shield/scripts
    mkdir -p /opt/server-shield/logs
    
    cat > "$MONITOR_SCRIPT" << SCRIPT
#!/bin/bash
# Server Shield - Resource Monitor
# Проверка ресурсов и алерты

source /opt/server-shield/modules/telegram.sh 2>/dev/null

LOG="/opt/server-shield/logs/monitor.log"
ALERT_COOLDOWN_FILE="/tmp/shield-alert-cooldown"

# Пороги
DISK_THRESHOLD=$disk_threshold
RAM_THRESHOLD=$ram_threshold
CPU_THRESHOLD=$cpu_threshold
AUTO_CLEANUP=$auto_cleanup
CLEANUP_THRESHOLD=$cleanup_threshold

# Получаем значения
DISK=\$(df -h / | awk 'NR==2 {gsub(/%/,""); print \$5}')
RAM=\$(free | awk '/^Mem:/ {printf "%.0f", \$3/\$2 * 100}')
CPU=\$(top -bn2 -d0.5 | grep "Cpu(s)" | tail -1 | awk '{print int(\$2 + \$4)}')

# Получаем имя сервера (пользовательское или hostname)
SERVER_NAME=\$(grep "^SERVER_NAME=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)
if [[ -z "\$SERVER_NAME" ]]; then
    SERVER_NAME=\$(hostname -f 2>/dev/null || hostname)
fi

SERVER_IP=\$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "N/A")
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

# Функция проверки cooldown (чтобы не спамить)
check_cooldown() {
    local resource="\$1"
    local cooldown_file="\${ALERT_COOLDOWN_FILE}_\${resource}"
    
    # Cooldown 1 час
    if [[ -f "\$cooldown_file" ]]; then
        local last_alert=\$(cat "\$cooldown_file")
        local now=\$(date +%s)
        local diff=\$((now - last_alert))
        
        if [[ \$diff -lt 3600 ]]; then
            return 1  # Ещё на cooldown
        fi
    fi
    
    # Обновляем время
    date +%s > "\$cooldown_file"
    return 0
}

# Алерт диска
if [[ \$DISK -ge \$DISK_THRESHOLD ]]; then
    if check_cooldown "disk"; then
        send_telegram "💾 ВНИМАНИЕ: ДИСК > \${DISK_THRESHOLD}%

Сервер: \$SERVER_NAME
IP: \$SERVER_IP

Использовано: \${DISK}%
Свободно: \$(df -h / | awk 'NR==2 {print \$4}')

Время: \$DATE"
        
        echo "\$DATE | ALERT | disk: \${DISK}% > \${DISK_THRESHOLD}%" >> "\$LOG"
    fi
fi

# Алерт RAM
if [[ \$RAM -ge \$RAM_THRESHOLD ]]; then
    if check_cooldown "ram"; then
        send_telegram "🧠 ВНИМАНИЕ: RAM > \${RAM_THRESHOLD}%

Сервер: \$SERVER_NAME
IP: \$SERVER_IP

Использовано: \${RAM}%
Свободно: \$(free -h | awk '/^Mem:/ {print \$7}')

Время: \$DATE"
        
        echo "\$DATE | ALERT | ram: \${RAM}% > \${RAM_THRESHOLD}%" >> "\$LOG"
    fi
fi

# Алерт CPU
if [[ \$CPU -ge \$CPU_THRESHOLD ]]; then
    if check_cooldown "cpu"; then
        send_telegram "⚡ ВНИМАНИЕ: CPU > \${CPU_THRESHOLD}%

Сервер: \$SERVER_NAME
IP: \$SERVER_IP

Загрузка: \${CPU}%
Load average: \$(cat /proc/loadavg | awk '{print \$1, \$2, \$3}')

Время: \$DATE"
        
        echo "\$DATE | ALERT | cpu: \${CPU}% > \${CPU_THRESHOLD}%" >> "\$LOG"
    fi
fi

# Автоочистка при превышении порога
if [[ "\$AUTO_CLEANUP" == "true" ]] && [[ \$DISK -ge \$CLEANUP_THRESHOLD ]]; then
    DISK_BEFORE=\$DISK
    
    # Запускаем очистку
    /opt/server-shield/scripts/auto-cleanup.sh quiet
    
    DISK_AFTER=\$(df -h / | awk 'NR==2 {gsub(/%/,""); print \$5}')
    
    if [[ \$DISK_AFTER -lt \$DISK_BEFORE ]]; then
        FREED=\$((DISK_BEFORE - DISK_AFTER))
        
        send_telegram "🧹 Автоочистка выполнена

Сервер: \$SERVER_NAME

Диск до: \${DISK_BEFORE}%
Диск после: \${DISK_AFTER}%
Освобождено: ~\${FREED}%

Время: \$DATE"
        
        echo "\$DATE | AUTO_CLEANUP | Before: \${DISK_BEFORE}% | After: \${DISK_AFTER}%" >> "\$LOG"
    fi
fi

# Логируем текущее состояние (раз в час)
LAST_STATUS_FILE="/tmp/shield-last-status"
NOW_HOUR=\$(date +%H)

if [[ ! -f "\$LAST_STATUS_FILE" ]] || [[ "\$(cat \$LAST_STATUS_FILE)" != "\$NOW_HOUR" ]]; then
    echo "\$DATE | STATUS | disk: \${DISK}% | ram: \${RAM}% | cpu: \${CPU}%" >> "\$LOG"
    echo "\$NOW_HOUR" > "\$LAST_STATUS_FILE"
fi
SCRIPT

    chmod +x "$MONITOR_SCRIPT"
}

# Создать скрипт очистки
create_cleanup_script() {
    cat > "$CLEANUP_SCRIPT" << 'SCRIPT'
#!/bin/bash
# Server Shield - Auto Cleanup

QUIET="$1"
LOG="/opt/server-shield/logs/monitor.log"

log() {
    if [[ "$QUIET" != "quiet" ]]; then
        echo "$1"
    fi
}

# Системные логи
log "Очистка системных логов..."
find /var/log -name "*.log" -mtime +7 -type f -exec truncate -s 0 {} \; 2>/dev/null
find /var/log -name "*.log.*" -mtime +7 -type f -delete 2>/dev/null
find /var/log -name "*.gz" -mtime +7 -type f -delete 2>/dev/null
find /var/log -name "*.old" -mtime +3 -type f -delete 2>/dev/null

# Journal
if command -v journalctl &> /dev/null; then
    log "Очистка journal..."
    journalctl --vacuum-time=7d --vacuum-size=100M 2>/dev/null
fi

# Docker логи
if [[ -d /var/lib/docker/containers ]]; then
    log "Очистка Docker логов..."
    find /var/lib/docker/containers -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
fi

# APT кэш
log "Очистка APT кэша..."
apt-get clean 2>/dev/null
apt-get autoclean 2>/dev/null

# Temp файлы
log "Очистка temp файлов..."
find /tmp -type f -atime +3 -delete 2>/dev/null
find /var/tmp -type f -atime +7 -delete 2>/dev/null

# Shield логи
if [[ -d /opt/server-shield/logs ]]; then
    find /opt/server-shield/logs -name "*.log" -size +10M -exec truncate -s 1M {} \; 2>/dev/null
fi

# Docker cleanup
if command -v docker &> /dev/null; then
    log "Очистка Docker..."
    docker image prune -f 2>/dev/null
    docker container prune -f 2>/dev/null
    docker volume prune -f 2>/dev/null
fi

sync

log "Очистка завершена"
echo "$(date '+%Y-%m-%d %H:%M:%S') | CLEANUP | Scheduled cleanup completed" >> "$LOG"
SCRIPT

    chmod +x "$CLEANUP_SCRIPT"
}

# ============================================
# CRON НАСТРОЙКА
# ============================================

# Настроить cron для мониторинга
setup_monitor_cron() {
    local interval=$(get_config "MONITOR_INTERVAL" "5")
    
    # Создаём cron (каждые N минут)
    echo "*/$interval * * * * root $MONITOR_SCRIPT" > "$MONITOR_CRON"
    
    log_info "Мониторинг настроен (каждые $interval мин)"
}

# Настроить cron для очистки
setup_cleanup_cron() {
    local schedule=$(get_config "CLEANUP_SCHEDULE" "daily")
    
    rm -f "$CLEANUP_CRON"
    
    case "$schedule" in
        "off")
            log_info "Автоочистка по расписанию отключена"
            ;;
        "daily")
            # Каждый день в 4:00
            echo "0 4 * * * root $CLEANUP_SCRIPT" > "$CLEANUP_CRON"
            log_info "Автоочистка: ежедневно в 4:00"
            ;;
        "weekly")
            # Каждое воскресенье в 4:00
            echo "0 4 * * 0 root $CLEANUP_SCRIPT" > "$CLEANUP_CRON"
            log_info "Автоочистка: еженедельно (воскр. 4:00)"
            ;;
        "twice")
            # Два раза в день: 4:00 и 16:00
            echo "0 4,16 * * * root $CLEANUP_SCRIPT" > "$CLEANUP_CRON"
            log_info "Автоочистка: 2 раза в день (4:00, 16:00)"
            ;;
    esac
}

# Отключить мониторинг
disable_monitor() {
    rm -f "$MONITOR_CRON"
    save_config "MONITOR_ENABLED" "false"
    log_info "Мониторинг отключен"
}

# Включить мониторинг
enable_monitor() {
    create_monitor_script
    create_cleanup_script
    setup_monitor_cron
    setup_cleanup_cron
    save_config "MONITOR_ENABLED" "true"
    log_info "Мониторинг включен"
}

# ============================================
# ПЕРВОНАЧАЛЬНАЯ НАСТРОЙКА
# ============================================

setup_monitoring() {
    print_section "📊 Настройка мониторинга ресурсов"
    
    echo ""
    echo -e "${WHITE}Мониторинг будет отправлять алерты в Telegram при:${NC}"
    echo -e "  • Диск заполнен > порога"
    echo -e "  • RAM использована > порога"
    echo -e "  • CPU загружен > порога"
    echo ""
    
    # Проверяем Telegram
    get_tg_config
    if [[ -z "$TG_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
        log_warn "Telegram не настроен! Алерты не будут отправляться."
        echo -e "   Настройте через: ${CYAN}shield telegram${NC}"
        echo ""
    fi
    
    # Порог диска
    echo -e "${WHITE}Порог алерта диска (%)${NC}"
    echo -e "${CYAN}При превышении — отправится уведомление${NC}"
    read -p "Порог диска [90]: " disk_threshold
    disk_threshold=${disk_threshold:-90}
    
    # Порог RAM
    echo ""
    echo -e "${WHITE}Порог алерта RAM (%)${NC}"
    read -p "Порог RAM [90]: " ram_threshold
    ram_threshold=${ram_threshold:-90}
    
    # Порог CPU
    echo ""
    echo -e "${WHITE}Порог алерта CPU (%)${NC}"
    read -p "Порог CPU [90]: " cpu_threshold
    cpu_threshold=${cpu_threshold:-90}
    
    # Интервал проверки
    echo ""
    echo -e "${WHITE}Как часто проверять (минуты):${NC}"
    echo -e "  ${CYAN}1${NC} — каждую минуту (для критичных серверов)"
    echo -e "  ${CYAN}5${NC} — каждые 5 минут (рекомендуется)"
    echo -e "  ${CYAN}15${NC} — каждые 15 минут"
    read -p "Интервал [5]: " interval
    interval=${interval:-5}
    
    # Автоочистка
    echo ""
    echo -e "${WHITE}Автоочистка при заполнении диска?${NC}"
    read -p "Включить автоочистку при >80%? (Y/n): " auto_cleanup
    if [[ "$auto_cleanup" =~ ^[Nn]$ ]]; then
        auto_cleanup="false"
        cleanup_threshold="999"
    else
        auto_cleanup="true"
        echo ""
        read -p "Порог для автоочистки (%) [80]: " cleanup_threshold
        cleanup_threshold=${cleanup_threshold:-80}
    fi
    
    # Расписание очистки
    echo ""
    echo -e "${WHITE}Расписание плановой очистки:${NC}"
    echo -e "  ${CYAN}1${NC}) Ежедневно (4:00)"
    echo -e "  ${CYAN}2${NC}) 2 раза в день (4:00, 16:00)"
    echo -e "  ${CYAN}3${NC}) Еженедельно (воскр. 4:00)"
    echo -e "  ${CYAN}4${NC}) Отключить"
    read -p "Выбор [1]: " schedule_choice
    
    case "$schedule_choice" in
        2) schedule="twice" ;;
        3) schedule="weekly" ;;
        4) schedule="off" ;;
        *) schedule="daily" ;;
    esac
    
    # Сохраняем настройки
    save_config "MONITOR_ENABLED" "true"
    save_config "MONITOR_DISK_THRESHOLD" "$disk_threshold"
    save_config "MONITOR_RAM_THRESHOLD" "$ram_threshold"
    save_config "MONITOR_CPU_THRESHOLD" "$cpu_threshold"
    save_config "MONITOR_INTERVAL" "$interval"
    save_config "MONITOR_AUTO_CLEANUP" "$auto_cleanup"
    save_config "MONITOR_CLEANUP_THRESHOLD" "$cleanup_threshold"
    save_config "CLEANUP_SCHEDULE" "$schedule"
    
    # Создаём скрипты и cron
    create_monitor_script
    create_cleanup_script
    setup_monitor_cron
    setup_cleanup_cron
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ Мониторинг настроен!                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Порог диска: ${CYAN}${disk_threshold}%${NC}"
    echo -e "  Порог RAM: ${CYAN}${ram_threshold}%${NC}"
    echo -e "  Порог CPU: ${CYAN}${cpu_threshold}%${NC}"
    echo -e "  Проверка: каждые ${CYAN}${interval} мин${NC}"
    
    if [[ "$auto_cleanup" == "true" ]]; then
        echo -e "  Автоочистка: при ${CYAN}>${cleanup_threshold}%${NC} диска"
    fi
    
    case "$schedule" in
        "daily") echo -e "  Плановая очистка: ${CYAN}ежедневно 4:00${NC}" ;;
        "twice") echo -e "  Плановая очистка: ${CYAN}2 раза/день${NC}" ;;
        "weekly") echo -e "  Плановая очистка: ${CYAN}еженедельно${NC}" ;;
        "off") echo -e "  Плановая очистка: ${YELLOW}отключена${NC}" ;;
    esac
    echo ""
}

# ============================================
# МЕНЮ
# ============================================

monitor_menu() {
    while true; do
        print_header
        print_section "📊 Мониторинг ресурсов"
        
        # Текущие значения
        local disk=$(get_disk_usage)
        local ram=$(get_ram_usage)
        local cpu=$(get_cpu_usage)
        local disk_free=$(get_disk_free)
        local ram_free=$(get_ram_free)
        
        # Настройки
        local enabled=$(get_config "MONITOR_ENABLED" "false")
        local disk_threshold=$(get_config "MONITOR_DISK_THRESHOLD" "90")
        local ram_threshold=$(get_config "MONITOR_RAM_THRESHOLD" "90")
        local cpu_threshold=$(get_config "MONITOR_CPU_THRESHOLD" "90")
        local auto_cleanup=$(get_config "MONITOR_AUTO_CLEANUP" "false")
        local cleanup_threshold=$(get_config "MONITOR_CLEANUP_THRESHOLD" "80")
        local schedule=$(get_config "CLEANUP_SCHEDULE" "daily")
        
        echo ""
        echo -e "${WHITE}  Текущее состояние:${NC}"
        echo ""
        
        # Диск с цветом
        if [[ $disk -ge $disk_threshold ]]; then
            echo -e "    💾 Диск: ${RED}${disk}%${NC} (свободно: $disk_free) ${RED}⚠️${NC}"
        elif [[ $disk -ge $cleanup_threshold ]]; then
            echo -e "    💾 Диск: ${YELLOW}${disk}%${NC} (свободно: $disk_free)"
        else
            echo -e "    💾 Диск: ${GREEN}${disk}%${NC} (свободно: $disk_free)"
        fi
        
        # RAM с цветом
        if [[ $ram -ge $ram_threshold ]]; then
            echo -e "    🧠 RAM:  ${RED}${ram}%${NC} (свободно: $ram_free) ${RED}⚠️${NC}"
        elif [[ $ram -ge 70 ]]; then
            echo -e "    🧠 RAM:  ${YELLOW}${ram}%${NC} (свободно: $ram_free)"
        else
            echo -e "    🧠 RAM:  ${GREEN}${ram}%${NC} (свободно: $ram_free)"
        fi
        
        # CPU с цветом
        if [[ $cpu -ge $cpu_threshold ]]; then
            echo -e "    ⚡ CPU:  ${RED}${cpu}%${NC} ${RED}⚠️${NC}"
        elif [[ $cpu -ge 70 ]]; then
            echo -e "    ⚡ CPU:  ${YELLOW}${cpu}%${NC}"
        else
            echo -e "    ⚡ CPU:  ${GREEN}${cpu}%${NC}"
        fi
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Статус мониторинга
        if [[ "$enabled" == "true" ]]; then
            echo -e "  ${GREEN}●${NC} Мониторинг: ${GREEN}Активен${NC}"
            echo -e "    Пороги: диск ${CYAN}${disk_threshold}%${NC} | RAM ${CYAN}${ram_threshold}%${NC} | CPU ${CYAN}${cpu_threshold}%${NC}"
        else
            echo -e "  ${RED}○${NC} Мониторинг: ${RED}Не настроен${NC}"
        fi
        
        # Статус автоочистки
        if [[ "$auto_cleanup" == "true" ]]; then
            echo -e "  ${GREEN}●${NC} Автоочистка: при ${CYAN}>${cleanup_threshold}%${NC} диска"
        else
            echo -e "  ${YELLOW}○${NC} Автоочистка: ${YELLOW}отключена${NC}"
        fi
        
        # Расписание
        case "$schedule" in
            "daily") echo -e "  📅 Плановая очистка: ${CYAN}ежедневно 4:00${NC}" ;;
            "twice") echo -e "  📅 Плановая очистка: ${CYAN}2 раза/день${NC}" ;;
            "weekly") echo -e "  📅 Плановая очистка: ${CYAN}еженедельно${NC}" ;;
            "off") echo -e "  📅 Плановая очистка: ${YELLOW}отключена${NC}" ;;
        esac
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} 🔧 Настроить мониторинг"
        echo -e "  ${WHITE}2)${NC} 🧹 Запустить очистку сейчас"
        echo -e "  ${WHITE}3)${NC} 📋 Изменить пороги алертов"
        echo -e "  ${WHITE}4)${NC} ⏰ Изменить расписание очистки"
        echo -e "  ${WHITE}5)${NC} 📊 Просмотр логов мониторинга"
        echo ""
        
        if [[ "$enabled" == "true" ]]; then
            echo -e "  ${WHITE}6)${NC} 🔴 Отключить мониторинг"
        else
            echo -e "  ${WHITE}6)${NC} 🟢 Включить мониторинг"
        fi
        
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) setup_monitoring ;;
            2) 
                full_cleanup
                ;;
            3)
                # Изменить пороги
                echo ""
                read -p "Порог диска (%) [$disk_threshold]: " new_disk
                read -p "Порог RAM (%) [$ram_threshold]: " new_ram
                read -p "Порог CPU (%) [$cpu_threshold]: " new_cpu
                
                save_config "MONITOR_DISK_THRESHOLD" "${new_disk:-$disk_threshold}"
                save_config "MONITOR_RAM_THRESHOLD" "${new_ram:-$ram_threshold}"
                save_config "MONITOR_CPU_THRESHOLD" "${new_cpu:-$cpu_threshold}"
                
                create_monitor_script
                log_info "Пороги обновлены"
                ;;
            4)
                # Изменить расписание
                echo ""
                echo -e "${WHITE}Расписание плановой очистки:${NC}"
                echo -e "  ${CYAN}1${NC}) Ежедневно (4:00)"
                echo -e "  ${CYAN}2${NC}) 2 раза в день (4:00, 16:00)"
                echo -e "  ${CYAN}3${NC}) Еженедельно (воскр. 4:00)"
                echo -e "  ${CYAN}4${NC}) Отключить"
                read -p "Выбор: " sched
                
                case "$sched" in
                    1) save_config "CLEANUP_SCHEDULE" "daily" ;;
                    2) save_config "CLEANUP_SCHEDULE" "twice" ;;
                    3) save_config "CLEANUP_SCHEDULE" "weekly" ;;
                    4) save_config "CLEANUP_SCHEDULE" "off" ;;
                esac
                
                setup_cleanup_cron
                ;;
            5)
                # Просмотр логов
                echo ""
                echo -e "${WHITE}Последние записи мониторинга:${NC}"
                echo ""
                if [[ -f "$MONITOR_LOG" ]]; then
                    tail -30 "$MONITOR_LOG"
                else
                    echo "Логов пока нет"
                fi
                ;;
            6)
                # Включить/выключить
                if [[ "$enabled" == "true" ]]; then
                    disable_monitor
                else
                    enable_monitor
                fi
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Получить статус для главного меню
get_monitor_status_line() {
    local enabled=$(get_config "MONITOR_ENABLED" "false")
    
    if [[ "$enabled" == "true" ]]; then
        local disk=$(get_disk_usage)
        local ram=$(get_ram_usage)
        echo -e "${GREEN}●${NC} D:${disk}% R:${ram}%"
    else
        echo -e "${RED}○${NC} Выключен"
    fi
}
