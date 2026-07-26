#!/bin/bash
# 2026-07-14 미니 웹앱(코스 탐색 PWA) 배포
#  - WAS: server.js — 공개 탐색 API GET /api/public/explore (로그인 불필요, 5분 캐시, IP 레이트리밋)
#  - WEB: /var/www/tteona.kr/explore/ 신규 (index.html + manifest + sw.js + icons)
#         index.html·popular.html — 네비게이션에 "코스 탐색" 링크 추가
#
# nginx는 건드리지 않는다 — /explore는 기존 정적 루트, /api/는 기존 프록시로 충분.
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEB_SRC="$HOME/Documents/tteona-web"

echo "▶ [0/6] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"
test -f "$WEB_SRC/explore/index.html"
test -f "$WEB_SRC/explore/manifest.json"
test -f "$WEB_SRC/explore/sw.js"
test -f "$WEB_SRC/explore/icons/icon-512.png"

echo "▶ [1/6] WAS: server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [2/6] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 6"

echo "▶ [3/6] WAS: 공개 탐색 API 스모크 테스트 (로컬호스트)..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "curl -sf 'http://localhost:3000/api/public/explore?sort=latest&limit=2' | head -c 400; echo"

echo "▶ [4/6] WEB: 랜딩 백업 + explore 업로드..."
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "mkdir -p /home/ubuntu/web-backups && chmod 700 /home/ubuntu/web-backups && \
   sudo cp /var/www/tteona.kr/index.html /home/ubuntu/web-backups/index.html.bak-$(date +%Y%m%d-%H%M%S) && \
   sudo cp /var/www/tteona.kr/popular.html /home/ubuntu/web-backups/popular.html.bak-$(date +%Y%m%d-%H%M%S)"
scp -i "$WEB_KEY" -P $PORT -r "$WEB_SRC/explore" $WEB_HOST:/tmp/explore-deploy
scp -i "$WEB_KEY" -P $PORT "$WEB_SRC/index.html" "$WEB_SRC/popular.html" $WEB_HOST:/tmp/
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo rm -rf /var/www/tteona.kr/explore && \
   sudo mv /tmp/explore-deploy /var/www/tteona.kr/explore && \
   sudo mv /tmp/index.html /var/www/tteona.kr/index.html && \
   sudo mv /tmp/popular.html /var/www/tteona.kr/popular.html && \
   sudo chown -R www-data:www-data /var/www/tteona.kr/explore /var/www/tteona.kr/index.html /var/www/tteona.kr/popular.html"

echo "▶ [5/6] 공개 URL 검증..."
for u in "https://tteona.kr/explore/" \
         "https://tteona.kr/explore/manifest.webmanifest" \
         "https://tteona.kr/explore/sw.js" \
         "https://tteona.kr/explore/icons/icon-192.png" \
         "https://tteona.kr/api/public/explore?sort=popular&limit=2"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  echo "  $code  $u"
done

echo "▶ [6/6] manifest Content-Type 확인 (application/manifest+json 권장)..."
curl -sI "https://tteona.kr/explore/manifest.webmanifest" | grep -i content-type

echo "✅ 배포 완료 — https://tteona.kr/explore/"
