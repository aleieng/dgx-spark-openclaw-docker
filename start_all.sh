#!/usr/bin/env bash
# ============================================================
#  DGX Spark 一键启动脚本
#  作者：Ken He
#  功能：根据 install.sh 保存的部署配置，自动启动对应的
#        推理框架（vLLM / Ollama）+ OpenClaw Gateway
#  支持模型：
#    - Qwen3.5-35B-A3B          → vLLM
#    - MiniMax-M2.5-REAP-NVFP4  → vLLM（专用 NVFP4 内核）
#    - GLM-4.7-Flash            → Ollama
#  使用：bash start_all.sh [--port PORT]
#  停止 Gateway：bash start_all.sh stop
#  停止所有服务：bash start_all.sh stop --all
# ============================================================
set -euo pipefail

# ── 全局默认配置 ───────────────────────────────────────────────
DEPLOY_CONFIG="$HOME/.openclaw_deploy_config"   # install.sh 生成的部署配置
GATEWAY_PORT=18789                              # OpenClaw Gateway 默认端口
GATEWAY_CONTAINER_PORT=18789                    # OpenClaw 容器内固定监听端口
CONFIG_DIR="$HOME/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
TOKEN_FILE="$CONFIG_DIR/.gateway_token"
OPENCLAW_GATEWAY_CONTAINER_NAME="openclaw-gateway"
OPENCLAW_WORKSPACE_DIR="$CONFIG_DIR/workspace"
OPENCLAW_PLUGIN_DIR="$CONFIG_DIR/plugin-runtime-deps"
OPENCLAW_CONTAINER_UID=1000
OPENCLAW_CONTAINER_GID=1000

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── 命令行参数解析 ─────────────────────────────────────────────
_do_stop=false
_stop_all=false
RESTART_MODEL=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            if [[ -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ || "${2}" -lt 1 || "${2}" -gt 65535 ]]; then
                echo -e "${RED}  ✗ --port 参数无效，请指定 1-65535 之间的整数${NC}"
                exit 1
            fi
            GATEWAY_PORT="$2"
            shift 2
            ;;
        stop)
            _do_stop=true
            shift
            ;;
        all|--all|-all|--stop-all)
            _stop_all=true
            shift
            ;;
        -restart_model|--restart_model|--restart-model)
            RESTART_MODEL=true
            shift
            ;;
        -h|--help)
            echo "用法：bash start_all.sh [--port PORT] [--restart_model]"
            echo ""
            echo "选项："
            echo "  --port PORT   指定 OpenClaw Gateway 对外 HTTP 端口（默认：18789）"
            echo "  --restart_model 强制重启推理服务，即使现有 vLLM 容器可用"
            echo "  stop          仅停止 OpenClaw Gateway（默认不停止 vLLM/Ollama）"
            echo "  stop --all    停止 OpenClaw Gateway 和推理服务"
            echo "  -h, --help    显示此帮助信息"
            echo ""
            echo "示例："
            echo "  bash start_all.sh                # 使用默认端口 18789 启动"
            echo "  bash start_all.sh --port 8080    # 使用端口 8080 启动"
            echo "  bash start_all.sh --restart_model # 强制重启推理服务"
            echo "  bash start_all.sh stop           # 仅停止 Gateway"
            echo "  bash start_all.sh stop --all     # 停止所有服务"
            exit 0
            ;;
        *)
            echo -e "${RED}  ✗ 未知参数：$1${NC}"
            echo "用法：bash start_all.sh [--port PORT]"
            exit 1
            ;;
    esac
done

# ── 读取部署配置 ───────────────────────────────────────────────
if [[ ! -f "$DEPLOY_CONFIG" ]]; then
    echo -e "${RED}  ✗ 未找到部署配置文件 ${DEPLOY_CONFIG}${NC}"
    echo -e "    请先运行 ${CYAN}./install.sh${NC} 完成安装"
    exit 1
fi
# shellcheck source=/dev/null
source "$DEPLOY_CONFIG"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"

# 根据框架确定推理服务端口
case "${SELECTED_FRAMEWORK:-vllm}" in
    vllm)   INFERENCE_PORT="${VLLM_PORT:-8000}" ;;
    ollama) INFERENCE_PORT="${OLLAMA_PORT:-11434}" ;;
    *)      INFERENCE_PORT=8000 ;;
esac

