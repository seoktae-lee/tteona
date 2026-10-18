# map-api 실행 이미지. jar는 미리 빌드해서 넣는다(./gradlew bootJar).
# JRE만 담아 이미지를 작게 유지한다. 운영 서버(x86_64)와 로컬(arm64) 모두 지원하는 공식 Temurin 이미지.
FROM eclipse-temurin:25-jre
WORKDIR /app
# root로 실행하지 않는다. 컨테이너가 뚫려도 권한을 줄인다.
RUN useradd --system --uid 10001 mapapi
COPY build/libs/map-api-0.0.1-SNAPSHOT.jar app.jar
COPY data/ data/
USER mapapi
# 컨테이너 메모리 상한의 70%를 힙으로 쓴다. 나머지는 스레드 스택·메타스페이스 몫.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
