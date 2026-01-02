#!/bin/bash

# Annotate recently built image with labels about the content of the image

set -e

docker=${docker:-docker}
TMPDIR=${TMPDIR:-/tmp}/freeipa-image-$$
mkdir -p $TMPDIR

IMAGE_FILE="$1"
DOCKERFILE="$2"
TAG="$3"
GITTREE="$4"
REPO_URL="$5"
JOB_PATH="$6"

COMMIT=$( git rev-parse HEAD )
test -n "$COMMIT"
FROM=$( awk '/^FROM / { print $2 ; exit }' "$DOCKERFILE" )
test -n "$FROM"
CREATED="$( date --utc --rfc-3339=seconds )"

# Sadly we cannot --filter specific image because in that case docker
# does not show the digest
BASE_DIGEST=$( $docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' | awk -v image="$FROM" '$1 == image { print $2 }' )
if [ -z "$BASE_DIGEST" ] ; then
	# Since docker images strips the docker.io/ prefix, try again without it
	BASE_DIGEST=$( $docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' | awk -v image="${FROM#docker.io/}" '$1 == image { print $2 }' )
fi
if [ -z "$BASE_DIGEST" ] ; then
	# When FROM does not specify a tag, try again with :latest
	BASE_DIGEST=$( $docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' | awk -v image="$FROM:latest" '$1 == image { print $2 }' )
fi
if [ -z "$BASE_DIGEST" ] ; then
	# When FROM does not specify a tag, try again with :latest
	BASE_DIGEST=$( $docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' | awk -v image="${FROM#docker.io/}:latest" '$1 == image { print $2 }' )
fi
test -n "$BASE_DIGEST"

IPA_VERSION=$( $docker run --rm --entrypoint rpm "$TAG" -qf --qf '%{version}\n' /usr/sbin/ipa-server-install /usr/bin/ipa-server-install | grep '^[1-9]' | head -1 )
test -n "$IPA_VERSION"
RPM_QA_SHA=$( $docker run --rm --entrypoint rpm "$TAG" -qa | LC_COLLATE=C sort | sha256sum | sed 's/ .*//' )
test -n "$RPM_QA_SHA"
if test -z "$GITTREE" ; then
	GITTREE=$( git write-tree )
fi
test -n "$GITTREE"


tar x -C $TMPDIR -f $IMAGE_FILE index.json manifest.json
OCI_MANIFEST=$( jq -r '.manifests[0].digest' $TMPDIR/index.json | sed 's%^sha256:%blobs/sha256/%' )
test -n "$OCI_MANIFEST"
tar x -C $TMPDIR -f $IMAGE_FILE $OCI_MANIFEST
OCI_CONFIG=$( jq -r '.config.digest' $TMPDIR/$OCI_MANIFEST | sed 's%^sha256:%blobs/sha256/%' )
test -n "$OCI_CONFIG"

DOCKER_CONFIG=$( jq -r '.[0].Config' $TMPDIR/manifest.json )
test -n "$DOCKER_CONFIG"

test "$OCI_CONFIG" = "$DOCKER_CONFIG"

tar x -C $TMPDIR -f $IMAGE_FILE $OCI_CONFIG
jq --arg CREATED "$CREATED" \
	--arg COMMIT "$COMMIT" \
	--arg VERSION "$IPA_VERSION-rpms-$RPM_QA_SHA-gittree-$GITTREE" \
	--arg FROM "$FROM" --arg BASE_DIGEST "$BASE_DIGEST" \
	--arg REPO_URL "$REPO_URL" \
	--arg SOURCE_URL "$REPO_URL/blob/$COMMIT/$DOCKERFILE" \
	--arg JOB_URL "$REPO_URL/$JOB_PATH" \
	-f /dev/stdin <<'EOS' $TMPDIR/$OCI_CONFIG > $TMPDIR/oci-config
	.config.Labels = {
		"org.opencontainers.image.created": $CREATED,
		"org.opencontainers.image.authors": .config.Labels["org.opencontainers.image.authors"],
		"org.opencontainers.image.url": $JOB_URL,
		"org.opencontainers.image.documentation": $REPO_URL,
		"org.opencontainers.image.source": $SOURCE_URL,
		"org.opencontainers.image.version": $VERSION,
		"org.opencontainers.image.revision": $COMMIT,
		"org.opencontainers.image.licenses": "Apache-2.0",
		"org.opencontainers.image.title": .config.Labels["org.opencontainers.image.title"],
		"org.opencontainers.image.base.digest": $BASE_DIGEST,
		"org.opencontainers.image.base.name": $FROM
	}
EOS
CONFIG_SHA=$( sha256sum $TMPDIR/oci-config | sed 's/ .*//' )
CONFIG_SIZE=$( wc -c < $TMPDIR/oci-config )
mv -v $TMPDIR/oci-config $TMPDIR/blobs/sha256/$CONFIG_SHA

jq --arg SHA $CONFIG_SHA --argjson SIZE $CONFIG_SIZE \
	'.config.digest = "sha256:" + $SHA | .config.size = $SIZE' $TMPDIR/$OCI_MANIFEST > $TMPDIR/oci-manifest
OCI_MANIFEST_SHA=$( sha256sum $TMPDIR/oci-manifest | sed 's/ .*//' )
OCI_MANIFEST_SIZE=$( wc -c < $TMPDIR/oci-manifest )
mv -v $TMPDIR/oci-manifest $TMPDIR/blobs/sha256/$OCI_MANIFEST_SHA

jq --arg SHA $OCI_MANIFEST_SHA --argjson SIZE $OCI_MANIFEST_SIZE -f /dev/stdin <<'EOS' $TMPDIR/index.json > $TMPDIR/index.json.new
	.manifests[0].digest = "sha256:" + $SHA
	| .manifests[0].size = $SIZE
	| .manifests[0].annotations["org.opencontainers.image.ref.name"] = .manifests[0].annotations["io.containerd.image.name"]
EOS
mv -v $TMPDIR/index.json.new $TMPDIR/index.json

jq --arg SHA $CONFIG_SHA '.[0].Config = "blobs/sha256/" + $ARGS.named["SHA"]' $TMPDIR/manifest.json > $TMPDIR/manifest.json.new
mv -v $TMPDIR/manifest.json.new $TMPDIR/manifest.json

tar r -C $TMPDIR -vf $IMAGE_FILE blobs/sha256/$CONFIG_SHA blobs/sha256/$OCI_MANIFEST_SHA index.json manifest.json

