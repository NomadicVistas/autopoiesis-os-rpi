# Rolling Log

## 2026-06-05

- Created program directory inside the OS repo for migration-safe project management.
- Added program tag autopoiesis_os_frames, database namespace aos, and table prefix aos_.
- Created seven active aos-* OpenClaw cron jobs using gpt-5.4 with high thinking and Telegram summaries.
- Next phase started: MVP 0.1 online/backend API foundation added in the main Autopoiesis Flask app. The API now has a real aos_ SQLite-backed path for registration, pairing, settings, heartbeat, feed scaffold, command queue, likes, and admin device views.
- Device-side API wiring added: local setup now attempts online registration for pairing codes, can poll pairing status, syncs settings, sends heartbeat, and stores queued commands. Pairing still falls back to local mock mode if the backend is unreachable.
- Online control surfaces added in the main Autopoiesis frontend: /profile/frames for subscriber/device pairing and stream preferences, and /admin/frames for fleet monitoring, heartbeat review, and queued commands. Verified by frontend production build.
- Online admin operations extended: broadcasts can be created and queued to devices, releases can be recorded and queued as update commands, subscribers can be listed/updated, and devices can query the latest published release for their update channel.
- Delivery/rollout tracking added in the online app: broadcasts and releases now create per-device tracking rows, command acknowledgements update them, heartbeat version reports can complete rollout rows, and user preference saves cascade to paired devices through sync_settings commands.
- Pi-side command/release executor added: local UI can process remote commands, execute sync_settings/clear_cache/restart_display/update_device/enable-disable/show_broadcast, acknowledge commands back to the Frames API, check/apply latest releases, and run every 2 minutes through a systemd timer.
- Auth hardening added: the online API now issues per-device API keys, protects registered device endpoints, and can token-gate Admin Frames with AUTOPOIESIS_FRAMES_ADMIN_TOKEN. The Pi stores the device key, sends it on remote calls, and redacts it from local status JSON.
