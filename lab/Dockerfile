# Client for the HTTP/3 lab (lab/README.md): curl with HTTP/3 and
# the Python libraries aioquic (HTTP/3) and h2 (HTTP/2). Test tool only, never deployed.
FROM python:3.13-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends curl >/dev/null && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir --quiet aioquic h2
