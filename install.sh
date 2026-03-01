#!/usr/bin/env bash
#
# OpenFang 一键安装/更新脚本（含 DingTalk Stream 补丁 + 自动配置）
#
# 用法：
#   ./install.sh                # 首次安装或更新
#   ./install.sh --force        # 跳过版本检查强制重新编译
#   ./install.sh --check        # 只检查是否有新版本
#
# 流程：
#   1. 前置检查（Rust/git）
#   2. 克隆源码 → 替换 dingtalk.rs → 编译
#   3. 安装二进制到 ~/.openfang/bin/
#   4. 配置安全策略（仅缺失时补充，不覆盖已有配置）
#   5. 配置 agent（仅修改关键字段，不动 system_prompt）
#   6. 配置 API Key（仅未配置时交互式输入）
#   7. 启动 daemon 并验证
#

set -euo pipefail

# ── 配置 ─────────────────────────────────────────────────────────
OPENFANG_HOME="$HOME/.openfang"
OPENFANG_BIN="$OPENFANG_HOME/bin/openfang"
BUILD_DIR="/tmp/openfang-build"
REPO_URL="https://github.com/RightNow-AI/openfang.git"
DINGTALK_TARGET="crates/openfang-channels/src/dingtalk.rs"
LOG_FILE="$OPENFANG_HOME/update.log"
CONFIG="$OPENFANG_HOME/config.toml"
AGENT_DIR="$OPENFANG_HOME/agents/assistant"
AGENT_TOML="$AGENT_DIR/agent.toml"
SECRETS_FILE="$OPENFANG_HOME/secrets.env"

# 补丁文件：优先用脚本同目录下的，其次用 ~/.openfang/patches/ 下的，最后从 GitHub 下载
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_GITHUB_URL="https://raw.githubusercontent.com/pemagic/openfang_diy/main/patches/dingtalk_stream.rs"

if [[ -f "$SCRIPT_DIR/patches/dingtalk_stream.rs" ]]; then
    PATCH_FILE="$SCRIPT_DIR/patches/dingtalk_stream.rs"
elif [[ -f "$OPENFANG_HOME/patches/dingtalk_stream.rs" ]]; then
    PATCH_FILE="$OPENFANG_HOME/patches/dingtalk_stream.rs"
else
    # 自动从 GitHub 下载补丁文件
    PATCH_FILE="$OPENFANG_HOME/patches/dingtalk_stream.rs"
    mkdir -p "$OPENFANG_HOME/patches"
    if curl -sfL "$PATCH_GITHUB_URL" -o "$PATCH_FILE" 2>/dev/null && [[ -s "$PATCH_FILE" ]]; then
        : # 下载成功，在 preflight 后会提示
    else
        PATCH_FILE=""
    fi
fi

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

# ── 判断安装模式 ─────────────────────────────────────────────────
IS_FRESH_INSTALL=false
if [[ ! -f "$OPENFANG_BIN" ]]; then
    IS_FRESH_INSTALL=true
fi

# ══════════════════════════════════════════════════════════════════
#  第一阶段：编译安装
# ══════════════════════════════════════════════════════════════════

preflight() {
    if ! command -v cargo &>/dev/null; then
        err "未找到 cargo。请先安装 Rust: https://rustup.rs"
        exit 1
    fi
    if ! command -v git &>/dev/null; then
        err "未找到 git"
        exit 1
    fi
    if [[ -z "$PATCH_FILE" ]]; then
        err "未找到 DingTalk Stream 补丁文件"
        err "请将 dingtalk_stream.rs 放在以下任一位置："
        err "  $SCRIPT_DIR/patches/dingtalk_stream.rs"
        err "  $OPENFANG_HOME/patches/dingtalk_stream.rs"
        exit 1
    fi
}

get_local_version() {
    if [[ -f "$OPENFANG_BIN" ]]; then
        "$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "未安装"
    else
        echo "未安装"
    fi
}

get_remote_version() {
    git ls-remote --tags "$REPO_URL" 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V \
        | tail -1 \
        | tr -d 'v' \
        || echo "unknown"
}