CONTAINER_NAME="openclaw-${SELECTED_FRAMEWORK:-vllm}"

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   DGX Spark · 本地大模型 · OpenClaw                 ║"
    echo "║              一键启动脚本                            ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_banner

# ════════════════════════════════════════════════════════════════
# stop 模式
# ════════════════════════════════════════════════════════════════
if [[ "$_do_stop" == "true" ]]; then
    if [[ "$_stop_all" == "true" ]]; then
        echo -e "${YELLOW}正在停止所有服务...${NC}"
    else
        echo -e "${YELLOW}正在停止 OpenClaw Gateway（保留推理服务）...${NC}"
    fi

    if [[ "$_stop_all" == "true" ]]; then
        # 停止 vLLM 容器
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
            echo -e "${GREEN}  ✓ 推理容器（${CONTAINER_NAME}）已停止${NC}"
        fi

        # 停止 Ollama 服务
        if [[ "${SELECTED_FRAMEWORK:-}" == "ollama" ]]; then
            pkill -f "ollama serve" 2>/dev/null || true
            echo -e "${GREEN}  ✓ Ollama 服务已停止${NC}"
        fi
    fi

    # 停止 OpenClaw Gateway 容器
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${OPENCLAW_GATEWAY_CONTAINER_NAME}$"; then
        docker rm -f "$OPENCLAW_GATEWAY_CONTAINER_NAME" 2>/dev/null || true
        echo -e "${GREEN}  ✓ OpenClaw Gateway 容器已停止${NC}"
    else
        echo -e "${GREEN}  ✓ OpenClaw Gateway 容器未运行${NC}"
    fi

    if [[ "$_stop_all" == "true" ]]; then
        echo -e "${GREEN}${BOLD}所有服务已停止。${NC}"
    else
        echo -e "${GREEN}${BOLD}OpenClaw Gateway 已停止，推理服务仍保留运行。${NC}"
    fi
    exit 0
fi

echo -e "    模型：${CYAN}${BOLD}${MODEL_DISPLAY:-未知}${NC}"
echo -e "    框架：${CYAN}${BOLD}${FRAMEWORK_DISPLAY:-未知}${NC}"
echo -e "    OpenClaw Gateway 端口：${CYAN}${BOLD}${GATEWAY_PORT}${NC}"
echo ""

# ════════════════════════════════════════════════════════════════
# 步骤 1：检查依赖
# ════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[1/6] 检查依赖...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 docker，请先安装 Docker${NC}"; exit 1
fi
if ! docker info &>/dev/null 2>&1; then
    echo -e "${RED}  ✗ 当前用户无法访问 Docker，请先运行 ./install.sh 或配置 Docker 权限${NC}"; exit 1
fi
if ! docker image inspect "$OPENCLAW_IMAGE" &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 OpenClaw Docker 镜像：${OPENCLAW_IMAGE}${NC}"
    echo -e "    请先运行 ${CYAN}./install.sh${NC} 拉取镜像"; exit 1
fi

case "${SELECTED_FRAMEWORK:-vllm}" in
    vllm)
        if ! command -v docker &>/dev/null; then
            echo -e "${RED}  ✗ 未找到 docker，请先安装 Docker${NC}"; exit 1
        fi
        if [[ ! -d "${MODEL_BASE_DIR}/${MODEL_NAME}" ]]; then
            echo -e "${RED}  ✗ 模型目录不存在：${MODEL_BASE_DIR}/${MODEL_NAME}${NC}"
            echo -e "    请先运行 ${CYAN}./install.sh${NC} 下载模型"; exit 1
        fi
        ;;
    ollama)
        if ! command -v ollama &>/dev/null; then
            echo -e "${RED}  ✗ 未找到 ollama，请先运行 ./install.sh${NC}"; exit 1
        fi
        ;;
esac
echo -e "${GREEN}  ✓ 所有依赖检查通过${NC}"

