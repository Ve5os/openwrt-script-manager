# OpenWrt Script Manager v2

Standalone web panel for OpenWrt.

- URL: http://ROUTER_IP:9696
- Login with the OpenWrt/LuCI admin password.
- No LuCI application page is required.
- Backend is a small POSIX shell CGI-style HTTP server using BusyBox `httpd`.
- Scripts are stored in `/etc/openwrt-script-manager/scripts`.
- Cron is managed in `/etc/crontabs/root` inside a marked block.
- Existing unrelated cron entries are preserved.

## Install from GitHub

After publishing this repository, installation is a single command:

    sh -c "$(wget -qO- https://raw.githubusercontent.com/OWNER/REPO/main/install.sh)"

The installer downloads the current project archive from GitHub, installs the service,
asks for the OpenWrt/LuCI admin password, enables the service and starts it.

You can also explicitly select a repository/branch:

    GITHUB_REPO=OWNER/REPO GITHUB_BRANCH=main sh -c "$(wget -qO- https://raw.githubusercontent.com/OWNER/REPO/main/install.sh)"

No files need to be manually copied to the router.

Then open:

    http://ROUTER_IP:9696

## Uninstall

    sh /usr/lib/openwrt-script-manager/uninstall.sh

The uninstall removes the service, web assets and only the Script Manager cron block.
User scripts/configuration are retained.

## Notes

This version is deliberately self-contained and does not require Python, Node.js, PHP,
or a LuCI extension.
