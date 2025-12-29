#!/bin/bash
#
# traffic.sh - Ограничение скорости per-client через tc (U32 Hash)
# Server Security Shield
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# ============================================
# КОНФИГУРАЦИЯ
# ============================================

TRAFFIC_CONFIG_DIR="$CONFIG_DIR/traffic"
TRAFFIC_SCRIPT="/opt/server-shield/scripts/tc-limiter.sh"
TRAFFIC_SERVICE="/etc/systemd/system/shield-traffic.service"
TRAFFIC_LOG="/var/log/shield-traffic.log"
IFB_DEV="ifb0"
MAX_BUCKETS=256

# ============================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

# Автоопределение сетевого интерфейса
detect_interface() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -br link show | grep -v "lo" | grep "UP" | awk '{print $1}' | head -1)
    fi
    echo "${iface:-eth0}"
}

# Выбор интерфейса интерактивно
select_interface() {
    echo ""
    echo -e "${WHITE}Доступные интерфейсы:${NC}"
    
    local interfaces=()
    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        [[ "$name" != "lo" ]] && interfaces+=("$name")
    done < <(ip -br link show | grep "UP")
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_error "Нет активных сетевых интерфейсов"
        return 1
    fi
    
    local i=1
    for iface in "${interfaces[@]}"; do
        local ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        echo -e "  ${WHITE}$i)${NC} $iface ${CYAN}($ip_addr)${NC}"
        ((i++))
    done
    
    echo ""
    local detected=$(detect_interface)
    read -p "Выбор [по умолчанию: $detected]: " choice
    
    if [[ -z "$choice" ]]; then
        echo "$detected"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
        echo "${interfaces[$((choice-1))]}"
    else
        echo "$detected"
    fi
}

# Проверка что tc работает
check_tc_available() {
    if ! command -v tc &>/dev/null; then
        log_error "tc не установлен. Установите: apt install iproute2"
        return 1
    fi
    return 0
}

# Получить список настроенных лимитов
get_configured_limits() {
    if [[ ! -d "$TRAFFIC_CONFIG_DIR" ]]; then
        return
    fi
    
    for conf in "$TRAFFIC_CONFIG_DIR"/port-*.conf; do
        [[ -f "$conf" ]] && echo "$conf"
    done
}

# Проверить активен ли лимитер
is_limiter_active() {
    local iface=$(detect_interface)
    tc qdisc show dev "$iface" 2>/dev/null | grep -q "htb"
}

# Получить статистику по классу
get_class_stats() {
    local iface="$1"
    local class_id="$2"
    
    tc -s class show dev "$iface" 2>/dev/null | grep -A2 "class htb $class_id " | grep "Sent" | awk '{print $2}'
}

# ============================================
# ГЕНЕРАЦИЯ TC СКРИПТА (U32 Hash Mode)
# ============================================

