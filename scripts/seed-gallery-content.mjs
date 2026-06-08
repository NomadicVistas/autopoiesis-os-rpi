#!/usr/bin/env node
/**
 * seed-gallery-content.mjs — Seed aos_broadcasts with real gallery artwork
 *
 * Reads artwork JSON files from the autopoiesis gallery directory and seeds
 * them into the hosted API's aos_broadcasts table via the admin CRUD
 * endpoints. This populates the stream composition engine with real content,
 * unblocking the feed/cache/kiosk/admin pipelines.
 *
 * Usage:
 *   # Seed via hosted API admin endpoints (production/staging)
 *   node scripts/seed-gallery-content.mjs \
 *     --api-url http://localhost:3100 \
 *     --admin-token test-admin-token \
 *     --gallery-dir ../autopoiesis/gallery/artworks \
 *     --base-url https://autopoiesis.art
 *
 *   # Dry run (show what would be seeded)
 *   node scripts/seed-gallery-content.mjs --dry-run --gallery-dir ../autopoiesis/gallery/artworks
 *
 *   # Limit to first N artworks
 *   node scripts/seed-gallery-content.mjs --limit 20 ...
 *
 *   # Seed direct to SQLite (skips API, for development)
 *   node scripts/seed-gallery-content.mjs \
 *     --db-path /tmp/test.db \
 *     --gallery-dir ../autopoiesis/gallery/artworks \
 *     --base-url https://autopoiesis.art
 */

import { readFileSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';

// ── Artist display names ────────────────────────────────────────────────────
const ARTIST_NAMES = {
  vessel:   'Vessel',
  sandman:  'Sandman',
  jessy:    'Jessy',
  kinema:   'Kinema',
  spool:    'Spool',
  link:     'Link',
  typo:     'Typo',
  agitprop: 'Agitprop',
  emergent: 'Emergent',
};

// ── Medium to broadcast type mapping ────────────────────────────────────────
const MEDIUM_TYPE_MAP = {
  'image':            'artwork',
  'generative-html':  'artwork',
  'generative-svg':   'artwork',
  'interactive-html': 'artwork',
  'code-cinema':      'artwork',
  'audio':            'artwork',
  'mixed-media':      'artwork',
  'collaborative':    'artwork',
  'text':             'blog',
  'ascii-art':        'artwork',
};

// ── Tier to priority mapping ────────────────────────────────────────────────
const TIER_PRIORITY_MAP = {
  'featured':  'high',
  'highlight': 'high',
  'standard':  'normal',
  'developing': 'low',
};

// ── Parse CLI args ──────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    apiUrl:     process.env.AOS_API_URL || null,
    adminToken: process.env.AOS_ADMIN_TOKEN || null,
    galleryDir: process.env.AOS_GALLERY_DIR || null,
    baseUrl:    process.env.AOS_BASE_URL || 'https://autopoiesis.art',
    dbPath:     process.env.AOS_DB_PATH || null,
    limit:      Infinity,
    dryRun:     false,
    verbose:    false,
    artists:    null,  // comma-separated filter
    status:     'published', // seed status: published or draft
    help:       false,
  };

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--api-url':      args.apiUrl = argv[++i]; break;
      case '--admin-token':  args.adminToken = argv[++i]; break;
      case '--gallery-dir':  args.galleryDir = argv[++i]; break;
      case '--base-url':     args.baseUrl = argv[++i]; break;
      case '--db-path':      args.dbPath = argv[++i]; break;
      case '--limit':        args.limit = parseInt(argv[++i], 10); break;
      case '--dry-run':      args.dryRun = true; break;
      case '--verbose':      args.verbose = true; break;
      case '--artists':      args.artists = argv[++i].split(',').map(s => s.trim()); break;
      case '--status':       args.status = argv[++i]; break;
      case '--help':         args.help = true; break;
      case '-h':             args.help = true; break;
    }
  }

  return args;
}

// ── Read gallery artwork files ──────────────────────────────────────────────
function readGalleryArtworks(galleryDir, opts = {}) {
  const files = readdirSync(galleryDir).filter(f => f.endsWith('.json'));
  const artworks = [];

  for (const fn of files) {
    try {
      const raw = JSON.parse(readFileSync(join(galleryDir, fn), 'utf8'));

      // Only seed displayed artworks
      if (raw.status !== 'displayed') continue;

      // Artist filter
      if (opts.artists && !opts.artists.includes(raw.artist_id)) continue;

      artworks.push(raw);
    } catch (err) {
      if (opts.verbose) console.error(`  skip ${fn}: ${err.message}`);
    }
  }

  return artworks;
}

