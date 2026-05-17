import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import * as jwt from "jsonwebtoken";

admin.initializeApp();

const appleTeamId = defineSecret("APPLE_TEAM_ID");
const appleKeyId = defineSecret("APPLE_KEY_ID");
const applePrivateKey = defineSecret("APPLE_PRIVATE_KEY");

async function generateAppleClientSecret(): Promise<string> {
  const privateKey = applePrivateKey.value().replace(/\\n/g, "\n");
  return jwt.sign({}, privateKey, {
    algorithm: "ES256",
    expiresIn: "1h",
    audience: "https://appleid.apple.com",
    issuer: appleTeamId.value(),
    subject: "com.seoktae.tteona",
    keyid: appleKeyId.value(),
  });
}

const db = admin.firestore();
const messaging = admin.messaging();

interface FCMRequest {
  type: string;
  senderUserId: string;
  senderNickname: string;
  roomIds?: string[];
  courseName?: string;
  placeName?: string;
  // feed_comment 전용
  targetUserId?: string;
  roomId?: string;
  commentText?: string;
  processed: boolean;
  createdAt: admin.firestore.Timestamp;
}

// 알림 타입별 메시지 생성
function buildMessage(type: string, nickname: string, courseName?: string, commentText?: string, placeName?: string): { title: string; body: string } {
  switch (type) {
    case "free_trip_start":
      return {
        title: "나의 오늘 시작",
        body: `${nickname}님이 오늘의 기록을 시작했어요!`,
      };
    case "free_trip_end":
      return {
        title: "나의 오늘 종료",
        body: courseName
          ? `${nickname}님이 오늘 ${courseName}을 완료했어요!`
          : `${nickname}님이 오늘의 기록을 마쳤어요!`,
      };
    case "course_trip_start":
      return {
        title: "🚀 여행 시작",
        body: courseName
          ? `${nickname}님이 '${courseName}' 코스 여행을 시작했어요!`
          : `${nickname}님이 코스 여행을 시작했어요!`,
      };
    case "video_recorded":
      return {
        title: "📹 영상 촬영",
        body: placeName
          ? `${nickname}님이 ${placeName}에서 영상을 남겼어요`
          : `${nickname}님이 영상을 남겼어요`,
      };
    case "feed_comment":
      return {
        title: `${nickname}님이 답장을 남겼어요`,
        body: "답장을 확인해주세요!",
      };
    default:
      return {
        title: "떠나",
        body: `${nickname}님의 새로운 소식이 있어요!`,
      };
  }
}

// MARK: - 카카오 Custom Token 발급
export const createKakaoCustomToken = onCall(async (request) => {
  const kakaoAccessToken = request.data?.kakaoAccessToken as string | undefined;
  if (!kakaoAccessToken) {
    throw new HttpsError("invalid-argument", "kakaoAccessToken is required");
  }

  // 카카오 사용자 정보 조회
  const response = await fetch("https://kapi.kakao.com/v2/user/me", {
    headers: { Authorization: `Bearer ${kakaoAccessToken}` },
  });

  if (!response.ok) {
    throw new HttpsError("unauthenticated", "Invalid Kakao access token");
  }

  const kakaoUser = await response.json() as { id: number; kakao_account?: { email?: string } };
  const kakaoId = kakaoUser.id;
  const uid = `kakao_${kakaoId}`;

  // Firebase Custom Token 발급
  const customToken = await admin.auth().createCustomToken(uid, {
    provider: "kakao",
    kakaoId: String(kakaoId),
  });

  return { customToken };
});

// fcmRequests 컬렉션 트리거
export const sendGroupNotification = onDocumentCreated(
  "fcmRequests/{requestId}",
  async (event) => {
    const requestId = event.params.requestId;
    const data = event.data?.data() as FCMRequest | undefined;
    if (!data || data.processed) return;

    const { type, senderUserId, senderNickname, roomIds, courseName, commentText, placeName } = data;
    const { title, body } = buildMessage(type, senderNickname, courseName, commentText, placeName);

    // 수신자 ID 수집
    const recipientUserIds = new Set<string>();

    if (type === "feed_comment" && data.targetUserId) {
      // 댓글 알림: 피드 작성자에게만 (발신자가 본인 피드에 댓글 달 경우 제외)
      if (data.targetUserId !== senderUserId) {
        recipientUserIds.add(data.targetUserId);
      }
    } else {
      // 방 전체 멤버에게 (발신자 제외)
      await Promise.all(
        (roomIds ?? []).map(async (roomId) => {
          const roomDoc = await db.collection("rooms").doc(roomId).get();
          const memberIds: string[] = roomDoc.data()?.memberIds ?? [];
          memberIds
            .filter((id) => id !== senderUserId)
            .forEach((id) => recipientUserIds.add(id));
        })
      );
    };

    if (recipientUserIds.size === 0) {
      await event.data?.ref.update({ processed: true });
      return;
    }

    // 각 멤버의 FCM 토큰 조회 (userPrivate 컬렉션)
    const tokens: string[] = [];
    await Promise.all(
      Array.from(recipientUserIds).map(async (userId) => {
        const privateDoc = await db.collection("userPrivate").doc(userId).get();
        const token = privateDoc.data()?.fcmToken as string | undefined;
        if (token) tokens.push(token);
      })
    );

    if (tokens.length === 0) {
      await event.data?.ref.update({ processed: true });
      return;
    }

    // FCM 멀티캐스트 전송
    const firstRoomId = (roomIds && roomIds.length > 0) ? roomIds[0] : "";
    const fcmData: Record<string, string> = {
      type,
      senderUserId,
      courseName: courseName ?? "",
      roomId: firstRoomId,
    };
    if (data.targetUserId) {
      fcmData.targetUserId = data.targetUserId;
    }

    const response = await messaging.sendEachForMulticast({
      tokens,
      notification: { title, body },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
      data: fcmData,
    });

    console.log(
      `[FCM] sent: ${response.successCount} success, ${response.failureCount} failure for requestId=${requestId}`
    );

    // 처리 완료 표시
    await event.data?.ref.update({ processed: true });
  }
);

