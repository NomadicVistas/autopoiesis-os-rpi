# Node.js Version Check in Installer

## 2026-06-23 10:35 AM Europe/Berlin - LEAD / RPI APPLIANCE - Node.js version check in installer

Agent: Pulse
Context: RPI APPLIANCE workstream - improving the robustness of the one-command install by validating Node.js early.
What changed: Added a check for Node.js presence and version (>=18) in the install.sh script before proceeding with installation. The check exits with a clear error message if Node.js is missing or too old.
Why this matters: The Autopoiesis OS appliance requires Node.js >=18 for the local UI server. Early detection avoids proceeding with installation only to fail later during bootstrap or runtime. Improves the robustness of the one-command install experience.
Verification: 
- node --check local-ui/server.js passed
- bash -n install.sh update.sh uninstall-dev-tools.sh factory-reset.sh scripts/*.sh passed
- Manual test: verifying the script exits with helpful message when Node.js is missing or too old (simulated by temporarily adjusting PATH or version output).
Next step: Monitor installer logs for any Node-related issues in the field.