check_compatibility() {
    local src_dir="$1"
    local issues=0

    log "正在检查补丁适配性..."

    if ! grep -q "fn name(&self) -> &str" "$src_dir/crates/openfang-channels/src/types.rs" 2>/dev/null \
        && ! grep -q "fn name(&self) -> &str" "$src_dir/crates/openfang-channels/src/lib.rs" 2>/dev/null; then
        warn "ChannelAdapter trait 的 name() 签名可能已变更"
        ((issues++)) || true
    fi

    if grep -q "DingTalkAdapter::new" "$src_dir/crates/openfang-api/src/channel_bridge.rs" 2>/dev/null; then
        local comma_count
        comma_count=$(grep "DingTalkAdapter::new" "$src_dir/crates/openfang-api/src/channel_bridge.rs" | tr -cd ',' | wc -c | tr -d ' ')
        if [[ "$comma_count" -ne 2 ]]; then
            warn "DingTalkAdapter::new() 的参数数量已变更"
            ((issues++)) || true
        fi
    else
        warn "未在 channel_bridge.rs 中找到 DingTalkAdapter::new 调用"
        ((issues++)) || true
    fi

    for type_name in "ChannelMessage" "ChannelUser" "ChannelContent" "ChannelType" "ChannelAdapter"; do
        if ! grep -rq "$type_name" "$src_dir/crates/openfang-channels/src/types.rs" 2>/dev/null; then
            warn "类型 $type_name 可能已移动或重命名"
            ((issues++)) || true
        fi
    done

    for dep in "tokio-tungstenite" "reqwest" "tokio-stream" "zeroize"; do
        if ! grep -q "$dep" "$src_dir/crates/openfang-channels/Cargo.toml" 2>/dev/null; then
            warn "依赖 $dep 已从 Cargo.toml 中移除"
            ((issues++)) || true
        fi
    done

    if [[ $issues -gt 0 ]]; then
        warn "发现 $issues 个潜在适配问题"
        return 1
    fi

    ok "适配性检查通过"
    return 0
}

build_and_install() {
    local force="$1"

    local local_ver
    local_ver=$(get_local_version)
    log "当前本地版本: $local_ver"

    log "正在检查远程版本..."
    local remote_ver
    remote_ver=$(get_remote_version)
    log "最新远程版本: $remote_ver"

    if [[ "$IS_FRESH_INSTALL" == false && "$local_ver" == "$remote_ver" && "$force" != true ]]; then
        ok "已是最新版本 ($local_ver)，跳过编译"
        return 0
    fi

    if [[ "$IS_FRESH_INSTALL" == true ]]; then
        log "首次安装，开始编译..."
    else
        log "准备更新: $local_ver → $remote_ver"
    fi

    # 克隆源码
    log "正在克隆源码..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 "$REPO_URL" "$BUILD_DIR" 2>&1 | tail -2
    ok "源码克隆完成"

    # 适配性检查
    if ! check_compatibility "$BUILD_DIR"; then
        if [[ "$force" != true ]]; then
            err "适配性检查未通过。使用 --force 跳过检查"
            exit 1
        fi
        warn "强制模式：跳过适配性检查"
    fi

    # 替换 dingtalk.rs
    log "正在替换 dingtalk.rs 为 Stream 版本..."
    mkdir -p "$OPENFANG_HOME/patches"
    cp "$BUILD_DIR/$DINGTALK_TARGET" "$OPENFANG_HOME/patches/dingtalk_upstream_latest.rs"
    cp "$PATCH_FILE" "$BUILD_DIR/$DINGTALK_TARGET"
    ok "dingtalk.rs 已替换"

    # 编译
    log "正在编译 (release mode)，这可能需要几分钟..."
    cd "$BUILD_DIR"
    if ! cargo build --release -p openfang-cli 2>&1 | tee -a "$LOG_FILE" | tail -5; then
        err "编译失败！完整日志: $LOG_FILE"
        err "请对比检查:"
        err "  上游原版: $OPENFANG_HOME/patches/dingtalk_upstream_latest.rs"
        err "  我们的版本: $PATCH_FILE"
        exit 1
    fi
    ok "编译成功"

    # 停止运行中的服务
    if [[ "$IS_FRESH_INSTALL" == false ]]; then
        log "正在停止 OpenFang 服务..."
        curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
        sleep 2
        pkill -f "openfang start" 2>/dev/null || true
        sleep 1
    fi

    # 安装二进制
    log "正在安装二进制..."
    mkdir -p "$OPENFANG_HOME/bin"
    if [[ -f "$OPENFANG_BIN" ]]; then
        cp "$OPENFANG_BIN" "$OPENFANG_BIN.bak.$(date +%Y%m%d%H%M%S)"
        ls -t "$OPENFANG_HOME/bin/openfang.bak."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi
    cp "$BUILD_DIR/target/release/openfang" "$OPENFANG_BIN"
    chmod +x "$OPENFANG_BIN"
    ok "二进制已安装到 $OPENFANG_BIN"

    # 清理
    log "正在清理编译目录..."
    rm -rf "$BUILD_DIR"
    ok "清理完成"

    local new_ver
    new_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installed $local_ver → $new_ver (dingtalk stream patched)" >> "$LOG_FILE"
}

