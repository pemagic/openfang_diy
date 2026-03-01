#!/usr/bin/env bash
#
# OpenFang 一键安装/更新 + 定制配置脚本
#
# 基于官方安装流程，叠加以下定制：
#   - DingTalk Stream 补丁（需要 Rust 编译环境，可选）
#   - 安全策略：关闭审批、开放 shell 执行
#   - Agent 模型：glm-5 (智谱 Coding API)
#   - 交互式配置 API Key
#
# 用法：
#   curl -sL https://raw.githubusercontent.com/pemagic/openfang_diy/main/install.sh | bash
#   ./install.sh                # 安装/更新
#   ./install.sh --no-patch     # 跳过 DingTalk 补丁编译（仅用官方预编译二进制）
#   ./install.sh --force        # 强制重新编译补丁
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
LOG_FILE="$OPENFANG_HOME/update.log"
PATCH_GITHUB_URL="https://raw.githubusercontent.com/pemagic/openfang_diy/main/patches/dingtalk_stream.rs"

# 补丁文件查找
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/tmp")"
PATCH_FILE=""
for p in "$SCRIPT_DIR/patches/dingtalk_stream.rs" "$OPENFANG_HOME/patches/dingtalk_stream.rs"; do
    if [[ -f "$p" ]]; then PATCH_FILE="$p"; break; fi
done

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ══════════════════════════════════════════════════════════════════
#  第一阶段：安装 OpenFang（官方流程）
# ══════════════════════════════════════════════════════════════════

install_openfang() {
    if [[ -f "$OPENFANG_BIN" ]]; then
        local local_ver
        local_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        ok "OpenFang 已安装 (v${local_ver})"
        return 0
    fi

    log "正在通过官方脚本安装 OpenFang..."
    if curl -fsSL https://openfang.sh/install | sh; then
        ok "OpenFang 官方安装完成"
    else
        err "官方安装脚本失败"
        exit 1
    fi

    # 刷新 PATH（官方脚本可能修改了 shell profile）
    export PATH="$OPENFANG_HOME/bin:$PATH"

    if [[ ! -f "$OPENFANG_BIN" ]]; then
        err "安装后未找到 openfang 二进制: $OPENFANG_BIN"
        exit 1
    fi

    local ver
    ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    ok "OpenFang v${ver} 已安装"
}

init_openfang() {
    # 如果已经初始化过（config.toml 存在），跳过
    if [[ -f "$CONFIG" ]]; then
        ok "OpenFang 已初始化，跳过 init"
        return 0
    fi

    log "正在初始化 OpenFang..."
    "$OPENFANG_BIN" init 2>/dev/null || true
    ok "OpenFang 初始化完成"
}

# ══════════════════════════════════════════════════════════════════
#  第二阶段：DingTalk Stream 补丁（可选，需要 Rust）
# ══════════════════════════════════════════════════════════════════

