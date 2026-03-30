#!/usr/bin/env bash

set -u

APP_NAME="gotelegram"
APP_PATH="/usr/local/bin/gotelegram"
CONFIG_DIR="/etc/gotelegram"
CONFIG_FILE="${CONFIG_DIR}/mtproxy.env"
CONTAINER_NAME="mtproto-proxy"
IMAGE_NAME="nineseconds/mtg:2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

print_ok()   { echo -e "${GREEN}●${NC} $1"; }
print_bad()  { echo -e "${RED}●${NC} $1"; }
print_warn() { echo -e "${YELLOW}●${NC} $1"; }
print_info() { echo -e "${CYAN}$1${NC}"; }
print_line() { echo -e "${BLUE}============================================================${NC}"; }

check_root() {
    if [ "${EUID}" -ne 0 ]; then
        echo -e "${RED}Ошибка: запусти скрипт от root.${NC}"
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

get_public_ip() {
    local ip
    ip="$(curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "${ip}" ]; then
        ip="$(curl -4 -s --max-time 4 https://ifconfig.io 2>/dev/null || true)"
    fi
    if [ -z "${ip}" ]; then
        ip="$(curl -4 -s --max-time 4 https://icanhazip.com 2>/dev/null || true)"
    fi
    if [ -z "${ip}" ]; then
        echo "unknown"
    else
        echo "${ip}" | tr -d '[:space:]'
    fi
}

ensure_docker() {
    if ! command_exists docker; then
        echo -e "${RED}Docker не найден.${NC}"
        echo "Установи Docker отдельно и запусти скрипт снова."
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
        echo -e "${YELLOW}Пакет qrencode не найден. Ставлю...${NC}"
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

container_exists() {
    docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"
}

container_running() {
    docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"
}

get_container_port() {
    docker inspect "${CONTAINER_NAME}" --format='{{range $p, $conf := .HostConfig.PortBindings}}{{(index $conf 0).HostPort}}{{end}}' 2>/dev/null | head -n1
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

generate_secret() {
    local domain="$1"
    docker pull "${IMAGE_NAME}" >/dev/null
    docker run --rm "${IMAGE_NAME}" generate-secret --hex "${domain}"
}

show_qr() {
    local text="$1"
    if command_exists qrencode; then
        qrencode -t ANSIUTF8 "$text"
    else
        echo -e "${YELLOW}qrencode не установлен, QR не показан.${NC}"
    fi
}

show_connection_data() {
    load_config

    if ! container_exists; then
        echo -e "${RED}MTProxy контейнер не найден.${NC}"
        return 1
    fi

    local ip port link
    ip="$(get_public_ip)"
    port="${PORT}"

    if [ -z "${port}" ]; then
        port="$(get_container_port)"
    fi

    if [ -z "${SECRET}" ] || [ -z "${port}" ]; then
        echo -e "${RED}Не удалось прочитать параметры подключения.${NC}"
        return 1
    fi

    link="tg://proxy?server=${ip}&port=${port}&secret=${SECRET}"

    print_line
    echo -e "${WHITE}MTProxy connection data${NC}"
    print_line
    echo -e "Server: ${ip}"
    echo -e "Port:   ${port}"
    echo -e "Domain: ${DOMAIN:-unknown}"
    echo -e "Secret: ${SECRET}"
    echo -e "Link:   ${CYAN}${link}${NC}"
    print_line
    show_qr "${link}"
    print_line
}

show_status() {
    load_config

    local public_ip
    public_ip="$(get_public_ip)"

    print_line
    echo -e "${WHITE}MTProxy status${NC}"
    print_line
    echo -e "Host:      $(hostname -f 2>/dev/null || hostname)"
    echo -e "Public IP: ${public_ip}"
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

    if [ -n "${PORT:-}" ]; then
        if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${PORT}" 2>/dev/null; then
            print_ok "TCP connect to 127.0.0.1:${PORT}"
        else
            print_bad "TCP connect to 127.0.0.1:${PORT}"
        fi
    fi

    print_line
}

remove_proxy() {
    if container_exists; then
        docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        print_ok "Контейнер ${CONTAINER_NAME} удалён"
    else
        print_warn "Контейнер ${CONTAINER_NAME} не найден"
    fi
}

choose_domain() {
    local domains domain_choice custom_domain
    domains=(
        "google.com"
        "wikipedia.org"
        "github.com"
        "stackoverflow.com"
        "bbc.com"
        "reuters.com"
        "cloudflare.com"
        "microsoft.com"
        "apple.com"
        "amazon.com"
    )

    echo -e "${CYAN}Выбери домен-маскировку:${NC}"
    local i=1
    for d in "${domains[@]}"; do
        printf "%2d) %s\n" "${i}" "${d}"
        i=$((i+1))
    done
    echo "11) Ввести свой домен"
    read -r -p "Выбор [1-11]: " domain_choice

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
        11)
            read -r -p "Введи свой домен-маскировку: " custom_domain
            DOMAIN="${custom_domain}"
            ;;
        *)
            DOMAIN="google.com"
            ;;
    esac
}

choose_port() {
    local answer
    echo -e "${CYAN}Выбери порт:${NC}"
    echo "1) 8443 (рекомендуется)"
    echo "2) 443  (только если точно свободен)"
    echo "3) Ввести свой порт"
    read -r -p "Выбор [1-3]: " answer

    case "${answer}" in
        1) PORT="8443" ;;
        2) PORT="443" ;;
        3)
            read -r -p "Введи порт: " PORT
            ;;
        *)
            PORT="8443"
            ;;
    esac

    if ! validate_port "${PORT}"; then
        echo -e "${RED}Некорректный порт.${NC}"
        return 1
    fi

    return 0
}

