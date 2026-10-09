#!/bin/bash
# Release to the running site, from your machine.
#
#   ./deploy.sh <app ref> [<deploy ref>]
#
#   ./deploy.sh main                 # brain-freeze's main, and this repo's HEAD
#   ./deploy.sh v1.2.0 main          # a tag of the app, this repo's main
#
# <app ref> is a branch, tag or commit of brain-freeze. <deploy ref> is one of
# this repository, and defaults to the commit checked out here, which must
# already be pushed: the VM fetches both refs from their repositories itself.
#
# On the VM, node/bin/release moves both checkouts on the data disk, loads
# the app's code into the database, and restarts the app instances one at a
# time, each drained first. The site stays up.
#
# Needs gcloud, logged in, with IAP access to the project, and the Terraform
# state this repository's terraform/ was applied from (for which VM, where).

set -euo pipefail
APP_REF="${1:?usage: ./deploy.sh <app ref> [<deploy ref>]}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -n "${2:-}" ]; then
    DEPLOY_REF="$2"
else
    DEPLOY_REF="$(git -C "$HERE" rev-parse HEAD)"
    if [ -z "$(git -C "$HERE" branch -r --contains "$DEPLOY_REF" 2>/dev/null)" ]; then
        echo "This repository's HEAD ($DEPLOY_REF) is not on any pushed branch." >&2
        echo "Push it, or name a pushed ref: ./deploy.sh $APP_REF <deploy ref>" >&2
        exit 1
    fi
fi

out() { terraform -chdir="$HERE/terraform" output -raw "$1"; }
PROJECT="$(out project_id)"
ZONE="$(out active_zone)"
GROUP="$(out active_group)"

VM="$(gcloud compute instance-groups managed list-instances "$GROUP" \
        --project "$PROJECT" --zone "$ZONE" --format='value(instance.basename())' \
        | head -1)"
[ -n "$VM" ] || { echo "no VM in $GROUP ($ZONE)" >&2; exit 1; }

echo "Releasing brain-freeze $APP_REF and brain-freeze-deploy $DEPLOY_REF to $VM ($ZONE)"
gcloud compute ssh "$VM" --project "$PROJECT" --zone "$ZONE" --tunnel-through-iap \
    --command "sudo /var/lib/brainfreeze/deploy/node/bin/release '$APP_REF' '$DEPLOY_REF'"