apply_dingtalk_patch() {
    local force="$1"

    # 检查 Rust 工具链，没有则自动安装
    if ! command -v cargo &>/dev/null; then
        log "未找到 Rust 编译环境，正在自动安装 rustup..."
        if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tail -3; then
            # 加载 cargo 环境
            source "$HOME/.cargo/env" 2>/dev/null || true
            if command -v cargo &>/dev/null; then
                ok "Rust 工具链安装成功 ($(rustc --version 2>/dev/null || echo 'unknown'))"
            else
                err "Rust 安装后仍无法找到 cargo，请手动运行: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
                return 1
            fi
        else
            err "Rust 自动安装失败，请手动安装: https://rustup.rs"
            return 1
        fi
    fi

    if ! command -v git &>/dev/null; then
        err "未找到 git，请先安装 git"
        return 1
    fi

    # 获取补丁文件
    if [[ -z "$PATCH_FILE" ]]; then
        log "正在从 GitHub 下载 DingTalk Stream 补丁..."
        mkdir -p "$OPENFANG_HOME/patches"
        PATCH_FILE="$OPENFANG_HOME/patches/dingtalk_stream.rs"
        if ! curl -sfL "$PATCH_GITHUB_URL" -o "$PATCH_FILE" 2>/dev/null || [[ ! -s "$PATCH_FILE" ]]; then
            err "补丁文件下载失败"
            PATCH_FILE=""
            return 1
        fi
        ok "补丁文件已下载"
    fi

    # 版本检查（非强制模式下）
    if [[ "$force" != true ]]; then
        local local_ver remote_ver
        local_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        remote_ver=$(git ls-remote --tags "$REPO_URL" 2>/dev/null \
            | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 | tr -d 'v' || echo "unknown")

        # 检查是否已经编译过补丁（标记文件）
        if [[ -f "$OPENFANG_HOME/.dingtalk_patched" ]]; then
            local patched_ver
            patched_ver=$(cat "$OPENFANG_HOME/.dingtalk_patched")
            if [[ "$patched_ver" == "$remote_ver" ]]; then
                ok "DingTalk Stream 补丁已是最新 (v${patched_ver})"
                return 0
            fi
        fi
    fi

    log "正在编译 DingTalk Stream 补丁（需要几分钟）..."

    # 克隆源码
    log "克隆 OpenFang 源码..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 "$REPO_URL" "$BUILD_DIR" 2>&1 | tail -2
    ok "源码克隆完成"

    # 适配性检查
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
        err "适配性检查未通过，使用 --force 强制编译"
        rm -rf "$BUILD_DIR"
        return 1
    fi

    # 替换 dingtalk.rs
    mkdir -p "$OPENFANG_HOME/patches"
    cp "$BUILD_DIR/$DINGTALK_TARGET" "$OPENFANG_HOME/patches/dingtalk_upstream_latest.rs"
    cp "$PATCH_FILE" "$BUILD_DIR/$DINGTALK_TARGET"
    ok "dingtalk.rs 已替换"

    # 编译
    log "正在编译 (release mode)..."
    cd "$BUILD_DIR"
    if ! cargo build --release -p openfang-cli 2>&1 | tee -a "$LOG_FILE" | tail -5; then
        err "编译失败！日志: $LOG_FILE"
        rm -rf "$BUILD_DIR"
        return 1
    fi
    ok "编译成功"

    # 停止服务
    curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
    pkill -f "openfang start" 2>/dev/null || true
    sleep 2

    # 备份并替换二进制
    if [[ -f "$OPENFANG_BIN" ]]; then
        cp "$OPENFANG_BIN" "$OPENFANG_BIN.bak.$(date +%Y%m%d%H%M%S)"
        ls -t "$OPENFANG_HOME/bin/openfang.bak."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi
    cp "$BUILD_DIR/target/release/openfang" "$OPENFANG_BIN"
    chmod +x "$OPENFANG_BIN"
    ok "已替换为 DingTalk Stream 版本"

    # 记录补丁版本
    local new_ver
    new_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo "$new_ver" > "$OPENFANG_HOME/.dingtalk_patched"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Patched v${new_ver} (dingtalk stream)" >> "$LOG_FILE"

    # 清理
    rm -rf "$BUILD_DIR"
    ok "编译目录已清理"
}

# ══════════════════════════════════════════════════════════════════
#  第三阶段：定制配置（仅补充缺失项，不覆盖已有）
# ══════════════════════════════════════════════════════════════════

configure_config_toml() {
    log "检查 config.toml 定制配置..."

    if [[ ! -f "$CONFIG" ]]; then
        warn "config.toml 不存在，请先运行 openfang init"
        return 1
    fi

    # [approval] — 仅缺失时添加
    if ! grep -q '^\[approval\]' "$CONFIG"; then
        printf '\n[approval]\nrequire_approval = false\n' >> "$CONFIG"
        ok "已添加 [approval] require_approval = false"
    else
        ok "[approval] 已配置，跳过"
    fi

    # [exec_policy] — 仅缺失时添加
    if ! grep -q '^\[exec_policy\]' "$CONFIG"; then
        printf '\n[exec_policy]\nmode = "full"\n' >> "$CONFIG"
        ok "已添加 [exec_policy] mode = \"full\""
    else
        ok "[exec_policy] 已配置，跳过"
    fi

    # [channels.dingtalk] — 仅缺失时添加
    if ! grep -q '^\[channels\.dingtalk\]' "$CONFIG"; then
        printf '\n[channels.dingtalk]\ndefault_agent = "assistant"\n' >> "$CONFIG"
        ok "已添加 [channels.dingtalk]"
    else
        ok "[channels.dingtalk] 已配置，跳过"
    fi

    # provider_urls.zhipu_coding — 仅缺失时添加
    if ! grep -q 'zhipu_coding' "$CONFIG"; then
        printf '\n[provider_urls]\nzhipu_coding = "https://open.bigmodel.cn/api/coding/paas/v4"\n' >> "$CONFIG"
        ok "已添加 zhipu_coding provider URL"
    else
        ok "zhipu_coding 已配置，跳过"
    fi
}

