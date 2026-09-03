FROM eclipse-temurin:21-jdk-alpine

WORKDIR /app
COPY Main.java ./

# Java 11+ can run a single-file source program directly, so no separate
# javac step or build tool is needed for a one-class app.
EXPOSE 8080
CMD ["java", "Main.java"]
