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

## Network

```bash
/opt/autopoiesis-os/app/scripts/network-status.sh
nmcli device status
nmcli networking connectivity
```

## LAN

```bash
sudo /opt/autopoiesis-os/app/scripts/connect-lan.sh
nmcli device show eth0
```

If the Ethernet device is not `eth0`, read the device name from `network-status.sh` and pass it explicitly:

```bash
sudo /opt/autopoiesis-os/app/scripts/connect-lan.sh enp1s0
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