generate_tc_script() {
    mkdir -p "$(dirname "$TRAFFIC_SCRIPT")"
    
    cat > "$TRAFFIC_SCRIPT" << 'SCRIPT'
#!/bin/bash
#
# Server Security Shield - Traffic Limiter
# U32 Hash Mode для per-IP лимитов
#
set -u

CONFIG_DIR="/opt/server-shield/config/traffic"
IFB_DEV="ifb0"
LOG_FILE="/var/log/shield-traffic.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

run_tc() {
    local out
    if ! out=$("$@" 2>&1); then
        log "ERROR: $* -> $out"
        return 1
    fi
    return 0
}

cleanup_all() {
    log "Очистка старых правил..."
    
    # Очищаем все интерфейсы
    ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$' | while read -r iface; do
        tc qdisc del dev "$iface" root 2>/dev/null
        tc qdisc del dev "$iface" ingress 2>/dev/null
    done
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null
    ip link set dev "$IFB_DEV" down 2>/dev/null
}

apply_limits() {
    log "=== Запуск Shield Traffic Limiter ==="
    
    # Загрузка модулей ядра
    modprobe ifb numifbs=1 2>/dev/null || true
    modprobe sch_htb 2>/dev/null || true
    modprobe sch_sfq 2>/dev/null || true
    modprobe cls_u32 2>/dev/null || true
    modprobe act_mirred 2>/dev/null || true
    
    # Проверка конфигов
    local configs=($(find "$CONFIG_DIR" -maxdepth 1 -name "port-*.conf" -type f 2>/dev/null | sort))
    if [[ ${#configs[@]} -eq 0 ]]; then
        log "Нет активных лимитов"
        exit 0
    fi
    
    log "Найдено конфигов: ${#configs[@]}"
    
    # Подготовка IFB
    ip link set dev "$IFB_DEV" up 2>/dev/null || true
    
    # Инициализация интерфейсов
    declare -A handled_ifaces
    for conf in "${configs[@]}"; do
        source "$conf"
        if [[ -z "${handled_ifaces[$IFACE]:-}" ]]; then
            log "Настройка интерфейса: $IFACE"
            
            # Egress (Download для клиентов)
            run_tc tc qdisc add dev "$IFACE" root handle 1: htb default 9999 || exit 1
            run_tc tc class add dev "$IFACE" parent 1: classid 1:9999 htb rate 10gbit || exit 1
            
            # Ingress -> IFB (Upload)
            run_tc tc qdisc add dev "$IFACE" handle ffff: ingress || exit 1
            run_tc tc filter add dev "$IFACE" parent ffff: protocol ip prio 1 u32 \
                match u32 0 0 action mirred egress redirect dev "$IFB_DEV" || exit 1
            
            handled_ifaces[$IFACE]=1
        fi
    done
    
    # IFB root
    if ! tc qdisc show dev "$IFB_DEV" 2>/dev/null | grep -q "htb"; then
        run_tc tc qdisc add dev "$IFB_DEV" root handle 2: htb default 9999 || exit 1
        run_tc tc class add dev "$IFB_DEV" parent 2: classid 2:9999 htb rate 10gbit || exit 1
    fi
    
    # Применение правил для каждого порта
    local PORT_IDX=1
    
    for conf in "${configs[@]}"; do
        source "$conf"
        
        local TOTAL="${TOTAL_LIMIT:-10000mbit}"
        local MAX="${MAX_USERS:-256}"
        
        # Генерация ID (математическая, безопасно до 15 портов)
        local DL_PARENT=$((0x10 * PORT_IDX))
        local DL_BASE=$((0x1000 * PORT_IDX))
        local DL_HASH=$(printf "%x" $((0x100 + PORT_IDX)))
        
        local UL_PARENT=$((0x20 * PORT_IDX))
        local UL_BASE=$((0x2000 * PORT_IDX))
        local UL_HASH=$(printf "%x" $((0x200 + PORT_IDX)))
        
        log "Порт $PORT: DL=$DOWN_LIMIT UL=$UP_LIMIT на $IFACE"
        
        # === DOWNLOAD (Egress) ===
        # Родительский класс
        run_tc tc class add dev "$IFACE" parent 1: classid "1:$(printf %x $DL_PARENT)" \
            htb rate "$TOTAL" ceil "$TOTAL" quantum 60000 || exit 1
        
        # Hash table (256 buckets)
        run_tc tc filter add dev "$IFACE" parent 1: protocol ip prio 1 \
            handle "${DL_HASH}:" u32 divisor 256 || exit 1
        
        # Фильтр: src port -> hash по dst IP
        run_tc tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 \
            match ip sport "$PORT" 0xffff \
            hashkey mask 0x000000ff at 16 \
            link "${DL_HASH}:" || exit 1
        
        # Per-IP классы
        for bucket in $(seq 0 $((MAX - 1))); do
            local CID=$((DL_BASE + bucket))
            local CLASS="1:$(printf %x $CID)"
            local BHEX=$(printf "%02x" $bucket)
            
            run_tc tc class add dev "$IFACE" parent "1:$(printf %x $DL_PARENT)" \
                classid "$CLASS" htb rate "$DOWN_LIMIT" ceil "$DOWN_LIMIT" burst 15k quantum 1500 || exit 1
            
            run_tc tc qdisc add dev "$IFACE" parent "$CLASS" sfq perturb 10 || exit 1
            
            run_tc tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 \
                ht "${DL_HASH}:${BHEX}:" match ip dst 0.0.0.0/0 flowid "$CLASS" || exit 1
        done
        
        # === UPLOAD (Ingress via IFB) ===
        run_tc tc class add dev "$IFB_DEV" parent 2: classid "2:$(printf %x $UL_PARENT)" \
            htb rate "$TOTAL" ceil "$TOTAL" quantum 60000 || exit 1
        
        run_tc tc filter add dev "$IFB_DEV" parent 2: protocol ip prio 1 \
            handle "${UL_HASH}:" u32 divisor 256 || exit 1
        
        run_tc tc filter add dev "$IFB_DEV" parent 2: protocol ip prio 1 u32 \
            match ip dport "$PORT" 0xffff \
            hashkey mask 0x000000ff at 12 \
            link "${UL_HASH}:" || exit 1
        
        for bucket in $(seq 0 $((MAX - 1))); do
            local CID=$((UL_BASE + bucket))
            local CLASS="2:$(printf %x $CID)"
            local BHEX=$(printf "%02x" $bucket)
            
            run_tc tc class add dev "$IFB_DEV" parent "2:$(printf %x $UL_PARENT)" \
                classid "$CLASS" htb rate "$UP_LIMIT" ceil "$UP_LIMIT" quantum 1500 || exit 1
            
            run_tc tc qdisc add dev "$IFB_DEV" parent "$CLASS" sfq perturb 10 || exit 1
            
            run_tc tc filter add dev "$IFB_DEV" parent 2: protocol ip prio 1 u32 \
                ht "${UL_HASH}:${BHEX}:" match ip src 0.0.0.0/0 flowid "$CLASS" || exit 1
        done
        
        PORT_IDX=$((PORT_IDX + 1))
    done
    
    log "=== Лимиты применены успешно ==="
}

show_status() {
    local configs=($(find "$CONFIG_DIR" -maxdepth 1 -name "port-*.conf" -type f 2>/dev/null))
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        echo "Нет активных лимитов"
        exit 0
    fi
    
    echo ""
    echo "=== Статус Shield Traffic Limiter ==="
    echo ""
    
    local idx=1
    for conf in "${configs[@]}"; do
        source "$conf"
        
        echo "Порт $PORT ($IFACE):"
        echo "  Download: $DOWN_LIMIT / Upload: $UP_LIMIT"
        
        local parent_class="1:$(printf %x $((0x10 * idx)))"
        local stats=$(tc -s class show dev "$IFACE" 2>/dev/null | grep -A1 "class htb $parent_class " | grep "Sent")
        
        if [[ -n "$stats" ]]; then
            local bytes=$(echo "$stats" | awk '{print $2}')
            local human=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "$bytes B")
            echo "  Трафик: $human"
        fi
        
        echo ""
        ((idx++))
    done
}

case "${1:-}" in
    start|apply)
        cleanup_all
        sleep 1
        apply_limits
        ;;
    stop|clear)
        cleanup_all
        log "Все лимиты сняты"
        ;;
    restart)
        cleanup_all
        sleep 1
        apply_limits
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
SCRIPT

    chmod +x "$TRAFFIC_SCRIPT"
}

