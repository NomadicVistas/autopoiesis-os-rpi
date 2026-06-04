# Autopoiesis OS Brief Summary

Mission: build a Raspberry Pi display appliance that boots into a fullscreen touchscreen experience for `https://autopoiesis.art/frames`.

The system should support:

- first-run setup
- Wi-Fi onboarding
- device pairing
- local/cloud preferences
- fullscreen artwork stream
- images, video, sound, browser-based artworks
- local fallback cache
- remote disable
- GitHub updates
- production cleanup without Codex

Priority:

```txt
boot -> setup -> wifi -> config -> kiosk -> pairing -> sync -> cache -> updates -> disable -> cleanup
```

First task:

Create repository structure, installer skeleton, local config files, systemd service templates, and documentation. Do not assume the final API exists. Use mock endpoints and clear API contracts.
