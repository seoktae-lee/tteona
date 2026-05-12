"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.deleteUnverifiedAccounts = exports.sendGroupNotification = exports.createKakaoCustomToken = void 0;
const admin = __importStar(require("firebase-admin"));
const firestore_1 = require("firebase-functions/v2/firestore");
const https_1 = require("firebase-functions/v2/https");
const scheduler_1 = require("firebase-functions/v2/scheduler");
admin.initializeApp();
const db = admin.firestore();
const messaging = admin.messaging();
// 알림 타입별 메시지 생성
function buildMessage(type, nickname, courseName, commentText, placeName) {
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
exports.createKakaoCustomToken = (0, https_1.onCall)(async (request) => {
    const kakaoAccessToken = request.data?.kakaoAccessToken;
    if (!kakaoAccessToken) {
        throw new https_1.HttpsError("invalid-argument", "kakaoAccessToken is required");
    }
    // 카카오 사용자 정보 조회
    const response = await fetch("https://kapi.kakao.com/v2/user/me", {
        headers: { Authorization: `Bearer ${kakaoAccessToken}` },
    });
    if (!response.ok) {
        throw new https_1.HttpsError("unauthenticated", "Invalid Kakao access token");
    }
    const kakaoUser = await response.json();
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
exports.sendGroupNotification = (0, firestore_1.onDocumentCreated)("fcmRequests/{requestId}", async (event) => {
    const requestId = event.params.requestId;
    const data = event.data?.data();
    if (!data || data.processed)
        return;
    const { type, senderUserId, senderNickname, roomIds, courseName, commentText, placeName } = data;
    const { title, body } = buildMessage(type, senderNickname, courseName, commentText, placeName);
    // 수신자 ID 수집
    const recipientUserIds = new Set();
    if (type === "feed_comment" && data.targetUserId) {
        // 댓글 알림: 피드 작성자에게만 (발신자가 본인 피드에 댓글 달 경우 제외)
        if (data.targetUserId !== senderUserId) {
            recipientUserIds.add(data.targetUserId);
        }
    }
    else {
        // 방 전체 멤버에게 (발신자 제외)
        await Promise.all((roomIds ?? []).map(async (roomId) => {
            const roomDoc = await db.collection("rooms").doc(roomId).get();
            const memberIds = roomDoc.data()?.memberIds ?? [];
            memberIds
                .filter((id) => id !== senderUserId)
                .forEach((id) => recipientUserIds.add(id));
        }));
    }
    if (recipientUserIds.size === 0) {
        await event.data?.ref.update({ processed: true });
        return;
    }
    // 각 멤버의 FCM 토큰 조회 (userPrivate 컬렉션)
    const tokens = [];
    await Promise.all(Array.from(recipientUserIds).map(async (userId) => {
        const privateDoc = await db.collection("userPrivate").doc(userId).get();
        const token = privateDoc.data()?.fcmToken;
        if (token)
            tokens.push(token);
    }));
    if (tokens.length === 0) {
        await event.data?.ref.update({ processed: true });
        return;
    }
    // FCM 멀티캐스트 전송
    const fcmData = {
        type,
        senderUserId,
        courseName: courseName ?? "",
    };
    if (type === "feed_comment" && data.roomId) {
        fcmData.roomId = data.roomId;
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
    console.log(`[FCM] sent: ${response.successCount} success, ${response.failureCount} failure for requestId=${requestId}`);
    // 처리 완료 표시
    await event.data?.ref.update({ processed: true });
});
// 매일 자정(KST) 미인증 계정 삭제 (가입 후 24시간 경과)
exports.deleteUnverifiedAccounts = (0, scheduler_1.onSchedule)({ schedule: "0 15 * * *", timeZone: "UTC" }, // UTC 15:00 = KST 자정
async () => {
    const cutoff = Date.now() - 24 * 60 * 60 * 1000; // 24시간 전
    let pageToken;
    do {
        const result = await admin.auth().listUsers(1000, pageToken);
        const toDelete = result.users
            .filter((u) => {
            if (u.emailVerified)
                return false;
            // 소셜 로그인(Google, Apple, Kakao) 계정 제외 — providerData로 판별
            const isEmailProvider = u.providerData.some((p) => p.providerId === "password");
            if (!isEmailProvider)
                return false;
            return new Date(u.metadata.creationTime).getTime() < cutoff;
        })
            .map((u) => u.uid);
        if (toDelete.length > 0) {
            await admin.auth().deleteUsers(toDelete);
            console.log(`[Cleanup] deleted ${toDelete.length} unverified accounts`);
        }
        pageToken = result.pageToken;
    } while (pageToken);
});
//# sourceMappingURL=index.js.map