# ══════════════════════════════════════════════════════════════════
#  第二阶段：配置（仅补充缺失项，不覆盖已有配置）
# ══════════════════════════════════════════════════════════════════

configure_config_toml() {
    log "检查 config.toml..."

    # 首次安装：创建基础 config.toml
    if [[ ! -f "$CONFIG" ]]; then
        log "创建基础 config.toml..."
        cat > "$CONFIG" <<'TOML'
api_listen = "127.0.0.1:4200"
TOML
        ok "已创建 config.toml"
    fi

    # [approval] — 仅缺失时添加
    if ! grep -q '^\[approval\]' "$CONFIG"; then
        printf '\n[approval]\nrequire_approval = false\n' >> "$CONFIG"
        ok "已添加 [approval] require_approval = false"
    else
        ok "[approval] 已存在，跳过"
    fi

    # [exec_policy] — 仅缺失时添加
    if ! grep -q '^\[exec_policy\]' "$CONFIG"; then
        printf '\n[exec_policy]\nmode = "full"\n' >> "$CONFIG"
        ok "已添加 [exec_policy] mode = \"full\""
    else
        ok "[exec_policy] 已存在，跳过"
    fi

    # [channels.dingtalk] — 仅缺失时添加
    if ! grep -q '^\[channels\.dingtalk\]' "$CONFIG"; then
        printf '\n[channels.dingtalk]\ndefault_agent = "assistant"\n' >> "$CONFIG"
        ok "已添加 [channels.dingtalk]"
    else
        ok "[channels.dingtalk] 已存在，跳过"
    fi

    # provider_urls.zhipu_coding — 仅缺失时添加
    if ! grep -q 'zhipu_coding' "$CONFIG"; then
        printf '\n[provider_urls]\nzhipu_coding = "https://open.bigmodel.cn/api/coding/paas/v4"\n' >> "$CONFIG"
        ok "已添加 zhipu_coding provider URL"
    else
        ok "zhipu_coding provider URL 已存在，跳过"
    fi
}

