#!/bin/bash

set -e
# set -x

DIR=$( dirname $0 )

DOCKERFILE="$1"
if [ -z "$DOCKERFILE" ] ; then
	echo "Usage: $0 Dockerfile-to-process" >&2
	exit 1
fi

export docker=${docker:-docker}

function run_and_wait_for () {
	(
	set +x
	local IMAGE="$1"
	local NAME="$2"
	OPTS=
	if [ "${docker%podman}" = "$docker" ] ; then
		# if it is not podman, it is docker
		if [ -f /sys/fs/cgroup/cgroup.controllers ] ; then
			# we assume unified cgroup v2 and docker with userns remapping enabled
			OPTS="--tmpfs /run --tmpfs /tmp --sysctl net.ipv6.conf.all.disable_ipv6=0"
		else
			OPTS="--tmpfs /run --tmpfs /tmp -v /sys/fs/cgroup:/sys/fs/cgroup:ro --sysctl net.ipv6.conf.all.disable_ipv6=0"
		fi
	fi
	if [ -n "$seccomp" ] ; then
		OPTS="$OPTS --security-opt seccomp=$seccomp"
	fi
	( set -x ; $docker run --name $NAME -d -h ipa.example.test \
		$OPTS $IMAGE )
	for j in $( seq 1 30 ) ; do
		if $docker exec $NAME systemctl is-system-running --no-pager -l 2> /dev/null | grep -q -E 'running|degraded' ; then
			return
		fi
		if ! $docker ps | grep -q "\b$NAME$" ; then
			return
		fi
		sleep 2
	done
	)
}

SUFFIX=${DOCKERFILE#Dockerfile.}

END=$( wc -l < "$DOCKERFILE" )
START=1
while [ "$START" -lt "$END" ] ; do
	SED_TO_NEXT_TEST='1,/^# test:/{s/^# \(debug\|test-add\):\ *//;p}'
	if [ "$START" = '1' ] ; then
		echo "# This line is commented out to match line count" > "$DOCKERFILE.part"
		sed --posix -n "$SED_TO_NEXT_TEST" "$DOCKERFILE" >> "$DOCKERFILE.part"
	else
		echo "FROM localhost/freeipa-server-test:$SUFFIX" > "$DOCKERFILE.part"
		sed --posix -n "1,${START}{s/^/## /;p;d};$SED_TO_NEXT_TEST" "$DOCKERFILE" >> "$DOCKERFILE.part"
	fi

	TEST_SCRIPT=$( sed --posix '$s/^# test:\ *\([a-zA-Z0-9.-]*\)/\1 'freeipa-server-container-$SUFFIX'/;t;d' "$DOCKERFILE.part" )
	if [ -n "$TEST_SCRIPT" ] ; then
		$docker build -t "localhost/freeipa-server-test:$SUFFIX" -f "$DOCKERFILE.part" .
		echo "FROM localhost/freeipa-server-test:$SUFFIX" > "$DOCKERFILE.part.addons"
		sed --posix 's/# test-addon:\ *//;t;d' "$DOCKERFILE.part" >> "$DOCKERFILE.part.addons"
		$docker build -t "localhost/freeipa-server-test-addons:$SUFFIX" -f "$DOCKERFILE.part.addons" .
		$docker rm -f freeipa-server-container-$SUFFIX > /dev/null 2>&1 || :
		# Starting systemd container
		run_and_wait_for localhost/freeipa-server-test-addons:$SUFFIX freeipa-server-container-$SUFFIX
		echo Executing $DIR/$TEST_SCRIPT
		$DIR/$TEST_SCRIPT
	else
		break
	fi

	START=$( wc -l < "$DOCKERFILE.part" )
	START=$(( START - 1 ))
done

echo OK $0.