# ════════════════════════════════════════════════════════════════
# 步骤 1.5：校验模型关键 JSON 文件完整性（仅 vLLM）
# ════════════════════════════════════════════════════════════════
if [[ "${SELECTED_FRAMEWORK:-vllm}" == "vllm" ]]; then
    echo -e "${YELLOW}[1.5/6] 校验模型文件完整性...${NC}"
    JSON_CORRUPT=false
    for JSON_FILE in config.json generation_config.json; do
        FULL_PATH="${MODEL_BASE_DIR}/${MODEL_NAME}/${JSON_FILE}"
        if [[ ! -f "$FULL_PATH" ]]; then
            echo -e "    ${YELLOW}[缺失]${NC} ${JSON_FILE}"
            JSON_CORRUPT=true
            continue
        fi
        if ! python3 -c "import json,sys; json.load(open('${FULL_PATH}'))" 2>/dev/null; then
            echo -e "    ${RED}[损坏]${NC} ${JSON_FILE} 不是有效的 JSON 文件（可能下载不完整）"
            rm -f "$FULL_PATH"
            JSON_CORRUPT=true
        else
            echo -e "    ${GREEN}[正常]${NC} ${JSON_FILE}"
        fi
    done
    if [[ "$JSON_CORRUPT" == "true" ]]; then
        echo -e ""
        echo -e "${RED}  ✗ 模型文件损坏或缺失，请重新运行 install.sh 补充下载：${NC}"
        echo -e "${CYAN}      ./install.sh${NC}"
        exit 1
    fi
    echo -e "${GREEN}  ✓ 模型关键文件校验通过${NC}"
fi

