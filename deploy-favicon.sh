#!/bin/bash
# 2026-07-26 파비콘 배포
#  - WEB: /var/www/tteona.kr/ 루트에 favicon.ico(16/32/48) + PNG 2종 + apple-touch-icon 추가
#         HTML 12개 <head>에 link 태그 삽입 (절대경로 + ?v=2)
#
# WAS는 건드리지 않는다 — 정적 파일만 바뀐다.
# nginx도 건드리지 않는다 — 기존 정적 루트로 그대로 서빙된다.
# 백업은 웹 루트 바깥(/home/ubuntu/web-backups)에 둔다 — 루트에 두면 nginx가 그대로 서빙한다.
set -euo pipefail

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
WEB_SRC="$HOME/Documents/tteona-web"
WEB_ROOT="/var/www/tteona.kr"
BACKUP_DIR="/home/ubuntu/web-backups"
STAMP=$(date +%Y%m%d-%H%M%S)

ICONS=(favicon.ico favicon-16x16.png favicon-32x32.png apple-touch-icon.png)
PAGES=(index.html about.html course.html popular.html privacy.html terms.html
       updates.html child-safety.html room.html
       course/index.html room/index.html explore/index.html)
ALL=("${ICONS[@]}" "${PAGES[@]}")

cd "$WEB_SRC"

echo "▶ [0/5] 로컬 검사..."
for f in "${ALL[@]}"; do test -f "$f" || { echo "  ✗ 누락: $f"; exit 1; }; done
python3 -c "
from PIL import Image
ico = Image.open('favicon.ico')
assert sorted(ico.ico.sizes()) == [(16,16),(32,32),(48,48)], ico.ico.sizes()
assert Image.open('apple-touch-icon.png').size == (180,180)
print('  ICO 16/32/48 · apple-touch 180² 확인')"
for f in "${PAGES[@]}"; do
  grep -q 'favicon.ico?v=2' "$f" || { echo "  ✗ link 태그 없음: $f"; exit 1; }
done
echo "  파일 ${#ALL[@]}개 확인"

echo "▶ [1/5] 배포 꾸러미 생성..."
tar czf /tmp/favicon-deploy.tgz "${ALL[@]}"
tar tzf /tmp/favicon-deploy.tgz | sed 's/^/  /'

echo "▶ [2/5] WEB: 기존 HTML 백업 (웹 루트 바깥)..."
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "mkdir -p $BACKUP_DIR && chmod 700 $BACKUP_DIR && cd $WEB_ROOT && \
   sudo tar czf $BACKUP_DIR/html-$STAMP.tgz ${PAGES[*]} && \
   sudo chown ubuntu:ubuntu $BACKUP_DIR/html-$STAMP.tgz && \
   ls -la $BACKUP_DIR/html-$STAMP.tgz"

echo "▶ [3/5] WEB: 업로드 + 전개..."
scp -i "$WEB_KEY" -P $PORT /tmp/favicon-deploy.tgz "$WEB_HOST":/tmp/
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "sudo tar xzf /tmp/favicon-deploy.tgz -C $WEB_ROOT && \
   sudo chown www-data:www-data ${ALL[*]/#/$WEB_ROOT/} && \
   sudo chmod 644 ${ALL[*]/#/$WEB_ROOT/} && \
   rm -f /tmp/favicon-deploy.tgz && \
   ls -la $WEB_ROOT/favicon.ico $WEB_ROOT/apple-touch-icon.png"
rm -f /tmp/favicon-deploy.tgz

echo "▶ [4/5] 공개 URL 검증..."
fail=0
for u in "https://tteona.kr/favicon.ico" \
         "https://tteona.kr/favicon.ico?v=2" \
         "https://tteona.kr/favicon-16x16.png?v=2" \
         "https://tteona.kr/favicon-32x32.png?v=2" \
         "https://tteona.kr/apple-touch-icon.png?v=2"; do
  out=$(curl -s -o /dev/null -w "%{http_code} %{content_type}" "$u")
  echo "  $out  $u"
  [[ "$out" == 200* ]] || fail=1
done
# 백업이 외부에 노출되지 않는지 확인 (404여야 정상)
b=$(curl -s -o /dev/null -w "%{http_code}" "https://tteona.kr/backup-html-$STAMP.tgz")
echo "  $b  (백업 노출 점검 — 404여야 정상)"
[ "$b" = "404" ] || fail=1

echo "▶ [5/5] HTML에 link 태그 반영 확인..."
for u in "https://tteona.kr/" "https://tteona.kr/privacy.html" "https://tteona.kr/explore/"; do
  n=$(curl -s "$u" | grep -c 'favicon.ico?v=2' || true)
  echo "  link ${n}건  $u"
  [ "$n" -ge 1 ] || fail=1
done

if [ $fail -ne 0 ]; then
  echo "❌ 검증 실패 — 롤백 명령:"
  echo "   ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo tar xzf $BACKUP_DIR/html-$STAMP.tgz -C $WEB_ROOT\""
  exit 1
fi
echo "✅ 배포 완료 — 백업: $BACKUP_DIR/html-$STAMP.tgz"
