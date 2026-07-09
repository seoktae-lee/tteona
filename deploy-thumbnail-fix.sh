#!/bin/bash
# 썸네일/아바타 표시 버그 수정 배포
#  - WEB nginx: location /uploads/ → ^~ /uploads/ (정규식 \.(jpg|png)$ 우선매칭 차단)
#  - WAS server.js: 썸네일 POST에 ?v=timestamp 캐시버스트
# 안전장치: nginx -t 성공 시에만 reload(실패 시 자동 롤백), pm2는 git 이전버전으로 롤백 가능
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "▶ [1/4] WEB: nginx uploads location 우선순위 수정 (^~) + 검증 게이트..."
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" 'bash -s' <<'REMOTE'
set -e
CONF=/etc/nginx/conf.d/tteona.conf
BAK="$CONF.deploybak.$(date +%s)"
sudo cp "$CONF" "$BAK"
echo "  백업: $BAK"
if grep -q '^    location \^~ /uploads/ {' "$CONF"; then
  echo "  이미 ^~ 적용됨 — 스킵"
else
  sudo sed -i 's|^    location /uploads/ {|    location ^~ /uploads/ {|' "$CONF"
  echo "  변경 후:"; grep -n 'location .*/uploads/ {' "$CONF"
fi
if sudo nginx -t; then
  sudo systemctl reload nginx
  echo "  ✅ nginx reload 완료"
else
  echo "  ⚠️ nginx -t 실패 — 롤백"
  sudo cp "$BAK" "$CONF"
  exit 1
fi
REMOTE

echo "▶ [2/4] WAS: server.js 업로드 (썸네일 ?v= 캐시버스트 포함)..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" "$WAS_HOST":/home/ubuntu/tteona-api/server.js

echo "▶ [3/4] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT "$WAS_HOST" \
  "pm2 restart tteona-api && sleep 2 && pm2 logs tteona-api --nostream --lines 6"

echo "▶ [4/4] 동작 테스트 (jpg가 이제 Express에서 응답해야 함)..."
sleep 1
# 존재하지 않는 썸네일 → Express는 JSON 404(정상 프록시), nginx 정적404면 text/html(버그)
CT=$(curl -s -o /dev/null -w "%{content_type}" "https://tteona.kr/uploads/thumbnails/__probe__.jpg")
echo "  /uploads/thumbnails/__probe__.jpg content-type: $CT"
if echo "$CT" | grep -qi json; then
  echo "  ✅ WAS 프록시 정상 (jpg가 Express로 도달)"
else
  echo "  ⚠️ 여전히 정적 응답 — nginx 반영 확인 필요"
fi

echo ""
echo "✅ 배포 완료!"
