-- Add disabled column to aos_frame_devices for device fleet management.
-- Allows admin to remotely disable a device (blocking all remote actions except enable_device).

ALTER TABLE aos_frame_devices ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0;
