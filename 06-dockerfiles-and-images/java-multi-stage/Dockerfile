# ---- Stage 1: compile with the full JDK ----
FROM eclipse-temurin:21-jdk-alpine AS builder

WORKDIR /build
COPY Main.java ./
RUN javac -d out Main.java

# ---- Stage 2: run on the JRE only ----
# javac, jlink, jdb and the rest of the JDK tooling are left behind in
# stage 1; only the compiled .class file crosses over.
FROM eclipse-temurin:21-jre-alpine

WORKDIR /app
COPY --from=builder /build/out ./

EXPOSE 8080
CMD ["java", "Main"]
