#!/bin/bash
# 관리자 세션 토큰화 배포 (보안감사 S5)
#  - WAS: server.js — 정적 ADMIN_TOKEN 폐기, 로그인마다 24h 만료 랜덤 세션 토큰 발급 + /api/admin/logout
#  - WEB: admin/index.html — 로그아웃 시 서버 세션 무효화 호출
#  배포 즉시 기존 정적 토큰은 전부 401 → 대시보드는 자동으로 재로그인 화면 전환 (프론트 401 핸들러)
# 2026-07-14
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "▶ [1/5] WAS: server.js 업로드..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js

echo "▶ [2/5] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 restart tteona-api && sleep 2 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [3/5] WEB: admin/index.html 업로드 (백업 후 교체)..."
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo cp /var/www/tteona.kr/admin/index.html /var/www/tteona.kr/admin/index.html.bak-\$(date +%Y%m%d-%H%M%S)"
scp -i "$WEB_KEY" -P $PORT "$SCRIPT_DIR/admin/index.html" $WEB_HOST:/tmp/admin-index.html
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mv /tmp/admin-index.html /var/www/tteona.kr/admin/index.html"

echo "▶ [4/5] 검증 (무인)..."
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
echo "  /api/health → HTTP $CODE $([ "$CODE" = "200" ] && echo ✅ || echo ❌)"
# 구 정적 토큰(임의 문자열 포함 비세션 토큰)은 전부 401이어야 함
CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer not-a-session-token" https://tteona.kr/api/admin/stats)
echo "  비세션 토큰으로 admin/stats → HTTP $CODE $([ "$CODE" = "401" ] && echo ✅ || echo ❌)"
# 틀린 비밀번호 로그인 → 401 (브루트포스 카운터 1회만 소모)
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST https://tteona.kr/api/admin/login \
  -H "Content-Type: application/json" -d '{"password":"wrong-password-probe"}')
echo "  틀린 비번 로그인 → HTTP $CODE $([ "$CODE" = "401" ] && echo ✅ || echo ❌)"
# WS 프록시 생존 확인 (nginx 무변경이지만 재배포 후 101 확인은 상시 수칙)
WS=$(curl -s -o /dev/null -w "%{http_code}" -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://tteona.kr/ws/location)
echo "  /ws/location 업그레이드 → HTTP $WS $([ "$WS" = "101" ] && echo ✅ || echo "❌ (/ws/ 블록 확인!)")"

echo "▶ [5/5] 검증 (선택 — 실제 로그인 E2E)..."
read -r -s -p "  관리자 비밀번호 (엔터만 치면 건너뜀): " ADMIN_PW; echo
if [ -n "$ADMIN_PW" ]; then
  TOKEN=$(curl -s -X POST https://tteona.kr/api/admin/login \
    -H "Content-Type: application/json" -d "{\"password\":\"$ADMIN_PW\"}" |
    python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
  if [ -z "$TOKEN" ]; then echo "  로그인 실패 ❌"; exit 1; fi
  echo "  로그인 → 세션 토큰 발급 ✅ (${TOKEN:0:8}…)"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" https://tteona.kr/api/admin/stats)
  echo "  세션 토큰으로 stats → HTTP $CODE $([ "$CODE" = "200" ] && echo ✅ || echo ❌)"
  curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" https://tteona.kr/api/admin/logout
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" https://tteona.kr/api/admin/stats)
  echo "  로그아웃 후 같은 토큰 → HTTP $CODE $([ "$CODE" = "401" ] && echo "✅ (세션 무효화 동작)" || echo ❌)"
fi

echo ""
echo "✅ 배포 완료."
echo "  · WAS의 .env에서 ADMIN_TOKEN 줄은 이제 사용되지 않음 — 다음 정리 때 삭제해도 무방"
echo "  · 브라우저에 남은 구 토큰은 첫 API 호출에서 401 → 자동 재로그인 화면"
