# OpenFang DIY

OpenFang 个人定制脚本：一键安装/更新 + DingTalk Stream 补丁 + 自动配置。

## 快速开始

一句话安装：

```bash
bash <(curl -sL https://raw.githubusercontent.com/pemagic/openfang_diy/main/install.sh)
```

或者 clone 后运行：

```bash
git clone https://github.com/pemagic/openfang_diy.git
cd openfang_diy
./install.sh
```

## 脚本说明

### install.sh — 一键安装/更新（推荐）

合并了安装、更新、配置三个步骤，自动判断是首次安装还是更新：

1. 克隆 OpenFang 源码，替换 DingTalk Stream 补丁，编译安装
2. 配置安全策略（关闭审批、开放 shell）— 仅缺失时补充，不覆盖已有配置
3. 配置 assistant agent（glm-5 模型）— 仅修改关键字段，不动 system_prompt
4. 交互式输入 API Key — 已配置的自动跳过
5. 启动 daemon 并验证

```bash
./install.sh                # 首次安装或更新
./install.sh --force        # 跳过版本检查强制重新编译
./install.sh --check        # 只检查是否有新版本
```

### setup-assistant.sh — 仅配置（不编译）

只做配置，不涉及编译。适用于已安装 OpenFang 后单独调整配置：

```bash
cp setup-assistant.sh ~/.openfang/
~/.openfang/setup-assistant.sh
```

### update-openfang.sh — 仅更新（不配置 agent）

只做编译更新 + DingTalk 补丁，不修改 agent 和安全策略：

```bash
cp update-openfang.sh ~/.openfang/
~/.openfang/update-openfang.sh
```

## 目录结构

```
openfang_diy/
├── install.sh              # 一键安装/更新（推荐入口）
├── setup-assistant.sh      # 仅配置
├── update-openfang.sh      # 仅更新
├── patches/
│   └── dingtalk_stream.rs  # DingTalk Stream 模式补丁
└── README.md
```

## 前置要求

- macOS / Linux
- Rust 工具链（`cargo`）— 用于编译
- Git
- API Key：智谱（必需）、钉钉（可选）、Gemini（可选）

## 配置的内容

| 配置项 | 文件 | 说明 |
|--------|------|------|
| `[approval] require_approval = false` | config.toml | 关闭工具执行审批 |
| `[exec_policy] mode = "full"` | config.toml + agent.toml | 允许所有 shell 命令 |
| `provider = "zhipu_coding"` | agent.toml | 使用智谱 Coding API |
| `model = "glm-5"` | agent.toml | 使用 GLM-5 模型 |
| `api_key_env = "ZHIPU_API_KEY"` | agent.toml | 防止被 default_model 覆盖 |
| `shell = ["*"]` | agent.toml | agent 级别无命令限制 |
