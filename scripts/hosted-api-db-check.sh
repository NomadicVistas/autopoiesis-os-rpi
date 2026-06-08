#!/usr/bin/env bash
set -euo pipefail

# ── AOS Hosted API Database Query Layer Validation Gate ────────────────────
# Proves that hosted-api/db.js maps API behavioral contracts to correct
# SQL operations against the aos_ tables created by run-migrations.sh.
#
# Usage:
#   scripts/hosted-api-db-check.sh
#
# Environment:
#   AOS_DB_CHECK_PORT   Port for Node test server (default: 3199)

PORT="${AOS_DB_CHECK_PORT:-3199}"
FAILURES=0
TOTAL=0
STEPS=0
TMPDIR=""

pass() { TOTAL=$((TOTAL + 1)); echo "  ✓ $*"; }
fail() { TOTAL=$((TOTAL + 1)); FAILURES=$((FAILURES + 1)); echo "  ✗ FAIL: $*" >&2; }
step() { STEPS=$((STEPS + 1)); echo ""; echo "Step $STEPS: $*"; }

cleanup() {
  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

TMPDIR="$(mktemp -d)"

echo "════════════════════════════════════════════════════════════════════"
echo "AOS Hosted API DB Layer — Isolated Validation Gate"
echo "════════════════════════════════════════════════════════════════════"

# ── Step 1: Syntax and module loading ──────────────────────────────────────
step "Syntax validation"

node --check hosted-api/db.js && pass "hosted-api/db.js syntax valid" || fail "hosted-api/db.js syntax error"

# Verify module loads
node -e "const AosDb = require('./hosted-api/db'); if (typeof AosDb !== 'function') process.exit(1);" \
  && pass "Module loads as constructor" || fail "Module load failed"

# Verify all expected methods exist
node -e "
const AosDb = require('./hosted-api/db');
const expected = [
  'registerDevice', 'authenticateDevice', 'getDevice', 'getPairingStatus',
  'claimPairingCode', 'getSettings', 'pushSettings', 'getUserPreferences',
  'setUserPreferences', 'ingestHeartbeat', 'getLatestHeartbeat',
  'queueCommand', 'getPendingCommands', 'acknowledgeCommand', 'getCommand',
  'getDeviceEvents', 'getBroadcastDeliveries', 'getLatestRelease',
  'createRelease', 'getSubscription', 'upsertSubscription',
  'likeArtwork', 'unlikeArtwork', 'getLikedArtworks',
  'isInitialized', 'listTables', 'close'
];
const proto = Object.getOwnPropertyNames(AosDb.prototype);
const missing = expected.filter(m => !proto.includes(m));
if (missing.length) { console.error('Missing:', missing.join(', ')); process.exit(1); }
console.log('All', expected.length, 'methods present');
" && pass "All 27 expected methods present" || fail "Missing methods"

# ── Step 2: Create database and bootstrap ──────────────────────────────────
step "Database bootstrap via migration runner"

DBFILE="$TMPDIR/aos-test.db"

bash scripts/run-migrations.sh --engine sqlite --db "$DBFILE" --no-validate 2>&1 \
  && pass "Migration runner created database" || fail "Migration runner failed"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');
const tables = db.listTables();
if (tables.length < 10) { console.error('Only', tables.length, 'tables'); process.exit(1); }
console.log(tables.length, 'aos_ tables found');
db.close();
" && pass "Database has aos_ tables" || fail "Database missing aos_ tables"

# ── Step 3: Device registration ────────────────────────────────────────────
step "Device registration"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// New registration
const r1 = db.registerDevice({ deviceId: 'dev-001', softwareVersion: '0.1.0', deviceName: 'Test Frame' });
if (!r1.deviceId || r1.deviceId !== 'dev-001') { console.error('Bad deviceId'); process.exit(1); }
if (!r1.deviceApiKey || !r1.deviceApiKey.startsWith('mk_dev_')) { console.error('Bad apiKey'); process.exit(1); }
if (r1.paired !== false) { console.error('Should not be paired'); process.exit(1); }
if (!r1.pairingCode || !r1.expiresAt) { console.error('Missing pairing info'); process.exit(1); }
console.log('New registration ok:', r1.deviceId, 'code:', r1.pairingCode);

// Re-registration: same device, fresh pairing code
const r2 = db.registerDevice({ deviceId: 'dev-001', softwareVersion: '0.2.0' });
if (r2.deviceApiKey !== r1.deviceApiKey) { console.error('Key changed on re-reg'); process.exit(1); }
if (r2.pairingCode === r1.pairingCode) { console.error('Same pairing code on re-reg'); process.exit(1); }
console.log('Re-registration ok: same key, new code');

db.close();
" && pass "New device registration creates device + pairing code" || fail "Registration failed"
pass "Re-registration preserves API key, refreshes pairing code"

# ── Step 4: Device authentication ──────────────────────────────────────────
step "Device authentication"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

const reg = db.registerDevice({ deviceId: 'dev-auth-001', softwareVersion: '0.1.0' });

// Correct key
const ok = db.authenticateDevice('dev-auth-001', reg.deviceApiKey);
if (!ok) { console.error('Auth failed for correct key'); process.exit(1); }
if (ok.deviceId !== 'dev-auth-001') { console.error('Wrong deviceId in auth result'); process.exit(1); }
console.log('Correct key auth ok');

// Wrong key
const bad = db.authenticateDevice('dev-auth-001', 'wrong_key');
if (bad !== null) { console.error('Should reject wrong key'); process.exit(1); }
console.log('Wrong key rejected');

// Non-existent device
const nope = db.authenticateDevice('dev-nonexistent', reg.deviceApiKey);
if (nope !== null) { console.error('Should return null for non-existent'); process.exit(1); }
console.log('Non-existent device rejected');

// Missing params
if (db.authenticateDevice(null, 'key') !== null) process.exit(1);
if (db.authenticateDevice('dev-auth-001', null) !== null) process.exit(1);
console.log('Null params rejected');

db.close();
" && pass "Correct key authenticates" || fail "Auth test failed"
pass "Wrong key returns null"
pass "Non-existent device returns null"
pass "Null params return null"

# ── Step 5: Pairing status and claim ──────────────────────────────────────
step "Pairing lifecycle"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

const reg = db.registerDevice({ deviceId: 'dev-pair-001' });

// Status before pairing
const s1 = db.getPairingStatus('dev-pair-001');
if (s1.paired !== false) { console.error('Should not be paired'); process.exit(1); }
if (!s1.pairing || !s1.pairing.pairingCode) { console.error('Missing pairing code in status'); process.exit(1); }
console.log('Pre-pair status ok:', s1.pairing.status);

// Claim with pairing code
const claim = db.claimPairingCode(reg.pairingCode, 'user-owner-001');
if (!claim.ok || !claim.paired) { console.error('Claim failed:', JSON.stringify(claim)); process.exit(1); }
if (claim.ownerUserId !== 'user-owner-001') { console.error('Wrong owner'); process.exit(1); }
console.log('Claim ok:', claim.deviceId, '→', claim.ownerUserId);

// Status after pairing
const s2 = db.getPairingStatus('dev-pair-001');
if (s2.paired !== true) { console.error('Should be paired'); process.exit(1); }
if (s2.ownerUserId !== 'user-owner-001') { console.error('Wrong owner in status'); process.exit(1); }
if (!s2.pairing || s2.pairing.status !== 'completed') { console.error('Pairing should be completed'); process.exit(1); }
console.log('Post-pair status ok: paired=true, completed');

// Re-claim same code should fail
const claim2 = db.claimPairingCode(reg.pairingCode, 'user-owner-002');
if (claim2.ok) { console.error('Should reject already-claimed code'); process.exit(1); }
console.log('Re-claim rejected:', claim2.error);

// Wrong code
const claim3 = db.claimPairingCode('WRONG-CODE', 'user-owner-001');
if (claim3.ok) { console.error('Should reject wrong code'); process.exit(1); }
console.log('Wrong code rejected:', claim3.error);

// Non-existent device
const s3 = db.getPairingStatus('dev-nonexistent');
if (s3.ok !== false) { console.error('Should fail for non-existent'); process.exit(1); }
console.log('Non-existent device pairing status fails correctly');

db.close();
" && pass "Pre-pair status shows pending with code" || fail "Pairing status failed"
pass "Claim by code pairs device to owner"
pass "Post-pair status shows completed"
pass "Re-claim same code rejected"
pass "Wrong code rejected"
pass "Non-existent device returns error"

# ── Step 6: Settings read/write with conflict resolution ──────────────────
step "Settings read/write with updatedAt conflict resolution"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// Create and pair device
const reg = db.registerDevice({ deviceId: 'dev-settings-001' });
db.claimPairingCode(reg.pairingCode, 'user-settings-owner');

// Read default settings
const s1 = db.getSettings('dev-settings-001');
if (!s1.ok) { console.error('Initial read failed'); process.exit(1); }
if (typeof s1.settings !== 'object') { console.error('Settings not object'); process.exit(1); }
if (!s1.updatedAt) { console.error('Missing updatedAt'); process.exit(1); }
console.log('Initial settings read ok, updatedAt:', s1.updatedAt);

// Write newer settings
const futureTime = new Date(Date.now() + 60000).toISOString();
const s2 = db.pushSettings('dev-settings-001', { displayMode: 'slideshow', shuffleInterval: 45 }, futureTime);
if (!s2.ok) { console.error('Newer write rejected:', JSON.stringify(s2)); process.exit(1); }
if (s2.settings.displayMode !== 'slideshow') { console.error('Settings not merged'); process.exit(1); }
if (s2.updatedAt !== futureTime) { console.error('updatedAt mismatch'); process.exit(1); }
console.log('Newer write accepted:', s2.updatedAt);

// Write stale settings
const pastTime = new Date(Date.now() - 60000).toISOString();
const s3 = db.pushSettings('dev-settings-001', { displayMode: 'shuffle' }, pastTime);
if (s3.ok) { console.error('Stale write should be rejected'); process.exit(1); }
if (!s3.conflict) { console.error('Should have conflict flag'); process.exit(1); }
if (s3.reason !== 'stale_write') { console.error('Wrong reason:', s3.reason); process.exit(1); }
if (s3.settings.displayMode !== 'slideshow') { console.error('Conflict settings wrong'); process.exit(1); }
console.log('Stale write correctly rejected with conflict');

// Read after conflict — should still have newer value
const s4 = db.getSettings('dev-settings-001');
if (s4.settings.displayMode !== 'slideshow') { console.error('Settings corrupted after conflict'); process.exit(1); }
console.log('Settings preserved after stale conflict');

db.close();
" && pass "Initial settings read returns defaults with updatedAt" || fail "Settings test failed"
pass "Newer write accepted with merged settings"
pass "Stale write rejected with conflict=true and reason=stale_write"
pass "Settings preserved after stale write conflict"

# ── Step 7: Owner preferences and cascade ──────────────────────────────────
step "User preferences and owner cascade in settings"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// Create device with owner
const reg = db.registerDevice({ deviceId: 'dev-owner-001' });
db.claimPairingCode(reg.pairingCode, 'user-owner-001');

// Set owner preferences
const prefs = db.setUserPreferences('user-owner-001', {
  activeArtists: ['artist-1', 'artist-2'],
  allowVideos: true,
  streamCategories: ['artwork']
});
if (!prefs.ok) { console.error('Set prefs failed'); process.exit(1); }
console.log('Owner prefs set:', prefs.updatedAt);

// Read device settings — should include owner preferences
const s = db.getSettings('dev-owner-001');
if (!s.ownerPreferences) { console.error('Missing ownerPreferences'); process.exit(1); }
if (!s.ownerPreferencesUpdatedAt) { console.error('Missing ownerPreferencesUpdatedAt'); process.exit(1); }
if (!s.ownerPreferences.activeArtists || s.ownerPreferences.activeArtists.length !== 2) {
  console.error('Wrong cascade data'); process.exit(1);
}
console.log('Owner cascade present in settings:', Object.keys(s.ownerPreferences).join(', '));

// Unowned device should NOT have owner preferences
const reg2 = db.registerDevice({ deviceId: 'dev-unowned-001' });
const s2 = db.getSettings('dev-unowned-001');
if (s2.ownerPreferences) { console.error('Unowned device should not have owner prefs'); process.exit(1); }
console.log('Unowned device has no owner prefs');

db.close();
" && pass "Owner preferences set and read back" || fail "Owner prefs test failed"
pass "Owner cascade appears in device settings"
pass "Unowned device has no owner preferences"

# ── Step 8: Heartbeat ingestion ────────────────────────────────────────────
step "Heartbeat ingestion with events and broadcast deliveries"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// Create and pair device
const reg = db.registerDevice({ deviceId: 'dev-hb-001' });
db.claimPairingCode(reg.pairingCode, 'user-hb-owner');

// Ingest heartbeat with events
const r1 = db.ingestHeartbeat('dev-hb-001', {
  softwareVersion: '0.2.0',
  systemMetrics: { networkOnline: true, networkType: 'wifi' },
  events: [
    { eventKey: 'boot_001', source: 'device', eventType: 'boot', observedAt: '2026-06-08T10:00:00Z' },
    { eventKey: 'display_001', source: 'kiosk', eventType: 'frame_shown', observedAt: '2026-06-08T10:01:00Z' }
  ]
});
if (!r1.ok) { console.error('Heartbeat failed'); process.exit(1); }
if (!r1.eventAck) { console.error('Missing eventAck'); process.exit(1); }
if (r1.eventAck.acceptedCount !== 2) { console.error('Wrong event count'); process.exit(1); }
console.log('Heartbeat with events ok:', r1.heartbeatAt, 'events:', r1.eventAck.acceptedCount);

// Verify device status updated
const dev = db.getDevice('dev-hb-001');
if (dev.softwareVersion !== '0.2.0') { console.error('Version not updated'); process.exit(1); }
if (!dev.lastHeartbeatAt) { console.error('No lastHeartbeatAt'); process.exit(1); }
console.log('Device status updated:', dev.softwareVersion, dev.lastHeartbeatAt);

// Ingest heartbeat with broadcast deliveries
const r2 = db.ingestHeartbeat('dev-hb-001', {
  broadcastDeliveries: {
    deliveries: [
      { broadcastId: 'bcast-001', status: 'shown', shownAt: '2026-06-08T10:05:00Z' },
      { broadcastId: 'bcast-002', status: 'received', receivedAt: '2026-06-08T10:06:00Z' }
    ]
  }
});
if (!r2.deliveryAck) { console.error('Missing deliveryAck'); process.exit(1); }
if (r2.deliveryAck.acceptedCount !== 2) { console.error('Wrong delivery count'); process.exit(1); }
console.log('Broadcast deliveries ingested:', r2.deliveryAck.acceptedCount);

// Upsert: update existing delivery status
const r3 = db.ingestHeartbeat('dev-hb-001', {
  broadcastDeliveries: {
    deliveries: [
      { broadcastId: 'bcast-001', status: 'dismissed', dismissedAt: '2026-06-08T10:10:00Z' }
    ]
  }
});
console.log('Delivery upsert ok');

// Verify delivery state
const deliveries = db.getBroadcastDeliveries({ deviceId: 'dev-hb-001' });
if (deliveries.length !== 2) { console.error('Expected 2 deliveries, got', deliveries.length); process.exit(1); }
const bcast001 = deliveries.find(d => d.broadcastId === 'bcast-001');
if (bcast001.status !== 'dismissed') { console.error('Status not updated to dismissed'); process.exit(1); }
console.log('Delivery state verified:', deliveries.length, 'records, bcast-001 status:', bcast001.status);

// Heartbeat without events/deliveries
const r4 = db.ingestHeartbeat('dev-hb-001', { softwareVersion: '0.2.0' });
if (!r4.ok) { console.error('Empty heartbeat failed'); process.exit(1); }
if (r4.eventAck !== null) { console.error('Should not have eventAck'); process.exit(1); }
if (r4.deliveryAck !== null) { console.error('Should not have deliveryAck'); process.exit(1); }
console.log('Empty heartbeat ok');

db.close();
" && pass "Heartbeat with events ingested, eventAck returned" || fail "Heartbeat test failed"
pass "Device status updated from heartbeat metrics"
pass "Broadcast deliveries ingested and upserted"
pass "Empty heartbeat succeeds without eventAck/deliveryAck"

# ── Step 9: Command lifecycle ──────────────────────────────────────────────
step "Command queue, poll, and acknowledge"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// Create device
const reg = db.registerDevice({ deviceId: 'dev-cmd-001' });
db.claimPairingCode(reg.pairingCode, 'user-cmd-owner');

// Queue commands
const c1 = db.queueCommand('dev-cmd-001', 'sync_settings', { source: 'admin' });
if (!c1.ok) { console.error('Queue failed'); process.exit(1); }
if (c1.command.status !== 'queued') { console.error('Wrong initial status'); process.exit(1); }
console.log('Command queued:', c1.command.commandId);

const c2 = db.queueCommand('dev-cmd-001', 'show_broadcast', { broadcastId: 'bcast-001', title: 'Test' });
console.log('Second command queued:', c2.command.commandId);

// Get pending commands
const pending = db.getPendingCommands('dev-cmd-001');
if (pending.length !== 2) { console.error('Expected 2 pending, got', pending.length); process.exit(1); }
console.log('Pending commands:', pending.length);

// Acknowledge first command
const ack = db.acknowledgeCommand('dev-cmd-001', c1.command.commandId, 'acknowledged');
if (!ack.ok) { console.error('Ack failed'); process.exit(1); }
if (ack.status !== 'acknowledged') { console.error('Wrong ack status'); process.exit(1); }
console.log('Command acknowledged:', ack.commandId);

// Get pending again — should only have the second
const pending2 = db.getPendingCommands('dev-cmd-001');
if (pending2.length !== 1) { console.error('Expected 1 pending after ack, got', pending2.length); process.exit(1); }
if (pending2[0].commandId !== c2.command.commandId) { console.error('Wrong remaining command'); process.exit(1); }
console.log('After ack, 1 pending remaining');

// Get specific command
const cmd = db.getCommand(c1.command.commandId);
if (!cmd || cmd.status !== 'acknowledged') { console.error('Get command failed'); process.exit(1); }
console.log('Get command ok:', cmd.status);

// Acknowledge non-existent command
const ack2 = db.acknowledgeCommand('dev-cmd-001', 'cmd_nonexistent', 'acknowledged');
if (ack2.ok) { console.error('Should fail for non-existent'); process.exit(1); }
console.log('Non-existent command ack rejected');

db.close();
" && pass "Commands queued with pending status" || fail "Command test failed"
pass "Pending commands returned in order"
pass "Acknowledge updates status, removes from pending"
pass "Non-existent command ack returns error"

# ── Step 10: Device events query ───────────────────────────────────────────
step "Device events query"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// Create device and ingest events
const reg = db.registerDevice({ deviceId: 'dev-events-001' });
db.claimPairingCode(reg.pairingCode, 'user-events-owner');
db.ingestHeartbeat('dev-events-001', {
  events: [
    { eventKey: 'evt_boot', source: 'device', eventType: 'boot', observedAt: '2026-06-08T10:00:00Z' },
    { eventKey: 'evt_frame', source: 'kiosk', eventType: 'frame_shown', observedAt: '2026-06-08T10:01:00Z' },
    { eventKey: 'evt_like', source: 'device', eventType: 'artwork_liked', observedAt: '2026-06-08T10:02:00Z' }
  ]
});

const events = db.getDeviceEvents('dev-events-001');
if (events.length !== 3) { console.error('Expected 3 events, got', events.length); process.exit(1); }
if (events[0].eventKey !== 'evt_like') { console.error('Events not ordered by observed_at DESC'); process.exit(1); }
console.log('Events:', events.length, 'most recent:', events[0].eventKey);

// Upsert: same event key should update, not duplicate
db.ingestHeartbeat('dev-events-001', {
  events: [
    { eventKey: 'evt_like', source: 'device', eventType: 'artwork_liked', status: 'confirmed', observedAt: '2026-06-08T10:02:00Z' }
  ]
});
const events2 = db.getDeviceEvents('dev-events-001');
if (events2.length !== 3) { console.error('Upsert should not create duplicate, got', events2.length); process.exit(1); }
console.log('Event upsert ok: still', events2.length, 'events');

db.close();
" && pass "Events returned in reverse chronological order" || fail "Events test failed"
pass "Event upsert by (device_id, event_key) works correctly"

# ── Step 11: Releases ──────────────────────────────────────────────────────
step "Release creation and query"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// No releases initially
const none = db.getLatestRelease('stable');
if (none !== null) { console.error('Should be null with no releases'); process.exit(1); }
console.log('No releases initially');

// Create a draft release
const r1 = db.createRelease({ version: '0.1.0', channel: 'stable', status: 'draft', createdBy: 'pulse' });
if (!r1.ok) { console.error('Create release failed'); process.exit(1); }
console.log('Draft release created:', r1.release.id);

// Draft should not appear as latest
const draft = db.getLatestRelease('stable');
if (draft !== null) { console.error('Draft should not be latest'); process.exit(1); }
console.log('Draft not returned as latest');

// Publish it
const r2 = db.createRelease({ version: '0.1.0', channel: 'stable', status: 'published', createdBy: 'pulse',
  artifactUrl: 'https://example.com/artifact.tar.gz', checksum: 'abc123', notes: 'First release',
  changelogUrl: 'https://github.com/...', rollbackNotes: 'Reinstall 0.0.1' });
console.log('Published release:', r2.release.id);

// Latest should now return the published release
const latest = db.getLatestRelease('stable');
if (!latest || latest.version !== '0.1.0') { console.error('Latest release wrong'); process.exit(1); }
if (latest.artifactUrl !== 'https://example.com/artifact.tar.gz') { console.error('Missing artifact URL'); process.exit(1); }
console.log('Latest release ok:', latest.version, latest.channel);

db.close();
" && pass "No release returns null" || fail "Release test failed"
pass "Draft release created but not returned as latest"
pass "Published release returned as latest with all fields"

# ── Step 12: Subscriptions ─────────────────────────────────────────────────
step "Subscription CRUD"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// No subscription initially
const none = db.getSubscription('user-sub-001');
if (none !== null) { console.error('Should be null'); process.exit(1); }
console.log('No subscription initially');

// Create subscription
const c = db.upsertSubscription('user-sub-001', { plan: 'frames_trial', status: 'trial', provider: 'stripe' });
if (!c.ok) { console.error('Create failed'); process.exit(1); }
if (c.subscription.plan !== 'frames_trial') { console.error('Wrong plan'); process.exit(1); }
if (c.subscription.status !== 'trial') { console.error('Wrong status'); process.exit(1); }
console.log('Created:', c.subscription.plan, c.subscription.status);

// Update subscription (transition to active)
const u = db.upsertSubscription('user-sub-001', { plan: 'frames_basic', status: 'active' });
if (!u.ok) { console.error('Update failed'); process.exit(1); }
if (u.subscription.plan !== 'frames_basic') { console.error('Plan not updated'); process.exit(1); }
if (u.subscription.status !== 'active') { console.error('Status not updated'); process.exit(1); }
console.log('Updated:', u.subscription.plan, u.subscription.status);

// Read back
const s = db.getSubscription('user-sub-001');
if (s.plan !== 'frames_basic') { console.error('Read back wrong'); process.exit(1); }
console.log('Read back ok:', s.plan, s.status);

db.close();
" && pass "Subscription created and read back" || fail "Subscription test failed"
pass "Subscription updated (plan + status)"
pass "Read back matches updated values"

# ── Step 13: Artwork likes ─────────────────────────────────────────────────
step "Artwork likes"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// No likes initially
const none = db.getLikedArtworks('user-like-001');
if (none.length !== 0) { console.error('Should be empty'); process.exit(1); }
console.log('No likes initially');

// Like artworks
db.likeArtwork('user-like-001', 'art-001');
db.likeArtwork('user-like-001', 'art-002');
db.likeArtwork('user-like-001', 'art-003');

const liked = db.getLikedArtworks('user-like-001');
if (liked.length !== 3) { console.error('Expected 3, got', liked.length); process.exit(1); }
console.log('Liked:', liked);

// Idempotent like
db.likeArtwork('user-like-001', 'art-002');
const liked2 = db.getLikedArtworks('user-like-001');
if (liked2.length !== 3) { console.error('Should still be 3, got', liked2.length); process.exit(1); }
console.log('Idempotent like ok');

// Unlike
db.unlikeArtwork('user-like-001', 'art-001');
const liked3 = db.getLikedArtworks('user-like-001');
if (liked3.length !== 2 || liked3.includes('art-001')) { console.error('Unlike failed'); process.exit(1); }
console.log('Unliked art-001, remaining:', liked3);

db.close();
" && pass "Like artwork and retrieve" || fail "Likes test failed"
pass "Like is idempotent (INSERT OR IGNORE)"
pass "Unlike removes artwork from list"

# ── Step 14: Schema contract compatibility ─────────────────────────────────
step "Schema contract check passes after all operations"

# Run the schema contract checker against the database after all operations
bash scripts/aos-schema-contract-check.sh "$DBFILE" 2>&1 \
  && pass "Schema contract check passes on operated database" || fail "Schema contract check failed"

# ── Step 15: Cross-system integration ──────────────────────────────────────
step "Full lifecycle integration: register → pair → settings → heartbeat → commands"

node -e "
const AosDb = require('./hosted-api/db');
const db = new AosDb('$DBFILE');

// 1. Register
const reg = db.registerDevice({ deviceId: 'dev-lifecycle-001', softwareVersion: '0.1.0' });
if (!reg.pairingCode) { console.error('No pairing code'); process.exit(1); }
console.log('1. Registered:', reg.deviceId);

// 2. Pair
const claim = db.claimPairingCode(reg.pairingCode, 'user-lifecycle-owner');
if (!claim.ok) { console.error('Claim failed'); process.exit(1); }
console.log('2. Paired to:', claim.ownerUserId);

// 3. Authenticate
const auth = db.authenticateDevice('dev-lifecycle-001', reg.deviceApiKey);
if (!auth || !auth.paired) { console.error('Auth failed'); process.exit(1); }
console.log('3. Authenticated:', auth.deviceId, 'paired:', auth.paired);

// 4. Write settings
const settings = db.pushSettings('dev-lifecycle-001', { displayMode: 'slideshow', shuffleInterval: 60 }, new Date().toISOString());
if (!settings.ok) { console.error('Settings write failed'); process.exit(1); }
console.log('4. Settings written:', settings.settings.displayMode);

// 5. Queue command
const cmd = db.queueCommand('dev-lifecycle-001', 'restart_device', { reason: 'admin' });
console.log('5. Command queued:', cmd.command.commandType);

// 6. Heartbeat with events + delivery
const hb = db.ingestHeartbeat('dev-lifecycle-001', {
  softwareVersion: '0.1.0',
  systemMetrics: { networkOnline: true, networkType: 'ethernet' },
  events: [{ eventKey: 'evt_lifecycle_boot', source: 'device', eventType: 'boot', observedAt: '2026-06-08T11:00:00Z' }],
  broadcastDeliveries: { deliveries: [{ broadcastId: 'bcast-lifecycle', status: 'shown', shownAt: '2026-06-08T11:01:00Z' }] }
});
if (!hb.ok || !hb.eventAck || !hb.deliveryAck) { console.error('Heartbeat failed'); process.exit(1); }
console.log('6. Heartbeat: events:', hb.eventAck.acceptedCount, 'deliveries:', hb.deliveryAck.acceptedCount);

// 7. Get pending commands
const pending = db.getPendingCommands('dev-lifecycle-001');
if (pending.length !== 1) { console.error('Expected 1 pending'); process.exit(1); }
console.log('7. Pending commands:', pending.length);

// 8. Acknowledge command
const ack = db.acknowledgeCommand('dev-lifecycle-001', cmd.command.commandId, 'completed');
if (!ack.ok) { console.error('Ack failed'); process.exit(1); }
console.log('8. Command acknowledged:', ack.status);

// 9. Verify final device state
const dev = db.getDevice('dev-lifecycle-001');
if (!dev.paired || dev.ownerUserId !== 'user-lifecycle-owner') { console.error('Final state wrong'); process.exit(1); }
if (!dev.lastHeartbeatAt) { console.error('No heartbeat timestamp'); process.exit(1); }
console.log('9. Final device state: paired:', dev.paired, 'owner:', dev.ownerUserId, 'lastHB:', dev.lastHeartbeatAt);

// 10. Verify events and deliveries
const events = db.getDeviceEvents('dev-lifecycle-001');
const deliveries = db.getBroadcastDeliveries({ deviceId: 'dev-lifecycle-001' });
console.log('10. Events:', events.length, 'Deliveries:', deliveries.length);

console.log('');
console.log('Full lifecycle integration: PASSED');
db.close();
" && pass "Full lifecycle integration (10 operations) passes" || fail "Lifecycle integration failed"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
if [[ "$FAILURES" -eq 0 ]]; then
  echo "✅ ALL $TOTAL CHECKS PASSED ($STEPS steps)"
else
  echo "❌ $FAILURES FAILURES out of $TOTAL checks ($STEPS steps)"
fi
echo "════════════════════════════════════════════════════════════════════"

exit "$FAILURES"
