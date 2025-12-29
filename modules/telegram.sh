#!/bin/bash
#
# telegram.sh - Telegram уведомления с поддержкой групп и тем
#

source "$(dirname "$0")/utils.sh" 2>/dev/null || source "/opt/server-shield/modules/utils.sh"

# ============================================
# РАБОТА С КОНФИГОМ
# ============================================

# Получаем настройки Telegram
get_tg_config() {
    TG_TOKEN=$(get_config "TG_TOKEN" "")
    TG_CHAT_ID=$(get_config "TG_CHAT_ID" "")
    TG_THREAD_ID=$(get_config "TG_THREAD_ID" "")
    TG_CHAT_TYPE=$(get_config "TG_CHAT_TYPE" "private")  # private, group, supergroup
}

# ============================================
# ОТПРАВКА СООБЩЕНИЙ
# ============================================

# Универсальная функция отправки с поддержкой групп и тем
send_telegram() {
    local message="$1"
    
    get_tg_config
    
    if [[ -z "$TG_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
        return 1
    fi
    
    # Формируем параметры
    local params="-d chat_id=${TG_CHAT_ID}"
    params="$params -d text=${message}"
    params="$params -d parse_mode=HTML"
    
    # Добавляем thread_id если указан (для тем в группах)
    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
        params="$params -d message_thread_id=${TG_THREAD_ID}"
    fi
    
    # Отправляем
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" $params 2>&1)
    
    # Проверяем успех
    if echo "$response" | grep -q '"ok":true'; then
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | $response" >> /opt/server-shield/logs/telegram_errors.log 2>/dev/null
        return 1
    fi
}

# Отправка напрямую с параметрами (для скриптов)
send_telegram_direct() {
    local token="$1"
    local chat_id="$2"
    local thread_id="$3"
    local message="$4"
    
    local params="-d chat_id=${chat_id}"
    params="$params --data-urlencode text=${message}"
    
    if [[ -n "$thread_id" ]] && [[ "$thread_id" != "0" ]]; then
        params="$params -d message_thread_id=${thread_id}"
    fi
    
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" $params 2>&1
}

# ============================================
# ТИПЫ УВЕДОМЛЕНИЙ
# ============================================

# Уведомление о SSH входе
send_ssh_login() {
    local user="$1"
    local ip="$2"
    local server_name=$(get_server_name 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🔓 SSH Login

Сервер: ${server_name}
IP сервера: ${server_ip}
Пользователь: ${user}
IP клиента: ${ip}
Время: ${date}"
    
    send_telegram "$message"
}

# Уведомление о бане Fail2Ban
send_ban() {
    local ip="$1"
    local jail="$2"
    local bantime="$3"
    local server_name=$(get_server_name 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🚫 Fail2Ban: IP Забанен

Сервер: ${server_name}
IP сервера: ${server_ip}
Забанен IP: ${ip}
Jail: ${jail}
Время бана: ${bantime}
Дата: ${date}"
    
    send_telegram "$message"
}

# Уведомление о разбане
send_unban() {
    local ip="$1"
    local jail="$2"
    local server_name=$(get_server_name 2>/dev/null || hostname)
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="✅ Fail2Ban: IP Разбанен

Сервер: ${server_name}
IP: ${ip}
Jail: ${jail}
Дата: ${date}"
    
    send_telegram "$message"
}

# Уведомление об установке защиты
send_install_complete() {
    local server_name=$(get_server_name 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local ssh_port=$(get_config "SSH_PORT" "22")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="🛡️ Server Shield Установлен!

Сервер: ${server_name}
IP: ${server_ip}
SSH порт: ${ssh_port}

✅ SSH Hardening
✅ Kernel Hardening
✅ UFW Firewall
✅ Fail2Ban
✅ Telegram уведомления

Дата: ${date}"
    
    send_telegram "$message"
}

# Уведомление о rootkit
send_rootkit_alert() {
    local warning="$1"
    local server_name=$(get_server_name 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    local message="⚠️ Rootkit Alert!

Сервер: ${server_name}
IP: ${server_ip}
Предупреждение:
${warning}

Дата: ${date}

⚠️ Требуется проверка!"
    
    send_telegram "$message"
}

# ============================================
# ТЕСТИРОВАНИЕ
# ============================================

# Тестовое сообщение
send_test() {
    local server_name=$(get_server_name 2>/dev/null || hostname)
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    
    get_tg_config
    
    local message="🧪 Тестовое сообщение

Сервер: ${server_name}
IP: ${server_ip}
Дата: ${date}

✅ Telegram уведомления работают!"
    
    echo ""
    log_step "Отправка тестового сообщения..."
    echo -e "   Token: ${TG_TOKEN:0:10}..."
    echo -e "   Chat ID: ${TG_CHAT_ID}"
    
    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
        echo -e "   Thread ID: ${TG_THREAD_ID} (тема в группе)"
    fi
    
    echo ""
    
    # Формируем параметры
    local params="-d chat_id=${TG_CHAT_ID}"
    params="$params --data-urlencode text=${message}"
    
    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
        params="$params -d message_thread_id=${TG_THREAD_ID}"
    fi
    
    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" $params 2>&1)
    
    if echo "$response" | grep -q '"ok":true'; then
        log_info "Сообщение успешно отправлено!"
        return 0
    else
        log_error "Ошибка отправки!"
        echo ""
        echo -e "${RED}Ответ Telegram API:${NC}"
        echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        echo ""
        
        # Анализируем ошибку
        if echo "$response" | grep -q "chat not found"; then
            echo -e "${YELLOW}Ошибка: Чат не найден${NC}"
            echo "  • Для личного чата: напишите боту /start"
            echo "  • Для группы: добавьте бота в группу"
        elif echo "$response" | grep -q "bot was kicked"; then
            echo -e "${YELLOW}Ошибка: Бот удалён из чата${NC}"
            echo "  • Добавьте бота обратно в группу"
        elif echo "$response" | grep -q "THREAD_ID_INVALID\|message thread not found"; then
            echo -e "${YELLOW}Ошибка: Неверный ID темы${NC}"
            echo "  • Проверьте что тема существует"
            echo "  • Перешлите сообщение из темы боту @getmyid_bot чтобы узнать ID"
        elif echo "$response" | grep -q "have no rights"; then
            echo -e "${YELLOW}Ошибка: Нет прав на отправку${NC}"
            echo "  • Дайте боту права на отправку сообщений в группе"
        fi
        
        return 1
    fi
}

# ============================================
# НАСТРОЙКА SSH LOGIN
# ============================================

setup_ssh_login_notify() {
    log_step "Настройка SSH Login уведомлений..."
    
    get_tg_config
    
    # Формируем команду curl
    local curl_cmd="curl -s -X POST \"https://api.telegram.org/bot${TG_TOKEN}/sendMessage\" -d \"chat_id=${TG_CHAT_ID}\""
    
    # Добавляем thread_id если указан
    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
        curl_cmd="$curl_cmd -d \"message_thread_id=${TG_THREAD_ID}\""
    fi
    
    # Создаём скрипт для PAM
    cat > /etc/ssh/notify-login.sh << SCRIPT
#!/bin/bash
if [ "\$PAM_TYPE" = "open_session" ]; then
    $curl_cmd --data-urlencode "text=🔓 SSH Login

Сервер: \$(hostname)
Пользователь: \$PAM_USER
IP: \$PAM_RHOST
Время: \$(date '+%Y-%m-%d %H:%M:%S')" > /dev/null 2>&1
fi
SCRIPT
    
    chmod +x /etc/ssh/notify-login.sh
    
    # Добавляем в PAM
    if ! grep -q "notify-login.sh" /etc/pam.d/sshd 2>/dev/null; then
        echo "session optional pam_exec.so /etc/ssh/notify-login.sh" >> /etc/pam.d/sshd
    fi
    
    log_info "SSH Login уведомления настроены"
}

# ============================================
# ОПРЕДЕЛЕНИЕ ТИПА ЧАТА
# ============================================

# Определить тип чата по ID
detect_chat_type() {
    local chat_id="$1"
    
    # Группы и супергруппы имеют отрицательный ID
    if [[ "$chat_id" =~ ^-100 ]]; then
        echo "supergroup"
    elif [[ "$chat_id" =~ ^- ]]; then
        echo "group"
    else
        echo "private"
    fi
}

# Получить информацию о чате
get_chat_info() {
    local token="$1"
    local chat_id="$2"
    
    curl -s "https://api.telegram.org/bot${token}/getChat?chat_id=${chat_id}" 2>&1
}

# Проверить есть ли темы в группе
check_forum_topics() {
    local token="$1"
    local chat_id="$2"
    
    local info=$(get_chat_info "$token" "$chat_id")
    
    if echo "$info" | grep -q '"is_forum":true'; then
        echo "yes"
    else
        echo "no"
    fi
}

# ============================================
# МЕНЮ
# ============================================

telegram_menu() {
    while true; do
        print_header
        print_section "📱 Telegram Уведомления"
        
        get_tg_config
        local server_name=$(get_server_name 2>/dev/null || hostname)
        local custom_name=$(get_config "SERVER_NAME" "")
        
        echo ""
        if [[ -n "$TG_TOKEN" ]] && [[ -n "$TG_CHAT_ID" ]]; then
            echo -e "  ${GREEN}✓${NC} Telegram настроен"
            
            local chat_type=$(detect_chat_type "$TG_CHAT_ID")
            case "$chat_type" in
                "private")
                    echo -e "    Тип: ${CYAN}Личный чат${NC}"
                    ;;
                "group")
                    echo -e "    Тип: ${CYAN}Группа${NC}"
                    ;;
                "supergroup")
                    echo -e "    Тип: ${CYAN}Супергруппа${NC}"
                    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
                        echo -e "    Тема ID: ${CYAN}$TG_THREAD_ID${NC}"
                    fi
                    ;;
            esac
            
            echo -e "    Chat ID: ${CYAN}$TG_CHAT_ID${NC}"
        else
            echo -e "  ${YELLOW}○${NC} Telegram не настроен"
        fi
        
        # Имя сервера
        echo ""
        if [[ -n "$custom_name" ]]; then
            echo -e "  📛 Имя сервера: ${CYAN}$server_name${NC}"
        else
            echo -e "  📛 Имя сервера: ${YELLOW}$server_name${NC} (hostname)"
        fi
        
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${WHITE}1)${NC} 👤 Настроить (личный чат)"
        echo -e "  ${WHITE}2)${NC} 👥 Настроить (группа)"
        echo -e "  ${WHITE}3)${NC} 💬 Настроить (группа с темой)"
        echo ""
        echo -e "  ${WHITE}4)${NC} 🧪 Отправить тестовое сообщение"
        echo -e "  ${WHITE}5)${NC} 🔄 Переинициализировать (после смены настроек)"
        echo -e "  ${WHITE}6)${NC} 📛 Изменить имя сервера"
        echo -e "  ${WHITE}7)${NC} ❌ Отключить Telegram"
        echo -e "  ${WHITE}0)${NC} Назад"
        echo ""
        read -p "Выберите действие: " choice
        
        case $choice in
            1) setup_private_chat ;;
            2) setup_group_chat ;;
            3) setup_group_with_topic ;;
            4) send_test ;;
            5) reinit_all_telegram ;;
            6) change_server_name ;;
            7) disable_telegram ;;
            0) return ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        press_any_key
    done
}

