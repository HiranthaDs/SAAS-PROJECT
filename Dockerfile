FROM eclipse-temurin:21-jdk AS build
WORKDIR /workspace

COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw -B -DskipTests dependency:go-offline

COPY src src
COPY dist dist
RUN ./mvnw -B -DskipTests package

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN useradd --system --uid 10001 spring
COPY --from=build /workspace/target/nexora-suite.jar app.jar
ENV HOST=0.0.0.0
USER spring
EXPOSE 3000
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
