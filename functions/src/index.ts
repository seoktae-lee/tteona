import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

admin.initializeApp();

const db = admin.firestore();
const messaging = admin.messaging();

interface FCMRequest {
  type: string;
  senderUserId: string;
  senderNickname: string;
  roomIds?: string[];
  courseName?: string;
  // feed_comment 전용
  targetUserId?: string;
  roomId?: string;
  commentText?: string;
  processed: boolean;
  createdAt: admin.firestore.Timestamp;
}

// 알림 타입별 메시지 생성
function buildMessage(type: string, nickname: string, courseName?: string, commentText?: string): { title: string; body: string } {
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

    const { type, senderUserId, senderNickname, roomIds, courseName, targetUserId, commentText } = data;
    const { title, body } = buildMessage(type, senderNickname, courseName, commentText);

    // 각 룸의 멤버 ID 수집 (발신자 제외)
    const recipientUserIds = new Set<string>();

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

    if (recipientUserIds.size === 0) {
      await event.data?.ref.update({ processed: true });
      return;
    }

    // 각 멤버의 FCM 토큰 조회
    const tokens: string[] = [];
    await Promise.all(
      Array.from(recipientUserIds).map(async (userId) => {
        const userDoc = await db.collection("users").doc(userId).get();
        const token = userDoc.data()?.fcmToken as string | undefined;
        if (token) tokens.push(token);
      })
    );

    if (tokens.length === 0) {
      await event.data?.ref.update({ processed: true });
      return;
    }

    // FCM 멀티캐스트 전송
    const response = await messaging.sendEachForMulticast({
      tokens,
      notification: { title, body },
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
      data: {
        type,
        senderUserId,
        courseName: courseName ?? "",
      },
    });

    console.log(
      `[FCM] sent: ${response.successCount} success, ${response.failureCount} failure for requestId=${requestId}`
    );

    // 처리 완료 표시
    await event.data?.ref.update({ processed: true });
  }
);
