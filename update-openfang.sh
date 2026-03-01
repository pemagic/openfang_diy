#!/usr/bin/env bash
#
# OpenFang 自动更新脚本
# 功能：拉取最新源码 → 替换 dingtalk.rs 为 Stream 版本 → 编译 → 替换二进制
#
# 使用方法：
#   ~/.openfang/update-openfang.sh          # 正常更新
#   ~/.openfang/update-openfang.sh --force  # 跳过版本检查强制更新
#   ~/.openfang/update-openfang.sh --check  # 只检查是否有新版本

set -euo pipefail

# ── 配置 ─────────────────────────────────────────────────────────
OPENFANG_HOME="$HOME/.openfang"
OPENFANG_BIN="$OPENFANG_HOME/bin/openfang"
PATCH_FILE="$OPENFANG_HOME/patches/dingtalk_stream.rs"
BUILD_DIR="/tmp/openfang-build"
REPO_URL="https://github.com/RightNow-AI/openfang.git"
DINGTALK_TARGET="crates/openfang-channels/src/dingtalk.rs"
LOG_FILE="$OPENFANG_HOME/update.log"

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }

# ── 前置检查 ──────────────────────────────────────────────────────
preflight() {
    # 检查 Rust 工具链
    if ! command -v cargo &>/dev/null; then
        err "未找到 cargo。请先安装 Rust: https://rustup.rs"
        exit 1
    fi

    # 检查 git
    if ! command -v git &>/dev/null; then
        err "未找到 git"
        exit 1
    fi

    # 检查 patch 文件
    if [[ ! -f "$PATCH_FILE" ]]; then
        err "未找到 DingTalk Stream 补丁文件: $PATCH_FILE"
        err "请确保已将 dingtalk_stream.rs 放在 $OPENFANG_HOME/patches/ 目录下"
        exit 1
    fi

    # 检查当前二进制
    if [[ ! -f "$OPENFANG_BIN" ]]; then
        err "未找到 OpenFang 二进制: $OPENFANG_BIN"
        exit 1
    fi
}

# ── 确保 DingTalk 配置完整 ────────────────────────────────────────
ensure_dingtalk_config() {
    local config="$OPENFANG_HOME/config.toml"

    if [[ ! -f "$config" ]]; then
        warn "config.toml 不存在，将创建基础配置"
        cat > "$config" <<'TOML'
api_listen = "127.0.0.1:4200"

[channels.dingtalk]
default_agent = "assistant"
TOML
        ok "已创建 config.toml"
        return
    fi

    # 确保 [channels.dingtalk] 段存在
    if ! grep -q '^\[channels\.dingtalk\]' "$config"; then
        log "添加 [channels.dingtalk] 配置段..."
        printf '\n[channels.dingtalk]\ndefault_agent = "assistant"\n' >> "$config"
        ok "已添加 DingTalk 配置段"
        return
    fi

    # [channels.dingtalk] 存在但没有 default_agent
    if ! grep -A5 '^\[channels\.dingtalk\]' "$config" | grep -q 'default_agent'; then
        log "添加 default_agent 配置..."
        sed -i '' '/^\[channels\.dingtalk\]/a\
default_agent = "assistant"
' "$config"
        ok "已添加 default_agent = \"assistant\""
    fi
}

# ── 获取版本号 ────────────────────────────────────────────────────
get_local_version() {
    "$OPENFANG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"
}

get_remote_version() {
    git ls-remote --tags "$REPO_URL" 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V \
        | tail -1 \
        | tr -d 'v' \
        || echo "unknown"
}

# ── 适配性检查 ────────────────────────────────────────────────────
check_compatibility() {
    local src_dir="$1"
    local issues=0

    log "正在检查适配性..."

    # 1. 检查 ChannelAdapter trait 签名是否变了
    if ! grep -q "fn name(&self) -> &str" "$src_dir/crates/openfang-channels/src/types.rs" 2>/dev/null \
        && ! grep -q "fn name(&self) -> &str" "$src_dir/crates/openfang-channels/src/lib.rs" 2>/dev/null; then
        warn "ChannelAdapter trait 的 name() 签名可能已变更"
        ((issues++)) || true
    fi

    # 2. 检查 DingTalkAdapter::new 在 bridge 中的调用方式
    if grep -q "DingTalkAdapter::new" "$src_dir/crates/openfang-api/src/channel_bridge.rs" 2>/dev/null; then
        local call_sig
        call_sig=$(grep "DingTalkAdapter::new" "$src_dir/crates/openfang-api/src/channel_bridge.rs")
        # 检查是否还是 3 参数调用
        local comma_count
        comma_count=$(echo "$call_sig" | tr -cd ',' | wc -c | tr -d ' ')
        if [[ "$comma_count" -ne 2 ]]; then
            warn "DingTalkAdapter::new() 的参数数量已从 3 个变为其他数量"
            ((issues++)) || true
        fi
    else
        warn "未在 channel_bridge.rs 中找到 DingTalkAdapter::new 调用"
        ((issues++)) || true
    fi

    # 3. 检查核心类型是否存在
    for type_name in "ChannelMessage" "ChannelUser" "ChannelContent" "ChannelType" "ChannelAdapter"; do
        if ! grep -rq "$type_name" "$src_dir/crates/openfang-channels/src/types.rs" 2>/dev/null; then
            warn "类型 $type_name 可能已移动或重命名"
            ((issues++)) || true
        fi
    done

    # 4. 检查依赖是否还在
    for dep in "tokio-tungstenite" "reqwest" "tokio-stream" "zeroize"; do
        if ! grep -q "$dep" "$src_dir/crates/openfang-channels/Cargo.toml" 2>/dev/null; then
            warn "依赖 $dep 已从 Cargo.toml 中移除"
            ((issues++)) || true
        fi
    done

    # 5. 检查原始 dingtalk.rs 是否有重大变更（对比关键函数签名）
    local orig="$src_dir/$DINGTALK_TARGET"
    if [[ -f "$orig" ]]; then
        # 检查 pub fn new 签名
        if ! grep -q "pub fn new(access_token: String, secret: String" "$orig"; then
            warn "原始 dingtalk.rs 的 new() 签名已变更，需要手动适配"
            ((issues++)) || true
        fi
    fi

    if [[ $issues -gt 0 ]]; then
        warn "发现 $issues 个潜在适配问题"
        return 1
    fi

    ok "适配性检查通过"
    return 0
}