# ════════════════════════════════════════════════════════════════
# 步骤 2：清理旧的推理服务
# ════════════════════════════════════════════════════════════════
_restart_inference_services() {
echo ""
echo -e "${YELLOW}[2/6] 清理旧的推理服务（释放 GPU 内存）...${NC}"

# 无论选择哪个框架，都先停止所有可能占用 GPU 的服务
# 尤其是从 Ollama 切换到 vLLM 时，必须先释放 Ollama 占用的 GPU 内存

# 1. 停止旧 Docker 容器
_old_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^openclaw-" || true)
if [[ -n "$_old_containers" ]]; then
    echo "$_old_containers" | xargs -r docker rm -f 2>/dev/null || true
    echo -e "${GREEN}  ✓ 旧 Docker 容器已清理${NC}"
else
    echo -e "${GREEN}  ✓ 无旧 Docker 容器${NC}"
fi

# 2. 停止 Ollama 服务（释放其占用的 GPU 内存）
if pgrep -x ollama &>/dev/null || pgrep -f "ollama serve" &>/dev/null; then
    pkill -f "ollama serve" 2>/dev/null || true
    # 等待 Ollama 完全退出并释放 GPU 内存
    echo -e "    等待 Ollama 释放 GPU 内存..."
    sleep 5
    echo -e "${GREEN}  ✓ Ollama 已停止，GPU 内存已释放${NC}"
else
    echo -e "${GREEN}  ✓ Ollama 未运行${NC}"
fi

# ════════════════════════════════════════════════════════════════
# 步骤 3：启动推理服务
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[3/6] 启动推理服务：${FRAMEWORK_DISPLAY:-}...${NC}"

case "${SELECTED_FRAMEWORK:-vllm}" in
    # ── vLLM ──────────────────────────────────────────────────
    vllm)
        if [[ "${SELECTED_MODEL:-}" == "minimax" ]]; then
            # MiniMax-M2.5-REAP-NVFP4：专用 NVFP4 内核镜像（avarok/dgx-vllm-nvfp4-kernel）
            SERVED_MODEL_NAME="minimax-m2.5-nvfp4"
            TOOL_CALL_PARSER="minimax_m2"
            echo -e "    模型路径：${MODEL_BASE_DIR}/${MODEL_NAME}"
            echo -e "    镜像：${VLLM_IMAGE}"
            echo ""
            docker run -d --name "$CONTAINER_NAME" \
              --network host --gpus all --ipc=host \
              --ulimit memlock=-1 --ulimit stack=67108864 \
              -v "${MODEL_BASE_DIR}:/models" \
              -e HTTP_PROXY="" -e HTTPS_PROXY="" -e http_proxy="" -e https_proxy="" \
              -e NO_PROXY="*" -e no_proxy="*" \
              -e MODEL="/models/${MODEL_NAME}" \
              -e PORT="${INFERENCE_PORT}" \
              -e GPU_MEMORY_UTIL=0.85 \
              -e MAX_MODEL_LEN=32768 \
              -e MAX_NUM_SEQS=16 \
              -e TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
              -e VLLM_NVFP4_GEMM_BACKEND=marlin \
              -e VLLM_TEST_FORCE_FP8_MARLIN=1 \
              -e VLLM_USE_FLASHINFER_MOE_FP4=0 \
              -e VLLM_EXTRA_ARGS="--quantization modelopt --trust-remote-code --served-model-name ${SERVED_MODEL_NAME} --enable-auto-tool-choice --tool-call-parser ${TOOL_CALL_PARSER}" \
              "${VLLM_IMAGE}" serve
        else
            # Qwen3.5-35B-A3B：使用 cu130-nightly 镜像
            # vllm/vllm-openai:latest（0.16.0）不支持 qwen3_5_moe 架构
            # 需要 nightly 版本（含 transformers >= 4.52.0 对 Qwen3.5 MoE 的支持）
            SERVED_MODEL_NAME="qwen3.5-35b"
            echo -e "    模型路径：${MODEL_BASE_DIR}/${MODEL_NAME}"
            echo -e "    镜像：${VLLM_IMAGE}"
            echo ""
            docker run -d --name "$CONTAINER_NAME" \
              --network host --gpus all --ipc=host \
              --ulimit memlock=-1 --ulimit stack=67108864 \
              -v "${MODEL_BASE_DIR}:/models" \
              -e HTTP_PROXY="" -e HTTPS_PROXY="" -e http_proxy="" -e https_proxy="" \
              -e NO_PROXY="*" -e no_proxy="*" \
              "${VLLM_IMAGE}" \
              --model "/models/${MODEL_NAME}" \
              --port "${INFERENCE_PORT}" \
              --served-model-name "${SERVED_MODEL_NAME}" \
              --trust-remote-code \
              --gpu-memory-utilization 0.85 \
              --max-model-len 32768 \
              --enable-auto-tool-choice \
              --tool-call-parser hermes
        fi
        echo -e "${GREEN}  ✓ vLLM 容器已在后台启动（容器名：${CONTAINER_NAME}）${NC}"
        ;;

    # ── Ollama（GLM-4.7-Flash）────────────────────────────────────────────
    ollama)
        echo -e "    模型：${MODEL_NAME}"
        # 清除代理环境变量，避免 systemd 注入的代理导致 TLS 超时
        OLLAMA_HOST="0.0.0.0:${INFERENCE_PORT}" \
            env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
            NO_PROXY="*" no_proxy="*" \
            nohup ollama serve > /tmp/ollama.log 2>&1 &
        OLLAMA_PID=$!
        echo -e "${GREEN}  ✓ Ollama 服务已在后台启动（PID: ${OLLAMA_PID}）${NC}"
        sleep 3
        # 配置 Ollama 镜像源（如果还未配置）
        if [[ ! -f ~/.ollama/config.json ]] || ! grep -q "modelscope" ~/.ollama/config.json 2>/dev/null; then
            mkdir -p ~/.ollama
            cat > ~/.ollama/config.json << 'OLLAMA_CFG'
{
  "registry": {
    "mirrors": {
      "registry.ollama.ai": "https://ollama.modelscope.cn"
    }
  }
}
OLLAMA_CFG
            echo -e "${GREEN}  ✓ Ollama 镜像源已配置（ollama.modelscope.cn）${NC}"
        fi

        # 检查模型是否已存在
        if ollama list 2>/dev/null | grep -q "${MODEL_NAME}"; then
            echo -e "${GREEN}  ✓ 模型 ${MODEL_NAME} 已存在${NC}"
        else
            echo -e "    拉取模型（镜像源: ollama.modelscope.cn，官方格式，支持工具调用）..."
            PULL_OK=false
            for _attempt in 1 2 3; do
                [[ ${_attempt} -gt 1 ]] && echo -e "    尝试第 ${_attempt} 次..."
                if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
                       NO_PROXY="*" no_proxy="*" \
                       ollama pull "${MODEL_NAME}"; then
                    PULL_OK=true
                    break
                fi
                [[ ${_attempt} -lt 3 ]] && echo -e "    拉取失败，5 秒后重试..." && sleep 5
            done
            if ! ${PULL_OK}; then
                echo -e "${RED}  ✗ 模型下载失败。请检查网络后手动运行：${NC}"
                echo -e "    ${CYAN}ollama pull ${MODEL_NAME}${NC}"
                exit 1
            fi
        fi
        echo -e "${GREEN}  ✓ Ollama 模型已就绪${NC}"
        ;;
esac

# ════════════════════════════════════════════════════════════════
# 步骤 4：等待推理服务就绪
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[4/6] 等待推理服务就绪（模型加载约 2-5 分钟）...${NC}"

