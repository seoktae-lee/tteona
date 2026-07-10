# /admin/ Basic Auth 적용 절차 (WEB 서버)

> 대상: `114.110.182.45` (nginx, `/var/www/tteona.kr`)
> 목적: `https://tteona.kr/admin/` 이 인증 없이 HTTP 200을 반환하는 문제 차단.
>
> **`/api/admin/*` 에는 걸지 않는다.** 대시보드가 그 API를 `fetch()`로 호출하는데,
> 브라우저는 `/admin/`에서 인증한 자격증명을 `/api/` 경로로 자동 전송하지 않는다.
> API는 기존 `ADMIN_TOKEN` 방어를 그대로 유지한다 (비밀번호를 모르면 토큰도 못 받는다).

---

## 0. 적용 전 기준선 기록

```bash
curl -s -o /dev/null -w "admin  %{http_code}\n" https://tteona.kr/admin/   # 지금은 200
curl -s -o /dev/null -w "root   %{http_code}\n" https://tteona.kr/
curl -s -o /dev/null -w "api    %{http_code}\n" https://tteona.kr/api/vlog/bgm
```

`admin 200` / `root 200` / `api 200` 이 나오는지 확인. 작업 후 `admin`만 401로 바뀌면 성공.

## 1. 접속

```bash
KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
ssh -i "$KEYDIR/aeron-web-key.pem" -p 30022 ubuntu@114.110.182.45
```

## 2. 현재 설정 확인 (어느 파일에 tteona.kr 이 있는지)

```bash
ls /etc/nginx/sites-enabled/
sudo grep -rn "server_name\|location /admin" /etc/nginx/sites-enabled/
```

아래에서는 그 파일을 `$CONF` 라 부른다. (보통 `/etc/nginx/sites-enabled/tteona.kr`)

## 3. 백업 (되돌릴 수 있게)

```bash
CONF=/etc/nginx/sites-enabled/tteona.kr        # 2단계에서 확인한 실제 경로로
sudo cp "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
ls -la "$CONF".bak-*
```

## 4. 비밀번호 파일 생성

`htpasswd`가 없으면 설치:

```bash
which htpasswd || sudo apt-get update && sudo apt-get install -y apache2-utils
```

계정 생성 (아이디는 예시 `tteona`, 비밀번호는 대화형 입력 — 셸 히스토리에 남지 않음):

```bash
sudo htpasswd -c /etc/nginx/.htpasswd-admin tteona
sudo chown root:www-data /etc/nginx/.htpasswd-admin
sudo chmod 640 /etc/nginx/.htpasswd-admin
```

> `-c` 는 파일을 새로 만든다. **두 번째 계정을 추가할 땐 `-c` 를 빼야** 기존 계정이 날아가지 않는다.
> 이 비밀번호는 대시보드 로그인 비밀번호(`ADMIN_PASSWORD`)와 **다른 값**으로 정할 것. 그래야 2중 방어가 된다.

## 5. nginx 설정에 location 블록 추가

`$CONF` 의 `server { ... }` (443 리스닝하는 쪽) 안에 추가:

```nginx
location /admin/ {
    auth_basic           "tteona admin";
    auth_basic_user_file /etc/nginx/.htpasswd-admin;

    # 기존 정적 파일 서빙 방식 유지 (root 지시어가 server 블록에 있으면 이 줄은 불필요)
    try_files $uri $uri/ =404;
}
```

주의:
- `location /admin/` 은 슬래시로 끝난다. `/admin` (슬래시 없음) 으로 접근하면 nginx가 301로
  `/admin/` 에 리다이렉트하므로 결과적으로 막힌다. 확인은 4단계 테스트에서 함께 한다.
- `/api/` 프록시 블록은 **건드리지 않는다.**

## 6. 문법 검사 → 반영

```bash
sudo nginx -t          # syntax is ok / test is successful 확인
sudo systemctl reload nginx
```

`nginx -t` 가 실패하면 reload 하지 말 것. 3단계 백업으로 되돌린다.

## 7. 검증 (서버 밖, 로컬 맥에서)

```bash
# 인증 없이 → 401 이어야 정상
curl -s -o /dev/null -w "admin(no auth)  %{http_code}\n" https://tteona.kr/admin/

# 올바른 계정 → 200
curl -s -o /dev/null -w "admin(auth)     %{http_code}\n" -u tteona https://tteona.kr/admin/

# 사이트 본체·API는 영향 없어야 함 → 둘 다 200
curl -s -o /dev/null -w "root            %{http_code}\n" https://tteona.kr/
curl -s -o /dev/null -w "api             %{http_code}\n" https://tteona.kr/api/vlog/bgm
```

기대값: `401 / 200 / 200 / 200`

그리고 브라우저에서 `https://tteona.kr/admin/` 열어 basic auth 팝업 → 계정 입력 →
대시보드 로그인 화면 → `ADMIN_PASSWORD` 입력 → 유저 목록이 뜨는지까지 확인.
(대시보드가 `/api/admin/*` 를 정상 호출하는지 보는 게 핵심)

## 8. 롤백

```bash
CONF=/etc/nginx/sites-enabled/tteona.kr
sudo cp "$CONF".bak-<타임스탬프> "$CONF"
sudo nginx -t && sudo systemctl reload nginx
```

---

## 남는 위험

- `/api/admin/*` 는 여전히 공개 경로다. 방어는 `ADMIN_PASSWORD` + 로그인 IP당 15분 5회 제한
  (`server.js` 의 `adminLoginAttempts`). 이 비밀번호가 약하면 basic auth를 뚫지 않고도
  API를 직접 두드릴 수 있다 — **강한 비밀번호인지 확인할 것.**
- 더 강하게 가려면 IP 허용목록(`allow`/`deny`)을 `/api/admin/` 에도 걸 수 있으나,
  외부에서 운영할 일이 있으면 본인이 잠긴다.
