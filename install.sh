#!/usr/bin/env bash
#
# OpenFang 一键安装/更新 + DingTalk Stream 补丁 + 定制配置
#
# 完整流程（不依赖官方安装脚本和交互式 init）：
#   1. 检查/安装 Rust 和 Git
#   2. 克隆源码 → 替换 DingTalk Stream 补丁 → 编译
#   3. 安装二进制 → 配置 PATH
#   4. 初始化（openfang init --quick，无交互，生成目录/agent模板/基础配置）
#   5. 叠加定制配置（安全策略 + glm-5 模型 + 钉钉 channel）
#   6. 配置 API 密钥
#   7. 启动并验证
#
# 用法：
#   curl -sL https://raw.githubusercontent.com/pemagic/openfang_diy/main/install.sh | bash
#   ./install.sh                # 安装/更新
#   ./install.sh --force        # 强制重新编译
#   ./install.sh --check        # 只检查版本
#

set -euo pipefail

# ── 配置 ─────────────────────────────────────────────────────────
OPENFANG_HOME="$HOME/.openfang"
OPENFANG_BIN="$OPENFANG_HOME/bin/openfang"
CONFIG="$OPENFANG_HOME/config.toml"
AGENT_DIR="$OPENFANG_HOME/agents/assistant"
AGENT_TOML="$AGENT_DIR/agent.toml"
SECRETS_FILE="$OPENFANG_HOME/secrets.env"
BUILD_DIR="/tmp/openfang-build"
REPO_URL="https://github.com/RightNow-AI/openfang.git"
DINGTALK_TARGET="crates/openfang-channels/src/dingtalk.rs"
PATCH_GITHUB_URL="https://raw.githubusercontent.com/pemagic/openfang_diy/main/patches/dingtalk_stream.rs"
LOG_FILE="/tmp/openfang-install.log"

# 补丁文件查找（本地优先）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/tmp")"
PATCH_FILE=""
for p in "$SCRIPT_DIR/patches/dingtalk_stream.rs" "$OPENFANG_HOME/patches/dingtalk_stream.rs"; do
    [[ -f "$p" ]] && { PATCH_FILE="$p"; break; }
done

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
err()  { echo -e "${RED}  ✗${NC} $1" >&2; }
warn() { echo -e "${YELLOW}  !${NC} $1"; }

# ══════════════════════════════════════════════════════════════════
#  第一阶段：环境准备
# ══════════════════════════════════════════════════════════════════

ensure_rust() {
    if command -v cargo &>/dev/null; then
        ok "Rust 已安装 ($(rustc --version 2>/dev/null || echo '?'))"
        return 0
    fi

    log "未找到 Rust，正在自动安装 rustup..."
    if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -3; then
        source "$HOME/.cargo/env" 2>/dev/null || true
        if command -v cargo &>/dev/null; then
            ok "Rust 安装成功 ($(rustc --version 2>/dev/null || echo '?'))"
        else
            err "Rust 安装后仍无法找到 cargo"
            err "请手动运行: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
            exit 1
        fi
    else
        err "Rust 自动安装失败，请手动安装: https://rustup.rs"
        exit 1
    fi
}

ensure_git() {
    if command -v git &>/dev/null; then
        ok "Git 已安装"
        return 0
    fi
    err "未找到 git，请先安装"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        err "macOS: xcode-select --install"
    else
        err "Linux: sudo apt install git 或 sudo yum install git"
    fi
    exit 1
}

# ══════════════════════════════════════════════════════════════════
#  第二阶段：克隆 → 补丁 → 编译 → 安装
# ══════════════════════════════════════════════════════════════════