# Изменить имя сервера
change_server_name() {
    echo ""
    local current_name=$(get_server_name)
    local custom_name=$(get_config "SERVER_NAME" "")
    
    echo -e "${WHITE}Текущее имя сервера:${NC} ${CYAN}$current_name${NC}"
    if [[ -z "$custom_name" ]]; then
        echo -e "${YELLOW}(используется hostname)${NC}"
    fi
    echo ""
    echo -e "${WHITE}Введите новое имя для алертов:${NC}"
    echo -e "${CYAN}Примеры: USA-Node-1, NL-Panel, DE-VPN${NC}"
    echo -e "${YELLOW}Оставьте пустым для сброса на hostname${NC}"
    echo ""
    read -p "Имя сервера: " new_name
    
    if [[ -n "$new_name" ]]; then
        save_config "SERVER_NAME" "$new_name"
        log_info "Имя сервера установлено: $new_name"
    else
        save_config "SERVER_NAME" ""
        log_info "Имя сброшено на hostname: $(hostname)"
    fi
}

# Настройка личного чата
setup_private_chat() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}👤 НАСТРОЙКА ЛИЧНОГО ЧАТА${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${WHITE}Шаг 1: Получите токен бота${NC}"
    echo "  1. Откройте @BotFather в Telegram"
    echo "  2. Отправьте /newbot или используйте существующего"
    echo "  3. Скопируйте токен"
    echo ""
    read -p "Bot Token: " token
    
    if [[ -z "$token" ]]; then
        log_error "Токен не указан"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Шаг 2: Узнайте ваш Telegram ID${NC}"
    echo "  1. Напишите боту @userinfobot или @getmyid_bot"
    echo "  2. Он покажет ваш ID (просто число, напр. ${CYAN}123456789${NC})"
    echo ""
    echo -e "  ${YELLOW}⚠️  Не забудьте написать /start вашему боту!${NC}"
    echo ""
    read -p "Ваш Telegram ID: " chat_id
    
    if [[ -z "$chat_id" ]]; then
        log_error "ID не указан"
        return 1
    fi
    
    # Сохраняем
    save_config "TG_TOKEN" "$token"
    save_config "TG_CHAT_ID" "$chat_id"
    save_config "TG_THREAD_ID" ""
    save_config "TG_CHAT_TYPE" "private"
    
    # Тестируем
    TG_TOKEN="$token"
    TG_CHAT_ID="$chat_id"
    TG_THREAD_ID=""
    
    if send_test; then
        setup_ssh_login_notify
        reinit_fail2ban_telegram
        log_info "Личный чат настроен!"
    else
        log_warn "Настройки сохранены, но тест не прошёл"
    fi
}

