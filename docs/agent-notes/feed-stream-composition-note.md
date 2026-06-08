# Feed Stream Composition Note

Date: 2026-06-08 11:55 UTC / 2026-06-08 13:55 Europe/Berlin
Agent: Pulse
Context: BROADCAST / FEED cron pass. The mock API's stream endpoint returned 2 hardcoded items. This meant the entire device-side feed pipeline was tested with static content — no personalization, no targeting, no subscription-tier awareness, no content diversity.

## What Changed

Built `composePersonalizedStream(record)` — the core stream composition engine in the mock hosted API:

1. **Content pool**: 18 items across all 6 categories (artwork, broadcast, curatorial, blog, news, content), 7 artists, diverse types (image, video, audio, generative, broadcast_message, blog_post, news, announcement, curatorial). Items have realistic targeting, priority, scheduling, and cache eligibility.

2. **Targeting**: Filters by subscription tier (premium-only items), device ID, owner user ID, and exclusion lists. Unowned devices don't see targeted content.

3. **Scheduling**: Filters expired items and future-scheduled items. The pool includes one expired item and one future-scheduled item to validate filtering.

4. **Priority sort**: emergency(500) > critical(400) > high(300) > normal(200) > low(100). Artist preference boosting applies within priority groups (not across them — emergency broadcast always comes before high artwork even if artist is boosted).

5. **Polling**: Subscription-tier-aware defaults: trial (600s/1200s), default (300s/900s), premium (180s/600s).

6. **Broadcast commands**: Queued `show_broadcast` commands are included in the stream as broadcast items.

7. **Content injection**: `POST /mock/add-content` and `DELETE /mock/content` for runtime test fixtures.

## Key Design Decisions

- **Priority > artist boosting**: The sort applies priority first, then artist match within priority groups. This ensures emergency/critical broadcasts always surface first regardless of user preferences.

- **Owner cascade in stream response**: The stream endpoint now includes `ownerPreferences` when the device has an owner, enabling device-side owner cascade through both settings sync and feed sync paths.

- **Broadcast commands as stream items**: Queued `show_broadcast` commands are surfaced as items in the stream response, not as separate commands. This lets the device display them through the normal feed pipeline.

- **30-item cap**: Prevents oversized responses. The real hosted API will likely have a similar cap with pagination.

## What Needs Review

- The content pool is static (defined at module load). In the real hosted API, content should be queried from `aos_*` tables at request time.
- The targeting resolution duplicates logic from the device-side `feedItemTargetAllowed()`. The hosted API should use the same targeting vocabulary documented in the feed model contract.
- The priority mapping matches the device-side `priorityRank()` but is implemented independently. Consider extracting to a shared module when the hosted API is built.

## Next Recommended Actions

- Build the hosted API stream endpoint using `AosDb` to query content from `aos_*` tables.
- Add feed composition metrics to diagnostics: category distribution, targeting effectiveness, artist coverage.
- Test the full device-side pipeline: stream sync → normalization → eligibility → display queue → cache behavior with the new diverse content.
- Consider adding time-based content rotation (morning/evening themes, exhibition schedules) to the composition engine.
