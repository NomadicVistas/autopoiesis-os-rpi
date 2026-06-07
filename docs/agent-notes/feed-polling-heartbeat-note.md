# Feed Polling Heartbeat Note

Date: 2026-06-07
Agent: Pulse
Workstream: BROADCAST / FEED

## Context

The hosted `/stream` contract can provide redacted polling cadence, but the appliance previously treated that cadence mostly as metadata. Manual `POST /local/feed/sync` worked, and feed state exposed polling hints, but the installed heartbeat loop did not use those hints to refresh the personalized stream.

## Device-side contract

- `POST /local/heartbeat` now evaluates the saved feed polling policy before sending its hosted heartbeat.
- Initial missing feed state is due immediately.
- `nextPollAt`, `pollAfterSeconds`, and `maxPollSeconds` can mark a feed due; `staleAfter` marks it stale/due.
- `minPollSeconds` is respected by delaying a natural due time until the minimum interval has elapsed.
- Computed status is exposed as `pollingStatus` on `/local/feed`, `/local/frame-state`, diagnostics, health/readiness/support paths, and `feed_synced` delivery evidence.

## Backend follow-up

Hosted stream generation should keep emitting cadence hints from durable `aos_` stream policy rows. Staging should watch for `feed_stale` health issues and repeated `lastFeedPollStatus=error` before physical Pi validation, because those now mean the appliance is trying to obey polling policy but cannot reach or accept the hosted stream.
