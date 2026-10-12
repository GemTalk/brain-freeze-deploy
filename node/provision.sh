#!/bin/bash
# Make this VM serve Brain Freeze from the data disk startup.sh mounted.
#
#   sudo /var/lib/brainfreeze/deploy/node/provision.sh            # at boot
#   sudo /var/lib/brainfreeze/deploy/node/provision.sh --restart  # a release
#
# Run as root, by startup.sh on every boot and by bin/release on a deploy.
# Safe to run again: each step checks before it acts.
#
#   1. the packages the machine needs, resvg, and the monitoring agent;
#   2. GemDB, set up the way a reader sets it up -- GemDB Code's own setup,
#      headless, as brain-freeze's CI runs it (its ci/setup-gemdb/run.js) --
#      but only on a disk that has never had it;
#   3. the settings everything else reads, in /etc/brainfreeze/;
#   4. systemd units, the HAProxy configuration, the agent's configuration;
#   5. the database started, the app checkout's code loaded into it, and
#      the book seeded if, and only if, there is no book;
#   6. the app instances started one at a time (--restart: restarted one at
#      a time, each drained first), then HAProxy, then the timers.

set -euo pipefail

# This repository's node/, in the checkout on the data disk; the app is the
# brain-freeze checkout beside it.
HERE="$(cd "$(dirname "$0")" && pwd)"
MOUNT=/var/lib/brainfreeze
ROOT="$MOUNT/GemDB"
APP="$MOUNT/app"
DEPLOY="$MOUNT/deploy"
SERVICE_USER=brainfreeze
CONF=/etc/brainfreeze

say() { echo "brainfreeze-provision: $*"; }

metadata() {
    curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

INSTANCES="$(metadata bf-instances)"
GEMDB_VERSION="$(metadata bf-gemdb-version)"
NODE_VERSION="$(metadata bf-node-version)"
BUCKET="$(metadata bf-bucket)"
PAGE_CACHE_MB="$(metadata bf-page-cache-mb || true)"
DOMAIN="$(metadata bf-domain || true)"

case "$(uname -m)" in
    x86_64) GEMDB_PLATFORM=linux-x64; NODE_PLATFORM=linux-x64 ;;
    aarch64) GEMDB_PLATFORM=linux-arm64; NODE_PLATFORM=linux-arm64 ;;
    *) say "GemDB does not run on $(uname -m)"; exit 1 ;;
esac

as_service() { sudo -u "$SERVICE_USER" -H "$@"; }

# -- 1. packages ----------------------------------------------------------------

if ! command -v haproxy >/dev/null || ! command -v socat >/dev/null; then
    apt-get update -q
    # lsof: serving.py's preflight names whatever holds a port with it.
    apt-get install -y -q haproxy socat lsof unzip curl git
fi
# resvg draws the app's ID card PNG, the picture a shared card link shows as
# its preview (brain-freeze's web/cards.py). Ubuntu 24.04 doesn't package
# it, so this is the project's own release binary, pinned by version and
# checksum, in /usr/local/bin, which is on the app's PATH. There is no Linux
# arm64 release: on arm64 the card's PNG answers 503 and shared links show no
# picture, until resvg is built and installed by hand (cargo install resvg).
RESVG_VERSION=0.48.1
RESVG_SHA256=fa8c26495a187e592c501db15bf9e8a9fdc051d4b2b336b39703d5b59f912b9d
if [ "$(/usr/local/bin/resvg --version 2>/dev/null)" != "$RESVG_VERSION" ]; then
    if [ "$(uname -m)" = x86_64 ]; then
        curl -sSfLo /tmp/resvg.tar.gz \
            "https://github.com/linebender/resvg/releases/download/v$RESVG_VERSION/resvg-linux-x86_64.tar.gz"
        echo "$RESVG_SHA256  /tmp/resvg.tar.gz" | sha256sum -c --quiet
        tar -xzf /tmp/resvg.tar.gz -C /usr/local/bin resvg
        chmod 755 /usr/local/bin/resvg
        rm -f /tmp/resvg.tar.gz
    else
        say "no resvg release for $(uname -m): ID cards will have no link preview"
    fi