// ── Transform artwork → broadcast record ────────────────────────────────────
function artworkToBroadcast(artwork, baseUrl) {
  const artistId = artwork.artist_id || 'unknown';
  const artistName = ARTIST_NAMES[artistId] || artistId;
  const medium = artwork.medium || 'generative-html';
  const tier = artwork.pipeline_meta?.tier || 'standard';
  const type = MEDIUM_TYPE_MAP[medium] || 'artwork';
  const priority = TIER_PRIORITY_MAP[tier] || 'normal';

  // Resolve media URL
  let mediaUrl = null;
  if (artwork.media_url) {
    mediaUrl = artwork.media_url.startsWith('http')
      ? artwork.media_url
      : `${baseUrl}${artwork.media_url}`;
  }

  // Thumbnail: prefer image URLs, fallback to mediaUrl
  let thumbnailUrl = null;
  if (mediaUrl) {
    if (mediaUrl.endsWith('.png') || mediaUrl.endsWith('.jpg') ||
        mediaUrl.endsWith('.jpeg') || mediaUrl.endsWith('.webp')) {
      thumbnailUrl = mediaUrl;
    }
  }

  // Body: compose from concept + process
  const parts = [];
  if (artwork.concept)  parts.push(artwork.concept);
  if (artwork.process)  parts.push(`Process: ${artwork.process}`);
  if (artwork.experience) parts.push(`Experience: ${artwork.experience}`);
  const body = parts.length > 0 ? parts.join('\n\n') : null;

  // Cache eligibility: images yes, interactive/generative no
  const cacheAllowed = mediaUrl
    ? /\.(png|jpe?g|webp|gif|mp4)$/i.test(mediaUrl)
    : false;

  // Sound: audio pieces need sound
  const soundAllowed = medium === 'audio' || medium === 'mixed-media';

  // Duration hint (seconds)
  let duration = null;
  if (medium === 'audio') duration = 180;  // default 3min for audio
  if (type === 'artwork' && !duration) duration = 30; // 30s default display

  return {
    id: artwork.id,
    title: artwork.title || `Untitled by ${artistName}`,
    body,
    type,
    mediaUrl,
    thumbnailUrl,
    artist: artistName,
    artistId,
    targetType: 'all',
    targetValue: '',
    priority,
    duration,
    cacheAllowed,
    soundAllowed,
    dismissible: true,
    createdBy: 'seed-gallery-content',
    metadata: JSON.stringify({
      galleryMedium: medium,
      galleryTier: tier,
      galleryCreated: artwork.created,
      tags: artwork.tags || [],
      themes: artwork.pipeline_meta?.themes || [],
      score: artwork.pipeline_meta?.composite || null,
    }),
  };
}

// ── Sort artworks: featured first, then by score, then recent ──────────────
function sortArtworks(artworks) {
  return artworks.sort((a, b) => {
    const tierA = a.pipeline_meta?.tier || 'standard';
    const tierB = b.pipeline_meta?.tier || 'standard';
    const tierOrder = { featured: 0, highlight: 1, standard: 2, developing: 3 };
    const td = (tierOrder[tierA] ?? 2) - (tierOrder[tierB] ?? 2);
    if (td !== 0) return td;

    const scoreA = a.pipeline_meta?.composite || 0;
    const scoreB = b.pipeline_meta?.composite || 0;
    if (scoreB !== scoreA) return scoreB - scoreA;

    return (b.created || '').localeCompare(a.created || '');
  });
}

// ── Seed via admin API ──────────────────────────────────────────────────────
async function seedViaApi(broadcasts, apiUrl, adminToken, opts = {}) {
  const results = { created: 0, published: 0, errors: [] };

  for (const bc of broadcasts) {
    try {
      // Create
      const createRes = await fetch(`${apiUrl}/frames/admin/broadcasts`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-admin-token': adminToken,
        },
        body: JSON.stringify(bc),
      });

      const createData = await createRes.json();
      if (!createRes.ok || !createData.broadcast) {
        results.errors.push({ id: bc.id, phase: 'create', status: createRes.status, error: createData.error || 'no broadcast in response' });
        if (opts.verbose) console.error(`  ✗ create ${bc.id}: ${createData.error}`);
        continue;
      }

      // Use the server-generated ID (admin CRUD generates bcast_* IDs)
      const broadcastId = createData.broadcast.id;
      results.created++;
      if (opts.verbose) console.log(`  ✓ created ${broadcastId}: ${bc.title}`);

      // Publish (if status is 'published')
      if (opts.status === 'published') {
        const pubRes = await fetch(`${apiUrl}/frames/admin/broadcasts/${broadcastId}/publish`, {
          method: 'POST',
          headers: { 'x-admin-token': adminToken },
        });
        const pubData = await pubRes.json();
        if (!pubRes.ok) {
          results.errors.push({ id: broadcastId, phase: 'publish', status: pubRes.status, error: pubData.error });
          if (opts.verbose) console.error(`  ✗ publish ${broadcastId}: ${pubData.error}`);
        } else {
          results.published++;
        }
      }

      // Small delay to avoid overwhelming the server
      await new Promise(r => setTimeout(r, 20));

    } catch (err) {
      results.errors.push({ id: bc.id, phase: 'network', error: err.message });
      if (opts.verbose) console.error(`  ✗ network ${bc.id}: ${err.message}`);
    }
  }

  return results;
}