case "${SELECTED_FRAMEWORK:-vllm}" in
    vllm)
        HEALTH_URL="http://127.0.0.1:${INFERENCE_PORT}/v1/models"
        echo -e "    以下为实时日志，就绪后自动继续："
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"

        WAIT_SECONDS=0
        MAX_WAIT=900
        (
          while true; do
            sleep 5
            WAIT_SECONDS=$((WAIT_SECONDS + 5))
            if curl -sf "$HEALTH_URL" > /dev/null 2>&1; then
              pkill -f "docker logs -f ${CONTAINER_NAME}" 2>/dev/null || true
              break
            fi
            if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
              pkill -f "docker logs -f ${CONTAINER_NAME}" 2>/dev/null || true
              echo -e "\n${RED}  ✗ 推理容器意外退出！请检查上方日志。${NC}"
              exit 1
            fi
            if [[ $WAIT_SECONDS -ge $MAX_WAIT ]]; then
              pkill -f "docker logs -f ${CONTAINER_NAME}" 2>/dev/null || true
              echo -e "\n${RED}  ✗ 等待超时（${MAX_WAIT}秒），请检查上方日志。${NC}"
              exit 1
            fi
          done
        ) &
        POLLER_PID=$!
        docker logs -f "$CONTAINER_NAME" 2>&1 || true
        wait $POLLER_PID
        POLLER_EXIT=$?
        echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
        if [[ $POLLER_EXIT -ne 0 ]]; then exit 1; fi
        ;;

    ollama)
        echo "    等待 Ollama API 就绪..."
        WAIT_SECONDS=0
        MAX_WAIT=120
        while ! curl -sf "http://127.0.0.1:${INFERENCE_PORT}/api/tags" > /dev/null 2>&1; do
            sleep 3
            WAIT_SECONDS=$((WAIT_SECONDS + 3))
            if [[ $WAIT_SECONDS -ge $MAX_WAIT ]]; then
                echo -e "${RED}  ✗ Ollama 启动超时，请检查 /tmp/ollama.log${NC}"
                exit 1
            fi
        done
        ;;
esac

echo -e "${GREEN}  ✓ 推理服务已就绪！${NC}"
}