build_and_install() {
    local force="$1"

    # 版本检查（非强制模式）
    if [[ "$force" != true && -f "$OPENFANG_BIN" && -f "$OPENFANG_HOME/.dingtalk_patched" ]]; then
        local local_ver patched_ver remote_ver
        local_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        patched_ver=$(cat "$OPENFANG_HOME/.dingtalk_patched" 2>/dev/null || echo "")
        remote_ver=$(git ls-remote --tags "$REPO_URL" 2>/dev/null \
            | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 | tr -d 'v' || echo "unknown")

        if [[ -n "$patched_ver" && "$patched_ver" == "$remote_ver" ]]; then
            ok "OpenFang v${local_ver} + DingTalk Stream 已是最新"
            return 0
        fi
        log "发现新版本: 本地 v${patched_ver:-?} → 远程 v${remote_ver}"
    fi

    # ── 克隆源码 ──
    log "克隆 OpenFang 源码..."
    rm -rf "$BUILD_DIR"
    if ! git clone --depth 1 "$REPO_URL" "$BUILD_DIR" 2>&1 | tail -2; then
        err "源码克隆失败"
        exit 1
    fi
    ok "源码克隆完成"

    # ── 获取补丁文件 ──
    if [[ -z "$PATCH_FILE" ]]; then
        log "从 GitHub 下载 DingTalk Stream 补丁..."
        mkdir -p "$OPENFANG_HOME/patches"
        PATCH_FILE="$OPENFANG_HOME/patches/dingtalk_stream.rs"
        if ! curl -sfL "$PATCH_GITHUB_URL" -o "$PATCH_FILE" 2>/dev/null || [[ ! -s "$PATCH_FILE" ]]; then
            err "补丁文件下载失败"
            exit 1
        fi
        ok "补丁文件已下载"
    fi

    # ── 适配性检查 ──
    local issues=0
    log "检查补丁适配性..."
    if grep -q "DingTalkAdapter::new" "$BUILD_DIR/crates/openfang-api/src/channel_bridge.rs" 2>/dev/null; then
        local comma_count
        comma_count=$(grep "DingTalkAdapter::new" "$BUILD_DIR/crates/openfang-api/src/channel_bridge.rs" | tr -cd ',' | wc -c | tr -d ' ')
        if [[ "$comma_count" -ne 2 ]]; then
            warn "DingTalkAdapter::new() 参数已变更"
            ((issues++)) || true
        fi
    fi
    for dep in "tokio-tungstenite" "reqwest" "tokio-stream"; do
        if ! grep -q "$dep" "$BUILD_DIR/crates/openfang-channels/Cargo.toml" 2>/dev/null; then
            warn "依赖 $dep 已移除"
            ((issues++)) || true
        fi
    done
    if [[ $issues -gt 0 && "$force" != true ]]; then
        err "适配性检查未通过（${issues} 项），使用 --force 强制"
        rm -rf "$BUILD_DIR"
        exit 1
    fi
    ok "适配性检查通过"

    # ── 替换 DingTalk 源文件 ──
    mkdir -p "$OPENFANG_HOME/patches"
    cp "$BUILD_DIR/$DINGTALK_TARGET" "$OPENFANG_HOME/patches/dingtalk_upstream_latest.rs"
    cp "$PATCH_FILE" "$BUILD_DIR/$DINGTALK_TARGET"
    ok "DingTalk Stream 补丁已应用"

    # ── 编译 ──
    log "正在编译（release mode，需要几分钟）..."
    cd "$BUILD_DIR"
    if ! cargo build --release -p openfang-cli 2>&1 | tee -a "$LOG_FILE" | tail -5; then
        err "编译失败！完整日志: $LOG_FILE"
        cd "$HOME"
        rm -rf "$BUILD_DIR"
        exit 1
    fi
    ok "编译成功"

    # ── 停止已有服务 ──
    curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
    pkill -f "openfang start" 2>/dev/null || true
    sleep 2

    # ── 安装二进制 ──
    mkdir -p "$OPENFANG_HOME/bin"
    if [[ -f "$OPENFANG_BIN" ]]; then
        cp "$OPENFANG_BIN" "$OPENFANG_BIN.bak.$(date +%Y%m%d%H%M%S)"
        ls -t "$OPENFANG_HOME/bin/openfang.bak."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi
    cp "$BUILD_DIR/target/release/openfang" "$OPENFANG_BIN"
    chmod +x "$OPENFANG_BIN"

    local new_ver
    new_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo "$new_ver" > "$OPENFANG_HOME/.dingtalk_patched"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installed v${new_ver} with DingTalk Stream patch" >> "$LOG_FILE"
    ok "OpenFang v${new_ver} (DingTalk Stream) 已安装到 $OPENFANG_BIN"

    # ── 清理 ──
    cd "$HOME"
    rm -rf "$BUILD_DIR"
    ok "编译目录已清理"
}

