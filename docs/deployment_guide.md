# DGX Spark + OpenClaw 详细部署文档

**作者：Ken He | 更新日期：2026年3月**

> 本文档记录了在 NVIDIA DGX Spark 上稳定运行本地大模型并接入 OpenClaw 的完整方案，包含架构说明、关键参数解析和常见问题排查。

---

## 1. 整体架构

```
用户浏览器
    │
    ▼
OpenClaw Gateway（端口 18789，局域网可访问）
    │  OpenAI 兼容 API
    ▼
推理服务（vLLM / Ollama，仅本机访问）
    │
    ▼
本地模型（DGX Spark 128GB 统一内存）
```

三种部署方案的架构完全相同，只是推理框架和模型不同：

| 方案 | 模型 | 推理框架 | 推理端口 |
|------|------|----------|----------|
| A | Qwen3.5-35B-A3B | vLLM（标准镜像） | 8000 |
| B | MiniMax-M2.5-REAP-NVFP4 | vLLM（NVFP4 专用镜像） | 8000 |
| C | GLM-4.7-Flash | Ollama | 11434 |

---

## 2. 环境要求

### 2.1 硬件

- **设备**：NVIDIA DGX Spark
- **内存**：128GB 统一内存（GPU + CPU 共享）
- **存储**：至少 100GB 可用空间（用于模型文件）

### 2.2 软件

- Ubuntu 22.04+
- Docker（方案 A/B 必须）
- curl、wget、jq、python3

### 2.3 关于 Docker 代理

DGX Spark 上如果配置了 `~/.docker/config.json` 中的全局代理（如 Clash、V2Ray），Docker 容器会继承代理设置，导致推理服务的内部 warmup 请求被代理拦截而失败。

`start_all.sh` 已在所有 `docker run` 命令中显式清除代理环境变量：

```bash
-e HTTP_PROXY="" -e HTTPS_PROXY="" -e http_proxy="" -e https_proxy="" \
-e NO_PROXY="*" -e no_proxy="*"
```

这只影响推理容器，不影响宿主机的代理设置。

---

## 3. 快速部署

### 3.1 克隆仓库

```bash
git clone https://github.com/your-username/dgx-spark-openclaw.git
cd dgx-spark-openclaw
chmod +x install.sh start_all.sh
```

### 3.2 运行安装脚本

```bash
./install.sh
```

安装脚本会完成以下工作：

1. 交互式选择模型方案（菜单选择 1/2/3）
2. 检查并安装基础依赖（Docker、curl、wget、jq、Node.js、Ollama）
3. 全局安装 OpenClaw（`npm install -g openclaw`）
4. 拉取推理框架 Docker 镜像（含国内镜像加速）
5. 下载模型文件（含多方案容错和断点续传）
6. 将部署配置保存至 `~/.openclaw_deploy_config`

### 3.3 启动服务

```bash
./start_all.sh
```

启动脚本会完成以下工作：

1. 读取 `~/.openclaw_deploy_config` 中的部署配置
2. 校验模型文件完整性
3. 清理旧的推理服务容器/进程
4. 启动推理服务（vLLM Docker 容器 或 Ollama 进程）
5. 等待推理服务就绪（实时显示日志）
6. 发送测试请求验证模型推理功能
7. 生成或复用 OpenClaw token
8. 停止已有 Gateway 实例（包括 systemd 管理的实例）
9. 写入 `~/.openclaw/openclaw.json` 配置文件
10. 启动 OpenClaw Gateway
11. 输出完整的访问链接（含 token）

---

## 4. 方案 A：Qwen3.5-35B-A3B（vLLM）

### 4.1 模型信息

- **仓库**：`Qwen/Qwen3.5-35B-A3B`
- **类型**：MoE（混合专家），激活参数 3.5B，总参数 35B
- **精度**：BF16，约 70GB
- **特点**：最新 Qwen3.5 系列，推理能力强，不开启 thinking 模式，直接输出答案

### 4.2 Docker 启动命令（由脚本自动执行）

```bash
docker run -d --name openclaw-vllm \
  --network host --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -v ~/openclaw_project/models:/models \
  -e HTTP_PROXY="" -e HTTPS_PROXY="" -e http_proxy="" -e https_proxy="" \
  -e NO_PROXY="*" -e no_proxy="*" \
  vllm/vllm-openai:latest \
  --model /models/Qwen3.5-35B-A3B \
  --port 8000 \
  --served-model-name qwen3.5-35b \
  --trust-remote-code \
  --gpu-memory-utilization 0.85 \
  --max-model-len 32768 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes
```

### 4.3 关键参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `--tool-call-parser` | `hermes` | Qwen3.5 使用 Hermes 格式工具调用 |
| `--enable-auto-tool-choice` | （开关） | 启用自动工具选择，OpenClaw Agent 必须开启 |
| `--trust-remote-code` | （开关） | 加载 Qwen3.5 自定义模型代码必须开启 |
| `--max-model-len` | `32768` | 上下文长度，DGX Spark 内存充足可适当增大 |

---

## 5. 方案 B：MiniMax-M2.5-REAP-NVFP4（vLLM 专用内核）

### 5.1 模型信息

- **仓库**：`lukealonso/MiniMax-M2.5-REAP-139B-A10B-NVFP4`
- **类型**：MoE，激活参数 10B，总参数 139B
- **精度**：NVFP4 量化，约 78GB
- **特点**：MiniMax 旗舰模型，专为 DGX Spark GB10 架构优化

### 5.2 Docker 启动命令（由脚本自动执行）