configure_agent_toml() {
    log "检查 assistant agent.toml..."
    mkdir -p "$AGENT_DIR"

    if [[ ! -f "$AGENT_TOML" ]]; then
        log "agent.toml 不存在，等待首次启动后自动生成..."
        # 首次启动 daemon 会从内置模板创建 agent，之后再修改
        return 1  # 标记需要后续处理
    fi

    ok "agent.toml 已存在，检查关键字段..."

    # 用 python3 精确修改关键字段，不动其他内容
    python3 - "$AGENT_TOML" <<'PYEOF'
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
        if stripped == '[model]':
            in_model = True
        else:
            in_model = False
        if stripped == '[exec_policy]':
            has_exec_policy = True

    if in_model:
        if re.match(r'provider\s*=', stripped):
            if '"zhipu_coding"' not in stripped:
                line = 'provider = "zhipu_coding"'
                changed = True
        elif re.match(r'model\s*=', stripped):
            if '"glm-5"' not in stripped:
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

if not has_exec_policy:
    content = content.replace('[resources]', '[exec_policy]\nmode = "full"\n\n[resources]')
    changed = True

# 检查 shell 权限
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
    result=$(python3 - "$AGENT_TOML" <<'PYEOF2'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# 快速检查关键字段
checks = [
    '"zhipu_coding"' in content,
    '"glm-5"' in content,
    '"ZHIPU_API_KEY"' in content,
    '[exec_policy]' in content,
    'shell = ["*"]' in content,
]
if all(checks):
    print("ALL_OK")
else:
    missing = []
    labels = ["provider", "model", "api_key_env", "exec_policy", "shell"]
    for i, ok in enumerate(checks):
        if not ok:
            missing.append(labels[i])
    print("MISSING:" + ",".join(missing))
PYEOF2
    )

    if [[ "$result" == "ALL_OK" ]]; then
        ok "agent.toml 关键字段均已正确配置"
    else
        warn "agent.toml 部分字段需要检查: ${result#MISSING:}"
    fi

    return 0
}

