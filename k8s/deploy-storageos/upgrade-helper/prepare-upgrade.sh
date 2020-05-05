#!/bin/bash

LATEST_VERSION="storageos/node:1.5.3"
LATEST_OPERATOR_VERSION="storageos/cluster-operator:1.5.3"
LATEST_INIT="storageos/init:1.0.0"

PATCHED_FILES_LOC="/tmp/patched-tmp"
ONDELETE_PATCH="$PATCHED_FILES_LOC/ondelete.yaml"
INITCONTAINER_PATCH="$PATCHED_FILES_LOC/initimage.yaml"

print_green() {
    local msg="$1"
    GR='\033[0;32m'
    NC='\033[0m' # No Color

    echo -e "${GR}$msg${NC}"
}

print_red() {
    local msg="$1"
    RED='\033[0;31m'
    NC='\033[0m' # No Color

    echo -e "${RED}$msg${NC}"
}

verify_dependencies() {
    # JQ is a depenency to parse kubectl output
    which jq &>/dev/null
    if [ $? -ne 0 ]; then
        print_red "This script requires the use of 'jq' and it can't be found."
        exit 1
    fi

    # kubectl is a dependency to interact with the cluster
    which kubectl &>/dev/null
    if [ $? -ne 0 ]; then
        print_red "This script requires the use of 'kubectl' and it can't be found."
        exit 1
    fi

    print_green "Using the cluster: `kubectl config current-context`"
}

create_patches() {
    mkdir -p $PATCHED_FILES_LOC
    cat <<END > $ONDELETE_PATCH
spec:
  updateStrategy:
    type: OnDelete
END

    # The init container patch strategy set to merge on purpose, so it is
    # required to pass the whole API object to the patch command. Otherwise the
    # name of the init container can't be changed
    cat <<END > $INITCONTAINER_PATCH
spec:
  template:
    spec:
      initContainers:
      - name: storageos-init
        image: $LATEST_INIT
        env:
          - name: DAEMONSET_NAME
            value: storageos-daemonset
          - name: DAEMONSET_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
        imagePullPolicy: IfNotPresent
        resources: {}
        securityContext:
          capabilities:
            add:
            - SYS_ADMIN
          privileged: true
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
        volumeMounts:
        - mountPath: /lib/modules
          name: kernel-modules
          readOnly: true
        - mountPath: /sys
          mountPropagation: Bidirectional
          name: sys
        - mountPath: /var/lib/storageos
          mountPropagation: Bidirectional
          name: state
END
}

# check_operator_version Ensures that the StorageOS Cluster Operator is running
# the latest version
check_operator_version() {
    echo "Checking the StorageOS Cluster Operator version"
    local out="$(kubectl get pod --all-namespaces --no-headers -ocustom-columns=_:.metadata.name,_:.metadata.namespace | grep "storageos" | grep "operator")"

    local pod="$(echo $out | cut -d' ' -f1)"
    local ns="$(echo $out | cut -d' ' -f2)"

    if [ -z "$pod" ]; then
        echo "Couldn't find the StorageOS Cluster Operator Pod"
        exit 1
    fi

    local image="$(kubectl -n $ns get pod $pod -o go-template --template="{{range .spec.containers}}{{.image}} {{end}}")"
    if [ -z "$image" ]; then
        echo "Couldn't find the image of the Operator"
        exit 1
    fi

    current_version="$(echo $image | cut -d: -f2 | sed "s/\.//g")"
    last_version="$(echo $LATEST_OPERATOR_VERSION | cut -d: -f2 | cut -d'-' -f1 | sed "s/\.//g")"
    if [ $current_version -lt $last_version ]; then
        print_red "The Cluster Operator needs to be updated, follow the documentation to upgrade: https://docs.storageos.com/docs/reference/cluster-operator/upgrade"
        echo "The image $image is not the latest"
        exit 1
    fi

    print_green "Verified StorageOS Cluster Operator version $image"
}

# set_updatestrategy_ondelete Patches the StorageOS DaemonSet to ensure that no
# pods will be destroyed when the image of the containers changes. So only when
# the User deletes the Pods a new version of StorageOS will start.
set_updatestrategy_ondelete() {
    local ns="$1"

    # Ensure UpdateStrategy is on Delete
    echo "Setting the UpdateStrategy of the StorageOS DaemonSet to OnDelete"
    kubectl -n "$ns" patch ds/storageos-daemonset --patch "$(cat $ONDELETE_PATCH)"
}

