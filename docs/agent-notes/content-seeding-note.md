# Content Seeding Note

## 2026-06-08 — Gallery artwork → aos_broadcasts seeding

### What

`scripts/seed-gallery-content.mjs` reads artwork JSON files from the gallery directory
and seeds them into `aos_broadcasts` via the hosted API admin CRUD endpoints.

### Data source

- Directory: `/data/.openclaw/workspace/autopoiesis/gallery/artworks`
- 456 displayed artworks across 8 artists
- Artists: Vessel (56), Typo (99), Sandman (53), Kinema (69), Spool (55), Link (8), Agitprop (77), Emergent (39)
- Media types: generative-html (269), interactive-html (73), code-cinema (31), audio (29), mixed-media (18), generative-svg (15), text (13), collaborative (5), image (1), ascii-art (1)
- 272 artworks have image URLs (cacheable), 14 have HTML URLs, 166 have no media URL

### Transformations

- Gallery artwork ID → `aos_broadcasts.id` (preserved, requires admin handler `id` passthrough)
- `artist_id` → resolved to display name via ARTIST_NAMES map
- `media_url` → resolved to absolute URL against `--base-url` (default: https://autopoiesis.art)
- `pipeline_meta.tier` → priority (featured=high, standard=normal)
- `medium` → broadcast type (artwork, blog)
- Image URLs → `cacheAllowed=true`, thumbnailUrl set

### Usage

```bash
# Dry run
node scripts/seed-gallery-content.mjs --dry-run --gallery-dir ../autopoiesis/gallery/artworks

# Seed via API
node scripts/seed-gallery-content.mjs \
  --api-url http://localhost:3100 \
  --admin-token $TOKEN \
  --gallery-dir ../autopoiesis/gallery/artworks

# Seed specific artists
node scripts/seed-gallery-content.mjs --artists vessel,sandman --limit 20 ...

# Seed direct to SQLite (dev)
node scripts/seed-gallery-content.mjs \
  --db-path /tmp/aos.db \
  --gallery-dir ../autopoiesis/gallery/artworks
```

### Open questions

- Should content sync be scheduled (cron) or on-demand (admin button)?
- How to handle artworks without media_url (166 generative pieces)?
- Should we generate thumbnails for non-image artworks?
- Content freshness: rotation, expiry, priority decay?
- PostgreSQL seeding support for production?
