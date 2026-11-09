#!/usr/bin/env bash
# ============================================================================
# 朋友圈 AI 助手 · Oracle Cloud Always Free 一键部署脚本
# 适用：Ubuntu 22.04 / 24.04（ARM Ampere A1 或 AMD x86）
# 作用：安装 Docker + Nginx + Certbot → 开放端口 → 部署 pyq-server → 申请 HTTPS
#
# 用法（在 Oracle 实例里 SSH 登录后执行）：
#   1) 把本脚本和 server.js、Dockerfile 放到同一目录（如 ~/pyq-proxy）
#   2) export ZHIPU_API_KEY=你的智谱Key
#   3) export DOMAIN=你的域名（如 pyq.example.com，需已解析到实例公网 IP）
#   4) sudo bash oracle-setup.sh
#
# 可选环境变量：
#   AUTH_SECRET、PROXY_TOKEN、ALLOW_ORIGIN、FEISHU_APP_ID、FEISHU_APP_SECRET、FEISHU_FOLDER_TOKEN
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${DOMAIN:?请先 export DOMAIN=你的域名}"
ZHIPU_API_KEY="${ZHIPU_API_KEY:?请先 export ZHIPU_API_KEY=你的智谱Key}"
LE_EMAIL="${LE_EMAIL:-admin@$DOMAIN}"

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请用 sudo 运行：sudo bash $0" >&2
  exit 1
fi

echo "=== 1/6 安装 Docker ==="
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  systemctl enable --now docker
fi
docker --version

echo "=== 2/6 开放 Oracle iptables 端口（80/443/8787）==="
# Oracle 默认 iptables 只放行 22，需手动开放；同时持久化到 /etc/iptables/rules.v4
apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
for port in 80 443 8787; do
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
done
# Oracle 的 INPUT 链默认 DROP，确保 ESTABLISHED 放行
iptables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save
fi
echo "已开放 80 / 443 / 8787"

echo "=== 3/6 构建并启动 pyq-server 容器 ==="
if [ ! -f "$SCRIPT_DIR/server.js" ] || [ ! -f "$SCRIPT_DIR/Dockerfile" ]; then
  echo "❌ 当前目录缺少 server.js 或 Dockerfile，请确认脚本与它们在同一目录：$SCRIPT_DIR" >&2
  exit 1
fi
docker build -t pyq-server:latest "$SCRIPT_DIR"
docker rm -f pyq-server >/dev/null 2>&1 || true
docker run -d --name pyq-server --restart=always \
  -p 8787:8787 \
  -v pyq-data:/app/data \
  -e DATA_DIR=/app/data \
  -e TZ=Asia/Shanghai \
  -e ZHIPU_API_KEY="$ZHIPU_API_KEY" \
  ${AUTH_SECRET:+-e AUTH_SECRET="$AUTH_SECRET"} \
  ${PROXY_TOKEN:+-e PROXY_TOKEN="$PROXY_TOKEN"} \
  ${ALLOW_ORIGIN:+-e ALLOW_ORIGIN="$ALLOW_ORIGIN"} \
  ${FEISHU_APP_ID:+-e FEISHU_APP_ID="$FEISHU_APP_ID"} \
  ${FEISHU_APP_SECRET:+-e FEISHU_APP_SECRET="$FEISHU_APP_SECRET"} \
  ${FEISHU_FOLDER_TOKEN:+-e FEISHU_FOLDER_TOKEN="$FEISHU_FOLDER_TOKEN"} \
  pyq-server:latest

for i in $(seq 1 10); do
  if curl -fsS "http://127.0.0.1:8787/health" >/dev/null 2>&1; then
    echo "✅ pyq-server 已启动"
    curl -s "http://127.0.0.1:8787/health"; echo
    break
  fi
  sleep 1
  [ "$i" = 10 ] && { echo "❌ pyq-server 启动失败，日志："; docker logs --tail 30 pyq-server; exit 1; }
done

echo "=== 4/6 安装 Nginx ==="
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install -y -qq nginx
  systemctl enable --now nginx
fi

echo "=== 5/6 配置 Nginx 反向代理（HTTP 先通过，用于 Certbot 验证）==="
cat > /etc/nginx/sites-available/pyq-server <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 24m;
    proxy_read_timeout 240s;
    proxy_send_timeout 240s;
    proxy_connect_timeout 10s;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    add_header Access-Control-Allow-Origin "\$http_origin" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type, Authorization, X-Pyq-Token" always;
    add_header Access-Control-Allow-Credentials "true" always;
    if (\$request_method = OPTIONS) {
        add_header Access-Control-Max-Age 86400 always;
        return 204;
    }
    location / {
        proxy_pass http://127.0.0.1:8787;
    }
}
EOF
ln -sf /etc/nginx/sites-available/pyq-server /etc/nginx/sites-enabled/pyq-server
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
echo "✅ Nginx 已配置，HTTP 转发到 8787"

echo "=== 6/6 申请 HTTPS 证书（Let's Encrypt）==="
if ! command -v certbot >/dev/null 2>&1; then
  apt-get install -y -qq certbot python3-certbot-nginx
fi
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect || {
  echo "⚠️  HTTPS 申请失败（可能是域名未解析或 80 端口未通），请检查后手动运行：certbot --nginx -d $DOMAIN"
  echo "当前 HTTP 已可用：http://$DOMAIN/health"
  exit 0
}
systemctl reload nginx
echo "✅ HTTPS 已启用：https://$DOMAIN/health"

echo ""
echo "========================================="
echo "🎉 部署完成！"
echo "   健康检查：https://$DOMAIN/health"
echo "   数据持久化卷：pyq-data（/app/data）"
echo "   每日 0 点学习：容器内自动调度（Asia/Shanghai）"
echo "   查看日志：docker logs -f pyq-server"
echo "========================================="