# Настройка группы
setup_group_chat() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}👥 НАСТРОЙКА ГРУППЫ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${WHITE}Шаг 1: Получите токен бота${NC}"
    echo "  Используйте @BotFather для создания/получения токена"
    echo ""
    read -p "Bot Token: " token
    
    if [[ -z "$token" ]]; then
        log_error "Токен не указан"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Шаг 2: Добавьте бота в группу${NC}"
    echo "  1. Откройте вашу группу"
    echo "  2. Добавьте бота как участника"
    echo "  3. ${YELLOW}Дайте боту права на отправку сообщений!${NC}"
    echo ""
    
    echo -e "${WHITE}Шаг 3: Узнайте ID группы${NC}"
    echo "  Способ 1: Добавьте @getmyid_bot в группу"
    echo "  Способ 2: Перешлите сообщение из группы боту @getmyid_bot"
    echo ""
    echo -e "  ${CYAN}ID группы начинается с минуса, напр: -1001234567890${NC}"
    echo ""
    read -p "ID группы: " chat_id
    
    if [[ -z "$chat_id" ]]; then
        log_error "ID не указан"
        return 1
    fi
    
    # Проверяем что это группа
    if [[ ! "$chat_id" =~ ^- ]]; then
        log_warn "ID группы должен начинаться с минуса (-)"
        read -p "Продолжить? (y/N): " cont
        [[ ! "$cont" =~ ^[Yy]$ ]] && return 1
    fi
    
    # Сохраняем
    save_config "TG_TOKEN" "$token"
    save_config "TG_CHAT_ID" "$chat_id"
    save_config "TG_THREAD_ID" ""
    save_config "TG_CHAT_TYPE" "group"
    
    # Тестируем
    TG_TOKEN="$token"
    TG_CHAT_ID="$chat_id"
    TG_THREAD_ID=""
    
    if send_test; then
        setup_ssh_login_notify
        reinit_fail2ban_telegram
        log_info "Группа настроена!"
    else
        log_warn "Настройки сохранены, но тест не прошёл"
    fi
}

