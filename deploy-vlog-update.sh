#!/bin/bash
# Vlog 품질 개선 배포: 포맷별 독립 합성 + BGM 선택 API + 로고 타이틀카드 + 법률 문서 3종
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGO="$SCRIPT_DIR/assets/tteona-logo.png"

echo "▶ [1/6] WAS: server.js + 로고 업로드..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST "mkdir -p /home/ubuntu/tteona-api/assets/bgm/{couple,friends,family,solo}"
scp -i "$WAS_KEY" -P $PORT "$LOGO" $WAS_HOST:/home/ubuntu/tteona-api/assets/tteona-logo.png

echo "▶ [2/6] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 restart tteona-api && sleep 2 && pm2 logs tteona-api --nostream --lines 6"

echo "▶ [3/6] WEB: 법률 문서 3종 업로드..."
scp -i "$WEB_KEY" -P $PORT \
  "$SCRIPT_DIR/web/privacy.html" \
  "$SCRIPT_DIR/web/terms.html" \
  "$SCRIPT_DIR/web/child-safety.html" \
  $WEB_HOST:/var/www/tteona.kr/

echo "▶ [4/6] BGM 트랙 확인..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "find /home/ubuntu/tteona-api/assets/bgm -type f | head -20; echo '(비어 있으면 BGM 목록이 빈 상태로 내려감 — 자동/없음 옵션만 표시)'"

echo "▶ [5/6] 동작 테스트..."
sleep 1
for u in "https://tteona.kr/api/health" "https://tteona.kr/api/vlog/bgm" "https://tteona.kr/privacy.html" "https://tteona.kr/terms.html" "https://tteona.kr/child-safety.html"; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  echo "  $u → HTTP $CODE $([ "$CODE" = "200" ] && echo "✅" || echo "⚠️")"
done

echo "▶ [6/6] Vlog E2E 스모크 테스트 (잡 생성→합성→완성본 다운로드 관통)..."
"$SCRIPT_DIR/smoke-test-vlog.sh"

echo ""
echo "✅ 배포 완료!"