// 매일 자정(KST) 미인증 계정 삭제 (가입 후 24시간 경과)
export const deleteUnverifiedAccounts = onSchedule(
  { schedule: "0 15 * * *", timeZone: "UTC" }, // UTC 15:00 = KST 자정
  async () => {
    const cutoff = Date.now() - 24 * 60 * 60 * 1000; // 24시간 전
    let pageToken: string | undefined;

    do {
      const result = await admin.auth().listUsers(1000, pageToken);
      const toDelete = result.users
        .filter((u) => {
          if (u.emailVerified) return false;
          // 소셜 로그인(Google, Apple, Kakao) 계정 제외 — providerData로 판별
          const isEmailProvider = u.providerData.some((p) => p.providerId === "password");
          if (!isEmailProvider) return false;
          return new Date(u.metadata.creationTime).getTime() < cutoff;
        })
        .map((u) => u.uid);

      if (toDelete.length > 0) {
        await admin.auth().deleteUsers(toDelete);
        console.log(`[Cleanup] deleted ${toDelete.length} unverified accounts`);
      }

      pageToken = result.pageToken;
    } while (pageToken);
  }
);

// MARK: - 내 계정 삭제 (서버에서 일괄 처리)
export const deleteMyAccount = onCall({ secrets: [appleTeamId, appleKeyId, applePrivateKey] }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }

  try {
    // 1) 내가 만든 코스 삭제
    const coursesSnapshot = await db.collection("courses")
      .where("authorId", "==", uid)
      .get();
    await Promise.all(coursesSnapshot.docs.map((doc) => doc.ref.delete()));

    // 2) 내가 속한 방 처리: 멤버 제거 + 내 멤버 문서/locations 문서 삭제 + 내가 작성한 피드 삭제
    const roomsSnapshot = await db.collection("rooms")
      .where("memberIds", "array-contains", uid)
      .get();

    await Promise.all(roomsSnapshot.docs.map(async (roomDoc) => {
      const roomId = roomDoc.id;
      await db.collection("rooms").doc(roomId)
        .update({ memberIds: admin.firestore.FieldValue.arrayRemove(uid) });

      await Promise.all([
        db.collection("rooms").doc(roomId).collection("members").doc(uid).delete().catch(() => undefined),
        db.collection("rooms").doc(roomId).collection("locations").doc(uid).delete().catch(() => undefined),
      ]);

      const feedSnapshot = await db.collection("rooms").doc(roomId)
        .collection("feed")
        .where("userId", "==", uid)
        .get()
        .catch(() => undefined);

      if (feedSnapshot) {
        await Promise.all(feedSnapshot.docs.map((d) => d.ref.delete().catch(() => undefined)));
      }
    }));

    // 3) Apple Sign In credential revoke (저장된 authorizationCode가 있을 경우)
    const privateDoc = await db.collection("userPrivate").doc(uid).get().catch(() => undefined);
    const appleAuthCode = privateDoc?.data()?.appleAuthCode as string | undefined;
    if (appleAuthCode) {
      try {
        await admin.auth().revokeRefreshTokens(uid);
        // Apple REST API로 token revoke
        const appleRevokeRes = await fetch("https://appleid.apple.com/auth/revoke", {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            client_id: "com.seoktae.tteona",
            client_secret: await generateAppleClientSecret(),
            token: appleAuthCode,
            token_type_hint: "authorization_code",
          }).toString(),
        });
        if (!appleRevokeRes.ok) {
          console.warn("[deleteMyAccount] Apple revoke failed:", await appleRevokeRes.text());
        }
      } catch (e) {
        console.warn("[deleteMyAccount] Apple revoke error:", e);
      }
    }

    // 4) users / userPrivate 삭제
    await Promise.all([
      db.collection("users").doc(uid).delete().catch(() => undefined),
      db.collection("userPrivate").doc(uid).delete().catch(() => undefined),
    ]);

    // 5) Firebase Auth 유저 삭제 (Admin 권한이라 reauth 이슈 없음)
    await admin.auth().deleteUser(uid);

    return { ok: true };
  } catch (e) {
    console.error("[deleteMyAccount] failed", e);
    throw new HttpsError("internal", "Failed to delete account");
  }
});