# Настройка группы с темой
setup_group_with_topic() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}💬 НАСТРОЙКА ГРУППЫ С ТЕМОЙ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${WHITE}Шаг 1: Получите токен бота${NC}"
    read -p "Bot Token: " token
    
    if [[ -z "$token" ]]; then
        log_error "Токен не указан"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Шаг 2: Добавьте бота в группу${NC}"
    echo "  1. Откройте группу с темами (Topics)"
    echo "  2. Добавьте бота"
    echo "  3. ${YELLOW}Дайте права на отправку в нужную тему!${NC}"
    echo ""
    
    echo -e "${WHITE}Шаг 3: Узнайте ID группы${NC}"
    echo -e "  ${CYAN}ID супергруппы начинается с -100, напр: -1001234567890${NC}"
    echo ""
    read -p "ID группы: " chat_id
    
    if [[ -z "$chat_id" ]]; then
        log_error "ID не указан"
        return 1
    fi
    
    echo ""
    echo -e "${WHITE}Шаг 4: Узнайте ID темы (topic)${NC}"
    echo "  1. Откройте нужную тему в группе"
    echo "  2. Перешлите любое сообщение из этой темы боту @getmyid_bot"
    echo "  3. Бот покажет 'Topic Id:' — это и есть ID темы"
    echo ""
    echo -e "  ${CYAN}ID темы — это число, напр: 123 или 456${NC}"
    echo -e "  ${YELLOW}Для General темы ID = 1${NC}"
    echo ""
    read -p "ID темы (Thread ID): " thread_id
    
    if [[ -z "$thread_id" ]]; then
        log_warn "ID темы не указан — сообщения пойдут в General"
        thread_id="0"
    fi
    
    # Сохраняем
    save_config "TG_TOKEN" "$token"
    save_config "TG_CHAT_ID" "$chat_id"
    save_config "TG_THREAD_ID" "$thread_id"
    save_config "TG_CHAT_TYPE" "supergroup"
    
    # Тестируем
    TG_TOKEN="$token"
    TG_CHAT_ID="$chat_id"
    TG_THREAD_ID="$thread_id"
    
    if send_test; then
        setup_ssh_login_notify
        reinit_fail2ban_telegram
        log_info "Группа с темой настроена!"
    else
        log_warn "Настройки сохранены, но тест не прошёл"
    fi
}

