#!/bin/sh
u="https://raw.githubusercontent.com/ya-zhe/tcpcodex/2b0feebf983afb9c4ba51d7b3af379452d2face7/tcp-limit-panel.sh"
o="/root/tcp-limit-panel.sh"
if command -v wget >/dev/null 2>&1; then
  wget -qO "$o" "$u"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "$u" -o "$o"
else
  echo "need wget or curl"
  exit 1
fi
chmod +x "$o"
exec "$o"
