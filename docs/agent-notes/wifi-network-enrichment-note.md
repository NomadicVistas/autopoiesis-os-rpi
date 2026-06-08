## 2026-06-08 - Wi-Fi connection detail enrichment for remote monitoring

Date/time: 2026-06-08 12:35 UTC / 2026-06-08 14:35 Europe/Berlin
Agent: Pulse
Context: RPI APPLIANCE cron pass. The hosted API and admin dashboard had no visibility into device network quality. The heartbeat diagnostics contained basic network state (online/offline, primary type) but no signal strength, SSID, or IP address. When a Frame stopped working remotely, the admin could see "wifi connected" but not whether the signal was weak or the device had changed networks.

What changed: Added `wifiConnectionDetailsFallback(callback)` to local-ui/server.js that queries the active Wi-Fi connection via `nmcli -t -f ACTIVE,SIGNAL,SSID,SECURITY,FREQ,RATE device wifi list --rescan no` plus IP address lookups. Returns ssid, signal, signalQuality (excellent/good/fair/weak using the existing `signalQuality()` function), securityType (using existing `classifySecurity()`), frequency, bitrate, ip4Address, ip6Address. Enriched `networkStatus()` to conditionally call this when `network.wifi.connected` is true. The enriched data is written to `network.json`, which flows through `status()` → `collectDiagnostics()` → `sendHeartbeat()` → hosted API heartbeat endpoint. Added 12-step 46-check validation gate.

What needs review: The `wifiConnectionDetailsFallback` function uses `--rescan no` to avoid triggering a Wi-Fi scan on every heartbeat (which would drain power and cause delays). This means the signal reading may be slightly stale if the device has moved, but for a stationary frame this is acceptable. The function uses nested callbacks (nmcli → IP4 → IP6) which could be refactored to Promise-based for clarity, but works correctly for the current callback-based architecture of networkStatus().

Next recommended action: On the Pi, verify network.json includes signal quality with real Wi-Fi hardware. Wire enriched network data into the admin dashboard device detail view (signal strength indicator, SSID display, IP address). Add network quality alerts: flag devices where signal drops to "weak". Add network change event tracking for long-term connectivity analysis.