fi
if [ ! -d /etc/google-cloud-ops-agent ]; then
    curl -sSfo /tmp/add-ops-agent.sh \
        https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash /tmp/add-ops-agent.sh --also-install
fi

# The database lives in shared memory owned by the service account, and
# systemd removes a user's shared memory when that user's last login ends --
# someone running `sudo -iu brainfreeze` and logging out would take the
# database down. GemDB's own script turns that off.
if [ ! -f /etc/systemd/logind.conf.d/gemdb.conf ]; then
    mkdir -p /etc/systemd/logind.conf.d
    printf '[Login]\nRemoveIPC=no\n' > /etc/systemd/logind.conf.d/gemdb.conf
    systemctl restart systemd-logind
fi

# -- 2. GemDB, once per disk ------------------------------------------------------

if [ ! -x "$ROOT/bin/gemdb" ] || [ ! -f "$ROOT/db/data/extent0.dbf" ]; then
    say "setting GemDB Code $GEMDB_VERSION up on the data disk (first boot: 10-20 minutes)"
    work="$(mktemp -d)"
    vsix="$work/gemdb-$GEMDB_PLATFORM-$GEMDB_VERSION.vsix"
    curl -sSfL -o "$vsix" \
        "https://github.com/GemTalk/GemDB_Code/releases/download/v$GEMDB_VERSION/gemdb-$GEMDB_PLATFORM-$GEMDB_VERSION.vsix"
    # What GemDB's setup would ask for with sudo, run first so it asks
    # nothing: raise shared memory, if this kernel's limit is low.
    unzip -p "$vsix" extension/resources/setSharedMemoryLinux.sh > "$work/shm.sh"
    bash "$work/shm.sh"

    # GemDB Code's setup is Node, normally VS Code's own. A pinned Node,
    # used for this and removed after.
    node_dist="node-v$NODE_VERSION-$NODE_PLATFORM"
    curl -sSfL -o "$work/node.tar.xz" \
        "https://nodejs.org/dist/v$NODE_VERSION/$node_dist.tar.xz"
    curl -sSfL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" \
        | grep " $node_dist.tar.xz\$" | sed "s|$node_dist.tar.xz|$work/node.tar.xz|" \
        | sha256sum -c -
    tar -xJf "$work/node.tar.xz" -C "$work"
    chown -R "$SERVICE_USER:" "$work"

    as_service env HOME="$MOUNT" PATH="$work/$node_dist/bin:/usr/bin:/bin" \
        node "$APP/ci/setup-gemdb/run.js" "$vsix"
    rm -rf "$work"

    # Setup leaves the database running, started by GemDB Code. Stop it, so
    # that from here on systemd is what runs it (gemdb.service).
    as_service "$HERE/bin/gemdb-ctl" stop || true
    first_setup=yes
fi

# -- 3. settings ---------------------------------------------------------------------

GEMSTONE="$(printf '%s\n' "$ROOT"/GemStone64Bit* | sort -V | tail -1)"
mkdir -p "$CONF"
# What GemDB Code puts in the environment of the stone and NetLDI it starts
# (its `tp()`), so this database runs exactly as it would under the editor.
cat > "$CONF/gemdb.env" <<ENV
GEMSTONE=$GEMSTONE
GEMSTONE_GLOBAL_DIR=$ROOT
GEMSTONE_SYS_CONF=$ROOT/db/conf
GEMSTONE_EXE_CONF=$ROOT/db/conf
GEMSTONE_LOG=$ROOT/db/log/gemdb.log
GEMSTONE_NRS_ALL=#netldi:gemdbldi#dir:$ROOT/db#log:$ROOT/db/log/%N_%P.log
GRAIL_DIR=$ROOT/grail
PYTHON_PACKAGE_PATH=$ROOT/grail/src/python
SHIM_LIB_PATH=$ROOT/grail/src/c/shim/libcpython_ua.so
LD_LIBRARY_PATH=$GEMSTONE/lib
PATH=$ROOT/bin:$GEMSTONE/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin
ENV
cat > "$CONF/node.env" <<ENV
INSTANCES=$INSTANCES
BASE_PORT=5051
BUCKET=$BUCKET
ROOT=$ROOT
APP=$APP
DEPLOY=$DEPLOY
BRAINFREEZE_CARD_CACHE=/var/cache/brainfreeze/cards
ENV
# The site's address, for the absolute URLs in the card page's link-preview
# tags: behind the load balancer and HAProxy the app can't see it. A VM from
# a template older than bf-domain goes without, and the tags name the host
# the request came to, over http.
if [ -n "$DOMAIN" ]; then
    echo "BRAINFREEZE_PUBLIC_URL=https://$DOMAIN" >> "$CONF/node.env"
