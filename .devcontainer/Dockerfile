
FROM mcr.microsoft.com/devcontainers/python:3.12

ARG FLUTTER_VERSION=3.47.0

ENV FLUTTER_HOME=/opt/flutter
ENV PATH="${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
    --depth 1 \
    --branch "${FLUTTER_VERSION}" \
    https://github.com/flutter/flutter.git \
    "${FLUTTER_HOME}" \
    && git config --global --add safe.directory "${FLUTTER_HOME}" \
    && flutter precache --web \
    && flutter config --no-analytics

# Allow VS Code's user to update the Flutter SDK cache
RUN chown -R vscode:vscode "${FLUTTER_HOME}"

RUN python -m pip install --no-cache-dir --upgrade pip
