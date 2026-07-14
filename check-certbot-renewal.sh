#!/bin/bash
# TLS 인증서(Let's Encrypt) 자동 갱신 점검 + 미설정 시 활성화
#  - certbot.timer가 살아 있는지 확인하고, 꺼져 있으면 켠다
#  - renew --dry-run으로 실제 갱신 경로(웹루트/nginx 플러그인)가 동작하는지 검증
# 2026-07-14
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022

ssh -i "$WEB_KEY" -p $PORT $WEB_HOST 'bash -s' <<'REMOTE'
set -e
echo "▶ 인증서 현황:"
sudo certbot certificates 2>/dev/null | grep -E "Certificate Name|Domains|Expiry" || echo "  certbot 인증서 없음(!)"

echo "▶ 자동 갱신 타이머:"
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
  echo "  certbot.timer 활성 ✅"
  systemctl list-timers certbot.timer --no-pager | head -3
elif systemctl list-unit-files certbot.timer >/dev/null 2>&1 && systemctl list-unit-files | grep -q certbot.timer; then
  echo "  certbot.timer 존재하나 꺼져 있음 → 활성화"
  sudo systemctl enable --now certbot.timer
  echo "  활성화 완료 ✅"
elif crontab -l 2>/dev/null | grep -q certbot || sudo grep -rq certbot /etc/cron.d/ 2>/dev/null; then
  echo "  크론 기반 갱신 등록 확인 ✅"
else
  echo "  ❌ 타이머도 크론도 없음 — 크론 등록"
  ( sudo crontab -l 2>/dev/null | grep -v 'certbot renew' ; \
    echo "17 4 * * * certbot renew --quiet --deploy-hook 'nginx -s reload'" ) | sudo crontab -
  echo "  등록 완료 ✅ (매일 04:17 갱신 시도, 갱신 시 nginx 리로드)"
fi

echo "▶ 갱신 경로 리허설 (dry-run, 실제 발급 안 함):"
sudo certbot renew --dry-run 2>&1 | tail -4
REMOTE

echo ""
echo "✅ 점검 완료. dry-run에 'Congratulations' 또는 'simulating renewal... success'류 문구가 보이면 정상."
