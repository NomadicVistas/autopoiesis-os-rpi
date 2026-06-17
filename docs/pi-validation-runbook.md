# Physical Pi Validation Runbook

Date: 2026-06-17
Scope: Autopoiesis OS + Frames MVP 0.1 appliance validation on real Raspberry Pi hardware

## Purpose

This runbook is the operator-facing follow-through after the repo-side gates are green. Use it to validate the remaining hardware-bound behavior that mocked and host-side checks cannot prove.

The goal is a disciplined acceptance pass with clear evidence for:

- Wi-Fi onboarding
- owner preference cascade onto a real frame
- support snapshot fidelity on real hardware
- install, update, rollback, and recovery behavior under actual systemd conditions

## Preconditions

- Physical Raspberry Pi target with the appliance image installed
- Touchscreen or browser access to the local UI
- SSH access to the device
- NetworkManager and nmcli available on the target
- A known secured test SSID and password
- Hosted API or staging environment available for pairing and owner preference checks
- A test owner account that can pair the frame and edit Profile > Frames settings

## Evidence Capture

Create one working directory on the Pi for all artifacts:

    mkdir -p /tmp/aos-pi-validation

Recommended artifact set:

- /tmp/aos-pi-validation/readiness.json
- /tmp/aos-pi-validation/support-snapshot.json
- /tmp/aos-pi-validation/network-check.txt
- /tmp/aos-pi-validation/device.json
- /tmp/aos-pi-validation/pairing.json
- /tmp/aos-pi-validation/journal-local-ui.txt
- /tmp/aos-pi-validation/journal-autopoiesis.txt
- /tmp/aos-pi-validation/update-attempt.txt
- photos or screen recordings of key touchscreen states

## Phase 1: Baseline Readiness

1. Confirm the device is reachable and services are up.

       cd /opt/autopoiesis-os/app
       scripts/readiness-check.sh --json > /tmp/aos-pi-validation/readiness.json
       scripts/network-check.sh > /tmp/aos-pi-validation/network-check.txt
       sudo systemctl status autopoiesis.target --no-pager

2. Capture the offline SSH support artifact before changing anything.

       sudo /opt/autopoiesis-os/app/scripts/support-snapshot.sh /tmp/aos-pi-validation/support-snapshot.json
       sudo journalctl -u autopoiesis.target -u autopoiesis-local-ui.service -n 300 --no-pager > /tmp/aos-pi-validation/journal-autopoiesis.txt
       sudo journalctl -u autopoiesis-local-ui.service -n 300 --no-pager > /tmp/aos-pi-validation/journal-local-ui.txt

Pass criteria:

- readiness reports healthy enough to proceed
- autopoiesis target and local UI are running
- support snapshot is generated successfully
- snapshot contains redacted evidence, not secrets or raw credentials

## Phase 2: Wi-Fi Onboarding

This covers both the shell connector and the touchscreen or local UI path.

### 2A. Shell Connector

Run:

    sudo /opt/autopoiesis-os/app/scripts/connect-wifi.sh --rescan --require-connected "SSID" -

Paste the Wi-Fi password through stdin when prompted, then run:

    /opt/autopoiesis-os/app/scripts/network-check.sh | tee /tmp/aos-pi-validation/network-check-after-shell.txt

Pass criteria:

- command exits 0
- network-check.sh reports online=true
- primary=wifi
- password does not appear in stdout, stderr, shell history, or journal output

Negative test:

    sudo /opt/autopoiesis-os/app/scripts/connect-wifi.sh --rescan --require-connected "SSID" -

Use an intentionally wrong password.

Expected result:

- exit code 4 for wrong credentials, or 5 if post-connect verification fails
- output remains redacted

### 2B. Local UI Connector Path

1. Open the local setup UI.
2. Go to the Wi-Fi setup flow.
3. Connect with valid credentials.
4. Repeat once with intentionally wrong credentials.

Capture:

    cp /var/lib/autopoiesis-os/device.json /tmp/aos-pi-validation/device.json
    grep -RIn "test-password\|SSID" /tmp/aos-pi-validation /var/log /opt/autopoiesis-os 2>/dev/null | head

Pass criteria:

- successful connect returns the UI to an online network state
- /var/lib/autopoiesis-os/device.json shows wifiConfigured: true
- invalid credentials produce a clear failed response with connector exit metadata
- no password leaks into local UI JSON, logs, or support artifacts

References:

- docs/agent-notes/connect-wifi-physical-validation-pi-issue.md
- docs/agent-notes/local-ui-wifi-connect-connector-note.md

## Phase 3: Pairing and Owner Preference Cascade

This validates the bridge from hosted Profile > Frames preferences to local frame behavior.

1. Pair the real frame with the hosted owner account.
2. Save baseline local-only settings on the Pi:
   - brightness
   - volume
   - night mode
   - image duration
   - display mode