configure_agent_toml() {
    log "检查 assistant agent.toml..."

    if [[ ! -f "$AGENT_TOML" ]]; then
        ok "agent.toml 不存在，跳过（首次启动后可在 Dashboard 配置）"
        return 0
    fi

    # 用 python3 精确修改关键字段，不动 system_prompt 等其他内容
    local result
    result=$(python3 - "$AGENT_TOML" <<'PYEOF'
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
    )

    if [[ "$result" == "CHANGED" ]]; then
        ok "agent.toml 关键字段已更新（provider/model/exec_policy/shell）"
    else
        ok "agent.toml 已是正确配置，无需修改"
    fi
}

# ── API Key 配置 ─────────────────────────────────────────────────

write_key() {
    local var_name="$1"
    local display_name="$2"
    local help_text="$3"
    local required="${4:-optional}"

    # 1. secrets.env 中已配置 → 跳过
    if grep -q "${var_name}=.\+" "$SECRETS_FILE" 2>/dev/null; then
        ok "$display_name 已配置"
        return 0
    fi

    # 2. 环境变量已设置 → 直接写入
    local env_val="${!var_name:-}"
    if [[ -n "$env_val" ]]; then
        sed -i '' "/^${var_name}=/d" "$SECRETS_FILE" 2>/dev/null || true
        echo "${var_name}=${env_val}" >> "$SECRETS_FILE"
        ok "$display_name 已从环境变量写入"
        return 0
    fi

    # 3. 交互式输入（兼容 curl | bash）
    local input_val=""
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}[?] 请输入 ${display_name}（留空跳过）：${NC}"
        [[ -n "$help_text" ]] && echo -e "    $help_text"
        read -rp "    ${var_name}: " input_val
    elif [[ -e /dev/tty ]]; then
        echo -e "${YELLOW}[?] 请输入 ${display_name}（留空跳过）：${NC}"
        [[ -n "$help_text" ]] && echo -e "    $help_text"
        read -rp "    ${var_name}: " input_val < /dev/tty
    fi

    if [[ -n "$input_val" ]]; then
        sed -i '' "/^${var_name}=/d" "$SECRETS_FILE" 2>/dev/null || true
        echo "${var_name}=${input_val}" >> "$SECRETS_FILE"
        ok "$display_name 已写入"
    elif [[ "$required" == "required" ]]; then
        warn "$display_name 未配置，功能可能不可用"
    else
        echo -e "${YELLOW}[!] 已跳过${NC}"
    fi
}

configure_api_keys() {
    log "检查 API 密钥配置..."
    touch "$SECRETS_FILE"

    write_key "ZHIPU_API_KEY" "智谱 API Key" \
        "获取地址: https://open.bigmodel.cn/usercenter/apikeys" "required"

    write_key "DINGTALK_ACCESS_TOKEN" "钉钉 Access Token" \
        "获取地址: 钉钉开放平台 → 应用 → 机器人 → 凭证"

    write_key "DINGTALK_SECRET" "钉钉 Secret" ""

    write_key "GEMINI_API_KEY" "Gemini API Key（备用模型）" ""
}

# ══════════════════════════════════════════════════════════════════
#  第四阶段：启动并验证
# ══════════════════════════════════════════════════════════════════

