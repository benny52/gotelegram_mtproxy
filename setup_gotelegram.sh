#!/usr/bin/env bash

set -u

# --- ОСНОВНАЯ КОНФИГУРАЦИЯ ---
APP_NAME="gotelegram"
APP_PATH="/usr/local/bin/gotelegram"
CONFIG_DIR="/etc/gotelegram"
CONFIG_FILE="${CONFIG_DIR}/mtproxy.env"
CONTAINER_NAME="mtproto-proxy"
IMAGE_NAME="nineseconds/mtg:2"

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---
print_ok()   { echo -e "${GREEN}●${NC} $1"; }
print_bad()  { echo -e "${RED}●${NC} $1"; }
print_warn() { echo -e "${YELLOW}●${NC} $1"; }
print_info() { echo -e "${CYAN}$1${NC}"; }
print_line() { echo -e "${BLUE}============================================================${NC}"; }

# --- СИСТЕМНЫЕ ПРОВЕРКИ ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: запустите скрипт от root.${NC}"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_dirs() {
    mkdir -p "${CONFIG_DIR}"
}

install_self() {
    if [ -f "$0" ] && [ "$0" != "${APP_PATH}" ]; then
        cp "$0" "${APP_PATH}"
        chmod +x "${APP_PATH}"
    fi
}

ensure_docker() {
    if ! command_exists docker; then
        echo -e "${RED}Docker не найден.${NC}"
        echo -e "${YELLOW}Установите Docker отдельно и запустите скрипт снова.${NC}"
        exit 1
    fi

    if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}Docker установлен, но сервис не запущен. Пытаюсь запустить...${NC}"
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi

    if ! systemctl is-active --quiet docker; then
        echo -e "${RED}Сервис Docker не запущен.${NC}"
        exit 1
    fi
}

ensure_qrencode() {
    if ! command_exists qrencode; then
        echo -e "${YELLOW}Пакет qrencode не найден. Устанавливаю...${NC}"
        if command_exists apt-get; then
            apt-get update && apt-get install -y qrencode
        elif command_exists dnf; then
            dnf install -y qrencode
        elif command_exists yum; then
            yum install -y qrencode
        else
            echo -e "${YELLOW}Не удалось автоматически установить qrencode. Продолжаю без QR.${NC}"
        fi
    fi
}

# --- РАБОТА С КОНФИГОМ ---
load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}"
    else
        DOMAIN=""
        PORT=""
        SECRET=""
    fi
}

save_config() {
    cat > "${CONFIG_FILE}" <<EOF
DOMAIN="${DOMAIN}"
PORT="${PORT}"
SECRET="${SECRET}"
EOF
    chmod 600 "${CONFIG_FILE}"
}

# --- СЕТЕВЫЕ ФУНКЦИИ ---
get_ip() {
    local ip
    ip="$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "${ip}" ]; then
        ip="$(curl -s -4 --max-time 5 https://icanhazip.com 2>/dev/null || true)"
    fi
    if [ -z "${ip}" ]; then
        ip="$(curl -s -4 --max-time 5 https://ifconfig.io 2>/dev/null || true)"
    fi

    echo "${ip}" | grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1
}

port_is_busy() {
    local port="$1"
    ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$"
}

