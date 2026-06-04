# Troubleshooting

## Local UI

```bash
systemctl status autopoiesis-setup.service
journalctl -u autopoiesis-setup.service -n 100 --no-pager
```

## Kiosk

```bash
systemctl status autopoiesis-kiosk.service
journalctl -u autopoiesis-kiosk.service -n 100 --no-pager
```

## Wi-Fi

```bash
nmcli device wifi list
nmcli connection show
```

## Logs

```bash
ls -lah /var/log/autopoiesis-os
```
