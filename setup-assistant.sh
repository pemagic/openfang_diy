#!/usr/bin/env bash
#
# OpenFang 助手 Agent 一键配置脚本
# 用法: ~/.openfang/setup-assistant.sh
#
# 功能：
#   1. 配置全局安全策略（关闭审批、开放 shell）
#   2. 创建/覆盖 assistant agent（glm-5 + 全权限）
#   3. 重启 daemon 使配置生效
#

set -euo pipefail

OPENFANG_HOME="$HOME/.openfang"
CONFIG="$OPENFANG_HOME/config.toml"
AGENT_DIR="$OPENFANG_HOME/agents/assistant"
AGENT_TOML="$AGENT_DIR/agent.toml"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
log() { echo -e "${YELLOW}[>>]${NC} $1"; }

# ── 1. 修改 config.toml ──────────────────────────────────────────

log "检查 config.toml 安全策略..."

# 添加 [approval] 段（如果不存在）
if ! grep -q '^\[approval\]' "$CONFIG" 2>/dev/null; then
    printf '\n[approval]\nrequire_approval = false\n' >> "$CONFIG"
    ok "已添加 [approval] require_approval = false"
else
    # 确保 require_approval = false
    sed -i '' 's/require_approval = true/require_approval = false/' "$CONFIG"
    ok "[approval] 已存在，确认 require_approval = false"
fi

# 添加 [exec_policy] 段（如果不存在）
if ! grep -q '^\[exec_policy\]' "$CONFIG" 2>/dev/null; then
    printf '\n[exec_policy]\nmode = "full"\n' >> "$CONFIG"
    ok "已添加 [exec_policy] mode = \"full\""
else
    # 确保 mode = "full"
    sed -i '' '/^\[exec_policy\]/,/^\[/{s/mode = "allowlist"/mode = "full"/; s/mode = "deny"/mode = "full"/}' "$CONFIG"
    ok "[exec_policy] 已存在，确认 mode = \"full\""
fi

# 确保 [channels.dingtalk] 段存在
if ! grep -q '^\[channels\.dingtalk\]' "$CONFIG" 2>/dev/null; then
    printf '\n[channels.dingtalk]\ndefault_agent = "assistant"\n' >> "$CONFIG"
    ok "已添加 [channels.dingtalk]"
fi

# 确保 provider_urls 包含 zhipu_coding
if ! grep -q 'zhipu_coding' "$CONFIG" 2>/dev/null; then
    printf '\n[provider_urls]\nzhipu_coding = "https://open.bigmodel.cn/api/coding/paas/v4"\n' >> "$CONFIG"
    ok "已添加 zhipu_coding provider URL"
fi

# ── 2. 创建 assistant agent.toml ─────────────────────────────────

log "创建 assistant agent..."
mkdir -p "$AGENT_DIR"

# 复制现有的 agent.toml 作为基础，只确保关键字段正确
if [[ -f "$AGENT_TOML" ]]; then
    log "agent.toml 已存在，检查关键配置..."
else
    log "未找到 agent.toml，从上游默认模板创建..."
    # 如果没有现成的，用上游默认的再改
    cp "$OPENFANG_HOME/agents/assistant/agent.toml" "$AGENT_TOML" 2>/dev/null || true
fi

# 确保 provider/model/api_key_env 正确（不动 system_prompt）
python3 - "$AGENT_TOML" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 确保 [model] 段的关键字段
replacements = {
    r'(provider\s*=\s*)"[^"]*"': r'\1"zhipu_coding"',
    r'(model\s*=\s*)"[^"]*"': None,  # 跳过，model 可能匹配多处
    r'(api_key_env\s*=\s*)"[^"]*"': None,  # 跳过
}

# 只在 [model] 段替换 provider
lines = content.split('\n')
in_model = False
has_api_key_env = False
has_exec_policy = False
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
            line = 'provider = "zhipu_coding"'
        elif re.match(r'model\s*=', stripped):
            line = 'model = "glm-5"'
        elif re.match(r'api_key_env\s*=', stripped):
            line = 'api_key_env = "ZHIPU_API_KEY"'
            has_api_key_env = True

    result.append(line)

content = '\n'.join(result)

# 如果 [model] 段没有 api_key_env，添加一行
if not has_api_key_env:
    content = content.replace('[model]\n', '[model]\napi_key_env = "ZHIPU_API_KEY"\n', 1)

# 如果没有 [exec_policy]，添加
if not has_exec_policy:
    content = content.replace('[resources]', '[exec_policy]\nmode = "full"\n\n[resources]')

# 确保 shell = ["*"]
content = re.sub(r'shell\s*=\s*\[.*?\]', 'shell = ["*"]', content)

with open(path, 'w') as f:
    f.write(content)

print("agent.toml 关键字段已更新")
PYEOF

ok "assistant agent.toml 已创建"

# ── 3. 配置 API 密钥 ─────────────────────────────────────────────

SECRETS_FILE="$OPENFANG_HOME/secrets.env"
touch "$SECRETS_FILE"

echo ""
log "检查 API 密钥配置..."

# ZHIPU_API_KEY
if grep -q "ZHIPU_API_KEY=.\+" "$SECRETS_FILE" 2>/dev/null; then
    ok "ZHIPU_API_KEY 已配置"