port_owner() {
    local port="$1"
    ss -tulnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" || true
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

port_status_label() {
    local port="$1"
    if port_is_busy "${port}"; then
        echo -e "${RED}занят${NC}"
    else
        echo -e "${GREEN}свободен${NC}"
    fi
}

# --- DOCKER / CONTAINER ---
container_exists() {
    docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"
}

container_running() {
    docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"
}

get_container_port() {
    docker inspect "${CONTAINER_NAME}" --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' 2>/dev/null | head -n1
}

generate_secret() {
    local domain="$1"
    docker pull "${IMAGE_NAME}" >/dev/null
    docker run --rm "${IMAGE_NAME}" generate-secret --hex "${domain}"
}

# --- QR / ССЫЛКИ ---
show_qr() {
    local text="$1"
    if command_exists qrencode; then
        qrencode -t ANSIUTF8 "$text"
    else
        echo -e "${YELLOW}qrencode не установлен, QR не показан.${NC}"
    fi
}

show_config() {
    load_config

    if ! container_exists; then
        echo -e "${RED}Прокси не найден!${NC}"
        return
    fi

    local ip port link
    ip="$(get_ip)"
    port="${PORT}"

    if [ -z "${port}" ]; then
        port="$(get_container_port)"
    fi

    if [ -z "${SECRET}" ] || [ -z "${port}" ]; then
        echo -e "${RED}Не удалось прочитать параметры подключения.${NC}"
        return
    fi

    link="tg://proxy?server=${ip}&port=${port}&secret=${SECRET}"

    echo -e "\n${GREEN}=== ПАНЕЛЬ ДАННЫХ ===${NC}"
    echo -e "IP: ${ip} | Port: ${port}"
    echo -e "Domain: ${DOMAIN}"
    echo -e "Secret: ${SECRET}"
    echo -e "Link: ${BLUE}${link}${NC}"
    show_qr "${link}"
}

# --- СТАТУС ---
show_status() {
    load_config

    local public_ip
    public_ip="$(get_ip)"

    print_line
    echo -e "${WHITE}GoTelegram MTProxy Status${NC}"
    print_line
    echo -e "Host:      $(hostname -f 2>/dev/null || hostname)"
    echo -e "Public IP: ${public_ip:-unknown}"
    echo -e "Domain:    ${DOMAIN:-not set}"
    echo -e "Port:      ${PORT:-not set}"
    print_line

    if systemctl is-active --quiet docker; then
        print_ok "Docker service"
    else
        print_bad "Docker service"
    fi

    if container_exists; then
        print_ok "Container exists: ${CONTAINER_NAME}"
    else
        print_bad "Container exists: ${CONTAINER_NAME}"
    fi

    if container_running; then
        print_ok "Container running: ${CONTAINER_NAME}"
    else
        print_bad "Container running: ${CONTAINER_NAME}"
    fi

    if [ -n "${PORT:-}" ]; then
        if port_is_busy "${PORT}"; then
            print_ok "Local port ${PORT} is listening"
        else
            print_bad "Local port ${PORT} is not listening"
        fi
    else
        print_warn "Port not saved in config"
    fi

    if [ -n "${DOMAIN:-}" ]; then
        if getent ahostsv4 "${DOMAIN}" >/dev/null 2>&1; then
            print_ok "DNS resolves ${DOMAIN}"
        else
            print_bad "DNS resolves ${DOMAIN}"
        fi
    else
        print_warn "Domain not saved in config"
    fi

    print_line
}

# --- ВЫБОР ДОМЕНА ---
choose_domain() {
    local domains domain_choice custom_domain

    echo -e "${CYAN}--- Выберите домен для маскировки (Fake TLS) ---${NC}"

    domains=(
        "google.com"
        "wikipedia.org"
        "habr.com"
        "github.com"
        "coursera.org"
        "udemy.com"
        "medium.com"
        "bbc.com"
        "cnn.com"
        "reuters.com"
        "nytimes.com"
        "lenta.ru"
        "rbc.ru"
        "ria.ru"
        "kommersant.ru"
        "stepik.org"
        "duolingo.com"
        "khanacademy.org"
        "ted.com"
        "max.ru"
    )

    for i in "${!domains[@]}"; do
        printf "${YELLOW}%2d)${NC} %-20s " "$((i+1))" "${domains[$i]}"
        [[ $(( (i+1) % 2 )) -eq 0 ]] && echo ""
    done
    echo ""

    read -r -p "Ваш выбор [1-20]: " domain_choice

    case "${domain_choice}" in
        1) DOMAIN="${domains[0]}" ;;
        2) DOMAIN="${domains[1]}" ;;
        3) DOMAIN="${domains[2]}" ;;
        4) DOMAIN="${domains[3]}" ;;
        5) DOMAIN="${domains[4]}" ;;
        6) DOMAIN="${domains[5]}" ;;
        7) DOMAIN="${domains[6]}" ;;
        8) DOMAIN="${domains[7]}" ;;
        9) DOMAIN="${domains[8]}" ;;
        10) DOMAIN="${domains[9]}" ;;
        11) DOMAIN="${domains[10]}" ;;
        12) DOMAIN="${domains[11]}" ;;
        13) DOMAIN="${domains[12]}" ;;
        14) DOMAIN="${domains[13]}" ;;
        15) DOMAIN="${domains[14]}" ;;
        16) DOMAIN="${domains[15]}" ;;
        17) DOMAIN="${domains[16]}" ;;
        18) DOMAIN="${domains[17]}" ;;
        19) DOMAIN="${domains[18]}" ;;
        20) DOMAIN="${domains[19]}" ;;
        *)
            DOMAIN="google.com"
            ;;
    esac
}