# Создание systemd сервиса
create_systemd_service() {
    cat > "$TRAFFIC_SERVICE" << SERVICE
[Unit]
Description=Server Security Shield - Traffic Limiter
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$TRAFFIC_SCRIPT start
ExecStop=$TRAFFIC_SCRIPT stop
ExecReload=$TRAFFIC_SCRIPT restart

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
}

# ============================================
# ОСНОВНЫЕ ОПЕРАЦИИ
# ============================================

# Добавить лимит для порта
add_limit() {
    check_tc_available || return 1
    
    print_section "➕ Добавление лимита скорости"
    
    # Выбор интерфейса
    echo ""
    echo -e "${WHITE}Шаг 1: Выбор сетевого интерфейса${NC}"
    local iface=$(select_interface) || return 1
    
    # Ввод порта
    echo ""
    echo -e "${WHITE}Шаг 2: Укажите порт${NC}"
    echo -e "${CYAN}Примеры: 443 (HTTPS/VPN), 80 (HTTP), 8443${NC}"
    read -p "Порт для ограничения: " port
    
    if ! validate_port "$port"; then
        log_error "Неверный порт: $port"
        return 1
    fi
    
    # Проверка существующего лимита
    if [[ -f "$TRAFFIC_CONFIG_DIR/port-${port}.conf" ]]; then
        log_warn "Для порта $port уже есть лимит!"
        if ! confirm "Перезаписать?" "n"; then
            return 1
        fi
    fi
    
    # Лимиты
    echo ""
    echo -e "${WHITE}Шаг 3: Лимиты скорости (Мбит/с)${NC}"
    read -p "Скачивание (Download) на клиента [10]: " down_rate
    down_rate=${down_rate:-10}
    
    read -p "Загрузка (Upload) на клиента [10]: " up_rate
    up_rate=${up_rate:-10}
    
    # Общий лимит
    echo ""
    echo -e "${WHITE}Шаг 4: Общий лимит порта${NC}"
    echo -e "${CYAN}Максимум для всех клиентов вместе (0 = без лимита)${NC}"
    read -p "Общий лимит (Мбит/с) [0]: " total_rate
    total_rate=${total_rate:-0}
    
    local total_limit="10000mbit"
    if [[ "$total_rate" =~ ^[0-9]+$ ]] && [[ "$total_rate" -gt 0 ]]; then
        total_limit="${total_rate}mbit"
    fi
    
    # Подтверждение
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}Подтверждение:${NC}"
    echo -e "  Интерфейс: ${CYAN}$iface${NC}"
    echo -e "  Порт: ${CYAN}$port${NC}"
    echo -e "  Download: ${GREEN}${down_rate} Мбит/с${NC} на клиента"
    echo -e "  Upload: ${YELLOW}${up_rate} Мбит/с${NC} на клиента"
    if [[ "$total_limit" != "10000mbit" ]]; then
        echo -e "  Общий лимит: ${RED}${total_rate} Мбит/с${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! confirm "Применить?" "y"; then
        log_info "Отменено"
        return 1
    fi
    
    # Сохранение конфига
    mkdir -p "$TRAFFIC_CONFIG_DIR"
    cat > "$TRAFFIC_CONFIG_DIR/port-${port}.conf" << EOF
