#!/usr/bin/env bash
# ============================================================
#  DGX Spark 一键启动脚本
#  功能：自动启动 vLLM 推理服务 + OpenClaw Gateway
#  使用：bash start_all.sh [--port PORT]
#  示例：bash start_all.sh --port 8080
#  停止：bash start_all.sh stop
# ============================================================
set -euo pipefail

# ── 用户配置区（按需修改）────────────────────────────────────
MODEL_DIR="$HOME/openclaw_project/models"       # 模型所在目录
MODEL_NAME="MiniMax-M2.5-REAP-NVFP4"           # 模型文件夹名称
VLLM_PORT=8000                                  # vLLM 服务端口
GATEWAY_PORT=18789                              # OpenClaw Gateway 默认端口
VLLM_CONTAINER_NAME="vllm-minimax"             # Docker 容器名称
# ─────────────────────────────────────────────────────────────

# ── 命令行参数解析 ─────────────────────────────────────────────
# 支持：
#   --port PORT   指定 OpenClaw Gateway 对外 HTTP 端口（覆盖上方默认值）
#   stop          停止所有服务
#   -h / --help   显示帮助
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            if [[ -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ || "${2}" -lt 1 || "${2}" -gt 65535 ]]; then
                echo -e "\033[0;31m  ✗ --port 参数无效，请指定 1-65535 之间的整数\033[0m"
                exit 1
            fi
            GATEWAY_PORT="$2"
            shift 2
            ;;
        stop)
            # 直接调用 stop 逻辑并退出
            bash "$0" stop_internal
            exit 0
            ;;
        -h|--help)
            echo "用法：bash start_all.sh [--port PORT]"
            echo ""
            echo "选项："
            echo "  --port PORT   指定 OpenClaw Gateway 对外 HTTP 端口（默认：18789）"
            echo "  stop          停止所有服务（vLLM 容器 + Gateway）"
            echo "  -h, --help    显示此帮助信息"
            echo ""
            echo "示例："
            echo "  bash start_all.sh                # 使用默认端口 18789 启动"
            echo "  bash start_all.sh --port 8080    # 使用端口 8080 启动"
            echo "  bash start_all.sh stop           # 停止所有服务"
            exit 0
            ;;
        *)
            echo -e "\033[0;31m  ✗ 未知参数：$1\033[0m"
            echo "用法：bash start_all.sh [--port PORT]"
            exit 1
            ;;
    esac
done
# ─────────────────────────────────────────────────────────────

CONFIG_DIR="$HOME/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
TOKEN_FILE="$CONFIG_DIR/.gateway_token"

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   DGX Spark · MiniMax-M2.5 · OpenClaw       ║"
    echo "║            一键启动脚本                      ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_banner