start_and_verify() {
    log "启动 OpenFang daemon..."

    # 停止已有实例
    curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
    pkill -f "openfang start" 2>/dev/null || true
    sleep 3

    # 加载密钥并启动
    source "$SECRETS_FILE" 2>/dev/null || true
    "$OPENFANG_BIN" start > /tmp/openfang.log 2>&1 &
    sleep 5

    if curl -s http://127.0.0.1:4200/api/health | grep -q '"ok"'; then
        ok "OpenFang 已启动"
    else
        warn "daemon 可能未完全启动，请检查 /tmp/openfang.log"
        return
    fi

    # 验证 agent
    local agent_count
    agent_count=$(curl -s http://127.0.0.1:4200/api/agents | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [[ "$agent_count" -gt 0 ]]; then
        ok "Agent 已就绪 (共 ${agent_count} 个)"
    else
        log "尝试手动创建 agent..."
        curl -s -X POST http://127.0.0.1:4200/api/agents/spawn-by-name \
          -H "Content-Type: application/json" \
          -d '{"name": "assistant"}' >/dev/null 2>&1
        sleep 2
        agent_count=$(curl -s http://127.0.0.1:4200/api/agents | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [[ "$agent_count" -gt 0 ]]; then
            ok "Agent 已创建"
        else
            warn "Agent 创建失败，请在 Dashboard 手动创建"
        fi
    fi

    # 验证钉钉
    sleep 2
    if grep -q "Stream connected" /tmp/openfang.log 2>/dev/null; then
        ok "钉钉 Stream 已连接"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  主流程
# ══════════════════════════════════════════════════════════════════

main() {
    local force=false
    local no_patch=false
    local check_only=false

    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --no-patch) no_patch=true ;;
            --check) check_only=true ;;
            --help|-h)
                echo "用法: $0 [--no-patch] [--force] [--check]"
                echo ""
                echo "  无参数       安装 OpenFang + DingTalk 补丁 + 定制配置"
                echo "  --no-patch   跳过 DingTalk Stream 补丁（不需要 Rust）"
                echo "  --force      强制重新编译补丁"
                echo "  --check      只检查版本"
                exit 0
                ;;
        esac
    done

    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║   OpenFang 一键安装 + 定制配置            ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""

    # --check 模式
    if [[ "$check_only" == true ]]; then
        if [[ -f "$OPENFANG_BIN" ]]; then
            local ver
            ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
            log "本地版本: $ver"
            if [[ -f "$OPENFANG_HOME/.dingtalk_patched" ]]; then
                log "DingTalk 补丁版本: $(cat "$OPENFANG_HOME/.dingtalk_patched")"
            else
                log "DingTalk 补丁: 未安装"
            fi
        else
            log "OpenFang 未安装"
        fi
        exit 0
    fi

    # ── 第一阶段：安装 ──
    log "═══ 第一阶段：安装 OpenFang ═══"
    echo ""
    install_openfang
    init_openfang
    echo ""

    # ── 第二阶段：DingTalk 补丁 ──
    if [[ "$no_patch" == true ]]; then
        log "跳过 DingTalk Stream 补丁 (--no-patch)"
    else
        log "═══ 第二阶段：DingTalk Stream 补丁 ═══"
        echo ""
        apply_dingtalk_patch "$force"
    fi
    echo ""

    # ── 第三阶段：定制配置 ──
    log "═══ 第三阶段：定制配置 ═══"
    echo ""
    configure_config_toml
    echo ""
    configure_agent_toml
    echo ""
    configure_api_keys
    echo ""

    # ── 第四阶段：启动验证 ──
    log "═══ 第四阶段：启动并验证 ═══"
    echo ""
    start_and_verify

    # ── 完成 ──
    local final_ver
    final_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
    local patch_status="未安装"
    if [[ -f "$OPENFANG_HOME/.dingtalk_patched" ]]; then
        patch_status="已启用"
    fi

    echo ""
    echo "  ╔════════════════════════════════════════╗"
    echo "  ║            安装完成!                    ║"
    echo "  ║  版本: v${final_ver}                        ║"
    echo "  ║  模型: glm-5 (智谱 Coding API)          ║"
    echo "  ║  DingTalk Stream: ${patch_status}              ║"
    echo "  ║  Shell: 全权限 · 审批: 已关闭           ║"
    echo "  ╚════════════════════════════════════════╝"
    echo ""
}

main "$@"