IFACE="$iface"
PORT="$port"
DOWN_LIMIT="${down_rate}mbit"
UP_LIMIT="${up_rate}mbit"
TOTAL_LIMIT="$total_limit"
MAX_USERS="$MAX_BUCKETS"
EOF

    # Генерация и запуск
    log_step "Генерация скрипта..."
    generate_tc_script
    
    log_step "Создание сервиса..."
    create_systemd_service
    
    log_step "Применение лимитов..."
    systemctl restart shield-traffic
    
    sleep 2
    if systemctl is-active --quiet shield-traffic; then
        log_info "Лимит для порта $port успешно применён!"
    else
        log_error "Ошибка применения. Проверьте: journalctl -u shield-traffic"
    fi
}

# Удалить лимит
remove_limit() {
    local configs=($(get_configured_limits))
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        log_warn "Нет настроенных лимитов"
        return 1
    fi
    
    print_section "➖ Удаление лимита"
    
    echo ""
    echo -e "${WHITE}Настроенные лимиты:${NC}"
    local i=1
    for conf in "${configs[@]}"; do
        source "$conf"
        echo -e "  ${WHITE}$i)${NC} Порт ${CYAN}$PORT${NC} — $DOWN_LIMIT↓ / $UP_LIMIT↑ на ${CYAN}$IFACE${NC}"
        ((i++))
    done
    echo -e "  ${WHITE}a)${NC} ${RED}Удалить ВСЕ${NC}"
    echo ""
    
    read -p "Выбор: " choice
    
    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        if confirm "Удалить ВСЕ лимиты?" "n"; then
            rm -rf "$TRAFFIC_CONFIG_DIR"
            systemctl stop shield-traffic 2>/dev/null
            "$TRAFFIC_SCRIPT" stop 2>/dev/null
            log_info "Все лимиты удалены"
        fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#configs[@]} ]]; then
        local conf="${configs[$((choice-1))]}"
        source "$conf"
        
        if confirm "Удалить лимит для порта $PORT?" "n"; then
            rm -f "$conf"
            systemctl restart shield-traffic 2>/dev/null
            log_info "Лимит для порта $PORT удалён"
        fi
    else
        log_error "Неверный выбор"
    fi
}

