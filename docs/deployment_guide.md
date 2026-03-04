# 最终部署文档：DGX Spark + vLLM + MiniMax-M2.5 (NVFP4)

**作者：Ken He | 日期：2026年3月3日**

> **前言**：本文档是在经历了多次实际部署测试和迭代后，总结出的在 NVIDIA DGX Spark 上稳定运行 MiniMax-M2.5-REAP (NVFP4) 模型的最终方案。方案基于 vLLM 和社区优化的 Docker 镜像，解决了在 GB10 (sm_121a) 架构上遇到的多个底层硬件兼容性问题。

---

## 1. 最终架构

```
用户 -> OpenClaw (端口 3000) -> vLLM 推理服务 (Docker, 端口 8000) -> MiniMax-M2.5-REAP (NVFP4) -> DGX Spark
```

- **推理引擎**: **vLLM**
- **Docker 镜像**: **`avarok/dgx-vllm-nvfp4-kernel:v22`** (专为 DGX Spark 优化的社区镜像)
- **模型**: `lukealonso/MiniMax-M2.5-REAP-139B-A10B-NVFP4`

## 2. 环境准备

### 2.1 创建并进入工作目录

```bash
mkdir -p ~/openclaw_project/models
cd ~/openclaw_project
```

### 2.2 登录 NVIDIA NGC

```bash
# 1. 前往 https://ngc.nvidia.com/ 获取 API Key
# 2. 登录 (Username 固定为 $oauthtoken)
docker login nvcr.io
```

## 3. 下载模型

### 3.1 安装 HuggingFace CLI

```bash
curl -LsSf https://hf.co/cli/install.sh | bash
```

### 3.2 下载模型文件

```bash
# 设置国内镜像加速
export HF_ENDPOINT=https://hf-mirror.com

# 下载模型到指定目录
hf download lukealonso/MiniMax-M2.5-REAP-139B-A10B-NVFP4 \
  --local-dir ~/openclaw_project/models/MiniMax-M2.5-REAP-NVFP4 \
  --repo-type model
```

## 4. 部署 vLLM 推理服务

以下是经过反复测试验证成功的最终启动命令。

### 4.1 设置模型路径

```bash
export MODEL_DIR="$HOME/openclaw_project/models"
```

### 4.2 启动 vLLM 容器

```bash
docker run --rm --name vllm-minimax \
  --network host --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -v "$MODEL_DIR:/models" \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  -e VLLM_NVFP4_GEMM_BACKEND=marlin \
  -e VLLM_TEST_FORCE_FP8_MARLIN=1 \
  -e VLLM_USE_FLASHINFER_MOE_FP4=0 \
  avarok/dgx-vllm-nvfp4-kernel:v22 serve \
  /models/MiniMax-M2.5-REAP-NVFP4 \
  --port 8000 \
  --quantization modelopt \
  --gpu-memory-utilization 0.85 \
  --max-model-len 32768 \
  --max-num-seqs 16 \
  --trust-remote-code \
  --served-model-name "minimax-m2.5-nvfp4" \
  --enable-auto-tool-choice \
  --tool-call-parser minimax_m2
```

### 4.3 关键参数解析

| 参数/环境变量 | 值 | 作用与原因 |
| :--- | :--- | :--- |
| **镜像** | `avarok/dgx-vllm-nvfp4-kernel:v22` | **核心**。专为 DGX Spark (GB10) 优化的社区镜像，内置了解决硬件兼容性问题的补丁。 |
| `-e TRITON_PTXAS_PATH` | `/usr/local/cuda/bin/ptxas` | **解决 `sm_121a not defined` 错误**。强制容器内的 Triton JIT 编译器使用宿主机上支持 GB10 架构的 `ptxas`。 |
| `-e VLLM_NVFP4_GEMM_BACKEND` | `marlin` | **解决 `GEMM status=7` / `TMA descriptor` 错误**。切换 MoE 内核后端为 Marlin，避开 vLLM CUTLASS 内核在 GB10 上的兼容性问题。 |
| `-e VLLM_USE_FLASHINFER_MOE_FP4` | `0` | 确保 Marlin 后端被激活。 |
| `--quantization` | `modelopt` | 正确的量化加载标志，用于识别和加载 NVFP4 模型。 |
| `serve` | (镜像名后的命令) | `avarok` 镜像的入口点需要 `serve` 子命令来启动服务。 |
| `--enable-auto-tool-choice` | (开关) | **解决 400 错误**。启用 vLLM 的自动工具调用选择功能，OpenClaw Agent 发起工具调用时必须开启。 |
| `--tool-call-parser` | `minimax_m2` | 指定 MiniMax-M2.5 专用的工具调用格式解析器，确保 OpenClaw 的工具调用请求被正确解析。 |