configure_api_keys() {
    log "检查 API 密钥配置..."
    touch "$SECRETS_FILE"

    local all_configured=true

    # ZHIPU_API_KEY
    if grep -q "ZHIPU_API_KEY=.\+" "$SECRETS_FILE" 2>/dev/null; then
        ok "ZHIPU_API_KEY 已配置"
    else
        all_configured=false
        echo -e "${YELLOW}[?] 请输入智谱 API Key（用于 GLM-5 模型）：${NC}"
        echo -e "    获取地址: https://open.bigmodel.cn/usercenter/apikeys"
        read -rp "    ZHIPU_API_KEY: " zhipu_key
        if [[ -n "$zhipu_key" ]]; then
            sed -i '' '/^ZHIPU_API_KEY=/d' "$SECRETS_FILE" 2>/dev/null || true
            echo "ZHIPU_API_KEY=$zhipu_key" >> "$SECRETS_FILE"
            ok "ZHIPU_API_KEY 已写入"
        else
            echo -e "${YELLOW}[!] 已跳过${NC}"
        fi
    fi

    # DINGTALK_ACCESS_TOKEN
    if grep -q "DINGTALK_ACCESS_TOKEN=.\+" "$SECRETS_FILE" 2>/dev/null; then
        ok "DINGTALK_ACCESS_TOKEN 已配置"
    else
        all_configured=false
        echo -e "${YELLOW}[?] 请输入钉钉机器人 Access Token（留空跳过）：${NC}"
        echo -e "    获取地址: 钉钉开放平台 → 应用 → 机器人 → 凭证"
        read -rp "    DINGTALK_ACCESS_TOKEN: " dt_token
        if [[ -n "$dt_token" ]]; then
            sed -i '' '/^DINGTALK_ACCESS_TOKEN=/d' "$SECRETS_FILE" 2>/dev/null || true
            echo "DINGTALK_ACCESS_TOKEN=$dt_token" >> "$SECRETS_FILE"
            ok "DINGTALK_ACCESS_TOKEN 已写入"
        else
            echo -e "${YELLOW}[!] 已跳过${NC}"
        fi
    fi

    # DINGTALK_SECRET
    if grep -q "DINGTALK_SECRET=.\+" "$SECRETS_FILE" 2>/dev/null; then
        ok "DINGTALK_SECRET 已配置"
    else
        all_configured=false
        echo -e "${YELLOW}[?] 请输入钉钉机器人 Secret（留空跳过）：${NC}"
        read -rp "    DINGTALK_SECRET: " dt_secret
        if [[ -n "$dt_secret" ]]; then
            sed -i '' '/^DINGTALK_SECRET=/d' "$SECRETS_FILE" 2>/dev/null || true
            echo "DINGTALK_SECRET=$dt_secret" >> "$SECRETS_FILE"
            ok "DINGTALK_SECRET 已写入"
        else
            echo -e "${YELLOW}[!] 已跳过${NC}"
        fi
    fi

    # GEMINI_API_KEY
    if grep -q "GEMINI_API_KEY=.\+" "$SECRETS_FILE" 2>/dev/null; then
        ok "GEMINI_API_KEY 已配置"
    else
        all_configured=false
        echo -e "${YELLOW}[?] 请输入 Gemini API Key（备用模型，留空跳过）：${NC}"
        read -rp "    GEMINI_API_KEY: " gemini_key
        if [[ -n "$gemini_key" ]]; then
            sed -i '' '/^GEMINI_API_KEY=/d' "$SECRETS_FILE" 2>/dev/null || true
            echo "GEMINI_API_KEY=$gemini_key" >> "$SECRETS_FILE"
            ok "GEMINI_API_KEY 已写入"
        else
            echo -e "${YELLOW}[!] 已跳过${NC}"
        fi
    fi

    if [[ "$all_configured" == true ]]; then
        ok "所有 API 密钥均已配置，无需输入"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  第三阶段：启动并验证
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

    # 验证健康
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
        warn "Agent 未自动创建，尝试手动 spawn..."
        curl -s -X POST http://127.0.0.1:4200/api/agents/spawn-by-name \
          -H "Content-Type: application/json" \
          -d '{"name": "assistant"}' >/dev/null 2>&1
        sleep 2
        ok "已手动 spawn assistant agent"
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
    local check_only=false

    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --check) check_only=true ;;
            --help|-h)
                echo "用法: $0 [--force] [--check]"
                echo ""
                echo "  无参数     首次安装或检测更新并安装"
                echo "  --force    跳过版本检查强制重新编译"
                echo "  --check    只检查是否有新版本"
                exit 0
                ;;
        esac
    done

    echo ""
    if [[ "$IS_FRESH_INSTALL" == true ]]; then
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║   OpenFang 一键安装 (DingTalk Stream)     ║"
        echo "  ╚══════════════════════════════════════════╝"
    else
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║   OpenFang 更新检查 (DingTalk Stream)     ║"
        echo "  ╚══════════════════════════════════════════╝"
    fi
    echo ""

    preflight

    # --check 模式
    if [[ "$check_only" == true ]]; then
        local local_ver remote_ver
        local_ver=$(get_local_version)
        remote_ver=$(get_remote_version)
        log "本地版本: $local_ver"
        log "远程版本: $remote_ver"
        if [[ "$local_ver" == "$remote_ver" ]]; then
            ok "已是最新版本"
        else
            log "有新版本可用: $local_ver → $remote_ver"
        fi
        exit 0
    fi

    # ── 第一阶段：编译安装 ──
    mkdir -p "$OPENFANG_HOME"
    build_and_install "$force"

    # ── 第二阶段：配置 ──
    echo ""
    log "═══ 开始配置检查 ═══"
    echo ""

    configure_config_toml
    echo ""

    # 如果 agent.toml 不存在，先启动一次让 daemon 生成默认模板
    if ! configure_agent_toml; then
        log "首次启动 daemon 以生成 agent 模板..."
        source "$SECRETS_FILE" 2>/dev/null || true
        "$OPENFANG_BIN" start > /tmp/openfang.log 2>&1 &
        sleep 5
        curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
        sleep 2
        pkill -f "openfang start" 2>/dev/null || true
        sleep 1

        if [[ -f "$AGENT_TOML" ]]; then
            ok "agent.toml 已由 daemon 自动生成"
            configure_agent_toml
        else
            warn "agent.toml 仍未生成，请手动检查"
        fi
    fi
    echo ""

    configure_api_keys
    echo ""

    # ── 第三阶段：启动验证 ──
    log "═══ 启动并验证 ═══"
    echo ""
    start_and_verify

    # ── 完成 ──
    local final_ver
    final_ver=$("$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")

    echo ""
    echo "  ╔════════════════════════════════════════╗"
    echo "  ║            安装/更新完成!               ║"
    echo "  ║  版本: $final_ver                           ║"
    echo "  ║  模型: glm-5 (智谱 Coding API)          ║"
    echo "  ║  DingTalk Stream: 已启用                ║"
    echo "  ║  Shell: 全权限 · 审批: 已关闭           ║"
    echo "  ╚════════════════════════════════════════╝"
    echo ""
}

main "$@"
