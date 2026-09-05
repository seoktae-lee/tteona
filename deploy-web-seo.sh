#!/bin/bash
# 2026-09-05 tteona.kr 검색 노출 + 유입 측정 배포
#  - robots.txt / sitemap.xml 신설
#  - 전 페이지 canonical · OG · twitter 카드 보강, 랜딩에 JSON-LD 구조화 데이터
#  - 업데이트 노트를 v1.3.2까지 현행화
#  - 스토어 클릭 집계용 1x1 픽셀(/px/) + 각 페이지 수집 스크립트
#
# WAS/nginx는 건드리지 않는다 — /var/www/tteona.kr 정적 파일만 교체한다.
set -euo pipefail

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
WEB_SRC="$HOME/Documents/tteona-web"
WEB_ROOT="/var/www/tteona.kr"
BACKUP_DIR="/home/ubuntu/web-backups"
STAMP=$(date +%Y%m%d-%H%M%S)

PAGES=(index.html updates.html about.html privacy.html terms.html child-safety.html
       course.html room.html explore/index.html)
NEW=(robots.txt sitemap.xml px/store-ios.gif px/store-android.gif)
ALL=("${PAGES[@]}" "${NEW[@]}")

cd "$WEB_SRC"

echo "▶ [0/5] 로컬 검사..."
for f in "${ALL[@]}"; do test -f "$f" || { echo "  ✗ 누락: $f"; exit 1; }; done
python3 - <<'PY'
import xml.dom.minidom, io, re, json, sys
xml.dom.minidom.parse('sitemap.xml')
s = io.open('index.html', encoding='utf-8').read()
json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', s, re.S).group(1))
for f in ['index.html','updates.html','about.html','privacy.html','terms.html','child-safety.html','explore/index.html']:
    t = io.open(f, encoding='utf-8').read()
    assert 'rel="canonical"' in t, f + ' canonical 없음'
    assert 'og:title' in t, f + ' og 없음'
assert 'v1.3.2' in io.open('updates.html', encoding='utf-8').read(), '업데이트 노트가 옛 버전'
print('  sitemap XML · JSON-LD 파싱 OK · canonical/OG 7개 페이지 확인')
PY
grep -q "'/px/store-'" index.html || { echo "  ✗ 클릭 수집 스크립트 없음"; exit 1; }
echo "  파일 ${#ALL[@]}개 확인"

echo "▶ [1/5] 배포 꾸러미 생성..."
COPYFILE_DISABLE=1 tar czf /tmp/web-seo-deploy.tgz "${ALL[@]}"
tar tzf /tmp/web-seo-deploy.tgz | sed 's/^/  /'

echo "▶ [2/5] WEB: 기존 HTML 백업 (웹 루트 바깥)..."
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "mkdir -p $BACKUP_DIR && chmod 700 $BACKUP_DIR && cd $WEB_ROOT && \
   sudo tar czf $BACKUP_DIR/web-seo-$STAMP.tgz ${PAGES[*]} && \
   sudo chown ubuntu:ubuntu $BACKUP_DIR/web-seo-$STAMP.tgz && \
   ls -la $BACKUP_DIR/web-seo-$STAMP.tgz"

echo "▶ [3/5] WEB: 업로드 + 전개..."
scp -i "$WEB_KEY" -P $PORT /tmp/web-seo-deploy.tgz "$WEB_HOST":/tmp/
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "sudo tar xzf /tmp/web-seo-deploy.tgz -C $WEB_ROOT && \
   sudo chown -R www-data:www-data $WEB_ROOT/px && \
   sudo chown www-data:www-data ${ALL[*]/#/$WEB_ROOT/} && \
   sudo chmod 644 ${ALL[*]/#/$WEB_ROOT/} && \
   sudo chmod 755 $WEB_ROOT/px && \
   rm -f /tmp/web-seo-deploy.tgz && \
   ls -la $WEB_ROOT/robots.txt $WEB_ROOT/sitemap.xml $WEB_ROOT/px/"
rm -f /tmp/web-seo-deploy.tgz

echo "▶ [4/5] 검증 (HTTP)..."
fail=0
check() { # url 기대코드 [본문에 있어야 하는 문자열]
  code=$(curl -s -o /tmp/_c -w '%{http_code}' "$1")
  ok="$code"
  if [ -n "${3:-}" ] && ! grep -q "$3" /tmp/_c; then ok="$code(본문불일치)"; fi
  printf "  %-46s %s\n" "$1" "$ok"
  [ "$ok" = "$2" ] || fail=1
}
check "https://tteona.kr/robots.txt"            200 "Sitemap: https://tteona.kr/sitemap.xml"
check "https://tteona.kr/sitemap.xml"           200 "<loc>https://tteona.kr/</loc>"
check "https://tteona.kr/px/store-ios.gif"      200
check "https://tteona.kr/px/store-android.gif"  200
check "https://tteona.kr/index.html"            200 "application/ld+json"
check "https://tteona.kr/updates.html"          200 "v1.3.2"
check "https://tteona.kr/about.html"            200 "rel=\"canonical\""
check "https://tteona.kr/explore/"              200 "rel=\"canonical\""
rm -f /tmp/_c

echo "▶ [5/5] 결과"
if [ $fail -eq 0 ]; then
  echo "  ✅ 배포 완료"
  echo "  다음: 구글 서치콘솔 / 네이버 서치어드바이저에 sitemap.xml 제출 (수동)"
else
  echo "  ⚠️ 검증 실패 — 롤백:"
  echo "   ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo tar xzf $BACKUP_DIR/web-seo-$STAMP.tgz -C $WEB_ROOT\""
  exit 1
fi
