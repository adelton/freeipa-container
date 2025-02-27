#!/bin/bash

set -e
set -x

if ! [ -f /sys/fs/cgroup/cgroup.controllers ] ; then
	echo "We expect to only run on cgroups v2 systems." >&2
	exit 1
fi

# https://cri-o.io/
KUBERNETES_VERSION=v1.32
CRIO_VERSION=v1.32

sudo apt update
sudo apt install -y software-properties-common curl

curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key \
	| gpg --dearmor | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" \
	| sudo tee /etc/apt/sources.list.d/kubernetes.list

curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key \
	| gpg --dearmor | sudo tee /etc/apt/keyrings/cri-o-apt-keyring.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" \
	| sudo tee /etc/apt/sources.list.d/cri-o.list

sudo apt update
sudo apt install -y cri-o kubelet kubeadm kubectl

sudo cp /etc/cni/net.d/10-crio-bridge.conflist.disabled /etc/cni/net.d/10-crio-bridge.conflist
sudo systemctl start crio.service

sudo swapoff -a
sudo modprobe br_netfilter
sudo sysctl -w net.ipv4.ip_forward=1
sudo sudo iptables -A FORWARD -o cni0 -j ACCEPT

if ! sudo kubeadm init --config tests/k8s-userns-config.yaml ; then
	set +e
	sudo systemctl status kubelet
	sudo journalctl -xeu kubelet
	exit 1
fi

mkdir ~/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $( id -u ):$( id -g ) ~/.kube/config
( set +x ; while true ; do if kubectl get nodes | tee /dev/stderr | grep -q '\bReady\b' ; then break ; else sleep 5 ; fi ; done )

kubectl taint nodes $( hostname ) node-role.kubernetes.io/control-plane:NoSchedule-
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

if [ -n "$2" ] ; then
	sudo skopeo copy docker-archive:$2 containers-storage:$1
fi
kubectl get pods --all-namespaces
( set +x ; while ! kubectl get serviceaccount/default ; do sleep 5 ; done )

sudo resolvectl dns cni0 $( kubectl get -n kube-system service/kube-dns -o 'jsonpath={.spec.clusterIP}' )
sudo resolvectl domain cni0 cluster.local

# Remove the extremely permissive ACLs / mask that GitHub runners have on /opt
sudo mkdir /opt/local-path-provisioner
sudo setfacl -b /opt/local-path-provisioner

kubectl create -f <( sed "s#image:.*#image: $1#" tests/freeipa-k3s.yaml )
( set +x ; while kubectl get pod/freeipa-server | tee /dev/stderr | grep -Eq '\bPending\b|\bContainerCreating\b' ; do sleep 5 ; done )
if ! kubectl get pod/freeipa-server | grep -q '\bRunning\b' ; then
	kubectl describe pod/freeipa-server
	kubectl logs pod/freeipa-server
	exit 1
fi
( set +x ; for i in $( seq 1 10 ) ; do kubectl logs pod/freeipa-server > /dev/null && break ; sleep 3 ; done )
kubectl logs -f pod/freeipa-server &
MASTER_LOGS_PID=$!
trap "kill $MASTER_LOGS_PID 2> /dev/null || : ; trap - EXIT" EXIT
( set +x ; while true ; do if kubectl get pod/freeipa-server | grep -q '\b1/1\b' ; then kill $MASTER_LOGS_PID ; break ; else sleep 5 ; fi ; done )
kubectl describe pod/freeipa-server
kubectl exec freeipa-server -- cat /proc/1/uid_map | tee /dev/stderr | grep -q '^ *0 *[1-9]'
PV_DIR=$( kubectl get pvc/freeipa-data-pvc -o 'jsonpath={.spec.volumeName}_{.metadata.namespace}_{.metadata.name}' )
ls -la /opt/local-path-provisioner/$PV_DIR
IPA_SERVER_HOSTNAME=$( kubectl exec pod/freeipa-server -- hostname -f )
curl -Lk https://$IPA_SERVER_HOSTNAME/ | grep -E 'IPA: Identity Policy Audit|Identity Management'
curl -H "Referer: https://$IPA_SERVER_HOSTNAME/ipa/ui/" -H 'Accept-Language: fr' -d '{"method":"i18n_messages","params":[[],{}]}' -k https://$IPA_SERVER_HOSTNAME/ipa/i18n_messages | grep -q utilisateur
echo Secret123 | kubectl exec -i pod/freeipa-server -- kinit admin

IPA_SERVER_IP=$( kubectl get -o=jsonpath='{.spec.clusterIP}' service freeipa-server-service )
seq 15 -1 0 | while read i ; do dig +short $IPA_SERVER_HOSTNAME | tee /dev/stderr | grep -Fq $IPA_SERVER_IP && break ; sleep 5 ; [ $i == 0 ] && false ; done
seq 15 -1 0 | while read i ; do dig +short -t srv _ldap._tcp.${IPA_SERVER_HOSTNAME#*.} | tee /dev/stderr | grep -Fq "0 100 389 $IPA_SERVER_HOSTNAME." && break ; sleep 5 ; [ $i == 0 ] && false ; done

kill $MASTER_LOGS_PID 2> /dev/null || :
trap - EXIT

kubectl create -f <( sed "s#image:.*#image: $1#" tests/freeipa-replica-k3s.yaml )
( set +x ; while kubectl get pod/freeipa-replica | tee /dev/stderr | grep -Eq '\bPending\b|\bContainerCreating\b' ; do sleep 5 ; done )
if ! kubectl get pod/freeipa-replica | grep -q '\bRunning\b' ; then
	kubectl describe pod/freeipa-replica
	kubectl logs pod/freeipa-replica
	exit 1
fi
( set +x ; for i in $( seq 1 10 ) ; do kubectl logs pod/freeipa-replica > /dev/null && break ; sleep 3 ; done )
kubectl logs -f pod/freeipa-replica &
REPLICA_LOGS_PID=$!
trap "kill $REPLICA_LOGS_PID 2> /dev/null || : ; trap - EXIT" EXIT
( set +x ; while true ; do if kubectl get pod/freeipa-replica | grep -q '\b1/1\b' ; then kill $REPLICA_LOGS_PID ; break ; else sleep 5 ; fi ; done )
kubectl describe pod/freeipa-replica
kubectl exec freeipa-replica -- cat /proc/1/uid_map | tee /dev/stderr | grep -q '^ *0 *[1-9]'
PV_DIR=$( kubectl get pvc/freeipa-replica-pvc -o 'jsonpath={.spec.volumeName}_{.metadata.namespace}_{.metadata.name}' )
ls -la /opt/local-path-provisioner/$PV_DIR
IPA_REPLICA_HOSTNAME=$( kubectl exec pod/freeipa-replica -- hostname -f )
curl -Lk https://$IPA_REPLICA_HOSTNAME/ | grep -E 'IPA: Identity Policy Audit|Identity Management'
curl -H "Referer: https://$IPA_REPLICA_HOSTNAME/ipa/ui/" -H 'Accept-Language: fr' -d '{"method":"i18n_messages","params":[[],{}]}' -k https://$IPA_REPLICA_HOSTNAME/ipa/i18n_messages | grep -q utilisateur
echo Secret123 | kubectl exec -i pod/freeipa-replica -- kinit admin
IPA_REPLICA_IP=$( kubectl get -o=jsonpath='{.spec.clusterIP}' service freeipa-replica-service )
dig +short $IPA_REPLICA_HOSTNAME | tee /dev/stderr | grep -Fq $IPA_REPLICA_IP
kill $REPLICA_LOGS_PID 2> /dev/null || :
trap - EXIT

echo OK $0.