```bash
docker run -d --name openclaw-vllm \
  --network host --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -v ~/openclaw_project/models:/models \
  -e HTTP_PROXY="" -e HTTPS_PROXY="" -e http_proxy="" -e https_proxy="" \
  -e NO_PROXY="*" -e no_proxy="*" \
  -e MODEL="/models/MiniMax-M2.5-REAP-NVFP4" \
  -e PORT=8000 \
  -e GPU_MEMORY_UTIL=0.85 \
  -e MAX_MODEL_LEN=32768 \
  -e MAX_NUM_SEQS=16 \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  -e VLLM_NVFP4_GEMM_BACKEND=marlin \
  -e VLLM_TEST_FORCE_FP8_MARLIN=1 \
  -e VLLM_USE_FLASHINFER_MOE_FP4=0 \
  -e VLLM_EXTRA_ARGS="--quantization modelopt --trust-remote-code --served-model-name minimax-m2.5-nvfp4 --enable-auto-tool-choice --tool-call-parser minimax_m2" \
  avarok/dgx-vllm-nvfp4-kernel:v22 serve
```

### 5.3 关键参数说明

| 参数/环境变量 | 值 | 说明 |
|------|-----|------|
| **镜像** | `avarok/dgx-vllm-nvfp4-kernel:v22` | 专为 DGX Spark (GB10) 优化的社区镜像，内置硬件兼容性补丁 |
| `TRITON_PTXAS_PATH` | `/usr/local/cuda/bin/ptxas` | 解决 `sm_121a not defined` 错误，强制使用支持 GB10 架构的 ptxas |
| `VLLM_NVFP4_GEMM_BACKEND` | `marlin` | 解决 `GEMM status=7` 错误，切换 MoE 内核后端为 Marlin |
| `VLLM_USE_FLASHINFER_MOE_FP4` | `0` | 确保 Marlin 后端被激活 |
| `--quantization` | `modelopt` | 正确识别和加载 NVFP4 模型的量化标志 |
| `--tool-call-parser` | `minimax_m2` | MiniMax-M2.5 专用工具调用格式解析器 |

---

## 6. 方案 C：GLM-4.7-Flash（Ollama）

### 6.1 模型信息

- **模型名**：`glm-4.7-flash`（Ollama 官方库）
- **类型**：MoE，激活参数 3B，总参数 30B
- **精度**：Q4 量化，约 19GB
- **特点**：最轻量方案，Ollama 自动管理，首次启动自动下载

### 6.2 启动方式（由脚本自动执行）

```bash
# 启动 Ollama 服务
OLLAMA_HOST="0.0.0.0:11434" ollama serve &

# 拉取模型（首次约 19GB）
ollama pull glm-4.7-flash
```

### 6.3 注意事项

Ollama 提供 OpenAI 兼容 API（`/v1/chat/completions`），OpenClaw 可直接对接，无需额外配置。

---

## 7. OpenClaw 配置说明

`start_all.sh` 会自动生成 `~/.openclaw/openclaw.json`，关键配置项说明如下：

```json
{
  "gateway": {
    "bind": "lan",                          // 允许局域网访问（不仅限于 127.0.0.1）
    "auth": { "mode": "token", "token": "..." },  // token 认证
    "controlUi": {
      "allowInsecureAuth": true,            // 允许 HTTP（非 HTTPS）下的 token 认证
      "dangerouslyDisableDeviceAuth": true  // 跳过 device pairing 验证
    }
  },
  "models": {
    "providers": {
      "...": {
        "compat": { "supportsStore": false }  // 禁用 store 字段（本地模型不支持）
      }
    }
  }
}
```

`supportsStore: false` 是关键配置，缺少此项会导致 OpenClaw 发送带 `"store": true` 的请求，本地 vLLM/Ollama 不支持该字段，返回 400 错误。

---

## 8. 访问 OpenClaw Web UI

### 8.1 访问方式

启动脚本会输出完整的访问链接：

```
http://192.168.0.103:18789/?token=abc123...
```

**请使用脚本输出的完整链接**（包含 `?token=xxx`），不要手动输入 IP:端口。Gateway 收到带 token 的请求后会建立服务端 session cookie，后续页面内导航时浏览器自动携带 cookie，不会因页面刷新而丢失认证。

### 8.2 关于 systemd 自动启动

OpenClaw 安装时会注册 `openclaw-gateway.service` systemd user service，该服务在用户登录后自动启动。`start_all.sh` 在启动前会先通过 `systemctl --user stop openclaw-gateway.service` 停止该服务，再启动配置好的实例。

如果不需要 OpenClaw 随系统自动启动，可以禁用：

```bash
systemctl --user disable openclaw-gateway.service
```

---

## 9. 常见问题排查

### 9.1 推理服务无响应

```bash
# 检查容器状态
docker ps | grep openclaw

# 查看容器日志
docker logs --tail 50 openclaw-vllm

# 检查 GPU 内存（正常加载后应占用 60-80GB）
nvidia-smi
```

如果 `nvidia-smi` 显示 GPU 内存只有 100-200MB，说明模型未正确加载，通常是代理问题或 OOM。

### 9.2 device identity required

确保使用脚本输出的完整 `?token=xxx` 链接访问。如果问题持续，清除浏览器缓存后重新访问。

### 9.3 400 错误（OpenClaw 发送请求时）

检查 `openclaw.json` 中是否有 `"compat": { "supportsStore": false }`。`start_all.sh` 会自动写入此配置，如果手动修改了配置文件可能丢失。

### 9.4 模型下载失败

重新运行 `./install.sh` 即可自动续传。脚本会按顺序尝试 ModelScope → HuggingFace 官方 → hf-mirror.com → wget 逐文件，任意一个成功即可。
