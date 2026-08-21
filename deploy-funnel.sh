#!/bin/bash
# 코스 퍼널 이벤트 배포 — 2026-08-21
#   · WAS: course_funnel_events 스키마 + 수집 API(/api/stats/course-event) + 집계 API
#   · WEB: 어드민 '코스 퍼널' 탭
# 앱은 다음 릴리즈에 나가므로, 서버가 먼저 받을 준비를 해둬야 한다.
set -e
cd "$(dirname "$0")"
KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"; WAS="ubuntu@114.110.181.49"
WEB_KEY="$KEYDIR/aeron-web-key.pem"; WEB="ubuntu@114.110.182.45"
PORT=30022
STAMP=$(date +%Y%m%d-%H%M%S)

echo "▶ 1/5 로컬 점검"
node --check server.js
grep -q "course_funnel_events" server.js || { echo "  ✗ 스키마 없음"; exit 1; }
grep -q "loadFunnel" admin/index.html || { echo "  ✗ 어드민 탭 없음"; exit 1; }
echo "  ✓ 통과"

echo "▶ 2/5 WAS 백업"
ssh -i "$WAS_KEY" -p $PORT "$WAS" \
  "mkdir -p /home/ubuntu/backups && cp /home/ubuntu/tteona-api/server.js /home/ubuntu/backups/server-$STAMP.js && ls -l /home/ubuntu/backups/server-$STAMP.js"

echo "▶ 3/5 WAS 배포"
scp -i "$WAS_KEY" -P $PORT -q server.js "$WAS":/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT "$WAS" "cd /home/ubuntu/tteona-api && pm2 restart tteona-api >/dev/null && sleep 3 && pm2 list | grep tteona-api"

echo "▶ 4/5 어드민 배포"
ssh -i "$WEB_KEY" -p $PORT "$WEB" \
  "sudo cp /var/www/tteona.kr/admin/index.html /home/ubuntu/backups/admin-$STAMP.html 2>/dev/null || true"
scp -i "$WEB_KEY" -P $PORT -q admin/index.html "$WEB":/tmp/admin.html
ssh -i "$WEB_KEY" -p $PORT "$WEB" \
  "sudo cp /tmp/admin.html /var/www/tteona.kr/admin/index.html && sudo chown www-data:www-data /var/www/tteona.kr/admin/index.html && rm -f /tmp/admin.html"

echo "▶ 5/5 검증"
sleep 2
echo -n "  헬스체크: "; curl -s -o /dev/null -w "%{http_code}\n" https://tteona.kr/api/health
echo -n "  수집 API(무인증 차단 확인): "; curl -s -o /dev/null -w "%{http_code}\n" -X POST https://tteona.kr/api/stats/course-event -H 'Content-Type: application/json' -d '{"event":"pin_tap","courseId":"x"}'
echo -n "  어드민 탭 반영: "; curl -s https://tteona.kr/admin/ | grep -c "코스 퍼널" || echo 0
ssh -i "$WAS_KEY" -p $PORT "$WAS" "cd /home/ubuntu/tteona-api && node -e \"
require('dotenv').config({quiet:true});const {Pool}=require('pg');
const p=new Pool({host:process.env.PG_HOST||'10.30.10.170',port:5432,user:process.env.PG_USER||'tteona',password:process.env.PG_PASSWORD,database:process.env.PG_DB||'tteona_db'});
p.query('SELECT COUNT(*)::int c FROM course_funnel_events').then(r=>{console.log('  테이블 생성 확인 — 현재 행:',r.rows[0].c);process.exit(0);}).catch(e=>{console.error('  ✗ 테이블 없음:',e.message);process.exit(1);});
\" 2>&1 | grep -v injected"

echo
echo "✅ 배포 완료. 되돌리기:"
echo "   ssh -i \"\$WAS_KEY\" -p $PORT $WAS \"cp /home/ubuntu/backups/server-$STAMP.js /home/ubuntu/tteona-api/server.js && pm2 restart tteona-api\""
