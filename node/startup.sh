#!/bin/bash
# The VM's startup script: runs as root on every boot, from instance metadata.
#
# The VM itself is disposable. Everything that has to survive it -- the
# database engine, the database, the checkouts of the app (brain-freeze) and
# of this repository (brain-freeze-deploy) -- is on one regional
# persistent disk, replicated across two zones, which this attaches and
# mounts. A VM that the instance group replaces (it failed its health check,
# or the template changed, or its zone went down) boots into this script,
# takes the disk over, and carries on from what was committed.
#
# What this does, in order:
#   1. attach the data disk (forcing it away from a dead VM if it must),
#   2. mount it at /var/lib/brainfreeze, formatting it only if it is blank,
#   3. on the very first boot, clone the app and this repository onto it,
#   4. hand over to node/provision.sh in this repository's checkout, which
#      does the rest and is safe to run again by hand.
#
# Settings come from instance metadata (terraform/compute.tf), read
# below. Logs: `sudo journalctl -u google-startup-scripts`.

set -euo pipefail

# Ubuntu's GCE images ship gcloud as a snap, outside a startup script's PATH.
export PATH="$PATH:/snap/bin"

MOUNT=/var/lib/brainfreeze
DEVICE_NAME=gemdb-data
DEVICE=/dev/disk/by-id/google-$DEVICE_NAME
APP="$MOUNT/app"
DEPLOY="$MOUNT/deploy"
SERVICE_USER=brainfreeze
SERVICE_UID=2000

say() { echo "brainfreeze-startup: $*"; }

metadata() {
    curl -sf -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/$1"
}
attribute() { metadata "instance/attributes/$1"; }

NAME="$(metadata instance/name)"
ZONE="$(metadata instance/zone | awk -F/ '{print $NF}')"
DISK="$(attribute bf-data-disk)"
APP_REPO="$(attribute bf-app-repo)"
APP_REF="$(attribute bf-app-ref)"
DEPLOY_REPO="$(attribute bf-deploy-repo)"
DEPLOY_REF="$(attribute bf-deploy-ref)"

# -- 1. the data disk ---------------------------------------------------------

attach() {
    gcloud compute instances attach-disk "$NAME" --zone "$ZONE" \
        --disk "$DISK" --disk-scope regional --device-name "$DEVICE_NAME" "$@"
}

REGION="${ZONE%-*}"
FORCE="$(attribute bf-force-attach || echo false)"

# Which VM holds the disk, and whether the API says it is running.
holder() {
    gcloud compute disks describe "$DISK" --region "$REGION" \
        --format='value(users[0])' 2>/dev/null || true
}
holder_status() {
    gcloud compute instances describe "$1" --format='value(status)' \
        2>/dev/null || echo UNREACHABLE
}

if [ ! -e "$DEVICE" ]; then
    # Normally the VM this one replaces is already deleted and the disk is
    # free. When it is not:
    #
    # - held by a VM that is not RUNNING (stopping, terminated, or its zone
    #   unreachable): take it with --force-attach. The old VM's writes then
    #   fail, and the database recovers here from its transaction logs, as
    #   after a crash.
    # - held by a VM the API says is RUNNING: wait, and say so every 30s.
    #   Taking it would crash a database that is serving, and that VM's
    #   autohealing would take it back. Only `force_attach = true` in
    #   Terraform overrides this -- for a zone outage, where the API can
    #   still report a dead VM as RUNNING.
    while ! attach 2>/tmp/attach.err; do
        held_by="$(holder)"
        if [ -n "$held_by" ]; then
            status="$(holder_status "$held_by")"
            if [ "$status" != RUNNING ] || [ "$FORCE" = true ]; then
                say "taking $DISK from ${held_by##*/} ($status, force_attach=$FORCE)"
                attach --force-attach && break
            else
                say "$DISK is in use by ${held_by##*/}, which is RUNNING. Waiting." \
                    "To take it anyway, set force_attach = true and apply."
            fi
        else
            # gcloud's error spans lines and ends with a blank one.
            say "could not attach $DISK yet: $(tr -s '\n' ' ' </tmp/attach.err)"
        fi
        sleep 30
    done
    for _ in $(seq 1 30); do [ -e "$DEVICE" ] && break; sleep 2; done
fi
[ -e "$DEVICE" ] || { say "no $DEVICE after attaching $DISK"; exit 1; }

# -- 2. mount it ---------------------------------------------------------------

# A fixed uid, so the files on the disk belong to the same account on every
# VM that mounts it.
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --uid "$SERVICE_UID" --home-dir "$MOUNT" --no-create-home \
        --shell /bin/bash "$SERVICE_USER"
fi

mkdir -p "$MOUNT"
if ! blkid "$DEVICE" >/dev/null 2>&1; then
    # blkid finds no filesystem only on a brand-new disk. Anything else --
    # a disk that will not mount, say -- stops here rather than formatting
    # over a database.
    say "formatting the new, blank data disk"
    mkfs.ext4 -q -L brainfreeze -m 0 "$DEVICE"
    fresh=yes
fi
if ! grep -q " $MOUNT " /etc/fstab; then
    # nofail and a short device timeout: at boot the disk is not attached
    # yet -- this script attaches it -- and boot must not wait for it.
    echo "$DEVICE $MOUNT ext4 defaults,discard,nofail,x-systemd.device-timeout=1s 0 2" >> /etc/fstab
fi
mountpoint -q "$MOUNT" || mount "$MOUNT"
if [ -n "${fresh:-}" ]; then
    chown "$SERVICE_USER:$SERVICE_USER" "$MOUNT"
    rmdir "$MOUNT/lost+found" 2>/dev/null || true
fi

# -- 3. the two checkouts, cloned once -----------------------------------------

# Only ever cloned here. After that each checkout moves only when someone
# releases (deploy.sh), so a replacement VM serves exactly the release that
# was serving before, and booting needs nothing from GitHub.
#
# A branch is checked out as origin/<branch>, as node/bin/release does: a
# bare branch name other than the default one has no local branch, and git
# refuses to guess one with --detach. Tags and commit ids fall through.
# Cloned beside DIR and moved into place only once at REF, so a clone that
# fails partway is not taken for a finished one on the next boot.
clone() {   # clone REPO REF DIR
    [ -d "$3/.git" ] && return 0
    command -v git >/dev/null || { apt-get update -q && apt-get install -y -q git; }
    say "cloning $1 at $2 into $3"
    rm -rf "$3.new"
    sudo -u "$SERVICE_USER" git clone --quiet "$1" "$3.new"
    sudo -u "$SERVICE_USER" git -C "$3.new" checkout --quiet --detach "origin/$2" 2>/dev/null \
        || sudo -u "$SERVICE_USER" git -C "$3.new" checkout --quiet --detach "$2"
    mv "$3.new" "$3"
}
clone "$APP_REPO" "$APP_REF" "$APP"
clone "$DEPLOY_REPO" "$DEPLOY_REF" "$DEPLOY"

# -- 4. the rest ----------------------------------------------------------------

exec "$DEPLOY/node/provision.sh"
