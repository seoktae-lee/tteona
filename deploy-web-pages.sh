#!/bin/bash
# tteona.kr 정적 파일 배포 (범용)
#
#   ./deploy-web-pages.sh index.html updates.html about.html
#
# 인자로 준 파일만 /var/www/tteona.kr 에 올린다. nginx·WAS는 건드리지 않는다.
# 백업은 웹 루트 바깥(/home/ubuntu/web-backups)에 남긴다.
set -euo pipefail

[ $# -ge 1 ] || { echo "사용법: $0 <파일...>   (예: $0 index.html updates.html)"; exit 1; }

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
WEB_SRC="$HOME/Documents/tteona-web"
WEB_ROOT="/var/www/tteona.kr"
BACKUP_DIR="/home/ubuntu/web-backups"
STAMP=$(date +%Y%m%d-%H%M%S)
FILES=("$@")

cd "$WEB_SRC"

echo "▶ [1/4] 로컬 검사..."
for f in "${FILES[@]}"; do
  test -f "$f" || { echo "  ✗ 없는 파일: $f"; exit 1; }
  case "$f" in
    *.html) python3 - "$f" <<'PY'
import sys, io, re
s = io.open(sys.argv[1], encoding='utf-8').read()
for tag in ('html', 'head', 'body'):
    o, c = len(re.findall(r'<%s[\s>]' % tag, s)), s.count('</%s>' % tag)
    assert o == c == 1, '%s: <%s> %d개 / </%s> %d개' % (sys.argv[1], tag, o, tag, c)
print('  %-18s 태그 균형 OK' % sys.argv[1])
PY
    ;;
    *) echo "  $f";;
  esac
done

echo "▶ [2/4] 백업 + 업로드..."
COPYFILE_DISABLE=1 tar czf /tmp/web-pages.tgz "${FILES[@]}"
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "mkdir -p $BACKUP_DIR && chmod 700 $BACKUP_DIR && cd $WEB_ROOT && \
   sudo tar czf $BACKUP_DIR/pages-$STAMP.tgz ${FILES[*]} && \
   sudo chown ubuntu:ubuntu $BACKUP_DIR/pages-$STAMP.tgz && ls -la $BACKUP_DIR/pages-$STAMP.tgz"
scp -i "$WEB_KEY" -P $PORT /tmp/web-pages.tgz "$WEB_HOST":/tmp/
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "sudo tar xzf /tmp/web-pages.tgz -C $WEB_ROOT && \
   sudo chown www-data:www-data ${FILES[*]/#/$WEB_ROOT/} && \
   sudo chmod 644 ${FILES[*]/#/$WEB_ROOT/} && \
   sudo find $WEB_ROOT -name '._*' -delete && \
   rm -f /tmp/web-pages.tgz && echo '  전개 완료'"
rm -f /tmp/web-pages.tgz

echo "▶ [3/4] 검증..."
fail=0
for f in "${FILES[@]}"; do
  url="https://tteona.kr/${f%index.html}"
  [ "$f" = "index.html" ] && url="https://tteona.kr/index.html"
  code=$(curl -s -o /tmp/_p -w '%{http_code}' "$url")
  same="다름"
  cmp -s /tmp/_p "$f" && same="로컬과 동일"
  printf "  %-40s %s · %s\n" "$url" "$code" "$same"
  { [ "$code" = "200" ] && [ "$same" = "로컬과 동일" ]; } || fail=1
done
rm -f /tmp/_p

echo "▶ [4/4] 결과"
if [ $fail -eq 0 ]; then
  echo "  ✅ 배포 완료"
else
  echo "  ⚠️ 검증 실패 — 롤백:"
  echo "   ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo tar xzf $BACKUP_DIR/pages-$STAMP.tgz -C $WEB_ROOT\""
  exit 1
fi