# ── stop 模式：停止所有服务 ────────────────────────────────────
if [[ "${1:-}" == "stop_internal" ]]; then
    echo -e "${YELLOW}正在停止所有服务...${NC}"
    # 停止 vLLM 容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$"; then
        docker rm -f "$VLLM_CONTAINER_NAME" 2>/dev/null || true
        echo -e "${GREEN}  ✓ vLLM 容器已停止${NC}"
    else
        echo -e "${GREEN}  ✓ vLLM 容器未运行，跳过${NC}"
    fi
    # 停止 Gateway
    if lsof -i ":${GATEWAY_PORT}" > /dev/null 2>&1; then
        openclaw gateway stop 2>/dev/null || true
        sleep 1
        PID=$(lsof -ti ":${GATEWAY_PORT}" 2>/dev/null || true)
        [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
        echo -e "${GREEN}  ✓ OpenClaw Gateway 已停止${NC}"
    else
        echo -e "${GREEN}  ✓ OpenClaw Gateway 未运行，跳过${NC}"
    fi
    echo -e "${GREEN}${BOLD}所有服务已停止。${NC}"
    exit 0
fi

echo -e "    OpenClaw Gateway 端口：${CYAN}${BOLD}${GATEWAY_PORT}${NC}"
echo ""

# ── 步骤 1：检查依赖 ──────────────────────────────────────────
echo -e "${YELLOW}[1/6] 检查依赖...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 docker，请先安装 Docker${NC}"; exit 1
fi
if ! command -v openclaw &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 openclaw，请先安装 OpenClaw${NC}"; exit 1
fi
if [[ ! -d "${MODEL_DIR}/${MODEL_NAME}" ]]; then
    echo -e "${RED}  ✗ 模型目录不存在：${MODEL_DIR}/${MODEL_NAME}${NC}"
    echo -e "    请先下载模型，参考文档第 3 节${NC}"; exit 1
fi
echo -e "${GREEN}  ✓ 所有依赖检查通过${NC}"

# ── 步骤 2：停止旧的 vLLM 容器（如有）────────────────────────
echo ""
echo -e "${YELLOW}[2/6] 清理旧的 vLLM 容器...${NC}"
if docker ps -a --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$"; then
    docker rm -f "$VLLM_CONTAINER_NAME" 2>/dev/null || true
    echo -e "${GREEN}  ✓ 旧容器已清理${NC}"
else
    echo -e "${GREEN}  ✓ 无旧容器，跳过${NC}"
fi

# ── 步骤 3：后台启动 vLLM 容器 ───────────────────────────────
echo ""
echo -e "${YELLOW}[3/6] 启动 vLLM 推理服务（后台运行）...${NC}"
echo -e "    模型路径：${MODEL_DIR}/${MODEL_NAME}"

docker run -d --name "$VLLM_CONTAINER_NAME" \
  --network host --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -v "${MODEL_DIR}:/models" \
  -e MODEL="/models/${MODEL_NAME}" \
  -e PORT="${VLLM_PORT}" \
  -e GPU_MEMORY_UTIL=0.85 \
  -e MAX_MODEL_LEN=32768 \
  -e MAX_NUM_SEQS=16 \
  -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
  -e VLLM_NVFP4_GEMM_BACKEND=marlin \
  -e VLLM_TEST_FORCE_FP8_MARLIN=1 \
  -e VLLM_USE_FLASHINFER_MOE_FP4=0 \
  -e VLLM_EXTRA_ARGS="--quantization modelopt --trust-remote-code --served-model-name minimax-m2.5-nvfp4 --enable-auto-tool-choice --tool-call-parser minimax_m2" \
  avarok/dgx-vllm-nvfp4-kernel:v22 serve

echo -e "${GREEN}  ✓ vLLM 容器已在后台启动（容器名：${VLLM_CONTAINER_NAME}）${NC}"

# ── 步骤 4：等待 vLLM 就绪 ────────────────────────────────────
echo ""
echo -e "${YELLOW}[4/6] 等待 vLLM 服务就绪（模型加载约需 2-5 分钟）...${NC}"
echo -e "    以下为 vLLM 实时日志，就绪后自动继续："
echo -e "${CYAN}────────────────────────────────────────────────────${NC}"

# 后台轮询就绪状态
WAIT_SECONDS=0
MAX_WAIT=900  # 最多等待 15 分钟
(
  while true; do
    sleep 5
    WAIT_SECONDS=$((WAIT_SECONDS + 5))
    if curl -sf "http://127.0.0.1:${VLLM_PORT}/v1/models" > /dev/null 2>&1; then
      # 就绪：杀掉 docker logs 进程
      pkill -f "docker logs -f ${VLLM_CONTAINER_NAME}" 2>/dev/null || true
      break
    fi
    # 检查容器是否意外退出
    if ! docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$"; then
      pkill -f "docker logs -f ${VLLM_CONTAINER_NAME}" 2>/dev/null || true
      echo -e "\n${RED}  ✗ vLLM 容器意外退出！最后日志如上，请检查错误信息。${NC}"
      exit 1
    fi
    if [[ $WAIT_SECONDS -ge $MAX_WAIT ]]; then
      pkill -f "docker logs -f ${VLLM_CONTAINER_NAME}" 2>/dev/null || true
      echo -e "\n${RED}  ✗ 等待超时（${MAX_WAIT}秒），请检查上方日志。${NC}"
      exit 1
    fi
  done
) &
POLLER_PID=$!

# 前台实时显示日志（直到被 poller 杀掉）
docker logs -f "$VLLM_CONTAINER_NAME" 2>&1 || true

# 等待 poller 结束，检查退出码
wait $POLLER_PID
POLLER_EXIT=$?

echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
if [[ $POLLER_EXIT -ne 0 ]]; then
  exit 1
fi
echo -e "${GREEN}  ✓ vLLM 服务已就绪！${NC}"

# ── 步骤 5：准备 OpenClaw 配置 ────────────────────────────────
echo ""
echo -e "${YELLOW}[5/6] 准备 OpenClaw 配置...${NC}"
mkdir -p "$CONFIG_DIR"

# 生成或复用 token
if [[ -f "$TOKEN_FILE" ]]; then
    GATEWAY_TOKEN=$(cat "$TOKEN_FILE")
    echo -e "${GREEN}  ✓ 复用已有 Token${NC}"
else
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    echo "$GATEWAY_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo -e "${GREEN}  ✓ 已生成新 Token${NC}"
fi

# 停止已有 Gateway 实例（检查当前指定端口）
if lsof -i ":${GATEWAY_PORT}" > /dev/null 2>&1; then
    openclaw gateway stop 2>/dev/null || true
    sleep 2
    PID=$(lsof -ti ":${GATEWAY_PORT}" 2>/dev/null || true)
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
fi

# 写入配置文件（使用命令行指定的 GATEWAY_PORT）
cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${GATEWAY_PORT},
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    },
    "remote": {
      "token": "${GATEWAY_TOKEN}"
    },
    "controlUi": {
      "enabled": true,
      "allowedOrigins": ["*"],
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "minimax_local": {
        "baseUrl": "http://127.0.0.1:${VLLM_PORT}/v1",
        "apiKey": "unused",
        "api": "openai-completions",
        "models": [
          {
            "id": "minimax-m2.5-nvfp4",
            "name": "MiniMax-M2.5-REAP (本地 NVFP4)",
            "reasoning": true,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "minimax_local/minimax-m2.5-nvfp4"
      }
    }
  }
}
EOF