// ── Seed direct to SQLite ───────────────────────────────────────────────────
async function seedViaSqlite(broadcasts, dbPath, opts = {}) {
  let Database;
  try {
    Database = (await import('better-sqlite3')).default;
  } catch {
    console.error('Error: better-sqlite3 required for --db-path. Install with: npm install better-sqlite3');
    process.exit(1);
  }

  const db = new Database(dbPath);
  const results = { created: 0, published: 0, errors: [] };

  const insertStmt = db.prepare(`
    INSERT OR IGNORE INTO aos_broadcasts (
      id, title, body, type, media_url, thumbnail_url, artist, artist_id,
      target_type, target_value, priority, duration, cache_allowed,
      sound_allowed, dismissible, status, created_by, metadata_json
    ) VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?,
      ?, ?, ?, ?, ?
    )
  `);

  const publishStmt = db.prepare(`
    UPDATE aos_broadcasts SET status = 'published', updated_at = datetime('now')
    WHERE id = ? AND status = 'draft'
  `);

  const insertMany = db.transaction((items) => {
    for (const bc of items) {
      try {
        const status = opts.status === 'published' ? 'published' : 'draft';
        insertStmt.run(
          bc.id, bc.title, bc.body, bc.type, bc.mediaUrl, bc.thumbnailUrl,
          bc.artist, bc.artistId, bc.targetType, bc.targetValue, bc.priority,
          bc.duration, bc.cacheAllowed ? 1 : 0, bc.soundAllowed ? 1 : 0,
          bc.dismissible ? 1 : 0, status, bc.createdBy, bc.metadata
        );
        results.created++;
      } catch (err) {
        results.errors.push({ id: bc.id, phase: 'insert', error: err.message });
        if (opts.verbose) console.error(`  ✗ insert ${bc.id}: ${err.message}`);
      }
    }
  });

  insertMany(broadcasts);
  results.published = opts.status === 'published' ? results.created : 0;

  db.close();
  return results;
}

// ── Print help ──────────────────────────────────────────────────────────────
function printHelp() {
  console.log(`
seed-gallery-content.mjs — Seed aos_broadcasts with real gallery artwork

Usage:
  node scripts/seed-gallery-content.mjs [options]

Options:
  --gallery-dir DIR    Directory containing artwork JSON files
                       (default: AOS_GALLERY_DIR env var)
  --api-url URL        Hosted API URL for seeding via admin CRUD
                       (default: AOS_API_URL env var)
  --admin-token TOKEN  Admin auth token for API mode
                       (default: AOS_ADMIN_TOKEN env var)
  --db-path PATH       SQLite database path for direct seeding
                       (default: AOS_DB_PATH env var)
  --base-url URL       Base URL for media URL resolution
                       (default: https://autopoiesis.art)
  --limit N            Seed only first N artworks
  --artists LIST       Comma-separated artist filter (e.g. vessel,sandman)
  --status STATUS      Seed as 'published' or 'draft' (default: published)
  --dry-run            Show what would be seeded without writing
  --verbose            Print per-item progress
  --help, -h           Show this help

Modes:
  API mode:    Requires --api-url and --admin-token
  SQLite mode: Requires --db-path (uses better-sqlite3 directly)
  Dry run:     Requires neither, just prints plan

Environment variables:
  AOS_API_URL, AOS_ADMIN_TOKEN, AOS_GALLERY_DIR, AOS_BASE_URL, AOS_DB_PATH

Examples:
  # Dry run
  node scripts/seed-gallery-content.mjs --dry-run \\
    --gallery-dir ../autopoiesis/gallery/artworks

  # Seed 20 featured artworks via API
  node scripts/seed-gallery-content.mjs --limit 20 \\
    --api-url http://localhost:3100 --admin-token my-token \\
    --gallery-dir ../autopoiesis/gallery/artworks

  # Seed direct to SQLite for development
  node scripts/seed-gallery-content.mjs \\
    --db-path /tmp/aos.db \\
    --gallery-dir ../autopoiesis/gallery/artworks
`);
}

