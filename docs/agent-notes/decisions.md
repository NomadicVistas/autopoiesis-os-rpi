# Decisions

## 2026-06-05

- Program tag is autopoiesis_os_frames.
- Database namespace is aos.
- Recommended table prefix is aos_.
- Raspberry Pi remains the first target; desktop, phone, tablet, and other devices come later.
- Online Autopoiesis app is the source of truth.
- Devices can cache and queue offline changes, but server state wins on sync.
- Phase 1 broadcasts use polling, not websockets.
- Production updates must preserve local config and support rollback.