# ════════════════════════════════════════════════════════════════
# 步骤 4.5：发送实际 chat 请求验证模型真正可用
# ════════════════════════════════════════════════════════════════
_test_model_inference() {
    local port="$1"
    local model_id="$2"
    local test_url="http://127.0.0.1:${port}/v1/chat/completions"
    local response http_code error_body

    echo -e "    测试接口：${test_url}"

    # 测试 1：非流式请求
    local payload_nonstream
    payload_nonstream=$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":false}' "${model_id}")
    response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Accept-Encoding: identity" \
        -d "${payload_nonstream}" 2>/dev/null || true)
    http_code=$(echo "${response}" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')
    error_body=$(echo "${response}" | grep -v '__HTTP_CODE__' | head -5 || true)
    echo -e "    非流式请求（stream:false）：HTTP ${http_code}"
    [[ -n "${error_body}" && "${http_code}" != "200" ]] && echo -e "    错误：${error_body}"

    # 测试 2：流式请求（OpenClaw 实际使用的方式）
    local payload_stream
    payload_stream=$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":true}' "${model_id}")
    local stream_response stream_code stream_body
    stream_response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Accept-Encoding: identity" \
        -d "${payload_stream}" 2>/dev/null || true)
    stream_code=$(echo "${stream_response}" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')
    stream_body=$(echo "${stream_response}" | grep -v '__HTTP_CODE__' | head -3 || true)
    echo -e "    流式请求（stream:true）：HTTP ${stream_code}"
    [[ -n "${stream_body}" && "${stream_code}" != "200" ]] && echo -e "    错误：${stream_body}"

    # 测试 3：带 store:false 的请求（OpenClaw 默认会发送此字段）
    local payload_store
    payload_store=$(printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":true,"store":false}' "${model_id}")
    local store_response store_code store_body
    store_response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Accept-Encoding: identity" \
        -d "${payload_store}" 2>/dev/null || true)
    store_code=$(echo "${store_response}" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')
    store_body=$(echo "${store_response}" | grep -v '__HTTP_CODE__' | head -5 || true)
    echo -e "    带 store:false 的请求：HTTP ${store_code}"
    [[ -n "${store_body}" && "${store_code}" != "200" ]] && echo -e "    错误：${store_body}"

    if [[ "${http_code}" == "200" && "${stream_code}" == "200" && "${store_code}" == "200" ]]; then
        echo -e "${GREEN}  ✓ 模型推理测试全部通过${NC}"
        return 0
    elif [[ "${http_code}" == "200" && "${stream_code}" == "200" ]]; then
        echo -e "${YELLOW}  ⚠ 带 store:false 的请求返回 ${store_code}，OpenClaw 调用可能出现 400 错误${NC}"
        echo -e "    错误详情：${store_body}"
        return 0  # 不阻止启动，继续运行
    else
        echo -e "${RED}  ✗ 模型推理测试失败（HTTP ${http_code}）${NC}"
        echo -e "    请检查上方错误信息"
        return 1
    fi
}

_verify_model_inference() {
    TEST_MODEL_ID=$(curl -sf "http://127.0.0.1:${INFERENCE_PORT}/v1/models" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "")

    if [[ -z "${TEST_MODEL_ID}" ]]; then
        echo -e "${YELLOW}  ⚠ 无法获取模型 ID${NC}"
        return 1
    fi

    echo -e "    测试模型 ID：${TEST_MODEL_ID}"
    _test_model_inference "${INFERENCE_PORT}" "${TEST_MODEL_ID}"
}

REUSED_EXISTING_INFERENCE=false
if [[ "${SELECTED_FRAMEWORK:-vllm}" == "vllm" && "$RESTART_MODEL" != "true" ]] \
    && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    REUSED_EXISTING_INFERENCE=true
    echo ""
    echo -e "${YELLOW}[2-4/6] 检测到已运行的 vLLM 容器，跳过清理/启动/等待：${CONTAINER_NAME}${NC}"
    echo -e "    如需强制重启推理服务，请使用 ${CYAN}--restart_model${NC}"
else
    _restart_inference_services
fi

echo ""
echo -e "${YELLOW}[4.5/6] 验证模型推理功能...${NC}"
if ! _verify_model_inference; then
    if [[ "$REUSED_EXISTING_INFERENCE" == "true" ]]; then
        echo -e "${YELLOW}  ⚠ 现有 vLLM 容器无法完成推理验证，回退到清理并重启推理服务...${NC}"
        REUSED_EXISTING_INFERENCE=false
        _restart_inference_services
        echo ""
        echo -e "${YELLOW}[4.5/6] 重新验证模型推理功能...${NC}"
        if ! _verify_model_inference; then
            echo -e "${RED}  ✗ 推理服务重启后仍响应异常，请检查上方错误信息。${NC}"
            exit 1
        fi
    else
        echo -e "${RED}  ✗ 推理服务响应异常，请检查上方错误信息后重新启动。${NC}"
        exit 1
    fi
fi

# ════════════════════════════════════════════════════════════════
# 步骤 5：准备 OpenClaw 配置
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[5/6] 准备 OpenClaw 配置...${NC}"
mkdir -p "$CONFIG_DIR" "$OPENCLAW_WORKSPACE_DIR" "$OPENCLAW_PLUGIN_DIR"

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

echo -e "    正在设置 OpenClaw 容器写入目录权限（UID:GID ${OPENCLAW_CONTAINER_UID}:${OPENCLAW_CONTAINER_GID}）..."
sudo chown -R "${OPENCLAW_CONTAINER_UID}:${OPENCLAW_CONTAINER_GID}" \
    "$CONFIG_FILE" "$TOKEN_FILE" "$OPENCLAW_WORKSPACE_DIR" "$OPENCLAW_PLUGIN_DIR"
echo -e "${GREEN}  ✓ OpenClaw 容器写入权限已准备${NC}"

# 停止已有 Gateway 实例
echo -e "    正在停止已有 OpenClaw Gateway 容器..."
docker rm -f "$OPENCLAW_GATEWAY_CONTAINER_NAME" 2>/dev/null || true
sleep 1

# 动态查询推理服务实际返回的模型 ID（确保与服务完全一致，避免 400 错误）
_get_actual_model_id() {
    local api_url="$1"
    local model_id
    model_id=$(curl -sf "${api_url}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || true)
    echo "${model_id}"
}

HOST_BASE_URL="http://127.0.0.1:${INFERENCE_PORT}/v1"
BASE_URL="http://host.docker.internal:${INFERENCE_PORT}/v1"

case "${SELECTED_FRAMEWORK:-vllm}" in
    vllm)
        if [[ "${SELECTED_MODEL:-}" == "minimax" ]]; then
            PROVIDER_NAME="minimax_local"
            MODEL_DISPLAY_NAME="MiniMax-M2.5-REAP (本地 NVFP4)"
            REASONING=true
            CONTEXT_WINDOW=32768
        else
            # Qwen3.5-35B-A3B
            PROVIDER_NAME="qwen35_vllm"
            MODEL_DISPLAY_NAME="Qwen3.5-35B-A3B (本地 vLLM)"
            REASONING=false
            CONTEXT_WINDOW=32768
        fi
        MODEL_ID=$(_get_actual_model_id "${HOST_BASE_URL}/models")
        if [[ -z "$MODEL_ID" ]]; then
            [[ "${SELECTED_MODEL:-}" == "minimax" ]] && MODEL_ID="minimax-m2.5-nvfp4" || MODEL_ID="qwen3.5-35b"
            echo -e "    ${YELLOW}[警告]${NC} 无法动态获取模型 ID，使用默认值：${MODEL_ID}"
        else
            echo -e "    ${GREEN}[自动检测]${NC} 推理服务实际模型 ID：${MODEL_ID}"
        fi
        ;;
    ollama)
        PROVIDER_NAME="glm_ollama"
        MODEL_DISPLAY_NAME="GLM-4.7-Flash (本地 Ollama)"
        REASONING=true  # GLM-4.7-Flash 官方版支持 tools + thinking
        CONTEXT_WINDOW=32768
        MODEL_ID=$(_get_actual_model_id "${HOST_BASE_URL}/models")
        if [[ -z "$MODEL_ID" ]]; then
            MODEL_ID="${MODEL_NAME}"
            echo -e "    ${YELLOW}[警告]${NC} 无法动态获取模型 ID，使用默认值：${MODEL_ID}"
        else
            echo -e "    ${GREEN}[自动检测]${NC} 推理服务实际模型 ID：${MODEL_ID}"
        fi
        ;;
esac

# 写入 openclaw.json
cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${GATEWAY_CONTAINER_PORT},
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
      "${PROVIDER_NAME}": {
        "baseUrl": "${BASE_URL}",
        "apiKey": "unused",
        "api": "openai-completions",
        "models": [
          {
            "id": "${MODEL_ID}",
            "name": "${MODEL_DISPLAY_NAME}",
            "reasoning": ${REASONING},
            "input": ["text"],
            "compat": { "supportsStore": false },
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": ${CONTEXT_WINDOW}
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "${PROVIDER_NAME}/${MODEL_ID}"
      }
    }
  }
}
EOF

echo -e "${GREEN}  ✓ 配置文件已写入 ${CONFIG_FILE}${NC}"
echo -e "${GREEN}  ✓ 模型提供商：${PROVIDER_NAME} / ${MODEL_ID}${NC}"
echo -e "${GREEN}  ✓ Gateway 端口：${BOLD}${GATEWAY_PORT}${NC}"

# ════════════════════════════════════════════════════════════════
# 步骤 6：启动 OpenClaw Gateway
# ════════════════════════════════════════════════════════════════
echo ""
LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)

# 打印手动测试命令
echo -e "${YELLOW}手动测试推理接口（可直接复制执行）：${NC}"
echo -e "${CYAN}curl -s -X POST http://127.0.0.1:${INFERENCE_PORT}/v1/chat/completions \\
  -H 'Content-Type: application/json' -H 'Accept-Encoding: identity' \\
  -d '{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好，请介绍一下你自己\"}],\"max_tokens\":500,\"stream\":false}' \\
  | python3 -c \"import sys,json; r=json.load(sys.stdin); print(r['choices'][0]['message'].get('content') or r['choices'][0]['message'].get('reasoning_content',''))\"${NC}"
echo ""

echo -e "${YELLOW}[6/6] 正在启动 OpenClaw Gateway...${NC}"
echo ""

OPENCLAW_CONTAINER_CONFIG_PATH="/home/node/.openclaw/openclaw.json"

# 后台启动 Gateway 容器。使用默认 bridge 网络保留出站联网能力，但不共享宿主机网络栈。
docker run -d --name "$OPENCLAW_GATEWAY_CONTAINER_NAME" \
  --init \
  --network bridge \
  --add-host host.docker.internal:host-gateway \
  -p "0.0.0.0:${GATEWAY_PORT}:${GATEWAY_CONTAINER_PORT}" \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,nosuid,nodev,size=256m \
  -e HOME=/home/node \
  -e OPENCLAW_CONFIG_PATH="${OPENCLAW_CONTAINER_CONFIG_PATH}" \
  -e OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1 \
  -e OPENCLAW_DISABLE_BONJOUR=1 \
  -e OPENCLAW_GATEWAY_TOKEN="${GATEWAY_TOKEN}" \
  -v "${CONFIG_DIR}:/home/node/.openclaw" \
  -v "${OPENCLAW_PLUGIN_DIR}:/var/lib/openclaw/plugin-runtime-deps" \
  "$OPENCLAW_IMAGE" \
  node dist/index.js gateway --allow-unconfigured --bind lan --port "${GATEWAY_CONTAINER_PORT}" >/dev/null

# 等待 Gateway 就绪。首次启动会 staging bundled runtime deps，可能需要 1-3 分钟。
echo -e "    等待 Gateway 就绪..."
GW_WAIT=0
GW_MAX_WAIT=300
_gateway_ready() {
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${GATEWAY_PORT}/?token=${GATEWAY_TOKEN}" 2>/dev/null || true)
    [[ "$status" =~ ^(200|302|401|403)$ ]]
}
while ! _gateway_ready; do
    sleep 1
    GW_WAIT=$((GW_WAIT + 1))
    if ! docker ps --format '{{.Names}}' | grep -q "^${OPENCLAW_GATEWAY_CONTAINER_NAME}$"; then
        echo -e "${RED}  ✗ Gateway 容器意外退出，请查看日志：${NC}"
        echo -e "${CYAN}      docker logs ${OPENCLAW_GATEWAY_CONTAINER_NAME}${NC}"
        exit 1
    fi
    if [[ $((GW_WAIT % 15)) -eq 0 ]]; then
        echo -e "    Gateway 仍在启动中（${GW_WAIT}s/${GW_MAX_WAIT}s），首次启动安装插件依赖会较慢..."
    fi
    if [[ $GW_WAIT -ge $GW_MAX_WAIT ]]; then
        echo -e "${RED}  ✗ Gateway 启动超时（${GW_MAX_WAIT}s），请查看日志：${NC}"
        echo -e "${CYAN}      docker logs ${OPENCLAW_GATEWAY_CONTAINER_NAME}${NC}"
        echo -e "${YELLOW}    当前端口映射：${NC}"
        docker ps --filter "name=^/${OPENCLAW_GATEWAY_CONTAINER_NAME}$" --format '      {{.Names}}  {{.Ports}}' 2>/dev/null || true
        echo -e "${YELLOW}    最近日志：${NC}"
        docker logs --tail 30 "$OPENCLAW_GATEWAY_CONTAINER_NAME" 2>/dev/null || true
        exit 1
    fi
done
echo -e "${GREEN}  ✓ Gateway 已就绪${NC}"

# 生成访问链接
# 使用 ?token= 查询参数格式（官方标准格式）
# Gateway 收到请求后会建立服务端 session cookie，后续页面内导航时浏览器自动携带 cookie，
# 不会因页面刷新而丢失认证（避免 device identity required 错误）
LOCAL_URL="http://127.0.0.1:${GATEWAY_PORT}/?token=${GATEWAY_TOKEN}"
LAN_URL="http://${LAN_IP}:${GATEWAY_PORT}/?token=${GATEWAY_TOKEN}"

echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    启动成功！访问链接如下                       ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  本机访问：  %-54s  ║\n" "${LOCAL_URL:0:54}"
printf "║  局域网访问：%-54s  ║\n" "${LAN_URL:0:54}"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  停止服务：bash start_all.sh stop                               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "完整局域网链接（请复制此链接，包含完整 token）："
echo -e "${CYAN}${LAN_URL}${NC}"
echo ""

# 保持前台运行，轮询 OpenClaw Gateway 容器是否存在
echo -e "${YELLOW}Gateway 已在后台运行（按 Ctrl+C 或运行 'bash start_all.sh stop' 停止）...${NC}"
trap 'echo -e "\n${YELLOW}正在停止 OpenClaw Gateway 容器...${NC}"; docker rm -f "$OPENCLAW_GATEWAY_CONTAINER_NAME" 2>/dev/null || true; exit 0' INT TERM
while docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${OPENCLAW_GATEWAY_CONTAINER_NAME}$"; do
    sleep 5
done
echo -e "${YELLOW}OpenClaw Gateway 已退出。${NC}"
