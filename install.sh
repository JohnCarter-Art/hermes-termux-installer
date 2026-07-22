#!/data/data/com.termux/files/usr/bin/bash
#=============================================================================
# Hermes Agent — One-Shot Installer for Termux (Android)
# Версия: 1.1 | Фикс psutil (C extension → /proc stubs)
#=============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
fail() { echo -e "${RED}  ✗${NC} $1"; }

API_LEVEL=$(getprop ro.build.version.sdk 2>/dev/null || echo 34)

# ─── ШАГ 1: Python 3.13 ──────────────────────────────
log "🔧 Шаг 1: Python 3.13"
if command -v python3.13 &>/dev/null && python --version 2>&1 | grep -q "3.13"; then
    ok "Python 3.13 уже установлен"
else
    pkg install tur-repo -y 2>/dev/null || true
    pkg update -y 2>/dev/null
    pkg install python3.13 which -y
    ln -sf /data/data/com.termux/files/usr/bin/python3.13 $PREFIX/bin/python
fi

# ─── ШАГ 2: Build-зависимости (без glib/python!) ────
log "🔧 Шаг 2: Build-зависимости"
pkg install clang rust make libffi openssl ca-certificates curl zlib -y

# ─── ШАГ 3: Скачать Hermes ───────────────────────────
log "🔧 Шаг 3: Скачивание Hermes"
if [ ! -d ~/.hermes/hermes-agent ]; then
    cd ~ && curl -fsSL -o /tmp/hermes.tar.gz \
        https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.tar.gz
    mkdir -p .hermes && tar xzf /tmp/hermes.tar.gz -C /tmp
    mv /tmp/hermes-agent-main .hermes/hermes-agent && rm -f /tmp/hermes.tar.gz
fi

# ─── ШАГ 4: Виртуальное окружение ────────────────────
log "🔧 Шаг 4: Виртуальное окружение"
cd ~/.hermes/hermes-agent && rm -rf venv
python3.13 -m venv venv && source venv/bin/activate
pip install setuptools wheel -q

# ─── ШАГ 5: Psutil + первая часть Hermes ────────────
log "🔧 Шаг 5: Установка Hermes (первые пакеты)"
export OPENSSL_DIR=$PREFIX
export OPENSSL_LIB_DIR=$PREFIX/lib
export OPENSSL_INCLUDE_DIR=$PREFIX/include
export ANDROID_API_LEVEL=$API_LEVEL

ANDROID_API_LEVEL=$API_LEVEL pip install -e '.[termux-all]' -c constraints-termux.txt --prefer-binary --no-cache-dir 2>&1 | tail -5 || true

# ─── ШАГ 6: Psutil Android fix ───────────────────────
log "🔧 Шаг 6: Исправление psutil для Android"
PSUTIL_DIR=$(find ~/.hermes/hermes-agent/venv -path '*/psutil' -type d | head -1)

if [ -z "$PSUTIL_DIR" ]; then
    warn "psutil не найден, попытка доустановки..."
    ANDROID_API_LEVEL=$API_LEVEL pip install psutil==7.2.2
    PSUTIL_DIR=$(find ~/.hermes/hermes-agent/venv -path '*/psutil' -type d | head -1)
fi

# Удаляем битый C extension
rm -f "$PSUTIL_DIR/_psutil_linux.abi3.so" "$PSUTIL_DIR/_psutil_linux.abi3.so.bak"

# Создаём pure-Python заглушку вместо C extension
python3.13 -c "
import os
psutil_dir = '$PSUTIL_DIR'
stub_path = os.path.join(psutil_dir, '_psutil_linux.py')

# Read existing template if any
template = ''
if os.path.exists(stub_path):
    with open(stub_path) as f:
        template = f.read()

