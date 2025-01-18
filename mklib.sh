#!/bin/sh

CDIR=$(pwd)

PRJ2HASH_EXE=

function check_prj2hash() {
    if [ -f "./prj2hash" ]; then
        PRJ2HASH_EXE="./prj2hash"
        return 
    fi
    if [ -f "./tools/prj2hash" ]; then
        PRJ2HASH_EXE="./tools/prj2hash"
        return 
    fi

    GOLANG=$(command -v go)
    if [ "x$GOLANG" == "x" ]; then
        return
    fi

    if [ ! -d "${CDIR}/tools" ]; then
        mkdir "${CDIR}/tools"
    fi

    cd "${CDIR}/tools"
    git clone https://github.com/abatalev/prj2hash.git prj2hash.git
    cd "${CDIR}/tools/prj2hash.git"
    ./build.sh
    cd "${CDIR}"
    cp tools/prj2hash.git/prj2hash tools/prj2hash
    rm -Rf ${CDIR}/tools/prj2hash.git/
    PRJ2HASH_EXE="./tools/prj2hash"
}

DOCKER_BIN=docker
if [ $USE_PODMAN == 1 ]; then
    DOCKER_BIN=podman
fi

#if [ $USE_MINIKUBE == 1 ]; then
#    if [ $USE_PODMAN == 1 ]; then
#        minikube config set driver podman
#        minikube config set rootless true
#    fi
#if 

function image_exist() {
    I_PRJ=$1
    V_PRJ=$2
    $DOCKER_BIN image list | grep $I_PRJ | awk ' {print $2;}' | grep $V_PRJ | wc -l
}

function image_build() {
    B_PRJ=$1
    I_PRJ=$2
    V_PRJ=$3
    D_PRJ=$4
    N_PRJ=$5
    if [ ${B_PRJ} == 0 ]; then
        echo "### build $N_PRJ"
        $DOCKER_BIN build -t $I_PRJ:$V_PRJ -f $D_PRJ .
        if [  $? -ne 0  ]; then exit 1; fi
    else 
        echo "### Build $N_PRJ skipped. Image $I_PRJ:$V_PRJ already exist"    
    fi
}

function save_image() {
    if [ ! -f ${CDIR}/cache/${1}-${3}.tar ]; then
        if [ ! -d ${CDIR}/cache ]; then
            mkdir ${CDIR}/cache
        fi
        echo "### CACHE save ${1}-${3}"
        $DOCKER_BIN save -o ${CDIR}/cache/${1}-${3}.tar ${2}:${3}
    fi
}

function load_image() {
    BX=$(image_exist $2 $3)
    if [ ${BX} != 1 ]; then
        if [ -f ${CDIR}/cache/${1}-${3}.tar ]; then
            echo "### CACHE load ${1}-${3}"
            $DOCKER_BIN load -i ${CDIR}/cache/${1}-${3}.tar
        fi
    fi
}

function build_project() {
    PRJ_NAME=$1
    PRJ_NEEDBUILD=0
    PRJ_IMAGE="${PRJ_IMAGEGROUP}/${PRJ_NAME}"
    PRJ_VERSION="${PRJ_IMAGEVERSION}"
    
    cd "${CDIR}"
    if [ "x${PRJ2HASH_EXE}" != "x" ]; then
        PRJ_VERSION=$(${PRJ2HASH_EXE} -short build/${PRJ_NAME})
    fi
    load_image ${PRJ_NAME} ${PRJ_IMAGE} ${PRJ_VERSION}
    if [ "x${PRJ2HASH_EXE}" != "x" ]; then
        PRJ_NEEDBUILD=$(image_exist $PRJ_IMAGE $PRJ_VERSION)
    fi
    cd "${CDIR}/build"
    image_build $PRJ_NEEDBUILD $PRJ_IMAGE $PRJ_VERSION "Dockerfile.${PRJ_NAME}" "${PRJ_NAME}"
    if [ $USE_CACHE == 1 ]; then
        save_image ${PRJ_NAME} ${PRJ_IMAGE} ${PRJ_VERSION}
    fi
    cd "${CDIR}"
    IMAGE_VERSION=$PRJ_IMAGE:$PRJ_VERSION yq e -i ".services.${PRJ_NAME}.image = strenv(IMAGE_VERSION)" docker-compose.yaml
    # IMAGE_VERSION=$PRJ_IMAGE:$PRJ_VERSION yq e -i ".${PRJ_NAME}-chart.image.tag = strenv(IMAGE_VERSION)" ./my.yaml
    IMAGE_VERSION=$PRJ_IMAGE yq e -i ".stand-chart.${PRJ_NAME}-chart.image.repository = strenv(IMAGE_VERSION)" ./my.yaml
    IMAGE_VERSION=$PRJ_VERSION yq e -i ".stand-chart.${PRJ_NAME}-chart.image.tag = strenv(IMAGE_VERSION)" ./my.yaml
}

