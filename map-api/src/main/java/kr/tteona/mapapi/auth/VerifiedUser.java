package kr.tteona.mapapi.auth;

/** 검증된 토큰에서 꺼낸 사용자. guest = Firebase 익명 로그인(게스트 모드). 클라이언트가 보낸 값이 아니라 토큰에서 판정한다. */
public record VerifiedUser(String uid, boolean guest) {
}
