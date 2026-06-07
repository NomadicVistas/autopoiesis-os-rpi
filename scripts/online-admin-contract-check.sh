#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-${AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE:-}}"
TMP_FILE=""

cleanup() {
  if [[ -n "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

fail() {
  echo "online admin contract check failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/online-admin-contract-check.sh <online-admin-bundle.json>
  scripts/online-admin-contract-check.sh https://example/api/admin/frames/online-admin-bundle

Environment:
  AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_SOURCE  default file or URL when no argument is passed
  AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_TOKEN   optional bearer token for URL checks
EOF
}

if [[ -z "$SOURCE" ]]; then
  usage
  exit 2
fi

if [[ "$SOURCE" =~ ^https?:// ]]; then
  TMP_FILE="$(mktemp)"
  CURL_ARGS=(-fsS)
  if [[ -n "${AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${AUTOPOIESIS_ONLINE_ADMIN_CONTRACT_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "$SOURCE" >"$TMP_FILE" || fail "could not fetch online admin bundle URL"
  SOURCE="$TMP_FILE"
fi

[[ -f "$SOURCE" ]] || fail "online admin bundle file not found: $SOURCE"

node - "$SOURCE" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const allowedRoles = new Set(["admin", "maintainer", "ops", "owner", "super_admin", "support"]);
const expectedActions = new Set([
  "sync_settings",
  "clear_cache",
  "restart_display",
  "enable_device",
  "disable_device",
  "restart_device",
  "update_device",
  "show_broadcast",
  "factory_reset_request"
]);
const forbiddenPatterns = [
  /deviceApiKey/i,
  /device_api_key/i,
  /pairingCodeHash/i,
  /pairing_code_hash/i,
  /accessToken/i,
  /refreshToken/i,
  /apiKey/i,
  /secret/i,
  /password/i,
  /\/var\/lib\/autopoiesis-os/i,
  /\/opt\/autopoiesis-os/i
];

function fail(message) {
  console.error(message);
  process.exit(1);
}

function isObject(value) {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function asArray(value, field) {
  if (!Array.isArray(value)) fail(field + " must be an array");
  return value;
}

function validIso(value) {
  return typeof value === "string" && value.trim() && Number.isFinite(Date.parse(value));
}

function optionalIso(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (!validIso(value)) fail(field + " must be an ISO timestamp when present");
}

function requiredString(value, field) {
  if (typeof value !== "string" || !value.trim()) fail(field + " is required");
}

function optionalString(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "string") fail(field + " must be a string when present");
}

function optionalBoolean(value, field) {
  if (value === undefined || value === null) return;
  if (typeof value !== "boolean") fail(field + " must be boolean when present");
}

function optionalNumber(value, field) {
  if (value === undefined || value === null || value === "") return;
  if (!Number.isFinite(Number(value))) fail(field + " must be numeric when present");
}

function optionalArray(value, field) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) fail(field + " must be an array when present");
  return value;
}

function requirePageShape(section, field) {
  if (!isObject(section)) fail(field + " must be an object");
  optionalNumber(section.total, field + ".total");
  optionalNumber(section.page, field + ".page");
  optionalNumber(section.pageSize, field + ".pageSize");
  const items = asArray(section.items, field + ".items");
  if (section.total !== undefined && Number(section.total) < items.length) {
    fail(field + ".total cannot be smaller than items.length");
  }
  return items;
}

function normalizedId(value, field) {
  if (typeof value !== "string" || !value.trim()) fail(field + " is required");
  return value.trim();
}

function optionalReferenceId(value, field) {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value === "string") return normalizedId(value, field);
  if (isObject(value)) return normalizedId(value.artistId || value.artworkId || value.id, field + ".id");
  fail(field + " must be a string or object reference");
}

function optionalReferenceIds(value, field) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) fail(field + " must be an array when present");
  return value.map((item, index) => optionalReferenceId(item, field + "[" + index + "]")).filter(Boolean);
}

function assertUnique(map, id, field) {
  if (map.has(id)) fail(field + " duplicates id " + id);
  map.set(id, true);
  return id;
}

function optionalStatus(value, field, allowed) {
  if (value === undefined || value === null || value === "") return;
  if (typeof value !== "string") fail(field + " must be a string when present");
  if (!allowed.has(value)) fail(field + " is unsupported: " + value);
}

function validatePreferences(preferences, field) {
  if (!isObject(preferences)) fail(field + " must be an object");
  optionalIso(preferences.updatedAt || preferences.updated_at, field + ".updatedAt");
  optionalArray(preferences.activeArtists, field + ".activeArtists");
  optionalArray(preferences.streamCategories || preferences.enabledContentTypes, field + ".streamCategories");
  for (const key of [
    "allowImages",
    "allowVideos",
    "allowSoundWorks",
    "allowGenerativeWorks",
    "autoplay",
    "videoAutoplay",
    "soundAutoplay",
    "soundEnabled",
    "nightMode",
    "cacheEnabled",
    "cacheLikedArtworks",
    "cacheRecentArtworks",
    "cacheSelectedArtists",
    "likedWorksOnly",
    "showArtworkInfoOnTap"
  ]) {
    optionalBoolean(preferences[key], field + "." + key);
  }
  for (const key of ["volume", "imageDuration", "brightness", "cacheSizeLimitMb"]) {
    optionalNumber(preferences[key], field + "." + key);
  }
  optionalString(preferences.displayMode, field + ".displayMode");
  optionalString(preferences.streamProfile, field + ".streamProfile");
  optionalString(preferences.offlineFallbackMode, field + ".offlineFallbackMode");
}

function validateCache(cache, field, options = {}) {
  if (cache === undefined || cache === null) {
    if (options.required) fail(field + " is required");
    return;
  }
  if (!isObject(cache)) fail(field + " must be an object when present");
  for (const key of ["enabled", "likedArtworks", "recentArtworks", "selectedArtists"]) {
    optionalBoolean(cache[key], field + "." + key);
  }
  for (const key of ["sizeLimitMb", "cachedItems", "playableItems", "failedItems"]) {
    optionalNumber(cache[key], field + "." + key);
  }
  optionalIso(cache.lastSyncedAt, field + ".lastSyncedAt");
  if (options.requirePreferences) {
    for (const key of ["enabled", "likedArtworks", "recentArtworks", "selectedArtists"]) {
      if (typeof cache[key] !== "boolean") fail(field + "." + key + " must be an explicit boolean");
    }
    if (!Number.isFinite(Number(cache.sizeLimitMb))) fail(field + ".sizeLimitMb is required");
  }
}

function validateCachePreferenceCoherence(preferences, cache, field) {
  const pairs = [
    ["cacheEnabled", "enabled"],
    ["cacheLikedArtworks", "likedArtworks"],
    ["cacheRecentArtworks", "recentArtworks"],
    ["cacheSelectedArtists", "selectedArtists"],
    ["cacheSizeLimitMb", "sizeLimitMb"]
  ];

  for (const [preferenceKey, cacheKey] of pairs) {
    if (preferences[preferenceKey] === undefined || preferences[preferenceKey] === null || preferences[preferenceKey] === "") continue;
    const preferenceValue = preferences[preferenceKey];
    const cacheValue = cache[cacheKey];
    if (typeof preferenceValue === "boolean") {
      if (cacheValue !== preferenceValue) fail(field + "." + cacheKey + " must match preferences." + preferenceKey);
    } else if (Number.isFinite(Number(preferenceValue))) {
      if (!Number.isFinite(Number(cacheValue)) || Number(cacheValue) !== Number(preferenceValue)) {
        fail(field + "." + cacheKey + " must match preferences." + preferenceKey);
      }
    }
  }
}

function validatePairing(pairing, field) {
  if (pairing === undefined || pairing === null) return;
  if (!isObject(pairing)) fail(field + " must be an object when present");
  optionalString(pairing.status, field + ".status");
  optionalIso(pairing.expiresAt, field + ".expiresAt");
  optionalString(pairing.deviceId, field + ".deviceId");
  if (pairing.code !== undefined && typeof pairing.code !== "string") fail(field + ".code must be a string when present");
}

function normalizeActionAvailability(actionAvailability, field) {
  if (!isObject(actionAvailability)) fail(field + " must be an object");
  const actions = actionAvailability.actions || actionAvailability.decisions || actionAvailability;
  if (!isObject(actions)) fail(field + ".actions must be an object");
  return actions;
}

function validateActionDecision(decision, field) {
  if (typeof decision === "boolean") {
    if (decision === false) fail(field + " denied decisions must include a reason");
    return { allowed: true };
  }
  if (!isObject(decision)) fail(field + " must be boolean or object");
  const allowed =
    decision.allowed !== undefined ? decision.allowed :
    decision.permitted !== undefined ? decision.permitted :
    decision.enabled;
  if (typeof allowed !== "boolean") fail(field + ".allowed must be boolean");
  return { ...decision, allowed };
}

function validateDeviceActionAvailability(device, field, commandPolicies = null) {
  const actionAvailability =
    device.actionAvailability ||
    device.availableActions ||
    device.remoteActionAvailability ||
    device.actions;
  if (actionAvailability === undefined || actionAvailability === null) {
    fail(field + ".actionAvailability is required");
  }

  optionalIso(actionAvailability.generatedAt, field + ".actionAvailability.generatedAt");
  optionalIso(actionAvailability.evaluatedAt, field + ".actionAvailability.evaluatedAt");
  optionalString(actionAvailability.actorRole, field + ".actionAvailability.actorRole");
  optionalString(actionAvailability.reason, field + ".actionAvailability.reason");

  const actions = normalizeActionAvailability(actionAvailability, field + ".actionAvailability");
  for (const action of expectedActions) {
    if (!Object.prototype.hasOwnProperty.call(actions, action)) {
      fail(field + ".actionAvailability missing action decision for " + action);
    }
    const decision = validateActionDecision(actions[action], field + ".actionAvailability." + action);
    const command = commandPolicies ? commandPolicies.get(action) : null;

    if (decision.allowed) {
      optionalTrue(decision.requiresAuthorization || decision.authorizationRequired, field + ".actionAvailability." + action + ".requiresAuthorization");
      optionalTrue(decision.requiresAuditId || decision.auditRequired, field + ".actionAvailability." + action + ".requiresAuditId");
      optionalTrue(decision.requiresLocalConfirmation || decision.localConfirmationRequired, field + ".actionAvailability." + action + ".requiresLocalConfirmation");
      if (command && command.requiresAuthorization && decision.requiresAuthorization !== true && decision.authorizationRequired !== true) {
        fail(field + ".actionAvailability." + action + " must expose requiresAuthorization=true");
      }
      if (command && command.requiresAuditId && decision.requiresAuditId !== true && decision.auditRequired !== true) {
        fail(field + ".actionAvailability." + action + " must expose requiresAuditId=true");
      }
      if (command && command.requiresLocalConfirmation && decision.requiresLocalConfirmation !== true && decision.localConfirmationRequired !== true) {
        fail(field + ".actionAvailability." + action + " must expose requiresLocalConfirmation=true");
      }
    } else {
      const reason = decisionReason(decision);
      if (typeof reason !== "string" || !reason.trim()) {
        fail(field + ".actionAvailability." + action + " denied decisions must include a reason");
      }
      optionalString(decision.reasonCode || decision.disabledReasonCode, field + ".actionAvailability." + action + ".reasonCode");
    }
  }
}

function validateSubscription(subscription, field) {
  if (subscription === undefined || subscription === null) return;
  if (!isObject(subscription)) fail(field + " must be an object when present");
  optionalString(subscription.subscriptionId || subscription.id, field + ".subscriptionId");
  optionalString(subscription.status, field + ".status");
  optionalString(subscription.plan, field + ".plan");
  optionalString(subscription.tier, field + ".tier");
  optionalIso(subscription.currentPeriodEnd, field + ".currentPeriodEnd");
  optionalBoolean(subscription.cancelAtPeriodEnd, field + ".cancelAtPeriodEnd");
}

function optionalComparableValue(value) {
  if (value === undefined || value === null || value === "") return null;
  return String(value);
}

function requireMatchingOptional(left, right, field) {
  const leftValue = optionalComparableValue(left);
  const rightValue = optionalComparableValue(right);
  if (leftValue === null || rightValue === null) return;
  if (leftValue !== rightValue) fail(field + " must match referenced subscription");
}

function validateDevice(device, field, ownerUserId = null, options = {}) {
  if (!isObject(device)) fail(field + " must be an object");
  requiredString(device.deviceId, field + ".deviceId");
  optionalString(device.deviceName, field + ".deviceName");
  optionalString(device.ownerUserId, field + ".ownerUserId");
  if (ownerUserId && options.requireOwner && !device.ownerUserId) {
    fail(field + ".ownerUserId is required for owned Profile > Frames devices");
  }
  if (ownerUserId && device.ownerUserId && device.ownerUserId !== ownerUserId) {
    fail(field + ".ownerUserId does not match profile userId");
  }
  optionalString(device.softwareVersion, field + ".softwareVersion");
  optionalString(device.currentMode, field + ".currentMode");
  optionalString(device.currentArtworkId, field + ".currentArtworkId");
  optionalString(device.updateChannel, field + ".updateChannel");
  optionalBoolean(device.paired, field + ".paired");
  optionalBoolean(device.online, field + ".online");
  optionalBoolean(device.remoteEnabled, field + ".remoteEnabled");
  optionalBoolean(device.disabled, field + ".disabled");
  optionalIso(device.lastHeartbeatAt, field + ".lastHeartbeatAt");
  validateCache(device.cache, field + ".cache");
  validateSubscription(device.subscription, field + ".subscription");
  if (device.settings !== undefined && device.settings !== null) validatePreferences(device.settings, field + ".settings");
  if (device.health !== undefined && device.health !== null && !isObject(device.health)) fail(field + ".health must be an object when present");
  if (device.release !== undefined && device.release !== null && !isObject(device.release)) fail(field + ".release must be an object when present");
  if (options.requireActions) {
    validateDeviceActionAvailability(device, field, options.commandPolicies || null);
  }
}

function validateRemoteActions(remoteActions, field) {
  if (!isObject(remoteActions)) fail(field + " must be an object");
  const roles = optionalArray(remoteActions.acceptedActorRoles, field + ".acceptedActorRoles");
  if (!roles.length) fail(field + ".acceptedActorRoles must not be empty");
  for (const role of roles) {
    if (!allowedRoles.has(role)) fail(field + " contains unsupported actor role: " + role);
  }
  optionalNumber(remoteActions.authorizationWindowSeconds, field + ".authorizationWindowSeconds");
  if (remoteActions.highRiskRequiresAuditId !== undefined && remoteActions.highRiskRequiresAuditId !== true) {
    fail(field + ".highRiskRequiresAuditId must be true when present");
  }
  if (remoteActions.criticalRiskRequiresAuditId !== undefined && remoteActions.criticalRiskRequiresAuditId !== true) {
    fail(field + ".criticalRiskRequiresAuditId must be true when present");
  }

  const commands = asArray(remoteActions.commands, field + ".commands");
  const byType = new Map();
  for (const [index, command] of commands.entries()) {
    const prefix = field + ".commands[" + index + "]";
    if (!isObject(command)) fail(prefix + " must be an object");
    requiredString(command.commandType, prefix + ".commandType");
    requiredString(command.risk, prefix + ".risk");
    if (!["low", "medium", "high", "critical"].includes(command.risk)) fail(prefix + ".risk is unsupported");
    if (typeof command.requiresAuthorization !== "boolean") fail(prefix + ".requiresAuthorization must be boolean");
    if (typeof command.requiresAuditId !== "boolean") fail(prefix + ".requiresAuditId must be boolean");
    optionalBoolean(command.requiresLocalConfirmation, prefix + ".requiresLocalConfirmation");
    optionalString(command.status, prefix + ".status");
    optionalString(command.executionStatus, prefix + ".executionStatus");
    const commandRoles = optionalArray(command.acceptedActorRoles, prefix + ".acceptedActorRoles");
    for (const role of commandRoles) {
      if (!allowedRoles.has(role)) fail(prefix + " contains unsupported actor role: " + role);
    }
    if (["medium", "high", "critical"].includes(command.risk) && command.requiresAuthorization !== true) {
      fail(command.commandType + " must require authorization");
    }
    if (["high", "critical"].includes(command.risk) && command.requiresAuditId !== true) {
      fail(command.commandType + " must require an audit id");
    }
    if (command.risk === "critical" && command.requiresLocalConfirmation !== true) {
      fail(command.commandType + " must require local confirmation when risk is critical");
    }
    byType.set(command.commandType, command);
  }
  for (const action of expectedActions) {
    if (!byType.has(action)) fail(field + " missing command policy for " + action);
  }
  validateRoleActionMatrix(remoteActions, field, roles, byType);
}

function normalizeRoleActionRows(matrix, field) {
  if (Array.isArray(matrix)) {
    return matrix.map((row, index) => {
      if (!isObject(row)) fail(field + ".roleActionMatrix[" + index + "] must be an object");
      requiredString(row.role, field + ".roleActionMatrix[" + index + "].role");
      return row;
    });
  }
  if (isObject(matrix)) {
    return Object.entries(matrix).map(([role, value]) => {
      if (!isObject(value)) fail(field + ".roleActionMatrix." + role + " must be an object");
      return { role, ...value };
    });
  }
  fail(field + ".roleActionMatrix must be an array or object");
}

function actionDecisionFromRow(row, action, prefix) {
  const actions = isObject(row.actions) ? row.actions : row;
  if (Object.prototype.hasOwnProperty.call(actions, action)) {
    const decision = actions[action];
    if (typeof decision === "boolean") return { allowed: decision };
    if (!isObject(decision)) fail(prefix + "." + action + " must be boolean or object");
    const allowed =
      decision.allowed !== undefined ? decision.allowed :
      decision.permitted !== undefined ? decision.permitted :
      decision.enabled;
    if (typeof allowed !== "boolean") fail(prefix + "." + action + ".allowed must be boolean");
    return { ...decision, allowed };
  }

  const allowed = optionalArray(row.allowedActions || row.allowed, prefix + ".allowedActions");
  const denied = optionalArray(row.deniedActions || row.denied || row.blockedActions, prefix + ".deniedActions");
  if (allowed.includes(action) && denied.includes(action)) fail(prefix + " lists " + action + " as both allowed and denied");
  if (allowed.includes(action)) return { allowed: true };
  if (denied.includes(action)) return { allowed: false, reason: row.deniedReasons && row.deniedReasons[action] };
  fail(prefix + " must include an explicit decision for " + action);
}

function decisionReason(decision) {
  return decision.reason || decision.deniedReason || decision.disabledReason || decision.message;
}

function optionalTrue(value, field) {
  if (value === undefined || value === null) return;
  if (value !== true) fail(field + " must be true when present");
}

function validateRoleActionMatrix(remoteActions, field, roles, commandPolicies) {
  const matrix = remoteActions.roleActionMatrix || remoteActions.roleMatrix || remoteActions.permissions;
  if (matrix === undefined || matrix === null) {
    fail(field + ".roleActionMatrix is required");
  }

  const rows = normalizeRoleActionRows(matrix, field);
  const byRole = new Map();
  for (const [index, row] of rows.entries()) {
    const prefix = field + ".roleActionMatrix[" + index + "]";
    if (!allowedRoles.has(row.role)) fail(prefix + ".role is unsupported");
    if (byRole.has(row.role)) fail(field + ".roleActionMatrix has duplicate role " + row.role);
    byRole.set(row.role, { row, prefix });
  }

  let deniedCount = 0;
  let criticalDeniedCount = 0;
  for (const role of roles) {
    const entry = byRole.get(role);
    if (!entry) fail(field + ".roleActionMatrix missing role " + role);
    for (const action of expectedActions) {
      const command = commandPolicies.get(action);
      const decision = actionDecisionFromRow(entry.row, action, entry.prefix);
      if (decision.allowed) {
        const commandRoles = optionalArray(command.acceptedActorRoles, field + ".commands." + action + ".acceptedActorRoles");
        if (commandRoles.length && !commandRoles.includes(role)) {
          fail(entry.prefix + "." + action + " allows a role not accepted by command policy");
        }
        optionalTrue(decision.requiresAuthorization || decision.authorizationRequired, entry.prefix + "." + action + ".requiresAuthorization");
        optionalTrue(decision.requiresAuditId || decision.auditRequired, entry.prefix + "." + action + ".requiresAuditId");
        optionalTrue(decision.requiresLocalConfirmation || decision.localConfirmationRequired, entry.prefix + "." + action + ".requiresLocalConfirmation");
        if (command.requiresAuthorization && decision.requiresAuthorization !== true && decision.authorizationRequired !== true) {
          fail(entry.prefix + "." + action + " must expose requiresAuthorization=true");
        }
        if (command.requiresAuditId && decision.requiresAuditId !== true && decision.auditRequired !== true) {
          fail(entry.prefix + "." + action + " must expose requiresAuditId=true");
        }
        if (command.requiresLocalConfirmation && decision.requiresLocalConfirmation !== true && decision.localConfirmationRequired !== true) {
          fail(entry.prefix + "." + action + " must expose requiresLocalConfirmation=true");
        }
      } else {
        deniedCount += 1;
        if (command.risk === "critical") criticalDeniedCount += 1;
        const reason = decisionReason(decision);
        if (typeof reason !== "string" || !reason.trim()) {
          fail(entry.prefix + "." + action + " denied decisions must include a reason");
        }
      }
    }
  }

  if (!deniedCount) fail(field + ".roleActionMatrix must include at least one denied action");
  if (!criticalDeniedCount) fail(field + ".roleActionMatrix must deny at least one critical action");
}

function validateProfileFrames(profileFrames, commandPolicies = null) {
  if (!isObject(profileFrames)) fail("profileFrames must be an object");
  requiredString(profileFrames.userId, "profileFrames.userId");
  if (profileFrames.preferences === undefined) fail("profileFrames.preferences is required");
  validatePreferences(profileFrames.preferences, "profileFrames.preferences");
  validatePairing(profileFrames.pairing, "profileFrames.pairing");
  const cachePreferences = profileFrames.cachePreferences || profileFrames.cache;
  validateCache(cachePreferences, "profileFrames.cachePreferences", {
    required: true,
    requirePreferences: true
  });
  validateCachePreferenceCoherence(profileFrames.preferences, cachePreferences, "profileFrames.cachePreferences");

  const activeArtists = asArray(profileFrames.activeArtists, "profileFrames.activeArtists");
  const activeArtistIds = new Map();
  const activeArtistsById = new Map();
  const enabledActiveArtistIds = new Set();
  for (const [index, artist] of activeArtists.entries()) {
    const prefix = "profileFrames.activeArtists[" + index + "]";
    if (!isObject(artist)) fail(prefix + " must be an object");
    const artistId = assertUnique(activeArtistIds, normalizedId(artist.artistId || artist.id, prefix + ".artistId"), "profileFrames.activeArtists");
    activeArtistsById.set(artistId, artist);
    optionalString(artist.name, prefix + ".name");
    optionalBoolean(artist.enabled, prefix + ".enabled");
    if (artist.enabled === true) enabledActiveArtistIds.add(artistId);
  }
  for (const artistId of optionalReferenceIds(profileFrames.preferences.activeArtists, "profileFrames.preferences.activeArtists")) {
    if (!activeArtistIds.has(artistId)) {
      fail("profileFrames.preferences.activeArtists references an artist missing from profileFrames.activeArtists");
    }
    const artist = activeArtistsById.get(artistId);
    if (artist && artist.enabled === false) {
      fail("profileFrames.preferences.activeArtists references disabled artist " + artistId);
    }
  }
  if (enabledActiveArtistIds.size && profileFrames.preferences.activeArtists !== undefined) {
    const preferenceIds = new Set(optionalReferenceIds(profileFrames.preferences.activeArtists, "profileFrames.preferences.activeArtists"));
    for (const artistId of enabledActiveArtistIds) {
      if (!preferenceIds.has(artistId)) {
        fail("profileFrames.activeArtists enables artist " + artistId + " missing from preferences.activeArtists");
      }
    }
  }

  function validateLikedArtwork(artwork, prefix) {
    if (!isObject(artwork)) fail(prefix + " must be an object");
    const artworkId = normalizedId(artwork.artworkId || artwork.id, prefix + ".artworkId");
    optionalIso(artwork.likedAt, prefix + ".likedAt");
    optionalString(artwork.artistId, prefix + ".artistId");
    optionalString(artwork.title, prefix + ".title");
    return artworkId;
  }

  const likedArtworks = profileFrames.likedArtworks;
  const likedArtworkIds = new Map();
  if (Array.isArray(likedArtworks)) {
    for (const [index, artwork] of likedArtworks.entries()) {
      assertUnique(likedArtworkIds, validateLikedArtwork(artwork, "profileFrames.likedArtworks[" + index + "]"), "profileFrames.likedArtworks");
    }
  } else if (isObject(likedArtworks)) {
    optionalNumber(likedArtworks.total, "profileFrames.likedArtworks.total");
    optionalNumber(likedArtworks.page, "profileFrames.likedArtworks.page");
    optionalNumber(likedArtworks.pageSize, "profileFrames.likedArtworks.pageSize");
    const items = asArray(likedArtworks.items, "profileFrames.likedArtworks.items");
    if (likedArtworks.total !== undefined && Number(likedArtworks.total) < items.length) {
      fail("profileFrames.likedArtworks.total cannot be smaller than items.length");
    }
    for (const [index, artwork] of items.entries()) {
      assertUnique(likedArtworkIds, validateLikedArtwork(artwork, "profileFrames.likedArtworks.items[" + index + "]"), "profileFrames.likedArtworks");
    }
  } else {
    fail("profileFrames.likedArtworks must be an array or page object");
  }

  const devices = asArray(profileFrames.devices, "profileFrames.devices");
  for (const [index, device] of devices.entries()) {
    validateDevice(device, "profileFrames.devices[" + index + "]", profileFrames.userId, {
      requireActions: true,
      requireOwner: true,
      commandPolicies
    });
  }
}

function validateAdminFrames(adminFrames) {
  if (!isObject(adminFrames)) fail("adminFrames must be an object");
  if (!isObject(adminFrames.actor)) fail("adminFrames.actor must be an object");
  requiredString(adminFrames.actor.actorId || adminFrames.actor.userId, "adminFrames.actor.actorId");
  requiredString(adminFrames.actor.role, "adminFrames.actor.role");
  if (!allowedRoles.has(adminFrames.actor.role)) fail("adminFrames.actor.role is unsupported");

  const users = requirePageShape(adminFrames.users, "adminFrames.users");
  const subscribers = requirePageShape(adminFrames.subscribers, "adminFrames.subscribers");
  const subscriptions = requirePageShape(adminFrames.subscriptions, "adminFrames.subscriptions");
  const devices = requirePageShape(adminFrames.devices || adminFrames.deviceFleet, "adminFrames.devices");

  const subscriptionStatuses = new Set(["active", "trialing", "past_due", "canceled", "cancelled", "comped", "paused", "incomplete", "unpaid"]);
  const subscriberStatuses = new Set(["active", "trialing", "past_due", "canceled", "cancelled", "comped", "paused", "test", "inactive"]);
  const entitledSubscriptionStatuses = new Set(["active", "trialing", "past_due", "comped"]);
  const usersById = new Map();
  const subscribersByUserId = new Map();
  const subscriptionsById = new Map();
  const subscriptionsByUserId = new Map();
  const deviceIds = new Map();

  for (const [index, user] of users.entries()) {
    const prefix = "adminFrames.users.items[" + index + "]";
    if (!isObject(user)) fail(prefix + " must be an object");
    const userId = assertUnique(usersById, normalizedId(user.userId || user.id, prefix + ".userId"), "adminFrames.users");
    usersById.set(userId, user);
    optionalString(user.email, prefix + ".email");
    optionalNumber(user.frameCount, prefix + ".frameCount");
    validateSubscription(user.subscription, prefix + ".subscription");
    if (user.subscription) {
      optionalStatus(user.subscription.status, prefix + ".subscription.status", subscriptionStatuses);
    }
  }

  for (const [index, subscriber] of subscribers.entries()) {
    const prefix = "adminFrames.subscribers.items[" + index + "]";
    if (!isObject(subscriber)) fail(prefix + " must be an object");
    const userId = assertUnique(subscribersByUserId, normalizedId(subscriber.userId || subscriber.id, prefix + ".userId"), "adminFrames.subscribers");
    subscribersByUserId.set(userId, subscriber);
    if (!usersById.has(userId)) fail(prefix + ".userId must reference adminFrames.users");
    optionalStatus(subscriber.status, prefix + ".status", subscriberStatuses);
    optionalString(subscriber.plan, prefix + ".plan");
    optionalString(subscriber.tier, prefix + ".tier");
    optionalString(subscriber.subscriptionId, prefix + ".subscriptionId");
    optionalBoolean(subscriber.testAccount, prefix + ".testAccount");
  }

  for (const [index, subscription] of subscriptions.entries()) {
    const prefix = "adminFrames.subscriptions.items[" + index + "]";
    if (!isObject(subscription)) fail(prefix + " must be an object");
    const subscriptionId = assertUnique(subscriptionsById, normalizedId(subscription.subscriptionId || subscription.id, prefix + ".subscriptionId"), "adminFrames.subscriptions");
    const userId = normalizedId(subscription.userId, prefix + ".userId");
    subscriptionsById.set(subscriptionId, subscription);
    if (!subscriptionsByUserId.has(userId)) subscriptionsByUserId.set(userId, []);
    subscriptionsByUserId.get(userId).push(subscription);
    if (!usersById.has(userId)) fail(prefix + ".userId must reference adminFrames.users");
    optionalStatus(subscription.status, prefix + ".status", subscriptionStatuses);
    optionalString(subscription.plan, prefix + ".plan");
    optionalString(subscription.tier, prefix + ".tier");
    optionalIso(subscription.currentPeriodEnd, prefix + ".currentPeriodEnd");
    optionalBoolean(subscription.cancelAtPeriodEnd, prefix + ".cancelAtPeriodEnd");
    if (entitledSubscriptionStatuses.has(subscription.status) && !subscribersByUserId.has(userId)) {
      fail(prefix + ".userId with entitled status must also appear in adminFrames.subscribers");
    }
  }

  validateRemoteActions(adminFrames.remoteActions, "adminFrames.remoteActions");
  const commandPolicies = new Map(adminFrames.remoteActions.commands.map((command) => [command.commandType, command]));

  for (const [index, device] of devices.entries()) {
    validateDevice(device, "adminFrames.devices.items[" + index + "]", null, {
      requireActions: true,
      commandPolicies
    });
    assertUnique(deviceIds, device.deviceId, "adminFrames.devices");
    if (device.ownerUserId === undefined || device.ownerUserId === null || device.ownerUserId === "") {
      fail("adminFrames.devices.items[" + index + "].ownerUserId is required for fleet admin");
    }
    if (!usersById.has(device.ownerUserId)) {
      fail("adminFrames.devices.items[" + index + "].ownerUserId must reference adminFrames.users");
    }
    if (device.subscription) {
      optionalStatus(device.subscription.status, "adminFrames.devices.items[" + index + "].subscription.status", subscriptionStatuses);
      const subscriptionId = device.subscription.subscriptionId || device.subscription.id;
      if (subscriptionId && !subscriptionsById.has(subscriptionId)) {
        fail("adminFrames.devices.items[" + index + "].subscription.subscriptionId must reference adminFrames.subscriptions");
      }
      if (subscriptionId) {
        const subscription = subscriptionsById.get(subscriptionId);
        if (subscription.userId !== device.ownerUserId) {
          fail("adminFrames.devices.items[" + index + "].subscription.subscriptionId must belong to device.ownerUserId");
        }
        requireMatchingOptional(device.subscription.status, subscription.status, "adminFrames.devices.items[" + index + "].subscription.status");
        requireMatchingOptional(device.subscription.plan, subscription.plan, "adminFrames.devices.items[" + index + "].subscription.plan");
        requireMatchingOptional(device.subscription.tier, subscription.tier, "adminFrames.devices.items[" + index + "].subscription.tier");
      }
    }
  }

  for (const [userId, subscriber] of subscribersByUserId.entries()) {
    if (subscriber.subscriptionId && !subscriptionsById.has(subscriber.subscriptionId)) {
      fail("adminFrames.subscribers user " + userId + " references unknown subscriptionId");
    }
    if (subscriber.subscriptionId) {
      const subscription = subscriptionsById.get(subscriber.subscriptionId);
      if (subscription.userId !== userId) {
        fail("adminFrames.subscribers user " + userId + " references a subscription owned by another user");
      }
      requireMatchingOptional(subscriber.status, subscription.status, "adminFrames.subscribers user " + userId + " status");
      requireMatchingOptional(subscriber.plan, subscription.plan, "adminFrames.subscribers user " + userId + " plan");
      requireMatchingOptional(subscriber.tier, subscription.tier, "adminFrames.subscribers user " + userId + " tier");
    }
    if (!subscriptionsByUserId.has(userId) && subscriber.status !== "test" && subscriber.status !== "inactive") {
      fail("adminFrames.subscribers user " + userId + " must have a matching adminFrames.subscriptions row");
    }
  }

  return { commandPolicies };
}

let payload;
try {
  payload = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (error) {
  fail("invalid JSON: " + error.message);
}

const serialized = JSON.stringify(payload);
for (const pattern of forbiddenPatterns) {
  if (pattern.test(serialized)) fail("response appears to expose sensitive or local-only data: " + pattern);
}

if (!isObject(payload)) fail("online admin bundle must be a JSON object");
if (payload.ok === false) fail("online admin bundle ok=false");
if (payload.kind !== "autopoiesis_frames_online_admin_bundle") fail("kind must be autopoiesis_frames_online_admin_bundle");
if (payload.schemaVersion !== 1) fail("schemaVersion must be 1");
if (!validIso(payload.generatedAt)) fail("generatedAt is missing or invalid");

const adminContext = validateAdminFrames(payload.adminFrames);
validateProfileFrames(payload.profileFrames, adminContext.commandPolicies);

const profileDeviceCount = payload.profileFrames.devices.length;
const adminDeviceCount = (payload.adminFrames.devices || payload.adminFrames.deviceFleet).items.length;
const commandCount = payload.adminFrames.remoteActions.commands.length;
const roleMatrixCount = Object.keys(payload.adminFrames.remoteActions.roleActionMatrix || payload.adminFrames.remoteActions.roleMatrix || payload.adminFrames.remoteActions.permissions || {}).length;

console.log([
  "Autopoiesis Frames online admin contract",
  "profileDevices=" + profileDeviceCount,
  "adminDevices=" + adminDeviceCount,
  "users=" + payload.adminFrames.users.items.length,
  "subscribers=" + payload.adminFrames.subscribers.items.length,
  "subscriptions=" + payload.adminFrames.subscriptions.items.length,
  "remoteActions=" + commandCount,
  "roleMatrixRoles=" + roleMatrixCount
].join(" "));
NODE