else
    echo -e "${YELLOW}[?] 请输入智谱 API Key（用于 GLM-5 模型）：${NC}"
    echo -e "    获取地址: https://open.bigmodel.cn/usercenter/apikeys"
    read -rp "    ZHIPU_API_KEY: " zhipu_key
    if [[ -n "$zhipu_key" ]]; then
        # 移除旧的空行（如果有）
        sed -i '' '/^ZHIPU_API_KEY=/d' "$SECRETS_FILE" 2>/dev/null || true
        echo "ZHIPU_API_KEY=$zhipu_key" >> "$SECRETS_FILE"
        ok "ZHIPU_API_KEY 已写入 secrets.env"
    else
        echo -e "${YELLOW}[!] 已跳过，稍后请手动添加到 $SECRETS_FILE${NC}"
    fi
fi

# DINGTALK_ACCESS_TOKEN
if grep -q "DINGTALK_ACCESS_TOKEN=.\+" "$SECRETS_FILE" 2>/dev/null; then
    ok "DINGTALK_ACCESS_TOKEN 已配置"
else
    echo -e "${YELLOW}[?] 请输入钉钉机器人 Access Token（留空跳过）：${NC}"
    echo -e "    获取地址: 钉钉开放平台 → 应用 → 机器人 → 凭证"
    read -rp "    DINGTALK_ACCESS_TOKEN: " dt_token
    if [[ -n "$dt_token" ]]; then
        sed -i '' '/^DINGTALK_ACCESS_TOKEN=/d' "$SECRETS_FILE" 2>/dev/null || true
        echo "DINGTALK_ACCESS_TOKEN=$dt_token" >> "$SECRETS_FILE"
        ok "DINGTALK_ACCESS_TOKEN 已写入 secrets.env"
    else
        echo -e "${YELLOW}[!] 已跳过钉钉 Token 配置${NC}"
    fi
fi

# DINGTALK_SECRET
if grep -q "DINGTALK_SECRET=.\+" "$SECRETS_FILE" 2>/dev/null; then
    ok "DINGTALK_SECRET 已配置"
else
    echo -e "${YELLOW}[?] 请输入钉钉机器人 Secret（留空跳过）：${NC}"
    read -rp "    DINGTALK_SECRET: " dt_secret
    if [[ -n "$dt_secret" ]]; then
        sed -i '' '/^DINGTALK_SECRET=/d' "$SECRETS_FILE" 2>/dev/null || true
        echo "DINGTALK_SECRET=$dt_secret" >> "$SECRETS_FILE"
        ok "DINGTALK_SECRET 已写入 secrets.env"
    else
        echo -e "${YELLOW}[!] 已跳过钉钉 Secret 配置${NC}"
    fi
fi

# GEMINI_API_KEY（fallback 模型用）
if grep -q "GEMINI_API_KEY=.\+" "$SECRETS_FILE" 2>/dev/null; then
    ok "GEMINI_API_KEY 已配置"
else
    echo -e "${YELLOW}[?] 请输入 Gemini API Key（备用模型，留空跳过）：${NC}"
    read -rp "    GEMINI_API_KEY: " gemini_key
    if [[ -n "$gemini_key" ]]; then
        sed -i '' '/^GEMINI_API_KEY=/d' "$SECRETS_FILE" 2>/dev/null || true
        echo "GEMINI_API_KEY=$gemini_key" >> "$SECRETS_FILE"
        ok "GEMINI_API_KEY 已写入 secrets.env"
    else
        echo -e "${YELLOW}[!] 已跳过 Gemini Key 配置${NC}"
    fi
fi

echo ""

# ── 4. 重启 daemon ───────────────────────────────────────────────

log "重启 OpenFang daemon..."

# 尝试优雅关闭
curl -s -X POST http://127.0.0.1:4200/api/shutdown >/dev/null 2>&1 || true
sleep 3

# 加载密钥并启动
source "$OPENFANG_HOME/secrets.env" 2>/dev/null || true
"$OPENFANG_HOME/bin/openfang" start > /tmp/openfang.log 2>&1 &
sleep 5

# 验证
if curl -s http://127.0.0.1:4200/api/health | grep -q '"ok"'; then
    ok "OpenFang 已启动"
else
    echo -e "${YELLOW}[!] daemon 可能未完全启动，请检查 /tmp/openfang.log${NC}"
fi

# 检查 agent
AGENT_COUNT=$(curl -s http://127.0.0.1:4200/api/agents | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ "$AGENT_COUNT" -gt 0 ]]; then
    ok "Agent 已就绪 (共 ${AGENT_COUNT} 个)"
else
    echo -e "${YELLOW}[!] Agent 未自动创建，尝试手动 spawn...${NC}"
    curl -s -X POST http://127.0.0.1:4200/api/agents/spawn-by-name \
      -H "Content-Type: application/json" \
      -d '{"name": "assistant"}' >/dev/null 2>&1
    sleep 2
    ok "已手动 spawn assistant agent"
fi

# 检查钉钉连接
sleep 2
if grep -q "Stream connected" /tmp/openfang.log 2>/dev/null; then
    ok "钉钉 Stream 已连接"
fi

echo ""
echo "  ╔════════════════════════════════════╗"
echo "  ║      Assistant Agent 配置完成!      ║"
echo "  ║  模型: glm-5 (智谱 Coding API)     ║"
echo "  ║  Shell: 全权限                      ║"
echo "  ║  审批: 已关闭                       ║"
echo "  ╚════════════════════════════════════╝"
echo ""
