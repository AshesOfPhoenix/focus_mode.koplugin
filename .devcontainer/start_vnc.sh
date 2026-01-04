#!/bin/bash
cd /workspace/koreader

# Fix X11 perms
sudo mkdir -p /tmp/.X11-unix /tmp/runtime-ko
sudo chmod 1777 /tmp/.X11-unix
sudo chown root:root /tmp/.X11-unix

# Start Xvfb + VNC in background with nohup
nohup Xvfb :99 -screen 0 1072x1448x24 -nolisten unix > xvfb.log 2>&1 &
sleep 2
nohup x11vnc -display :99 -forever -shared -rfbport 5900 -bg -nopw > x11vnc.log 2>&1 &

echo "VNC ready on localhost:5900. Logs: xvfb.log, x11vnc.log"
echo "Run: ./kodev run -s=kindle-paperwhite -d"
tail -f /dev/null  # Keep container alive