3. In hosted Profile > Frames, change owner-level feed and cache preferences.
4. Force local sync and heartbeat:

       cd /opt/autopoiesis-os/app
       scripts/heartbeat.sh
       curl -sS -X POST http://127.0.0.1:3030/local/settings/sync

5. Observe the local UI and actual playback behavior.

Capture:

    cp /var/lib/autopoiesis-os/pairing.json /tmp/aos-pi-validation/pairing.json
    curl -sS http://127.0.0.1:3030/local/frame-state > /tmp/aos-pi-validation/frame-state.json
    curl -sS http://127.0.0.1:3030/local/feed/readiness > /tmp/aos-pi-validation/feed-readiness.json

Pass criteria:

- paired frame receives owner stream and cache preference changes
- feed composition and readiness reflect the hosted owner preferences
- local-only settings stay local and are not overwritten by owner cascade
- unpairing or using an unowned frame stops owner preference application

Reference:

- docs/agent-notes/aos-lead-owner-preference-cascade-gate-note.md

## Phase 4: Support Snapshot Fidelity on Real Hardware

Run:

    sudo /opt/autopoiesis-os/app/scripts/support-snapshot.sh /tmp/aos-pi-validation/support-snapshot-postpair.json

Verify the snapshot against the live machine state:

- service and timer state from systemctl
- journal evidence from journalctl
- Wi-Fi and LAN state from ip, nmcli, and rfkill
- display connector state from /sys/class/drm
- touchscreen detection
- cache and offline fallback state
- storage state and mount visibility
- thermal, power, time, and reboot evidence
- update and rollback evidence when available

Suggested spot checks:

    sudo rfkill list
    nmcli device status
    ip addr
    ls /sys/class/drm
    vcgencmd measure_temp
    vcgencmd get_throttled
    mount
    timedatectl

Pass criteria:

- snapshot matches the real machine closely enough for support triage
- no secrets, tokens, pairing codes, Wi-Fi passwords, raw EDID data, or sensitive paths are leaked
- evidence sections are populated with realistic connector, radio, thermal, and reboot state

Important hardware-bound sections called out by existing notes:

- journal and failure-unit evidence
- network and rfkill evidence
- storage and mount evidence
- display evidence
- cache and offline fallback evidence
- thermal, power, and time evidence
- reboot and update evidence

References:

- docs/agent-notes/local-appliance-support-snapshot-gate-note.md
- docs/agent-notes/support-snapshot-display-evidence-note.md
- docs/agent-notes/support-snapshot-thermal-evidence-note.md
- docs/agent-notes/support-snapshot-reboot-evidence-note.md

## Phase 5: Install, Update, Rollback, Recovery

This phase proves the release plane on the actual appliance.

1. Record the current installed version.
2. Run the supported update path on-device.
3. If possible, run one intentionally failing update scenario in a controlled environment to verify rollback and service recovery.

Suggested commands:

    cat /opt/autopoiesis-os/app/package.json | head
    sudo /opt/autopoiesis-os/app/update.sh | tee /tmp/aos-pi-validation/update-attempt.txt
    sudo systemctl status autopoiesis.target --no-pager
    sudo /opt/autopoiesis-os/app/scripts/support-snapshot.sh /tmp/aos-pi-validation/support-snapshot-postupdate.json

Pass criteria:

- update path completes or fails cleanly with actionable state
- rollback metadata is present when rollback is needed
- previously active services are restored after failure
- staging artifacts are cleaned up after failure
- support snapshot reflects the resulting update or rollback state accurately

## Phase 6: Consolidated Readiness Artifact

If the environment has the required target variables, generate the lead-owned readiness artifact too:

    cd /opt/autopoiesis-os/app
    AUTOPOIESIS_LOCAL_URL=http://127.0.0.1:3030 \
    scripts/mvp01-readiness-report.sh --quick --rollout-profile --include-local-readiness --report /tmp/aos-pi-validation/mvp01-readiness.json --issue-note /tmp/aos-pi-validation/mvp01-readiness-issue.md

Pass criteria:

- readiness report records the hardware target as present
- local readiness gate is included
- remaining failures, if any, are genuine blockers rather than missing-target placeholders

Reference:

- docs/agent-notes/mvp01-readiness-report-note.md

## Exit Decision

Call the Pi validation pass complete only when all of these are true:

- Wi-Fi onboarding passed from both shell and local UI paths
- owner preference cascade was observed on a real paired frame
- support snapshot matched live hardware state without leaking secrets
- update and recovery behavior was proven under real systemd conditions
- consolidated readiness evidence exists for the tested device

If any phase fails, write a focused issue note with:

- failing phase
- exact command or UI step
- observed result
- expected result
- artifact paths
- whether the defect is product, environment, or test-harness
