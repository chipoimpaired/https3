# Real browsers for the staging tests of README.md in the folder above: headless Chromium
# and Firefox, driven by the scripts in this directory. Needs the internet once (apt).
FROM debian:trixie-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        chromium firefox-esr ca-certificates python3 python3-websockets procps \
    && rm -rf /var/lib/apt/lists/*