install_or_update_proxy() {
    load_config
    choose_domain
    choose_port || return 1

    if [ "${PORT}" = "443" ]; then
        echo -e "${YELLOW}Внимание: 443 часто уже занят боевыми сервисами.${NC}"
        read -r -p "Точно продолжить с портом 443? [y/N]: " confirm443
        if [[ ! "${confirm443}" =~ ^[Yy]$ ]]; then
            echo "Отменено."
            return 1
        fi
    fi

    if port_is_busy "${PORT}"; then
        if container_running; then
            local current_port
            current_port="$(get_container_port)"
            if [ "${current_port}" = "${PORT}" ]; then
                print_warn "Порт ${PORT} уже занят текущим контейнером ${CONTAINER_NAME}, обновлю его."
            else
                print_bad "Порт ${PORT} уже занят."
                port_owner "${PORT}"
                return 1
            fi
        else
            print_bad "Порт ${PORT} уже занят."
            port_owner "${PORT}"
            return 1
        fi
    fi

    print_info "Тяну образ ${IMAGE_NAME}..."
    docker pull "${IMAGE_NAME}" || {
        print_bad "Не удалось скачать Docker image"
        return 1
    }

    print_info "Генерирую secret для домена ${DOMAIN}..."
    SECRET="$(generate_secret "${DOMAIN}")"
    if [ -z "${SECRET}" ]; then
        print_bad "Не удалось сгенерировать secret"
        return 1
    fi

    if container_exists; then
        print_warn "Останавливаю старый контейнер ${CONTAINER_NAME}..."
        docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
        docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi

    print_info "Запускаю MTProxy на порту ${PORT}..."
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -p "0.0.0.0:${PORT}:${PORT}/tcp" \
        "${IMAGE_NAME}" \
        simple-run -n 1.1.1.1 -i prefer-ipv4 "0.0.0.0:${PORT}" "${SECRET}" >/dev/null || {
        print_bad "Не удалось запустить контейнер"
        return 1
    }

    save_config

    echo
    print_ok "MTProxy запущен"
    show_connection_data
}

show_menu() {
    echo
    print_line
    echo -e "${WHITE}GoTelegram MTProxy Manager${NC}"
    print_line
    echo "1) Установить / обновить MTProxy"
    echo "2) Показать данные подключения"
    echo "3) Показать статус"
    echo "4) Проверить, занят ли порт"
    echo "5) Удалить MTProxy"
    echo "0) Выход"
    print_line
}

check_custom_port() {
    local p
    read -r -p "Введи порт для проверки: " p
    if ! validate_port "${p}"; then
        print_bad "Некорректный порт"
        return 1
    fi

    if port_is_busy "${p}"; then
        print_bad "Порт ${p} занят"
        port_owner "${p}"
    else
        print_ok "Порт ${p} свободен"
    fi
}

main() {
    check_root
    ensure_dirs
    install_self
    ensure_docker
    ensure_qrencode
    load_config

    while true; do
        show_menu
        read -r -p "Пункт: " menu_choice
        case "${menu_choice}" in
            1) install_or_update_proxy ;;
            2) show_connection_data ;;
            3) show_status ;;
            4) check_custom_port ;;
            5) remove_proxy ;;
            0) exit 0 ;;
            *) echo "Неверный ввод" ;;
        esac
    done
}

main