// ── Main ────────────────────────────────────────────────────────────────────
async function main() {
  const args = parseArgs(process.argv);

  if (args.help) {
    printHelp();
    process.exit(0);
  }

  // Validate
  if (!args.galleryDir) {
    console.error('Error: --gallery-dir is required. Use --help for usage.');
    process.exit(1);
  }

  const galleryDir = resolve(args.galleryDir);

  console.log('◈ seed-gallery-content');
  console.log(`  Gallery dir: ${galleryDir}`);
  console.log(`  Base URL:    ${args.baseUrl}`);
  console.log(`  Mode:        ${args.dryRun ? 'dry-run' : args.dbPath ? 'SQLite' : 'API'}`);
  if (args.limit < Infinity) console.log(`  Limit:       ${args.limit}`);
  if (args.artists) console.log(`  Artists:     ${args.artists.join(', ')}`);
  console.log(`  Status:      ${args.status}`);
  console.log('');

  // Read gallery artworks
  console.log('Reading gallery artworks...');
  const artworks = readGalleryArtworks(galleryDir, { verbose: args.verbose, artists: args.artists });
  console.log(`  Found ${artworks.length} displayed artworks`);

  // Sort: featured first, then by score
  const sorted = sortArtworks(artworks);

  // Apply limit
  const selected = args.limit < Infinity ? sorted.slice(0, args.limit) : sorted;

  // Transform to broadcast format
  const broadcasts = selected.map(a => artworkToBroadcast(a, args.baseUrl));

  // Stats
  const byArtist = {};
  const byType = {};
  const byPriority = {};
  let withMedia = 0;
  let cacheable = 0;

  for (const bc of broadcasts) {
    byArtist[bc.artistId] = (byArtist[bc.artistId] || 0) + 1;
    byType[bc.type] = (byType[bc.type] || 0) + 1;
    byPriority[bc.priority] = (byPriority[bc.priority] || 0) + 1;
    if (bc.mediaUrl) withMedia++;
    if (bc.cacheAllowed) cacheable++;
  }

  console.log(`  Selected ${broadcasts.length} artworks for seeding`);
  console.log('');
  console.log('  By artist:');
  for (const [a, c] of Object.entries(byArtist).sort((a, b) => b[1] - a[1])) {
    console.log(`    ${ARTIST_NAMES[a] || a}: ${c}`);
  }
  console.log(`  By type: ${Object.entries(byType).map(([t, c]) => `${t}=${c}`).join(', ')}`);
  console.log(`  By priority: ${Object.entries(byPriority).map(([p, c]) => `${p}=${c}`).join(', ')}`);
  console.log(`  With media URL: ${withMedia}`);
  console.log(`  Cacheable: ${cacheable}`);
  console.log('');

  if (args.dryRun) {
    console.log('Dry run — no data written. First 5 items:');
    for (const bc of broadcasts.slice(0, 5)) {
      console.log(`  ${bc.id} | ${bc.artist} | ${bc.priority} | ${bc.title}`);
      console.log(`    media: ${bc.mediaUrl || '(none)'}`);
      console.log(`    thumb: ${bc.thumbnailUrl || '(none)'}`);
    }
    if (broadcasts.length > 5) {
      console.log(`  ... and ${broadcasts.length - 5} more`);
    }
    console.log('');
    console.log(`Would seed ${broadcasts.length} artworks as ${args.status}.`);
    return;
  }

  // Seed
  let results;
  if (args.dbPath) {
    console.log('Seeding via SQLite...');
    results = await seedViaSqlite(broadcasts, args.dbPath, { status: args.status, verbose: args.verbose });
  } else if (args.apiUrl && args.adminToken) {
    console.log('Seeding via API...');
    results = await seedViaApi(broadcasts, args.apiUrl, args.adminToken, { status: args.status, verbose: args.verbose });
  } else {
    console.error('Error: specify --db-path for SQLite mode or --api-url + --admin-token for API mode.');
    console.error('Use --dry-run to preview without writing.');
    process.exit(1);
  }

  console.log('');
  console.log('Results:');
  console.log(`  Created:  ${results.created}`);
  console.log(`  Published: ${results.published}`);
  console.log(`  Errors:   ${results.errors.length}`);
  if (results.errors.length > 0) {
    for (const e of results.errors.slice(0, 5)) {
      console.error(`    ${e.id}: ${e.phase} — ${e.error}`);
    }
    if (results.errors.length > 5) {
      console.error(`    ... and ${results.errors.length - 5} more`);
    }
  }

  process.exit(results.errors.length > 0 ? 1 : 0);
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
