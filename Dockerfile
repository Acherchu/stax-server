# The Stax game server. Render builds this and runs it; players' games connect to it.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && apt-get clean

# Godot itself (the same version Stax is made with), without a window.
ARG GODOT=4.7.2-stable
RUN wget -q https://github.com/godotengine/godot/releases/download/${GODOT}/Godot_v${GODOT}_linux.x86_64.zip -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /tmp \
 && mv /tmp/Godot_v${GODOT}_linux.x86_64 /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot

WORKDIR /app
COPY stax-server.pck .

# Render tells the server which port to use in $PORT.
ENV PORT=10000
EXPOSE 10000
CMD ["sh", "-c", "exec godot --headless --main-pack /app/stax-server.pck -- --server --port=$PORT"]
