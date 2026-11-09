#!/usr/bin/env bash
# 朋友圈 AI 助手 · 后端代理联调自测脚本
# 用法：
#   1) export ZHIPU_API_KEY=你的智谱Key
#   2) cd /workspace/pyq-proxy && bash deploy.sh   # 或 docker build + run
#   3) bash smoke.sh https://你的域名 你的PROXY_TOKEN
set -euo pipefail

BASE="${1:-http://127.0.0.1:8787}"
TOKEN="${2:-}"

hdr() { echo "━━━ $1 ━━━"; }
CURL="curl -sS --max-time 60 ${TOKEN:+ -H \"X-Pyq-Token: $TOKEN\"}"

echo "🌐 代理根地址：$BASE"

hdr "健康检查"
curl -sS "$BASE/health"; echo

TEST_PHONE="139$(date +%H%M%S)00"
TEST_PHONE="${TEST_PHONE:0:11}"
hdr "账号：注册 / 登录 / 云同步 / 画像（测试手机号 $TEST_PHONE）"
REG=$(curl -sS -X POST "$BASE/auth/register" -H "Content-Type: application/json" \
  -d "{\"account\":\"$TEST_PHONE\",\"password\":\"smoke123456\",\"nickname\":\"自测\"}")
echo "$REG" | head -c 260; echo
TOKEN_USER=$(echo "$REG" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{try{console.log(JSON.parse(s).token||'')}catch(e){}})" 2>/dev/null || true)
if [ -n "$TOKEN_USER" ]; then
  curl -sS -X PUT "$BASE/sync" -H "Authorization: Bearer $TOKEN_USER" -H "Content-Type: application/json" \
    -d '{"payload":{"user":{"name":"自测"},"profileSections":[{"id":"who","content":"做母婴用品的小店主"}],"materials":{"copy":[{"text":"今天带娃去公园，风很大。"}]}},"baseUpdatedAt":""}'; echo
  curl -sS "$BASE/sync" -H "Authorization: Bearer $TOKEN_USER" | head -c 300; echo
  curl -sS -X POST "$BASE/persona/build" -H "Authorization: Bearer $TOKEN_USER" \
    -H "Content-Type: application/json" -d '{"force":true}' | head -c 400; echo
fi

hdr "文案生成（glm-4-flash）"
$CURL -X POST "$BASE/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-4-flash","temperature":0.7,"messages":[{"role":"user","content":"只说两个字：你好"}]}'
echo

hdr "图片生成（cogview-3-flash）"
$CURL -X POST "$BASE/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"model":"cogview-3-flash","size":"1024x1024","prompt":"一只戴着墨镜的柴犬，写实风"}'
echo

hdr "视频任务（cogvideox-flash，异步，会返回 task id）"
VIDEO_TASK=$($CURL -X POST "$BASE/v1/videos/generations" \
  -H "Content-Type: application/json" \
  -d '{"model":"cogvideox-flash","prompt":"日出时分的海边航拍"}')
echo "$VIDEO_TASK" | head -c 400; echo
TASK_ID=$(echo "$VIDEO_TASK" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
echo "task_id=$TASK_ID"
if [ -n "$TASK_ID" ]; then
  echo "等 10s 轮询一次…"
  sleep 10
  $CURL -X GET "$BASE/async-result/$TASK_ID"; echo
fi

hdr "图片云审（/moderate，先用一张 dataurl）"
# 1×1 纯色 PNG 的 dataurl（base64），体积小但模型能识别
TINY_PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
$CURL -X POST "$BASE/moderate" \
  -H "Content-Type: application/json" \
  -d "{\"task\":\"image\",\"mimeType\":\"image/png\",\"fileBase64\":\"$TINY_PNG\"}"
echo

hdr "不支持的模型 → 400"
$CURL -w "\nHTTP=%{http_code}\n" -X POST "$BASE/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}' | tail -2

hdr "无令牌 → 401（若部署时设置了 PROXY_TOKEN）"
curl -sS -w "\nHTTP=%{http_code}\n" -X POST "$BASE/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-4-flash","messages":[{"role":"user","content":"hi"}]}' | tail -2

hdr "OPTIONS 预检（网页版跨域必备）"
curl -sS -D - -o /dev/null -X OPTIONS "$BASE/chat/completions" | grep -iE "access-control|HTTP/"
echo
echo "✅ 全部跑完。文案应该能看到一段 30-80 字的朋友圈；图片返回 url；视频有 task_id；云审返回 blocked=false。"
