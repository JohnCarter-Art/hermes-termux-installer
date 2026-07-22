#!/data/data/com.termux/files/usr/bin/bash
#=============================================================================
# Hermes Agent — One-Shot Installer for Termux (Android)
# Версия: 1.0 | Учитывает все проблемы Python 3.14, psutil, cryptography
#=============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
fail() { echo -e "${RED}  ✗${NC} $1"; }

#───────────────────────────────────────────────
# ШАГ 0: Определяем API уровень и архитектуру
#───────────────────────────────────────────────
API_LEVEL=$(getprop ro.build.version.sdk 2>/dev/null || echo 34)
ARCH=$(uname -m)
log "📱 Android API: $API_LEVEL | Arch: $ARCH"

#───────────────────────────────────────────────
# ШАГ 1: Python 3.13 (ОБХОД Python 3.14)
#───────────────────────────────────────────────
log "🔧 Шаг 1: Python 3.13"

install_python313() {
    pkg install tur-repo -y 2>/dev/null || true
    pkg update -y 2>/dev/null
    pkg install python3.13 which -y
    # Жёсткий симлинк, который не сломается
    ln -sf /data/data/com.termux/files/usr/bin/python3.13 $PREFIX/bin/python
    # Проверка
    pyver=$(python --version 2>&1)
    if ! echo "$pyver" | grep -q "3.13"; then
        fail "Python 3.13 не установился. Версия: $pyver"
        exit 1
    fi
    ok "Python: $pyver"
}

# Проверяем, что python === 3.13
if command -v python3.13 &>/dev/null; then
    curpy=$(python --version 2>&1 || echo "none")
    if echo "$curpy" | grep -q "3.13"; then
        ok "Python 3.13 уже установлен: $curpy"
    else
        warn "Симлинк сбит. Чиню..."
        ln -sf /data/data/com.termux/files/usr/bin/python3.13 $PREFIX/bin/python
        ok "Симлинк восстановлен"
    fi
else
    install_python313
fi

#───────────────────────────────────────────────
# ШАГ 2: Build-зависимости (без glib → python)
#───────────────────────────────────────────────
log "🔧 Шаг 2: Build-зависимости"

# Только то, что НЕ тянет python
DEPS="clang rust make libffi openssl ca-certificates curl"
for pkg in $DEPS; do
    pkg install "$pkg" -y 2>/dev/null && ok "$pkg OK" || warn "$pkg не установился"
done

# pkg-config ставим отдельно, сохраняя симлинк
if ! command -v pkg-config &>/dev/null; then
    pkg install pkg-config -y 2>/dev/null || true
    # Восстанавливаем симлинк если pkg его перебил
    if ! python --version 2>&1 | grep -q "3.13"; then
        ln -sf /data/data/com.termux/files/usr/bin/python3.13 $PREFIX/bin/python
        ok "Симлинк восстановлен после pkg-config"
    fi
fi

# zlib нужен для Pillow отдельно
pkg install zlib -y 2>/dev/null || true
ok "Build-зависимости готовы"

#───────────────────────────────────────────────
# ШАГ 3: Скачивание Hermes
#───────────────────────────────────────────────
log "🔧 Шаг 3: Скачивание Hermes Agent"

if [ -d ~/.hermes/hermes-agent ]; then
    warn "Hermes уже скачан. Пропускаю."
else
    cd ~
    log "Скачиваю (~70MB)..."
    curl -fsSL -o /tmp/hermes.tar.gz \
        https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz
    log "Распаковываю..."
    mkdir -p .hermes
    tar xzf /tmp/hermes.tar.gz -C /tmp
    mv /tmp/hermes-agent-main .hermes/hermes-agent
    rm -f /tmp/hermes.tar.gz
    ok "Hermes скачан"
fi

#───────────────────────────────────────────────
# ШАГ 4: Виртуальное окружение
#───────────────────────────────────────────────
log "🔧 Шаг 4: Виртуальное окружение"

cd ~/.hermes/hermes-agent
rm -rf venv
python3.13 -m venv venv
source venv/bin/activate
pip install setuptools wheel -q
ok "venv готов"

#───────────────────────────────────────────────
# ШАГ 5: Psutil (ОБХОД платформы Android)
#───────────────────────────────────────────────
log "🔧 Шаг 5: psutil (совместимость с Android)"

install_psutil() {
    # Ищем предсобранный wheel в кэше
    local whl
    whl=$(find ~/.cache/pip/wheels -name 'psutil-*-android_*arm64_v8a.whl' 2>/dev/null | head -1)
    if [ -n "$whl" ]; then
        pip install "$whl" -q && return 0
    fi

    # Пробуем скачать и собрать
    pip download --no-binary psutil psutil==7.2.2 -d /tmp/psutil_src 2>/dev/null || true
    cd /tmp/psutil_src
    tar xzf psutil-7.2.2.tar.gz 2>/dev/null || { warn "Не удалось распаковать psutil"; return 1; }
    cd psutil-7.2.2
    python setup.py build 2>&1 | tail -1
    python setup.py install 2>&1 | tail -1
    cd ~/.hermes/hermes-agent
    rm -rf /tmp/psutil_src
}

if pip show psutil 2>/dev/null | grep -q "7.2.2"; then
    ok "psutil уже установлен"
else
    install_psutil && ok "psutil OK" || warn "psutil не установился, но продолжим"
fi

#───────────────────────────────────────────────
# ШАГ 6: Основная установка Hermes
#───────────────────────────────────────────────
log "🔧 Шаг 6: Установка Hermes (это ~10-20 мин на телефоне...)"

export OPENSSL_DIR=$PREFIX
export OPENSSL_LIB_DIR=$PREFIX/lib
export OPENSSL_INCLUDE_DIR=$PREFIX/include
export ANDROID_API_LEVEL=$API_LEVEL

# Сначала устанавливаем сложные пакеты по одному (для ясности ошибок)
for pkg in "cryptography==46.0.7" "Pillow==12.2.0"; do
    if ! pip show "${pkg%%==*}" 2>/dev/null | grep -q .; then
        log "Собираю $pkg..."
        ANDROID_API_LEVEL=$API_LEVEL pip install "$pkg" --prefer-binary 2>&1 | tail -1 || true
    fi
done

# Финальная установка
ANDROID_API_LEVEL=$API_LEVEL pip install -e '.[termux-all]' \
    -c constraints-termux.txt --prefer-binary --no-cache-dir 2>&1 | tail -20

#───────────────────────────────────────────────
# ФИНИШ
#───────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ Hermes Agent установлен!              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "Проверка установки..."
if command -v hermes &>/dev/null; then
    hermes --version 2>&1 || true
    echo ""
    echo "Запусти настройку: ${CYAN}hermes setup${NC}"
else
    warn "hermes не найден в PATH. Активируй venv: source ~/.hermes/hermes-agent/venv/bin/activate"
    echo "Потом запусти: ${CYAN}hermes setup${NC}"
fi