# Показать статус
show_status() {
    print_section "📊 Статус ограничения трафика"
    
    echo ""
    
    # Проверка сервиса
    if systemctl is-active --quiet shield-traffic 2>/dev/null; then
        echo -e "  Сервис: ${GREEN}● Активен${NC}"
    else
        echo -e "  Сервис: ${RED}○ Не активен${NC}"
    fi
    
    # Автозапуск
    if systemctl is-enabled --quiet shield-traffic 2>/dev/null; then
        echo -e "  Автозапуск: ${GREEN}Включен${NC}"
    else
        echo -e "  Автозапуск: ${YELLOW}Выключен${NC}"
    fi
    
    echo ""
    
    # Лимиты
    local configs=($(get_configured_limits))
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}Нет настроенных лимитов${NC}"
        return
    fi
    
    echo -e "${WHITE}Активные лимиты:${NC}"
    echo ""
    
    local idx=1
    for conf in "${configs[@]}"; do
        source "$conf"
        
        echo -e "  ${CYAN}▸${NC} Порт ${YELLOW}$PORT${NC} на ${CYAN}$IFACE${NC}"
        echo -e "    Download: ${GREEN}$DOWN_LIMIT${NC} | Upload: ${YELLOW}$UP_LIMIT${NC}"
        
        if [[ "${TOTAL_LIMIT:-10000mbit}" != "10000mbit" ]]; then
            echo -e "    Общий лимит: ${RED}$TOTAL_LIMIT${NC}"
        fi
        
        # Статистика если активен
        if is_limiter_active; then
            local parent_class="1:$(printf %x $((0x10 * idx)))"
            local bytes=$(get_class_stats "$IFACE" "$parent_class")
            
            if [[ -n "$bytes" ]] && [[ "$bytes" -gt 0 ]]; then
                local human=$(numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "$bytes B")
                echo -e "    Передано: ${PURPLE}$human${NC}"
            fi
        fi
        
        echo ""
        ((idx++))
    done
}

# Просмотр логов
show_logs() {
    print_section "📜 Логи"
    
    if [[ -f "$TRAFFIC_LOG" ]]; then
        echo ""
        tail -30 "$TRAFFIC_LOG"
    else
        log_warn "Лог файл не найден"
    fi
    
    echo ""
    echo -e "${WHITE}Журнал systemd:${NC}"
    journalctl -u shield-traffic --no-pager -n 20 2>/dev/null
}

