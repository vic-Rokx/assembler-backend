# The backend, with the Zig toolchain it compiles playground code with.
#
#   docker build -t assembler-backend .
#   docker run -p 8080:8080 --env-file .env assembler-backend
#
# Give it 2 GB of memory or more: compiling vapor takes most of that.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
# libssl-dev and libc6-dev: pg.zig (the users table) translates OpenSSL's
# headers, which include the C library's.
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils libssl-dev libc6-dev \
 && rm -rf /var/lib/apt/lists/* \
 && case "$TARGETARCH" in \
      amd64|"") arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported architecture $TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz" | tar -xJ -C /opt \
 && ln -s "/opt/zig-$arch-linux-$ZIG_VERSION/zig" /usr/local/bin/zig

RUN useradd --create-home --uid 10001 app
USER app
WORKDIR /home/app/backend

COPY --chown=app build.zig build.zig.zon ./
COPY --chown=app src src
COPY --chown=app playground_template playground_template
RUN zig build -Doptimize=ReleaseSafe

# Compile the template once, as the backend would, so the first visitor's
# build finds vapor fetched and compiled in the caches.
RUN mkdir -p /tmp/warm/src \
 && cp playground_template/build.zig playground_template/build.zig.zon /tmp/warm/ \
 && cp playground_template/src/*.zig /tmp/warm/src/ \
 && printf 'const Vapor = @import("vapor");\nexport fn init() void {\n    Vapor.init(.{});\n}\n' > /tmp/warm/src/main.zig \
 && cd /tmp/warm \
 && zig build -Doptimize=ReleaseSmall --cache-dir /home/app/backend/builds/.cache \
 && rm -rf /tmp/warm

ENV HOST=0.0.0.0 PORT=8080
EXPOSE 8080
CMD ["./zig-out/bin/assembler-backend"]