# ══════════════════════════════════════════════════════════════════
#  第三阶段：配置 PATH
# ══════════════════════════════════════════════════════════════════

configure_path() {
    # 临时生效
    export PATH="$OPENFANG_HOME/bin:$PATH"

    # 检查是否已在 profile 中
    local profile=""
    case "${SHELL:-/bin/bash}" in
        */zsh)  profile="$HOME/.zshrc" ;;
        */bash)
            if [[ -f "$HOME/.bash_profile" ]]; then
                profile="$HOME/.bash_profile"
            else
                profile="$HOME/.bashrc"
            fi
            ;;
        */fish) profile="$HOME/.config/fish/config.fish" ;;
        *)      profile="$HOME/.profile" ;;
    esac

    if [[ -n "$profile" && -f "$profile" ]] && grep -q '\.openfang/bin' "$profile" 2>/dev/null; then
        ok "PATH 已配置 ($profile)"
        return 0
    fi

    if [[ -n "$profile" ]]; then
        echo "" >> "$profile"
        echo '# OpenFang' >> "$profile"
        if [[ "$profile" == *"fish"* ]]; then
            echo 'set -gx PATH $HOME/.openfang/bin $PATH' >> "$profile"
        else
            echo 'export PATH="$HOME/.openfang/bin:$PATH"' >> "$profile"
        fi
        ok "PATH 已写入 $profile"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  第四阶段：初始化（目录 + agent 模板 + 基础配置）
# ══════════════════════════════════════════════════════════════════