function minikube_setup() {
    # load to cache docker-images
    for i in `find . -name "Dockerfile.*" -exec grep FROM {} \; | awk '{ print $2 }' | sort | uniq`
    do
        echo "  # Load docker image $i"
        x1=$(echo $i | awk -F":" '{print $1}' -)
        x2=$(echo $i | awk -F":" '{print $2}' -)
        x3=$(basename $x1)
        save_image $x3 $x1 $x2 
    done

    # => check status
    minikube status > /dev/null
    if [ $? != 0 ]; then
        echo "### Minikube status -- ($?). minikube starting"
        minikube start 
        # minikube start --driver=podman --container-runtime=cri-o
        # minikube start --driver=podman --container-runtime=containerd
    fi 
    minikube status > /dev/null
    if [ $? != 0 ]; then
        echo "### Minikube status -- ($?). aborted"
        exit 1
    fi
    echo "### Minikube started"

    # => setup environment
    CDIR=$(pwd)
    eval $(minikube -p minikube docker-env)

    E_NAMESPACE=$(kubectl get namespaces | grep stand | wc -l)
    if [ $E_NAMESPACE == 0 ]; then
        echo "create namespace"
        kubectl create -f minikube/stand-namespace.yaml
    fi
    kubectl config set-context $(kubectl config current-context) --namespace=stand

    # load in minikube images from cache
    for i in `find . -name "Dockerfile.*" -exec grep FROM {} \; | awk '{ print $2 }' | sort | uniq`
    do
        echo "  # Load docker image $i to minikube"
        x1=$(echo $i | awk -F":" '{print $1}' -)
        x2=$(echo $i | awk -F":" '{print $2}' -)
        x3=$(basename $x1)
        load_image $x3 $x1 $x2 
    done
}

function openshift_setup() {
    # ==> 
    CRC_BIN_ENABLE=$(which crc > /dev/null; echo "$?")
    if [ ${CRC_BIN_ENABLE} == 0 ]; then
        echo "### CRC VERSION"
        crc version
        echo "### CRC CONFIG"
        crc config view
    fi


    CRC_STOPPED=$(crc status | grep "^CRC VM" | grep "Stopped" | wc -l)
    if [ ${CRC_STOPPED} == 1 ]; then
        echo "crc status -- (Stopped). crc starting"
        crc start
        crc config set consent-telemetry no
    fi 
    echo "### CRC STATUS"
    crc status
    CRC_STOPPED=$(crc status | grep "^CRC VM" | grep "Stopped" | wc -l)
    if [ ${CRC_STOPPED} == 1 ]; then
        echo "crc status -- (Stopped). break."
        exit
    fi 

    eval $(crc oc-env)
    oc new-project stand
    oc project stand
    # project stand

    eval $(crc podman-env --root)
    echo "###     OC_BIN $(which oc)"
    echo "### PODMAN_BIN $(which podman)"
    echo "### PODMAN LOGIN" 
    podman login -u developer -p $(oc whoami -t) $(oc registry info) --tls-verify=false
}

function helm_run() {
    STANDID=$1
    echo "### HELM: update dependency  ============================================"
    helm dependency update helm/stand-chart
    helm dependency update $STANDID

    HELM_EXISTS=$(helm ls | grep "${HELM_NAME}" | wc -l --)
    if [ ${HELM_EXISTS} == 0 ]; then
        if [ "${HELM_STATE}" == "install" ]; then
            echo "### HELM: install  ====================================================="
            helm install ${HELM_NAME} $STANDID -f ./my.yaml
        fi
    else 
        if [ "${HELM_STATE}" == "delete" ]; then
            echo "### HELM: delete  ======================================================"
            helm delete ${HELM_NAME}
        fi
        if [ "${HELM_STATE}" == "install" ]; then
            echo "### HELM: upgrade  ====================================================="
            helm upgrade ${HELM_NAME} $STANDID -f ./my.yaml
        fi
    fi
}

function install_program() {
    OSNAME=$(uname)
    if [ "$OSNAME" == "Darwin" ]; then 
        echo "### Installing $1"
        brew update
        brew install $1
    elif [ "$OSNAME" == "Linux" ]; then
        LINUXNAME=$(hostnamectl | awk -F: '/^Opera/ { print $2 }')
        if [ "$LINUXNAME" == "Arch Linux" ]; then
            pacman -S $1
        else
            echo "### Script stopped"
        fi
    fi
}

function check_program() {
    X=$(which $1)
    if [ "${X}" == "" ]; then
        install_program "$2"
    fi 
}

function build_all() {

    if [[ $USE_OPENSHIFT == 1 || $USE_MINIKUBE == 1 || $USE_COMPOSE == 1 ]];  then 
        echo "### Starting"
    else
        echo "### Error! Use not defined"
        exit 1
    fi

    check_program yq yq
    check_program kubectl kubernetes-cli
    check_program helm helm
    check_program minikube minikube
    check_program docker-compose docker-compose
    check_prj2hash

    echo "" > "${CDIR}/my.yaml"

    if [ $USE_MINIKUBE == 1 ]; then
        minikube_setup
    fi

    if [ $USE_OPENSHIFT == 1 ]; then
        openshift_setup
    fi

    echo "### create docker-compose"
    cp docker-compose.tmpl docker-compose.yaml

    if [ ! -f "./my.yaml" ]; then
        touch ./my.yaml
    fi

    for prj_name in ${1}
    do
        build_project "${prj_name}"
    done

    cd "${CDIR}"
    if [ ${USE_COMPOSE} == 1 ]; then
        echo "### launch docker-compose =============================================="
        docker-compose up --remove-orphans # --scale actions=2
        echo "### ===================================================================="
    fi

    if [ ${USE_MINIKUBE} == 1 ]; then
        echo "### Kubernetes: minikube charts starting ==============================="
        helm_run helm/stand-minikube-chart
        echo "### Kubernetes: status ================================================="
        kubectl get all
        echo "### ===================================================================="
    fi 

    if [ ${USE_OPENSHIFT} == 1 ]; then
        echo "### OpenShift: openshift charts starting ==============================="
        helm_run helm/stand-openshift-chart
        echo "### OpenShift: status =================================================="
        oc get all
        echo "### ===================================================================="
    fi    
}