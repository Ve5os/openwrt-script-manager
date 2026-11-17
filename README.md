# OpenWrt Script Manager v2

Standalone web panel for OpenWrt.

- URL: http://ROUTER_IP:9696
- Login with the OpenWrt/LuCI admin password.
- No LuCI application page is required.
- Backend is a small POSIX shell CGI-style HTTP server using BusyBox `httpd`.
- Scripts are stored in `/etc/openwrt-script-manager/scripts`.
- Cron is managed in `/etc/crontabs/root` inside a marked block.
- Existing unrelated cron entries are preserved.

## Install

Copy the archive to the router and run:

    mkdir -p /tmp/osm
    tar -xzf openwrt-script-manager-v2.tar.gz -C /tmp/osm
    sh /tmp/osm/install.sh

Or, after putting `install.sh` on the router:

    sh /tmp/install.sh

Then open:

    http://ROUTER_IP:9696

## Uninstall

    sh /usr/lib/openwrt-script-manager/uninstall.sh

The uninstall removes the service, web assets and only the Script Manager cron block.
User scripts/configuration are retained.

## Notes

This version is deliberately self-contained and does not require Python, Node.js, PHP,
or a LuCI extension.