initialize_openfang() {
    if [[ -f "$CONFIG" && -d "$OPENFANG_HOME/agents/assistant" ]]; then
        ok "已初始化，跳过（config.toml 和 agent 模板已存在）"
        return 0
    fi

    log "初始化 OpenFang（非交互 --quick 模式）..."

    # openfang init --quick：
    #   - 创建 ~/.openfang/, data/, agents/ 目录（权限 0700）
    #   - 安装 30 个 bundled agent 模板（跳过已存在的）
    #   - 自动检测 provider（从环境变量）
    #   - 写入 config.toml（仅不存在时）
    #   - 完全无交互，专为脚本/CI 设计
    if "$OPENFANG_BIN" init --quick 2>&1 | tail -5; then
        ok "初始化完成（30 个 agent 模板已安装）"
    else
        err "初始化失败"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  第五阶段：定制配置（仅补充/修改必要项，不覆盖其他内容）
# ══════════════════════════════════════════════════════════════════

customize_config_toml() {
    log "定制 config.toml..."

    if [[ ! -f "$CONFIG" ]]; then
        err "config.toml 不存在"
        return 1
    fi

    local changed=false

    # [default_model] — 替换为 zhipu_coding / glm-5（init --quick 默认写 groq）
    if grep -q 'provider = "groq"' "$CONFIG" 2>/dev/null; then
        sed -i '' 's/provider = "groq"/provider = "zhipu_coding"/' "$CONFIG" 2>/dev/null || \
        sed -i 's/provider = "groq"/provider = "zhipu_coding"/' "$CONFIG"
        sed -i '' 's/model = "llama-3.3-70b-versatile"/model = "glm-5"/' "$CONFIG" 2>/dev/null || \
        sed -i 's/model = "llama-3.3-70b-versatile"/model = "glm-5"/' "$CONFIG"
        sed -i '' 's/api_key_env = "GROQ_API_KEY"/api_key_env = "ZHIPU_API_KEY"/' "$CONFIG" 2>/dev/null || \
        sed -i 's/api_key_env = "GROQ_API_KEY"/api_key_env = "ZHIPU_API_KEY"/' "$CONFIG"
        ok "default_model 已改为 zhipu_coding / glm-5"
        changed=true
    else
        ok "default_model 已是自定义配置，跳过"
    fi

    # [approval] require_approval = false — 关闭工具执行审批
    if ! grep -q '^\[approval\]' "$CONFIG"; then
        printf '\n[approval]\nrequire_approval = false\n' >> "$CONFIG"
        ok "已添加 [approval] require_approval = false"
        changed=true
    else
        ok "[approval] 已存在，跳过"
    fi

    # [exec_policy] mode = "full" — 开放所有 shell 命令
    if ! grep -q '^\[exec_policy\]' "$CONFIG"; then
        printf '\n[exec_policy]\nmode = "full"\n' >> "$CONFIG"
        ok "已添加 [exec_policy] mode = \"full\""
        changed=true
    else
        ok "[exec_policy] 已存在，跳过"
    fi

    # [channels.dingtalk] — 钉钉 channel 绑定 assistant
    if ! grep -q '^\[channels\.dingtalk\]' "$CONFIG"; then
        printf '\n[channels.dingtalk]\ndefault_agent = "assistant"\n' >> "$CONFIG"
        ok "已添加 [channels.dingtalk]"
        changed=true
    else
        ok "[channels.dingtalk] 已存在，跳过"
    fi

    # provider_urls.zhipu_coding — 智谱 Coding API 地址
    if ! grep -q '^\[provider_urls\]' "$CONFIG"; then
        printf '\n[provider_urls]\nzhipu_coding = "https://open.bigmodel.cn/api/coding/paas/v4"\n' >> "$CONFIG"
        ok "已添加 zhipu_coding provider URL"
        changed=true
    else
        ok "zhipu_coding 已存在，跳过"
    fi

    [[ "$changed" == false ]] && ok "config.toml 无需修改"
}

customize_agent_toml() {
    log "定制 assistant agent.toml..."

    if [[ ! -f "$AGENT_TOML" ]]; then
        warn "agent.toml 不存在，跳过（启动后可在 Dashboard 配置）"
        return 0
    fi

    # 用 python3 精确修改关键字段，不动 system_prompt 等其他内容
    # 写入临时文件（避免 curl | bash 下 heredoc 兼容性问题）
    local py_script="/tmp/openfang_customize_agent.py"
    cat > "$py_script" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

lines = content.split('\n')
in_model = False
has_api_key_env = False
has_exec_policy = False
changed = False
result = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        in_model = (stripped == '[model]')
        if stripped == '[exec_policy]':
            has_exec_policy = True

    if in_model:
        if re.match(r'provider\s*=', stripped) and '"zhipu_coding"' not in stripped:
            line = 'provider = "zhipu_coding"'
            changed = True
        elif re.match(r'model\s*=', stripped) and '"glm-5"' not in stripped:
            line = 'model = "glm-5"'
            changed = True
        elif re.match(r'api_key_env\s*=', stripped):
            has_api_key_env = True
            if '"ZHIPU_API_KEY"' not in stripped:
                line = 'api_key_env = "ZHIPU_API_KEY"'
                changed = True

    result.append(line)

content = '\n'.join(result)

if not has_api_key_env:
    content = content.replace('[model]\n', '[model]\napi_key_env = "ZHIPU_API_KEY"\n', 1)
    changed = True

if not has_exec_policy and '[resources]' in content:
    content = content.replace('[resources]', '[exec_policy]\nmode = "full"\n\n[resources]')
    changed = True
elif not has_exec_policy:
    content += '\n\n[exec_policy]\nmode = "full"\n'
    changed = True

if re.search(r'shell\s*=\s*\[', content) and 'shell = ["*"]' not in content:
    content = re.sub(r'shell\s*=\s*\[.*?\]', 'shell = ["*"]', content)
    changed = True

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("CHANGED")
else:
    print("UNCHANGED")
PYEOF
    local result
    result=$(python3 "$py_script" "$AGENT_TOML")
    rm -f "$py_script"

    if [[ "$result" == "CHANGED" ]]; then
        ok "agent.toml 已定制（provider=zhipu_coding, model=glm-5, exec_policy=full, shell=[*]）"
    else
        ok "agent.toml 已是正确配置"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  第六阶段：API 密钥
# ══════════════════════════════════════════════════════════════════

write_key() {
    local var_name="$1"
    local display_name="$2"
    local help_text="$3"
    local required="${4:-optional}"

    # 1. secrets.env 中已有 → 跳过
    if grep -q "${var_name}=.\+" "$SECRETS_FILE" 2>/dev/null; then
        ok "$display_name 已配置"
        return 0
    fi

    # 2. 环境变量已设置 → 直接写入
    local env_val="${!var_name:-}"
    if [[ -n "$env_val" ]]; then
        sed -i '' "/^${var_name}=/d" "$SECRETS_FILE" 2>/dev/null || sed -i "/^${var_name}=/d" "$SECRETS_FILE" 2>/dev/null || true
        echo "${var_name}=${env_val}" >> "$SECRETS_FILE"
        ok "$display_name 已从环境变量写入"
        return 0
    fi

    # 3. 交互式输入（兼容 curl | bash 的 stdin 被占用 / 无 tty 环境）
    local input_val=""
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}  ? 请输入 ${display_name}（留空跳过）：${NC}"
        [[ -n "$help_text" ]] && echo -e "    $help_text"
        read -rp "    ${var_name}: " input_val || true
    elif (echo -n > /dev/tty) 2>/dev/null; then
        echo -e "${YELLOW}  ? 请输入 ${display_name}（留空跳过）：${NC}"
        [[ -n "$help_text" ]] && echo -e "    $help_text"
        read -rp "    ${var_name}: " input_val < /dev/tty 2>/dev/null || true
    fi

    if [[ -n "$input_val" ]]; then
        sed -i '' "/^${var_name}=/d" "$SECRETS_FILE" 2>/dev/null || sed -i "/^${var_name}=/d" "$SECRETS_FILE" 2>/dev/null || true
        echo "${var_name}=${input_val}" >> "$SECRETS_FILE"
        ok "$display_name 已写入"
    elif [[ "$required" == "required" ]]; then
        warn "$display_name 未配置（必需，功能可能不可用）"
    else
        warn "$display_name 已跳过"
    fi
}

configure_api_keys() {
    log "配置 API 密钥..."
    touch "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"

    write_key "ZHIPU_API_KEY" "智谱 API Key" \
        "获取: https://open.bigmodel.cn/usercenter/apikeys" "required"

    write_key "DINGTALK_ACCESS_TOKEN" "钉钉 Access Token" \
        "获取: 钉钉开放平台 → 应用 → 机器人 → 凭证"

    write_key "DINGTALK_SECRET" "钉钉 Secret" ""

    write_key "GEMINI_API_KEY" "Gemini API Key（备用模型）" ""
}

# ══════════════════════════════════════════════════════════════════
#  第七阶段：启动并验证
# ══════════════════════════════════════════════════════════════════

start_and_verify() {
    log "启动 OpenFang..."

    # 停止已有
    curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
    pkill -f "openfang start" 2>/dev/null || true
    sleep 3

    # 加载密钥并启动
    set -a
    source "$SECRETS_FILE" 2>/dev/null || true
    [[ -f "$OPENFANG_HOME/.env" ]] && source "$OPENFANG_HOME/.env" 2>/dev/null || true
    set +a

    "$OPENFANG_BIN" start > /tmp/openfang-daemon.log 2>&1 &
    local daemon_pid=$!
    log "等待 daemon 启动 (PID: $daemon_pid)..."

    # 等待 health check（最多 15 秒）
    local ok_health=false
    for i in $(seq 1 15); do
        if curl -s http://127.0.0.1:4200/api/health 2>/dev/null | grep -q '"ok"'; then
            ok_health=true
            break
        fi
        sleep 1
    done

    if [[ "$ok_health" == true ]]; then
        ok "Daemon 已启动"
    else
        err "Daemon 启动超时，请检查 /tmp/openfang-daemon.log"
        return 1
    fi

    # 检查 agent
    sleep 2
    local agent_count
    agent_count=$(curl -s http://127.0.0.1:4200/api/agents 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$agent_count" -gt 0 ]]; then
        ok "Agent 已就绪（共 ${agent_count} 个）"
    else
        log "手动创建 assistant agent..."
        curl -s -X POST http://127.0.0.1:4200/api/agents/spawn-by-name \
            -H "Content-Type: application/json" \
            -d '{"name": "assistant"}' >/dev/null 2>&1
        sleep 3
        agent_count=$(curl -s http://127.0.0.1:4200/api/agents 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [[ "$agent_count" -gt 0 ]]; then
            ok "Agent 已创建"
        else
            warn "Agent 创建失败，请在 Dashboard (http://127.0.0.1:4200) 手动创建"
        fi
    fi

    # 检查钉钉
    sleep 2
    if grep -qi "stream.*connect\|dingtalk.*connect\|Stream connected" /tmp/openfang-daemon.log 2>/dev/null; then
        ok "钉钉 Stream 已连接"
    else
        warn "钉钉 Stream 未检测到连接（可能需要等待或检查 token）"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  主流程
# ══════════════════════════════════════════════════════════════════

main() {
    local force=false
    local check_only=false

    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --check) check_only=true ;;
            --help|-h)
                echo "用法: $0 [--force] [--check]"
                echo ""
                echo "  无参数     一键安装/更新（编译 + 补丁 + 配置）"
                echo "  --force    强制重新编译"
                echo "  --check    只检查版本"
                exit 0
                ;;
        esac
    done

    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║   OpenFang 一键安装 + DingTalk Stream    ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""

    # --check 模式
    if [[ "$check_only" == true ]]; then
        if [[ -f "$OPENFANG_BIN" ]]; then
            local ver
            ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
            log "本地版本: v$ver"
            if [[ -f "$OPENFANG_HOME/.dingtalk_patched" ]]; then
                log "DingTalk Stream 补丁: v$(cat "$OPENFANG_HOME/.dingtalk_patched")"
            else
                log "DingTalk Stream 补丁: 未安装"
            fi
        else
            log "OpenFang 未安装"
        fi
        exit 0
    fi

    # ── 第一阶段 ──
    log "══ 第一阶段：环境准备 ══"
    ensure_rust
    ensure_git
    echo ""

    # ── 第二阶段 ──
    log "══ 第二阶段：编译安装 ══"
    build_and_install "$force"
    echo ""

    # ── 第三阶段 ──
    log "══ 第三阶段：配置 PATH ══"
    configure_path
    echo ""

    # ── 第四阶段 ──
    log "══ 第四阶段：初始化 ══"
    initialize_openfang
    echo ""

    # ── 第五阶段 ──
    log "══ 第五阶段：定制配置 ══"
    customize_config_toml
    echo ""
    customize_agent_toml
    echo ""

    # ── 第六阶段 ──
    log "══ 第六阶段：API 密钥 ══"
    configure_api_keys
    echo ""

    # ── 第七阶段 ──
    log "══ 第七阶段：启动验证 ══"
    start_and_verify

    # ── 完成 ──
    local final_ver patch_ver
    final_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
    patch_ver=$(cat "$OPENFANG_HOME/.dingtalk_patched" 2>/dev/null || echo "?")

    echo ""
    echo "  ╔════════════════════════════════════════════════╗"
    echo "  ║              安装完成!                          ║"
    echo "  ╠════════════════════════════════════════════════╣"
    echo "  ║  版本: v${final_ver} (DingTalk Stream: v${patch_ver})     ║"
    echo "  ║  模型: glm-5 (智谱 Coding API)                  ║"
    echo "  ║  Shell: 全权限 · 审批: 已关闭                    ║"
    echo "  ║  Dashboard: http://127.0.0.1:4200               ║"
    echo "  ╚════════════════════════════════════════════════╝"
    echo ""
    echo "  更新时再跑一遍同样的命令即可。"
    echo ""
}

main "$@"
