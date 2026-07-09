#!/bin/bash
# 2026-07-10 수정 배포
#  - WAS: server.js — 크리에이터 랭킹 캐시 10분→2분, 인증마크 부여 API(/api/admin/users/:uid/verify),
#         UGC 번역 프록시(/api/translate + translation_cache 테이블 자동 생성)
#  - WEB: admin/index.html — 인증 컬럼·부여/해제 버튼, 동작하지 않던 blockUser/unblockUser 구현
#
# 참고: GOOGLE_TRANSLATE_KEY가 .env에 없으면 /api/translate는 원문을 그대로 반환한다(기능만 꺼짐).
#       키를 넣은 뒤에는 pm2 restart tteona-api 필요.
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADMIN_HTML="$HOME/Documents/tteona-web/admin/index.html"

echo "▶ [0/5] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"
test -f "$ADMIN_HTML" || { echo "admin/index.html 없음: $ADMIN_HTML"; exit 1; }

echo "▶ [1/5] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S) && ls -1 /home/ubuntu/tteona-api/server.js.bak-* | tail -3"

echo "▶ [2/5] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [3/5] WEB: 관리자 대시보드 백업 + 업로드..."
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo cp /var/www/tteona.kr/admin/index.html /var/www/tteona.kr/admin/index.html.bak-$(date +%Y%m%d-%H%M%S)"
scp -i "$WEB_KEY" -P $PORT "$ADMIN_HTML" $WEB_HOST:/tmp/admin-index.html
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mv /tmp/admin-index.html /var/www/tteona.kr/admin/index.html && sudo chown www-data:www-data /var/www/tteona.kr/admin/index.html"

echo "▶ [4/5] 헬스체크..."
sleep 1
for u in "https://tteona.kr/api/vlog/bgm" "https://tteona.kr/admin/"; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$u")
  echo "  $u → HTTP $CODE $([ "$CODE" = "200" ] && echo "✅" || echo "⚠️")"
done
# 인증 API는 토큰 없이 401이 나와야 정상 (엔드포인트 존재 + adminAuth 동작 확인)
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
  -H 'Content-Type: application/json' -d '{"verified":true}' \
  "https://tteona.kr/api/admin/users/__probe__/verify")
echo "  /api/admin/users/:uid/verify (인증 없음) → HTTP $CODE $([ "$CODE" = "401" ] && echo "✅ 예상대로 401" || echo "⚠️ 401이어야 정상")"

# 번역 프록시도 requireAuth — 토큰 없이 401이면 라우트가 살아 있다는 뜻 (404면 배포 실패)
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
  -H 'Content-Type: application/json' -d '{"texts":["테스트"],"target":"en"}' \
  "https://tteona.kr/api/translate")
echo "  /api/translate (인증 없음) → HTTP $CODE $([ "$CODE" = "401" ] && echo "✅ 예상대로 401" || echo "⚠️ 401이어야 정상 (404면 라우트 미배포)")"

echo "  translation_cache 테이블 생성 확인..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 logs tteona-api --nostream --lines 40 | grep -i 'Translate.*schema' || echo '  (스키마 오류 로그 없음 = 정상)'"

echo "▶ [5/5] 배포된 대시보드에 새 코드가 들어갔는지 확인..."
curl -s --max-time 10 https://tteona.kr/admin/ | grep -c "verifyUser" | sed 's/^/  verifyUser 등장 횟수: /'

echo ""
echo "✅ 배포 완료!"
echo "   롤백: WAS의 server.js.bak-* / WEB의 index.html.bak-* 를 되돌린 뒤 pm2 restart tteona-api"