# Переинициализация Fail2Ban Telegram
reinit_fail2ban_telegram() {
    # Проверяем есть ли функция из fail2ban.sh
    if type create_telegram_action &>/dev/null; then
        get_tg_config
        create_telegram_action "$TG_TOKEN" "$TG_CHAT_ID"
        
        # Обновляем скрипт fail2ban-notify-all.sh с поддержкой thread_id
        update_fail2ban_notify_script
        
        systemctl restart fail2ban 2>/dev/null || service fail2ban restart 2>/dev/null
        log_info "Fail2Ban уведомления обновлены"
    fi
}

# Обновить скрипт fail2ban с поддержкой thread_id
update_fail2ban_notify_script() {
    get_tg_config
    
    local thread_param=""
    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
        thread_param="-d message_thread_id=$TG_THREAD_ID"
    fi
    
    mkdir -p /opt/server-shield/scripts
    mkdir -p /opt/server-shield/logs
    
    cat > /opt/server-shield/scripts/fail2ban-notify-all.sh << SCRIPT
#!/bin/bash
# Fail2Ban Telegram Notify - All Jails
# С поддержкой групп и тем

TOKEN="$TG_TOKEN"
CHAT_ID="$TG_CHAT_ID"
THREAD_ID="$TG_THREAD_ID"

# Логируем вызов
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Called with: \$1 \$2 \$3" >> /opt/server-shield/logs/fail2ban-debug.log

# Проверяем режим уведомлений
MODE=\$(grep "^F2B_NOTIFY_MODE=" /opt/server-shield/config/shield.conf 2>/dev/null | cut -d'=' -f2)
MODE=\${MODE:-instant}

if [[ "\$MODE" == "off" ]]; then
    exit 0
fi

if [[ "\$MODE" != "instant" ]]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1 | \$2 | \$3" >> /opt/server-shield/logs/fail2ban-bans.log
    exit 0
fi

JAIL="\$1"
IP="\$2"
ACTION="\$3"
HOSTNAME=\$(hostname)
DATE=\$(date '+%Y-%m-%d %H:%M:%S')

case "\$JAIL" in
    "sshd"|"ssh") EMOJI="🔐"; DESC="SSH брутфорс" ;;
    "portscan") EMOJI="🔍"; DESC="Сканирование портов" ;;
    "nginx-auth") EMOJI="🌐"; DESC="Nginx брутфорс" ;;
    "nginx-bots") EMOJI="🤖"; DESC="Nginx сканер/бот" ;;
    "mysql") EMOJI="🗄️"; DESC="MySQL брутфорс" ;;
    *) EMOJI="🚫"; DESC="\$JAIL" ;;
