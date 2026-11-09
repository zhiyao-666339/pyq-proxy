# 朋友圈 AI 助手 · 后端代理启动脚本
# 用法：bash deploy.sh
# 会：构建 Docker 镜像、停旧容器、启新容器、等健康检查通过、打印访问地址
#
# 必填：ZHIPU_API_KEY
# 建议：AUTH_SECRET（账号 token 签名密钥，换掉会让旧登录失效）
# 可选：PROXY_TOKEN、FEISHU_APP_ID / FEISHU_APP_SECRET / FEISHU_FOLDER_TOKEN

set -euo pipefail

IMAGE="pyq-server:latest"
CONTAINER="pyq-server"
VOLUME="pyq-data"
PORT="8787"

if [ -z "${ZHIPU_API_KEY:-}" ]; then
  echo "❌ 请先 export ZHIPU_API_KEY=你的智谱Key" >&2
  exit 1
fi

# AUTH_SECRET 不填时容器会在数据卷里自动生成并持久化，但建议显式指定
if [ -z "${AUTH_SECRET:-}" ]; then
  echo "⚠️  未设置 AUTH_SECRET，将自动生成并保存在数据卷里"
fi

echo "📦 构建镜像"
docker build -t "$IMAGE" "$(dirname "$0")"

echo "🧹 清理旧容器"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "🚀 启动容器"
docker run -d --name "$CONTAINER" --restart=always \
  -p "$PORT:$PORT" \
  -v "$VOLUME:/app/data" \
  -e DATA_DIR=/app/data \
  -e TZ=Asia/Shanghai \
  -e ZHIPU_API_KEY="$ZHIPU_API_KEY" \
  ${AUTH_SECRET:+-e AUTH_SECRET="$AUTH_SECRET"} \
  ${PROXY_TOKEN:+-e PROXY_TOKEN="$PROXY_TOKEN"} \
  ${ALLOW_ORIGIN:+-e ALLOW_ORIGIN="$ALLOW_ORIGIN"} \
  ${FEISHU_APP_ID:+-e FEISHU_APP_ID="$FEISHU_APP_ID"} \
  ${FEISHU_APP_SECRET:+-e FEISHU_APP_SECRET="$FEISHU_APP_SECRET"} \
  ${FEISHU_FOLDER_TOKEN:+-e FEISHU_FOLDER_TOKEN="$FEISHU_FOLDER_TOKEN"} \
  "$IMAGE"

echo "⏳ 健康检查"
for i in 1 2 3 4 5; do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "✅ OK"
    curl -s "http://127.0.0.1:$PORT/health"
    echo
    echo "🌐 本机访问：http://127.0.0.1:$PORT"
    exit 0
  fi
  sleep 1
done

echo "❌ 启动失败，日志："
docker logs --tail 30 "$CONTAINER"
exit 1
