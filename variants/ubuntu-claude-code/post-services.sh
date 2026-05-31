# post-services.sh — variant overlay (ubuntu-claude-code)
#
# Enable + start the fleet job client. This runs AFTER 17-services-start.sh
# (which doesn't know about variant-specific units) and BEFORE 18-heartbeat.sh
# (the install-time heartbeat). Once the daemon is up, the portal's polling +
# the daemon's own 60s heartbeat keep the agent flagged online.

step "Waiting for fleet-job-client to come online (up to 60s)"

systemctl daemon-reload
systemctl enable fleet-job-client.service >/dev/null
systemctl start fleet-job-client.service

FJC_READY=0
for i in $(seq 1 12); do
  sleep 5
  if curl -sf --max-time 3 http://localhost:9876/health >/dev/null 2>&1; then
    FJC_READY=1
    log "fleet-job-client healthy after $((i*5))s"
    break
  fi
done

if [ "$FJC_READY" != "1" ]; then
  log "WARN: fleet-job-client did not respond on :9876 within 60s."
  log "  Check: systemctl status fleet-job-client && journalctl -u fleet-job-client -n 50"
fi