## 5. 配置并启动 OpenClaw

### 5.1 安装 OpenClaw

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

### 5.2 下载一键启动脚本

为了避免手动配置 token 的麻烦，提供一个自动化脚本来完成所有配置和启动工作。将脚本下载到 DGX Spark 上：

```bash
wget -O ~/start_openclaw.sh https://raw.githubusercontent.com/your-repo/start_openclaw.sh
chmod +x ~/start_openclaw.sh
```

> 如果无法从上面链接下载，可将本文档附带的 `start_openclaw.sh` 文件上传到 DGX Spark 的 `~/` 目录下，然后运行 `chmod +x ~/start_openclaw.sh`。

### 5.3 启动 OpenClaw

**一键启动（推荐）**

```bash
bash ~/start_openclaw.sh
```

脚本会自动完成以下所有工作，无需任何手动操作：

| 步骤 | 内容 |
| --- | --- |
| 检查 vLLM | 自动检测 8000 端口的 vLLM 服务是否在运行 |
| 停止旧实例 | 自动检测并停止已有 Gateway 实例，避免端口冲突 |
| 生成 Token | 首次运行自动生成随机 token 并保存到 `~/.openclaw/.gateway_token`；再次运行自动复用，无需重新生成 |
| 写入配置 | 自动将 token 写入 `~/.openclaw/openclaw.json`，并将 `bind` 设置为 `lan`，允许局域网访问 |
| 打印链接 | 自动获取局域网 IP，打印本机和局域网两个带 token 的访问链接 |
| 启动 Gateway | 自动启动 OpenClaw Gateway |

运行成功后，终端会输出类似如下的信息：

```
========================================
   Gateway 即将启动，访问链接如下：
========================================

  本机访问：  http://127.0.0.1:18789/?token=abc123...
  局域网访问：http://192.168.1.100:18789/?token=abc123...

  提示：首次访问时将链接复制到浏览器，token 会自动保存，后续无需再带 token
========================================
```

将局域网访问链接复制到您的笔记本浏览器中，即可直接访问 OpenClaw Web UI。

**如需后台持久运行**，将脚本放入 `screen` 中执行：

```bash
screen -S openclaw
bash ~/start_openclaw.sh
# 按 Ctrl+A 再按 D 脱离，进程在后台持续运行
# 使用 screen -r openclaw 可重新连接
```

## 6. 验证

```bash
# 1. 检查 vLLM 服务
curl http://127.0.0.1:8000/v1/models

# 2. 检查 OpenClaw
openclaw doctor
```

---


至此，您已成功在 DGX Spark 上通过 vLLM 部署了 MiniMax-M2.5 的 NVFP4 版本，并接入了 OpenClaw。

## 7. 访问和使用 OpenClaw Web UI

部署成功后，您可以通过浏览器与 OpenClaw 进行交互。

### 7.1 访问方式

OpenClaw 自带一个名为 "Control UI" 的 Web 界面，默认监听在 `18789` 端口。

**方式一：在 DGX Spark 本地访问 (推荐)**

在 DGX Spark 的桌面环境中打开浏览器，访问：

```
http://127.0.0.1:18789
```

由于是从本机访问，连接会自动被信任和批准。

**方式二：从局域网其他电脑直接访问（无需配对）**

OpenClaw 支持通过在 URL 中直接嵌入 token 的方式连接，**无需任何手动配对审批**。首先获取 DGX Spark 的局域网 IP：

```bash
# 在 DGX Spark 终端中运行，查看局域网 IP
ip addr show | grep 'inet ' | grep -v '127.0.0.1'
```

然后在您的笔记本浏览器中访问以下 URL（将 `<DGX_IP>` 替换为实际 IP，`<YOUR_TOKEN_HERE>` 替换为您在配置文件中设置的 token）：

```
http://<DGX_IP>:18789/?token=<YOUR_TOKEN_HERE>
```

例如：

```
http://192.168.1.100:18789/?token=abc123def456...
```

URL 中的 `token` 参数会被浏览器保存到 localStorage，后续访问无需再次带上 token。

> **注意**：该 token 就是您在 `config.json` 中配置的 `gateway.auth.token` 的値，两者必须一致。局域网访问时使用的是明文 HTTP，请确保在可信任的内网环境中使用。

### 7.2 基本使用

成功连接到 Control UI 后，您会看到一个类似聊天应用的界面。在这里您可以：

-   **直接对话**：在输入框中输入您的问题或指令，与背后由 MiniMax-M2.5 模型驱动的 AI Agent 进行交互。
-   **模型选择**：在界面右上角确认当前使用的模型是否为 `MiniMax-M2.5-REAP (本地 vLLM)`。
-   **管理配置**：通过左侧菜单栏进入设置，可以图形化地查看和修改 OpenClaw 的各项配置。