# Перезапуск
restart_limiter() {
    log_step "Перезапуск..."
    
    generate_tc_script
    systemctl restart shield-traffic
    
    sleep 2
    if systemctl is-active --quiet shield-traffic; then
        log_info "Перезапущено успешно"
    else
        log_error "Ошибка перезапуска"
    fi
}

# Включить/выключить автозапуск
toggle_autostart() {
    if systemctl is-enabled --quiet shield-traffic 2>/dev/null; then
        systemctl disable shield-traffic
        log_info "Автозапуск выключен"
    else
        create_systemd_service
        systemctl enable shield-traffic
        log_info "Автозапуск включен"
    fi
}

# ============================================
# МЕНЮ
# ============================================

traffic_menu() {
    while true; do
        print_header
        print_section "🚦 Ограничение скорости клиентов"
        
        echo ""
        echo -e "${WHITE}Персональный лимит скорости для каждого клиента на порту.${NC}"
        echo ""
        
        # Быстрый статус
        local configs=($(get_configured_limits))
        local is_active=$(is_limiter_active && echo "true" || echo "false")
        
        if [[ "$is_active" == "true" ]] && [[ ${#configs[@]} -gt 0 ]]; then
            echo -e "  ${GREEN}●${NC} Статус: ${GREEN}Активен${NC} (${#configs[@]} портов)"
        elif [[ ${#configs[@]} -gt 0 ]]; then
            echo -e "  ${YELLOW}○${NC} Статус: ${YELLOW}Настроен, не запущен${NC}"
        else
            echo -e "  ${RED}○${NC} Статус: ${RED}Не настроен${NC}"
        fi
        
        # Список портов
        if [[ ${#configs[@]} -gt 0 ]]; then
            for conf in "${configs[@]}"; do
                source "$conf"
                echo -e "    └─ Порт ${CYAN}$PORT${NC}: ${GREEN}$DOWN_LIMIT${NC}↓ / ${YELLOW}$UP_LIMIT${NC}↑"
            done
        fi
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} 📊 Подробный статус"
        echo -e "  ${WHITE}2)${NC} ➕ Добавить лимит для порта"
        echo -e "  ${WHITE}3)${NC} ➖ Удалить лимит"
        echo -e "  ${WHITE}4)${NC} 🔄 Перезапустить"
        echo -e "  ${WHITE}5)${NC} 📜 Просмотр логов"
        echo ""
        
        if systemctl is-enabled --quiet shield-traffic 2>/dev/null; then
            echo -e "  ${WHITE}6)${NC} ❌ Выключить автозапуск"
        else
            echo -e "  ${WHITE}6)${NC} ✅ Включить автозапуск"
        fi
        
        if [[ "$is_active" == "true" ]]; then
            echo -e "  ${WHITE}7)${NC} 🛑 Остановить"
        else
            echo -e "  ${WHITE}7)${NC} ▶️  Запустить"
        fi
        
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        
        read -p "Выберите действие: " choice
        
        case $choice in
            1) show_status ;;
            2) add_limit ;;
            3) remove_limit ;;
            4) restart_limiter ;;
            5) show_logs ;;
            6) toggle_autostart ;;
            7)
                if [[ "$is_active" == "true" ]]; then
                    systemctl stop shield-traffic
                    "$TRAFFIC_SCRIPT" stop 2>/dev/null
                    log_info "Остановлено"
                else
                    generate_tc_script
                    create_systemd_service
                    systemctl start shield-traffic
                    log_info "Запущено"
                fi
                ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Статус для главного меню
get_traffic_status_line() {
    local configs=($(get_configured_limits))
    
    if is_limiter_active && [[ ${#configs[@]} -gt 0 ]]; then
        echo -e "${GREEN}●${NC} ${#configs[@]} портов"
    elif [[ ${#configs[@]} -gt 0 ]]; then
        echo -e "${YELLOW}○${NC} Настроен"
    else
        echo -e "${RED}○${NC} Выкл"
    fi
}
