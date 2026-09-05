#!/bin/bash
# tteona.kr 웹 유입/전환 집계
#
#   ./web-stats.sh [일수]      (기본 14일)
#
# 웹서버 nginx 액세스 로그만 읽는다 — 쿠키도, 개인 식별 정보도 쓰지 않는다.
# 스토어 클릭은 각 페이지에 심은 1x1 픽셀(/px/store-{ios,android}.gif) 요청으로 센다.
set -euo pipefail

DAYS="${1:-14}"
KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022

echo "▶ 최근 ${DAYS}일 tteona.kr (봇 제외)"
printf "%-12s %7s %7s %7s %7s %8s\n" "날짜" "랜딩" "기타" "iOS" "AOS" "전환율"

ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" "DAYS=$DAYS sudo -E bash -s" <<'REMOTE' | sort | awk '
{
  v=$2; s=$3; i=$4; a=$5
  cr = (v>0) ? (i+a)*100.0/v : 0
  printf "%-12s %7d %7d %7d %7d %7.1f%%\n", $1, v, s, i, a, cr
  tv+=v; ts+=s; ti+=i; ta+=a
}
END {
  printf "%-12s %7d %7d %7d %7d %7.1f%%\n", "합계", tv, ts, ti, ta, (tv>0?(ti+ta)*100.0/tv:0)
}'
LOG=/var/log/nginx/tteona.access.log
CUTOFF=$(date -d "-${DAYS} days" +%s)
{ zcat -f ${LOG}.*.gz 2>/dev/null; cat ${LOG}.1 2>/dev/null; cat $LOG; } 2>/dev/null |
awk -v cutoff="$CUTOFF" '
  BEGIN {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
    for (i = 1; i <= 12; i++) mnum[mn[i]] = sprintf("%02d", i)
  }
  {
    ts = $4; gsub(/^\[/, "", ts)
    split(ts, a, ":"); split(a[1], d, "/")
    if (!(d[2] in mnum)) next
    epoch = mktime(d[3] " " mnum[d[2]] " " d[1] " " a[2] " " a[3] " " a[4])
    if (epoch < cutoff) next
    day = d[3] "-" mnum[d[2]] "-" d[1]

    line = tolower($0)
    if (line ~ /bot|crawler|spider|slurp|bingpreview|headlesschrome|python-requests|curl\//) next

    req = $7
    if (req ~ /^\/px\/store-ios\.gif/)          ios[day]++
    else if (req ~ /^\/px\/store-android\.gif/) aos[day]++
    else if (req == "/" || req == "/index.html") view[day]++
    else if (req ~ /^\/(updates|about)\.html/ || req ~ /^\/explore\/$/) etc[day]++
    else next
    seen[day] = 1
  }
  END {
    for (k in seen) printf "%s %d %d %d %d\n", k, view[k], etc[k], ios[k], aos[k]
  }'
REMOTE