esac

MESSAGE="\$EMOJI Fail2Ban: Бан

Сервер: \$HOSTNAME
Причина: \$DESC
IP: \$IP
Время: \$DATE"

# Формируем параметры
PARAMS="-d chat_id=\$CHAT_ID"
PARAMS="\$PARAMS --data-urlencode text=\$MESSAGE"

if [[ -n "\$THREAD_ID" ]] && [[ "\$THREAD_ID" != "0" ]]; then
    PARAMS="\$PARAMS -d message_thread_id=\$THREAD_ID"
fi

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \$PARAMS > /dev/null 2>&1
SCRIPT

    chmod +x /opt/server-shield/scripts/fail2ban-notify-all.sh
}

# Переинициализация всего
reinit_all_telegram() {
    log_step "Переинициализация Telegram..."
    
    get_tg_config
    
    if [[ -z "$TG_TOKEN" ]] || [[ -z "$TG_CHAT_ID" ]]; then
        log_error "Telegram не настроен!"
        return 1
    fi
    
    setup_ssh_login_notify
    update_fail2ban_notify_script
    reinit_fail2ban_telegram
    
    log_info "Telegram переинициализирован"
    echo ""
    echo -e "  Token: ${CYAN}${TG_TOKEN:0:10}...${NC}"
    echo -e "  Chat ID: ${CYAN}$TG_CHAT_ID${NC}"
    if [[ -n "$TG_THREAD_ID" ]] && [[ "$TG_THREAD_ID" != "0" ]]; then
        echo -e "  Thread ID: ${CYAN}$TG_THREAD_ID${NC}"
    fi
}

# Отключение Telegram
disable_telegram() {
    save_config "TG_TOKEN" ""
    save_config "TG_CHAT_ID" ""
    save_config "TG_THREAD_ID" ""
    save_config "TG_CHAT_TYPE" ""
    
    rm -f /etc/ssh/notify-login.sh
    sed -i '/notify-login.sh/d' /etc/pam.d/sshd 2>/dev/null
    
    log_info "Telegram отключен"
}

# ============================================
# CLI
# ============================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    action="$1"
    shift
    
    case "$action" in
        send_ssh_login) send_ssh_login "$@" ;;
        send_ban) send_ban "$@" ;;
        send_unban) send_unban "$@" ;;
        send_test) send_test ;;
        *) telegram_menu ;;
    esac
fi
