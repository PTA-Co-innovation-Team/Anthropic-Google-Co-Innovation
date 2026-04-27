#!/bin/sh
set -e

: "${API_BASE:?API_BASE environment variable must be set (the public Cloud Run URL of the backend)}"
: "${NOVNC_URL:=http://localhost:6080/vnc.html?autoconnect=true&resize=scale}"

export API_BASE NOVNC_URL

envsubst '$API_BASE $NOVNC_URL' \
  < /usr/share/nginx/html/config.js.template \
  > /usr/share/nginx/html/config.js

echo "Frontend runtime config:"
echo "  API_BASE=$API_BASE"
echo "  NOVNC_URL=$NOVNC_URL"

exec nginx -g 'daemon off;'