fi

# The app's ID card PNGs (web/cards.py): drawn once each and shared by every
# instance. On the boot disk, because any of them can be drawn again; files
# nobody has asked for in 30 days are removed by systemd-tmpfiles' daily
# clean, so made-up names can't fill the disk.
printf 'd /var/cache/brainfreeze/cards 0750 %s %s 30d\n' "$SERVICE_USER" "$SERVICE_USER" \
    > /etc/tmpfiles.d/brainfreeze-cards.conf
systemd-tmpfiles --create /etc/tmpfiles.d/brainfreeze-cards.conf

# The stone's page cache, if the deployment sets one. GemDB Code writes
# 100 MB; the free license allows more, and a server has the memory.
if [ -n "$PAGE_CACHE_MB" ]; then
    sed -i "s/^SHR_PAGE_CACHE_SIZE_KB = .*/SHR_PAGE_CACHE_SIZE_KB = $((PAGE_CACHE_MB * 1000));/" \
        "$ROOT/db/conf/gemdb.conf"
fi

# -- 4. units and configuration --------------------------------------------------------

install -m 644 "$HERE"/systemd/*.service "$HERE"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload

"$HERE/bin/haproxy-config" "$INSTANCES" > /etc/haproxy/haproxy.cfg.new
haproxy -c -q -f /etc/haproxy/haproxy.cfg.new
mv /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg

install -m 644 "$HERE/ops-agent.yaml" /etc/google-cloud-ops-agent/config.yaml
systemctl restart google-cloud-ops-agent

# -- 5. the database, its code, its book -------------------------------------------------

systemctl start gemdb.service
cd "$APP"
# Load this checkout into the database. Retried: a running instance can
# commit the same compiled code first, and losing that race is harmless.
for try in 1 2 3; do
    if as_service "$ROOT/bin/gemdb" tools/load.py; then break; fi
    [ "$try" = 3 ] && { say "tools/load.py failed three times"; exit 1; }
    sleep 5
done
# Seed only an empty database. tools/seed.py REPLACES the book, so on a
# database with customers in it this would be the one irreversible mistake.
set +e
as_service "$ROOT/bin/gemdb" -c \
    'import gemdb, sys; sys.exit(0 if "brainfreeze" in gemdb.root else 3)'
has_book=$?
set -e
if [ "$has_book" = 3 ]; then
    say "no book in the database: seeding it"
    as_service "$ROOT/bin/gemdb" tools/seed.py
elif [ "$has_book" != 0 ]; then
    say "could not ask the database whether it has a book"; exit 1
fi

# -- 6. serving ------------------------------------------------------------------------------

if [ "${1:-}" = "--restart" ]; then
    "$HERE/bin/instances" restart
else
    "$HERE/bin/instances" start
fi
systemctl enable haproxy
systemctl reload-or-restart haproxy
systemctl enable --now brainfreeze-backup.timer brainfreeze-gc.timer \
    brainfreeze-watchdog.timer
# What bin/watchdog waits for. In /run, so it is gone on the next boot until
# this has run again.
mkdir -p /run/brainfreeze && touch /run/brainfreeze/provisioned
# A new database is backed up at once rather than at 03:30: there is
# something to restore from today, and the no-backup alert has a backup to
# count from (terraform/monitoring.tf).
if [ -n "${first_setup:-}" ]; then
    systemctl start --no-block brainfreeze-backup.service
fi
say "serving $INSTANCES instances"