stub_code = '''version = 722

def check_pid_range(pid):
    if pid < 0:
        raise ValueError(f\\\"pid must be >= 0, got {pid}\\\")
    return True

def set_debug(debug):
    pass

import os

def getpagesize():
    return os.sysconf(os.sysconf_names[\\\"SC_PAGE_SIZE\\\"]) if hasattr(os, \\\"sysconf_names\\\") else 4096

def ppid_map():
    result = {}
    try:
        for entry in os.listdir(\\\"/proc\\\"):
            if entry.isdigit():
                with open(f\\\"/proc/{entry}/stat\\\") as f:
                    stat = f.read()
                    paren_end = stat.rindex(\\\") \\\")
                    fields = stat[paren_end + 2:].split()
                    result[int(entry)] = int(fields[1])
    except:
        pass
    return result

def linux_sysinfo():
    try:
        with open(\\\"/proc/meminfo\\\") as f:
            total = 0; free = 0
            for line in f:
                if line.startswith(\\\"MemTotal:\\\"): total = int(line.split()[1])
                elif line.startswith(\\\"MemFree:\\\"): free = int(line.split()[1])
        with open(\\\"/proc/uptime\\\") as f:
            uptime = float(f.read().split()[0])
        from collections import namedtuple
        si = namedtuple(\\\"sysinfo\\\", [\\\"uptime\\\",\\\"loads\\\",\\\"totalram\\\",\\\"freeram\\\",\\\"sharedram\\\",\\\"bufferram\\\",\\\"totalswap\\\",\\\"freeswap\\\",\\\"procs\\\",\\\"totalhigh\\\",\\\"freehigh\\\",\\\"mem_unit\\\"])
        return si(uptime, (0,0,0), total*1024, free*1024, 0,0,0,0, 0,0,0,1)
    except:
        return (0,(0,0,0),0,0,0,0,0,0,0,0,0,1)

class heap_info:
    @staticmethod
    def get_info(): return {}

def heap_trim(heap, tid): pass

def net_if_addrs():
    result = {}
    try:
        with open(\\\"/proc/net/dev\\\") as f:
            f.readline(); f.readline()
            for line in f:
                name = line.split(\\\":\\\")[0].strip()
                result[name] = []
    except: pass
    return result

DUPLEX_FULL=2; DUPLEX_HALF=1; DUPLEX_UNKNOWN=0

def net_if_mtu(name):
    try:
        with open(f\\\"/sys/class/net/{name}/mtu\\\") as f: return int(f.read().strip())
    except: return 1500

def net_if_flags(name): return [\\\"UP\\\"]
def net_if_duplex_speed(name): return (DUPLEX_UNKNOWN, 0)
def disk_partitions(mounts_path=\\\"/proc/self/mounts\\\"): return []
def users(): return []
def proc_priority_get(pid): return (0,0)
def proc_priority_set(pid, value): os.nice(value)
def proc_cpu_affinity_get(pid): return list(range(os.cpu_count() or 1))
def proc_cpu_affinity_set(pid, cpus): pass
def proc_ioprio_get(pid): return (0,0)
def proc_ioprio_set(pid, ioclass, value): pass
'''

with open(stub_path, 'w') as f:
    f.write(stub_code)
print('Fake C extension created')
"

ok "psutil исправлен для Android"

# ─── ШАГ 7: Глобальный симлинк ───────────────────────
log "🔧 Шаг 7: Глобальный symlink"
ln -sf ~/.hermes/hermes-agent/venv/bin/hermes $PREFIX/bin/hermes

# ─── ШАГ 8: API ключ в .env ─────────────────────────
log "🔧 Шаг 8: Файл .env"
if [ ! -f ~/.hermes/hermes-agent/.env ]; then
    echo "# Добавьте сюда ваш API ключ: DEEPSEEK_API_KEY=sk-..." > ~/.hermes/hermes-agent/.env
    ok "Создан ~/.hermes/hermes-agent/.env — вставьте туда ключ"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ Hermes Agent установлен для Android!      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "1. Добавьте API ключ:  echo 'DEEPSEEK_API_KEY=sk-...' >> ~/.hermes/hermes-agent/.env"
echo "2. Запуск:             hermes setup"
echo "3. Или сразу:          hermes -z \"Привет\""
