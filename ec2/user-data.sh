#!/bin/bash
set -euxo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="us-east-1"

dnf install -y httpd
if ! command -v aws >/dev/null 2>&1; then
  dnf install -y awscli-2 || dnf install -y awscli
fi

systemctl enable --now httpd

cat > /usr/local/bin/sync-cv.sh << 'END_SYNC_SCRIPT'
#!/bin/bash
# Copy site/ from the private bucket into the web root, then stamp the footer.
export AWS_PAGER=""
export AWS_DEFAULT_REGION="us-east-1"

BUCKET="cv-i230100"
DEST="/var/www/html"
LOG="/var/log/cv-sync.log"
REGION="us-east-1"

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
mkdir -p "$DEST"
touch "$LOG"

sync_ok=0
for _attempt in 1 2 3 4 5 6 7 8; do
  if aws s3 sync "s3://${BUCKET}/site/" "${DEST}/" --region "${REGION}" --only-show-errors; then
    sync_ok=1
    break
  fi
  sleep 5
done

if [[ "$sync_ok" -ne 1 ]]; then
  echo "${timestamp} FAIL s3 sync failed" >> "$LOG"
  exit 1
fi

if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "$DEST" || true
fi
chmod -R a+rX "$DEST"

token="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
instance_id=""
if [[ -n "${token}" ]]; then
  instance_id="$(curl -fsS -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/meta-data/instance-id" || true)"
fi

if [[ -z "${instance_id}" || ! -f "${DEST}/index.html" ]]; then
  echo "${timestamp} FAIL sync copied files but instance id or index.html was missing" >> "$LOG"
  exit 1
fi

sed -i "s/{{HOSTED_ON}}/EC2 ${instance_id}/g" "${DEST}/index.html"

if grep -q "Hosted on: EC2 ${instance_id}" "${DEST}/index.html"; then
  echo "${timestamp} OK sync worked" >> "$LOG"
else
  echo "${timestamp} FAIL sync worked but the footer was not updated" >> "$LOG"
  exit 1
fi
END_SYNC_SCRIPT
chmod 755 /usr/local/bin/sync-cv.sh

cat > /etc/systemd/system/cv-sync.service << 'EOF'
[Unit]
Description=Sync the CV site from S3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
EOF

cat > /etc/systemd/system/cv-sync.timer << 'EOF'
[Unit]
Description=Sync the CV site every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true
Unit=cv-sync.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cv-sync.timer
/usr/local/bin/sync-cv.sh
