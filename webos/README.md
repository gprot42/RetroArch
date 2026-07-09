## Building
```sh
# Needs webosbrew native toolchain + gmake (GNU make 4.x) on macOS
source ~/toolchains/arm-webos-linux-gnueabi_sdk-buildroot/environment-setup
export CC="$HOME/toolchains/arm-webos-linux-gnueabi_sdk-buildroot/bin/arm-webos-linux-gnueabi-gcc"
export CXX="$HOME/toolchains/arm-webos-linux-gnueabi_sdk-buildroot/bin/arm-webos-linux-gnueabi-g++"
export STRIP="$HOME/toolchains/arm-webos-linux-gnueabi_sdk-buildroot/bin/arm-webos-linux-gnueabi-strip"
gmake -f Makefile.webos -j$(getconf _NPROCESSORS_ONLN) ipk
```

## Deploy to TV (rooted / webosbrew)

Plain file copy / bare `opkg` leave files on disk but **SAM never lists the app**, so it
never appears on the dock. `ares-install` is also broken on Node 25+.

Use the deploy script — it installs through `com.webos.appInstallService` (same
mechanism as Homebrew Channel / ares):

```sh
# Deploy newest webos/*.ipk (default host 192.168.0.79, key ~/.ssh/webos_deploy)
./webos/deploy.sh

# Build then deploy
./webos/deploy.sh --build

# Custom device
WEBOS_HOST=192.168.0.50 WEBOS_SSH_KEY=~/.ssh/webos_deploy ./webos/deploy.sh

# Reboot TV after install
./webos/deploy.sh --reboot
```

**Where to look on the TV:** Home → full **Apps** grid (the bottom dock only shows
a short pinned list). RetroArch title is “RetroArch”.

## Testing
```sh
# Install and launch via ares (when CLI works)
make -f Makefile.webos launch

# Start installed application via SSH (often no GPU/display over SSH)
XDG_RUNTIME_DIR=/tmp/xdg /usr/bin/jailer -t native_devmode -i com.retroarch.webos -p /media/developer/apps/usr/palm/applications/com.retroarch.webos /media/developer/apps/usr/palm/applications/com.retroarch.webos/retroarch --verbose --verbose
```