# --- ВЫБОР ПОРТА С ПРОВЕРКОЙ ---
choose_port() {
    local p_choice custom_port

    while true; do
        clear
        echo -e "${CYAN}--- Выберите порт ---${NC}"
        echo -e "1) 8443 ($(port_status_label 8443))"
        echo -e "2) 443  ($(port_status_label 443))"
        echo -e "3) Проверить и выбрать другой порт"
        read -r -p "Выбор: " p_choice

        case "${p_choice}" in
            1)
                PORT=8443
                if port_is_busy "${PORT}"; then
                    echo -e "${RED}Порт ${PORT} уже занят.${NC}"
                    port_owner "${PORT}"
                    read -r -p "Нажмите Enter..."
                    continue
                fi
                return 0
                ;;
            2)
                PORT=443
                if port_is_busy "${PORT}"; then
                    echo -e "${RED}Порт ${PORT} уже занят.${NC}"
                    port_owner "${PORT}"
                    read -r -p "Нажмите Enter..."
                    continue
                fi
                return 0
                ;;
            3)
                read -r -p "Введите свой порт: " custom_port

                if ! validate_port "${custom_port}"; then
                    echo -e "${RED}Некорректный порт.${NC}"
                    read -r -p "Нажмите Enter..."
                    continue
                fi

                if port_is_busy "${custom_port}"; then
                    echo -e "${RED}Порт ${custom_port} уже занят.${NC}"
                    port_owner "${custom_port}"
                    read -r -p "Нажмите Enter..."
                    continue
                fi

                PORT="${custom_port}"
                return 0
                ;;
            *)
                echo -e "${RED}Неверный ввод.${NC}"
                read -r -p "Нажмите Enter..."
                ;;
        esac
    done
}

# --- УСТАНОВКА / ОБНОВЛЕНИЕ ---
menu_install() {
    clear
    choose_domain
    echo ""
    choose_port

    echo -e "${YELLOW}[*] Настройка прокси...${NC}"
    SECRET="$(generate_secret "${DOMAIN}")"

    if [ -z "${SECRET}" ]; then
        echo -e "${RED}Не удалось сгенерировать secret.${NC}"
        return 1
    fi

    docker stop "${CONTAINER_NAME}" &>/dev/null || true
    docker rm "${CONTAINER_NAME}" &>/dev/null || true

    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "0.0.0.0:${PORT}:${PORT}/tcp" \
        "${IMAGE_NAME}" \
        simple-run -n 1.1.1.1 -i prefer-ipv4 "0.0.0.0:${PORT}" "${SECRET}" >/dev/null

    if [ $? -ne 0 ]; then
        echo -e "${RED}Не удалось запустить контейнер.${NC}"
        return 1
    fi

    save_config

    clear
    show_config
    read -r -p "Установка завершена. Нажмите Enter..."
}

# --- УДАЛЕНИЕ ---
remove_proxy() {
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo -e "${GREEN}Прокси удалён.${NC}"
}

# --- РУЧНАЯ ПРОВЕРКА ПОРТА ---
check_custom_port() {
    local port_to_check

    read -r -p "Введите порт для проверки: " port_to_check

    if ! validate_port "${port_to_check}"; then
        echo -e "${RED}Некорректный порт.${NC}"
        return 1
    fi

    if port_is_busy "${port_to_check}"; then
        echo -e "${RED}Порт ${port_to_check} занят.${NC}"
        port_owner "${port_to_check}"
    else
        echo -e "${GREEN}Порт ${port_to_check} свободен.${NC}"
    fi
}

# --- ОСНОВНОЕ МЕНЮ ---
main_menu() {
    while true; do
        clear
        echo -e "\n${MAGENTA}=== GoTelegram Manager ===${NC}"
        echo -e "1) ${GREEN}Установить / Обновить прокси${NC}"
        echo -e "2) Показать данные подключения"
        echo -e "3) Показать статус"
        echo -e "4) Проверить порт"
        echo -e "5) ${RED}Удалить прокси${NC}"
        echo -e "0) Выход"
        read -r -p "Пункт: " m_idx

        case "${m_idx}" in
            1) menu_install ;;
            2) clear; show_config; read -r -p "Нажмите Enter..." ;;
            3) clear; show_status; read -r -p "Нажмите Enter..." ;;
            4) clear; check_custom_port; read -r -p "Нажмите Enter..." ;;
            5) clear; remove_proxy; read -r -p "Нажмите Enter..." ;;
            0) exit 0 ;;
            *) echo "Неверный ввод"; sleep 1 ;;
        esac
    done
}

# --- СТАРТ СКРИПТА ---
check_root
ensure_dirs
install_self
ensure_docker
ensure_qrencode
load_config
main_menu
