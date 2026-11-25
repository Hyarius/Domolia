#!/usr/bin/env bash
# Run the same streamed narrator used by an Android Party against a local model.
set -euo pipefail
cd "$(dirname "$0")/.."

model_sha=9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94
model_rev=f302c64a2269a69fb27b2f9473b362f5bb8e78d8
runner_sha=e37941d22b599d528410c81f17d84b6586a2d82ecb2f4840cebc8b83ad9f8fcd
release=b12738
cache=${DOMOLIA_AI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/domolia/local-ai}
tmp=$(mktemp -d)
mkdir -p "$cache"
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify() {
  echo "$1  $2" | sha256sum --check --status
}
fetch() {
  local url=$1 expected=$2 dest=$3 partial
  if [[ -f "$dest" ]] && verify "$expected" "$dest"; then return; fi
  partial=$(mktemp "$cache/.download-XXXXXXXX")
  if curl --fail --location --retry 3 -o "$partial" "$url" && verify "$expected" "$partial"; then
    mv -f "$partial" "$dest"
  else
    rm -f "$partial"
    echo "Download or checksum failed for $dest" >&2
    return 1
  fi
}

if [[ -n "${DOMOLIA_LLAMA_SERVER:-}" ]]; then
  server=$DOMOLIA_LLAMA_SERVER
else
  if [[ $(uname -sm) != 'Linux x86_64' ]]; then
    echo 'Set DOMOLIA_LLAMA_SERVER to a native llama-server with TLS support.' >&2
    exit 2
  fi
  archive="llama-$release-bin-ubuntu-x64.tar.gz"
  fetch "https://github.com/ggml-org/llama.cpp/releases/download/$release/$archive" "$runner_sha" "$cache/$archive"
  tar xzf "$cache/$archive" -C "$tmp"
  server="$tmp/llama-$release/llama-server"
fi

gguf=Qwen2.5-3B-Instruct-Q4_K_M.gguf
if [[ -n "${DOMOLIA_MODEL_FILE:-}" ]]; then
  model=$DOMOLIA_MODEL_FILE
  verify "$model_sha" "$model" || { echo 'Unexpected GGUF checksum' >&2; exit 2; }
else
  model="$cache/$gguf"
  fetch "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/$model_rev/$gguf" "$model_sha" "$model"
fi

# Keep the app's HTTPS transport, including streamed usage counters.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=127.0.0.1' \
  -addext 'subjectAltName=IP:127.0.0.1' -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
"$server" --offline -m "$model" --alias domolia-tests --host 127.0.0.1 --port "$port" \
  --ssl-key-file "$tmp/key.pem" --ssl-cert-file "$tmp/cert.pem" --device none \
  --parallel 1 --ctx-size 4096 --threads 4 --temp 0 --seed 41 --no-warmup >"$tmp/server.log" 2>&1 &
server_pid=$!
ready=false
for _ in {1..90}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
  if curl --noproxy '*' --max-time 2 --cacert "$tmp/cert.pem" --fail --silent \
       "https://127.0.0.1:$port/health" >/dev/null; then ready=true; break; fi
  sleep 1
done
if [[ "$ready" != true ]]; then cat "$tmp/server.log" >&2; exit 1; fi

export DOMOLIA_AI_PORT=$port DOMOLIA_AI_CERT="$tmp/cert.pem" DOMOLIA_AI_GGUF="$gguf"
export DOMOLIA_AI_RUNNER_VERSION
DOMOLIA_AI_RUNNER_VERSION=$("$server" --version 2>&1)
[[ -f .dart_tool/package_config.json ]] || flutter pub get
flutter test --no-pub --timeout 3m --dart-define=DOMOLIA_LOCAL_AI=true --reporter expanded test/local_ai_scene_test.dart