# ── 主流程 ────────────────────────────────────────────────────────
main() {
    local force=false
    local check_only=false

    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            --check) check_only=true ;;
            --help|-h)
                echo "用法: $0 [--force] [--check]"
                echo "  --force  跳过版本检查强制更新"
                echo "  --check  只检查是否有新版本"
                exit 0
                ;;
        esac
    done

    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   OpenFang 自动更新 (DingTalk Stream) ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    preflight

    # ── 确保 config.toml 中 DingTalk 配置完整 ──
    ensure_dingtalk_config

    local local_ver
    local_ver=$(get_local_version)
    log "当前本地版本: $local_ver"

    log "正在检查远程版本..."
    local remote_ver
    remote_ver=$(get_remote_version)
    log "最新远程版本: $remote_ver"

    if [[ "$check_only" == true ]]; then
        if [[ "$local_ver" == "$remote_ver" ]]; then
            ok "已是最新版本 ($local_ver)"
        else
            log "有新版本可用: $local_ver → $remote_ver"
        fi
        exit 0
    fi

    if [[ "$local_ver" == "$remote_ver" && "$force" != true ]]; then
        ok "已是最新版本 ($local_ver)，无需更新"
        log "使用 --force 强制重新编译"
        exit 0
    fi

    log "准备更新: $local_ver → $remote_ver"

    # ── 克隆源码 ──
    log "正在克隆源码..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 "$REPO_URL" "$BUILD_DIR" 2>&1 | tail -2
    ok "源码克隆完成"

    # ── 适配性检查 ──
    if ! check_compatibility "$BUILD_DIR"; then
        if [[ "$force" != true ]]; then
            err "适配性检查未通过。使用 --force 跳过检查（可能编译失败）"
            err "如果编译失败，请手动对比上游 dingtalk.rs 的变更并更新补丁文件"
            exit 1
        fi
        warn "强制模式：跳过适配性检查"
    fi

    # ── 替换 dingtalk.rs ──
    log "正在替换 dingtalk.rs 为 Stream 版本..."
    # 先备份上游原版
    cp "$BUILD_DIR/$DINGTALK_TARGET" "$OPENFANG_HOME/patches/dingtalk_upstream_latest.rs"
    # 用我们的 Stream 版本替换
    cp "$PATCH_FILE" "$BUILD_DIR/$DINGTALK_TARGET"
    ok "dingtalk.rs 已替换"

    # ── 编译 ──
    log "正在编译 (release mode)，这可能需要几分钟..."
    cd "$BUILD_DIR"

    if ! cargo build --release -p openfang-cli 2>&1 | tee -a "$LOG_FILE" | tail -5; then
        err "编译失败！完整日志: $LOG_FILE"
        err "可能原因: 上游 API 变更导致我们的 dingtalk.rs 不兼容"
        err "请对比检查:"
        err "  上游原版: $OPENFANG_HOME/patches/dingtalk_upstream_latest.rs"
        err "  我们的版本: $PATCH_FILE"
        exit 1
    fi
    ok "编译成功"

    # ── 停止服务 ──
    log "正在停止 OpenFang 服务..."
    "$OPENFANG_BIN" stop 2>/dev/null || true
    sleep 2
    pkill -f "openfang start" 2>/dev/null || true
    sleep 1

    # ── 替换二进制 ──
    log "正在替换二进制..."
    # 备份当前版本
    cp "$OPENFANG_BIN" "$OPENFANG_BIN.bak.$(date +%Y%m%d%H%M%S)"
    # 只保留最近 3 个备份
    ls -t "$OPENFANG_HOME/bin/openfang.bak."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    # 替换
    cp "$BUILD_DIR/target/release/openfang" "$OPENFANG_BIN"
    chmod +x "$OPENFANG_BIN"
    ok "二进制已替换"

    # ── 重启服务 ──
    log "正在启动 OpenFang..."
    "$OPENFANG_BIN" start &
    sleep 5

    # 验证
    if curl -s http://127.0.0.1:4200/api/health | grep -q '"ok"'; then
        ok "OpenFang 启动成功"
    else
        warn "OpenFang 可能未完全启动，请检查日志"
    fi

    local new_ver
    new_ver=$(get_local_version)

    # ── 清理 ──
    log "正在清理编译目录..."
    rm -rf "$BUILD_DIR"
    ok "清理完成"

    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║         更新完成!                      ║"
    echo "  ║  版本: $local_ver → $new_ver              ║"
    echo "  ║  DingTalk Stream 模式: 已启用          ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    # 记录更新日志
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated $local_ver → $new_ver (dingtalk stream patched)" >> "$LOG_FILE"
}

main "$@"
