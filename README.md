# OpenFang DIY

OpenFang 个人定制脚本：一键安装/更新 + DingTalk Stream 补丁 + 自动配置。

## 快速开始

一句话安装（从零开始，自动完成全部流程）：

```bash
curl -sL https://raw.githubusercontent.com/pemagic/openfang_diy/main/install.sh | bash
```

如果需要自动注入 API Key（无交互），可以提前设置环境变量：

```bash
export ZHIPU_API_KEY="your-key" DINGTALK_ACCESS_TOKEN="your-token" DINGTALK_SECRET="your-secret"
curl -sL https://raw.githubusercontent.com/pemagic/openfang_diy/main/install.sh | bash
```

更新时再跑一遍同样的命令，已有的配置和 Key 会自动跳过。

## 脚本做了什么

完整流程（7 个阶段，全自动）：

1. **环境准备** — 检查 Rust 和 Git，没有 Rust 会自动安装 rustup
2. **编译安装** — 克隆 OpenFang 源码 → 替换 DingTalk Stream 补丁 → 编译 → 安装二进制
3. **配置 PATH** — 写入 shell profile（.zshrc / .bashrc）
4. **初始化** — `openfang init --quick`（非交互），生成目录结构和 30 个 agent 模板
5. **定制配置** — 修改 config.toml 和 agent.toml（仅补充缺失项，不覆盖已有配置）
6. **API 密钥** — 从环境变量写入 / 交互式输入（已配置的自动跳过）
7. **启动验证** — 启动 daemon，检查 agent 和钉钉连接

```bash
./install.sh                # 首次安装或更新
./install.sh --force        # 强制重新编译
./install.sh --check        # 只检查版本
```

## 前置要求

- macOS / Linux
- Git（macOS: `xcode-select --install`）
- Rust 工具链 — 没有会自动安装
- API Key：智谱（必需）、钉钉（可选）、Gemini（可选）

## 配置的内容

| 配置项 | 文件 | 说明 |
|--------|------|------|
| `[default_model] provider = "zhipu_coding"` | config.toml | 默认模型改为智谱 |
| `[approval] require_approval = false` | config.toml | 关闭工具执行审批 |
| `[exec_policy] mode = "full"` | config.toml + agent.toml | 允许所有 shell 命令 |
| `[channels.dingtalk]` | config.toml | 钉钉 channel 绑定 assistant |
| `[provider_urls] zhipu_coding` | config.toml | 智谱 Coding API 地址 |
| `provider = "zhipu_coding"`, `model = "glm-5"` | agent.toml | 使用 GLM-5 模型 |
| `api_key_env = "ZHIPU_API_KEY"` | agent.toml | 防止被 default_model 覆盖 |
| `shell = ["*"]` | agent.toml | agent 级别无命令限制 |

## 目录结构

```
openfang_diy/
├── install.sh              # 一键安装/更新（推荐入口）
├── setup-assistant.sh      # 仅配置（不编译）
├── update-openfang.sh      # 仅更新（不配置 agent）
├── patches/
│   └── dingtalk_stream.rs  # DingTalk Stream 模式补丁
└── README.md
```