# set_rbac_rules_for_initcontainer Creates the RBAC rules for the init
# container to communicate with the k8s API. New StorageOS installations have
# this RBAC rules created by the StorageOS Cluster Operator
set_rbac_rules_for_initcontainer() {
    local ns="$1"
    local sa="storageos-daemonset-sa"
    kubectl -n $ns apply -f- <<END
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: init-container
rules:
- apiGroups:
  - apps
  resources:
  - daemonsets
  verbs:
  - '*'
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: init-container
subjects:
- kind: ServiceAccount
  name: $sa
  namespace: $ns
roleRef:
  kind: ClusterRole
  name: init-container
  apiGroup: rbac.authorization.k8s.io
END
}

# set_new_images Patches the StorageOS DaemonSet to set the new initContainer
# and latest main container
set_new_images() {
    local pod="$1"
    local ns="$2"

    local image="$(kubectl -n $ns get pod $pod -o go-template --template="{{range .spec.containers}}{{.image}} {{end}}" -o go-template --template="{{range .spec.containers}}{{.image}} {{end}}" | egrep -o "storageos/node:([0-9].?){3}")"
    local init_img="$(kubectl -n $ns get pod $pod -o go-template --template="{{range .spec.initContainers}}{{.image}} {{end}}")"

    if [ -z "$image" ]; then
        echo "Couldn't find the StorageOS installed version"
        exit 1
    fi

    if [ "$image" != "$LATEST_VERSION" ]; then
        if [ "$init_img" != "$LATEST_INIT" ]; then
            echo "Current init container: $init_img"
            print_green "Setting the image for the init container to $LATEST_INIT"
            kubectl -n $ns patch ds/storageos-daemonset --type='merge' --patch "$(cat $INITCONTAINER_PATCH)"
        fi
        echo "Current StorageOS version: $image"
        print_green "Setting image for DaemonSet storageos-daemonset to $LATEST_VERSION"
        kubectl -n $ns set image ds/storageos-daemonset storageos=$LATEST_VERSION
    fi
}

# list_pods_using_storageos_volumes Outputs the Pods using StorageOS PVCs
list_pods_using_storageos_volumes() {

    # Iterate over all the PVCs in the cluster that use the StorageOS
    # provisioner and print any existing Pod that uses any of these PVCs. In
    # practice, any Pod using a StorageOS volume
    counter=0
    while IFS= read -r line; do
        local ns=$(cut -f1  -d' ' <(echo $line))
        local pvc=$(cut -f2 -d' ' <(echo $line))

        list=$(kubectl -n $ns get pod -ojson | jq -M --arg PVC "$pvc" -r '.items[]
        | select(.spec.volumes[].persistentVolumeClaim.claimName != null)
        | select(.spec.volumes[].persistentVolumeClaim.claimName == $PVC)
        | { NameSpace: .metadata.namespace,  Pod: .metadata.name}')

        if [ ! -z "$list" ]; then
            echo "$list"
            ((counter++))
            list=''
        fi

    done < <(kubectl get pvc --all-namespaces -ojson \
        | jq -r '.items[]
        | select (.metadata.annotations."volume.beta.kubernetes.io/storage-provisioner"
        | test("storageos"))
        |  .metadata.namespace + " " + .metadata.name'
    )

    if [ $counter -eq 0 ]; then
        print_green "No StorageOS Volumes are in use, you can proceed"
    else
        print_red "The list above shows the Pods that are using StorageOS volumes."
        print_red "They need to be scaled to 0 or be restarted after StorageOS is running the newer version."
        print_red "Ensure that the StorageOS Pods are in READY state before you scale back up"
    fi
}

####### MAIN #########


verify_dependencies
create_patches

check_operator_version

# Find current StorageOS installed version
out=$(kubectl get pod --all-namespaces  -lapp=storageos,kind=daemonset --no-headers -ocustom-columns=_:.metadata.name,_:.metadata.namespace | head -1)

pod="$(cut -d' ' -f1 <(echo $out))"
ns="$(cut  -d' ' -f2 <(echo $out))"

if [ -z "$pod" ]; then
    echo "Couldn't find any StorageOS Pod"
    exit 1
fi

set_updatestrategy_ondelete $ns
set_rbac_rules_for_initcontainer $ns
set_new_images $pod $ns

list_pods_using_storageos_volumes

print_green "To complete the upgrade you must restart the StorageOS Pods on
each node. While the container is being restarted, volumes accessed from
application Pods on the node will be unavailable. We recommend that you put the
cluster in maintenance mode (link to docs) shutdown applications accessing
StorageOS volumes on the node, and then delete the StorageOS Pod. The DaemonSet
will restart the Pod using the updated version. Once all nodes have been
upgraded, disable maintenance mode."
print_green "It is safe to re-run this script."
print_green "To delete the StorageOS Pods, you can run: \"kubectl -n $ns delete pod -lapp=storageos,kind=daemonset\""
