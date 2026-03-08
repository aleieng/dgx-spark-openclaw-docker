# DGX Spark + OpenClaw：本地大模型一键部署方案

本项目提供了一套在 NVIDIA DGX Spark 上一键部署本地大模型并接入 OpenClaw 作为 AI Agent 前端的完整解决方案。两个脚本覆盖从环境安装到服务启动的全流程，无需手动配置。

## 支持的模型方案

| 方案 | 模型 | 框架 | 显存占用 | 特点 |
|------|------|------|----------|------|
| **A** | Qwen3.5-35B-A3B | vLLM | 约 70GB BF16 | 最新 Qwen3.5 MoE，激活参数 3.5B，推理能力强 |
| **B** | MiniMax-M2.5-REAP-NVFP4 | vLLM（专用内核） | 约 78GB NVFP4 | MiniMax 旗舰 MoE，专用 NVFP4 内核，工具调用优化 |
| **C** | GLM-4.7-Flash | Ollama | 约 19GB Q4 | Z.AI 30B-A3B MoE 推理模型，最轻量，秒级启动 |

## 特性

- **一键部署**：`install.sh` + `start_all.sh` 覆盖全流程，无需手动配置 token 或编辑 JSON。
- **DGX Spark 专属优化**：MiniMax 方案使用 `avarok/dgx-vllm-nvfp4-kernel` 社区优化镜像，充分利用 GB10 架构的 NVFP4 量化能力。
- **代理兼容**：自动清除 Docker 容器内的代理环境变量，避免 `~/.docker/config.json` 中的全局代理干扰推理服务。
- **网络优化**：内置国内镜像源（hf-mirror.com、ModelScope、Docker 镜像加速），无需 VPN 即可高速下载。
- **断点续传**：模型下载支持断点续传，可随时中断并重新运行脚本继续下载。
- **动态端口**：支持通过 `--port` 参数指定 OpenClaw Gateway 对外端口，避免端口冲突。
- **本地化推理**：所有推理均在本地 DGX Spark 完成，数据无需上云，零 API 成本。

## 快速开始

**硬件要求**：NVIDIA DGX Spark（128GB 统一内存）

**软件要求**：Ubuntu 22.04+、Docker、curl、wget、jq

### 1. 克隆仓库

```bash
git clone https://github.com/your-username/dgx-spark-openclaw.git
cd dgx-spark-openclaw
chmod +x install.sh start_all.sh
```

### 2. 安装环境与模型（首次运行）

运行后会弹出交互式菜单，选择要部署的模型方案。脚本会自动完成依赖安装、Docker 镜像拉取和模型文件下载。

```bash
./install.sh
```

> **Qwen3.5-35B-A3B**：约 70GB，优先通过 ModelScope（魔搭社区）下载，速度快。
>
> **MiniMax-M2.5-REAP-NVFP4**：约 78GB，通过 hf-mirror.com 下载，支持断点续传。
>
> **GLM-4.7-Flash**：约 19GB，由 Ollama 在首次启动时自动下载，无需提前下载。

### 3. 启动所有服务

```bash
# 使用默认端口 18789 启动
./start_all.sh

# 或指定端口启动
./start_all.sh --port 8080
```

脚本启动后会输出完整的访问链接（包含 token），将**局域网访问链接**复制到笔记本浏览器即可使用。

```
╔══════════════════════════════════════════════════════════════════╗
║                    启动成功！访问链接如下                       ║
╠══════════════════════════════════════════════════════════════════╣
║  本机访问：  http://127.0.0.1:18789/?token=abc123...            ║
║  局域网访问：http://192.168.0.103:18789/?token=abc123...        ║
╠══════════════════════════════════════════════════════════════════╣
║  停止服务：bash start_all.sh stop                               ║
╚══════════════════════════════════════════════════════════════════╝
```

> **重要**：请使用脚本输出的完整链接（包含 `?token=xxx`），不要手动输入 IP:端口。首次访问后浏览器会保存 session cookie，后续页面内导航不再需要 token。

### 4. 停止所有服务

```bash
./start_all.sh stop
```

## 脚本说明

| 脚本 | 功能 |
|------|------|
| `install.sh` | 交互式选择模型方案，自动安装依赖、配置国内镜像、拉取 Docker 镜像、下载模型文件，并将部署配置保存至 `~/.openclaw_deploy_config` |
| `start_all.sh` | 读取部署配置，一键启动推理服务（vLLM/Ollama）和 OpenClaw Gateway，支持 `--port` 参数和 `stop` 命令 |

## 常见问题

**Q：启动后 OpenClaw 界面输入消息没有回复？**

请先用脚本输出的 curl 命令手动测试推理接口是否正常响应。如果 curl 也没有输出，说明推理服务尚未就绪，请等待模型加载完成（首次启动约 2-5 分钟）。

**Q：`device identity required` 错误？**

请确保使用脚本输出的完整 `?token=xxx` 链接访问，不要手动输入 IP:端口。如果已经在使用完整链接，请尝试清除浏览器缓存后重新访问。

**Q：模型下载速度慢或失败？**

脚本会自动尝试多个下载方案（ModelScope → HuggingFace 官方 → hf-mirror.com → wget 逐文件），任意一个成功即可。下载中断后重新运行脚本会自动续传。

## 详细文档

完整的部署步骤、参数解析、常见问题排查，请参考 [详细部署文档](./docs/deployment_guide.md)。

## 作者

Ken He

## License

[MIT](./LICENSE)