echo -e "${GREEN}  ✓ 配置文件已写入 ${CONFIG_FILE}${NC}"
echo -e "${GREEN}  ✓ Gateway 端口：${BOLD}${GATEWAY_PORT}${NC}"

# ── 步骤 6：打印访问链接并启动 Gateway ───────────────────────
echo ""
LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    启动成功！访问链接如下                       ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  本机访问：  http://127.0.0.1:%-5s/?token=%-24s  ║\n" "${GATEWAY_PORT}" "${GATEWAY_TOKEN:0:20}..."
if [[ -n "$LAN_IP" ]]; then
printf "║  局域网访问：http://%-15s:%-5s/?token=%-14s  ║\n" "${LAN_IP}" "${GATEWAY_PORT}" "${GATEWAY_TOKEN:0:10}..."
fi
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  提示：首次访问时使用完整链接，token 自动保存，后续无需带 token ║"
echo "║  停止服务：bash start_all.sh stop                               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# 打印完整链接（方便复制）
echo -e "完整局域网链接："
echo -e "${CYAN}http://${LAN_IP}:${GATEWAY_PORT}/?token=${GATEWAY_TOKEN}${NC}"
echo ""
echo -e "${YELLOW}[6/6] 正在启动 OpenClaw Gateway（按 Ctrl+C 停止）...${NC}"
echo ""

export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"
export OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1
exec openclaw gateway --allow-unconfigured
