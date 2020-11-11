#!/bin/bash

[ -z $4 ] && echo "Usage: $0 <namespace> <OpenVPN URL> <service cidr> <pod cidr> <cluster domain>" && exit 1

namespace=$1
serverurl=$2
servicecidr=$3
podcidr=$4
domain=${5:-svc.cluster.local}

# Server name is in the form "udp://vpn.example.com:1194"
if [[ "$serverurl" =~ ^((udp|tcp)(4|6)?://)?([0-9a-zA-Z\.\-]+)(:([0-9]+))?$ ]]; then
    OVPN_PROTO=$(echo ${BASH_REMATCH[2]} | tr '[:lower:]' '[:upper:]')
    OVPN_CN=$(echo ${BASH_REMATCH[4]} | tr '[:upper:]' '[:lower:]')
    OVPN_PORT=${BASH_REMATCH[6]};
else
    echo "Need to pass in OpenVPN URL in 'proto://fqdn:port' format"
    echo "eg: tcp://my.fully.qualified.domain.com:1194"
    exit 1
fi
OVPN_PORT="${OVPN_PORT:-1194}"

if [ ! -d pki ]; then
    echo "This script requires a directory named 'pki' in the current working directory, populated with a CA generated by easyrsa"
    echo "You can easily generate this. Execute the following command and follow the instructions on screen:"
    echo "docker run -e OVPN_SERVER_URL=$serverurl -v $PWD:/etc/openvpn:z -ti ptlange/openvpn ovpn_initpki"
    exit 1
fi

# test if -w0 is a valid option
base64 -w0 /dev/null > /dev/null 2>&1
if [ $? -eq 0 ]; then
    base64="base64 -w0"
else
    base64="base64"
fi

kuberes='./kube/kube-resources'
mkdir -p $kuberes

echo "Generating Kubernetes resources"

cat << EOSECRETS > $kuberes/openvpn-pki.yaml
apiVersion: v1
kind: Secret
metadata:
  name: openvpn-pki
type: Opaque
data:
  private.key: "$($base64 pki/private/${OVPN_CN}.key)"
  ca.crt: "$($base64 pki/ca.crt)"
  certificate.crt: "$($base64 pki/issued/${OVPN_CN}.crt)"
  dh.pem: "$($base64 pki/dh.pem)"
  ta.key: "$($base64 pki/ta.key)"
---
EOSECRETS

cat << EOCONFIGMAP > $kuberes/openvpn-settings.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openvpn-settings
data:
  servicecidr: "${servicecidr}"
  podcidr: "${podcidr}"
  serverurl: "${serverurl}"
  domain: "${domain}"
  statusfile: "/etc/openvpn/status/server.status"
---
EOCONFIGMAP

cat << EOSERVICE > $kuberes/openvpn-svc.yaml
---
apiVersion: v1
kind: Service
metadata:
  labels:
    openvpn: ${OVPN_CN}
  name: openvpn
spec:
  type: NodePort
  ports:
  - port: ${OVPN_PORT}
    protocol: ${OVPN_PROTO}
    targetPort: 1194
  selector:
    openvpn: ${OVPN_CN}
---
EOSERVICE

echo "Creating and applying Kubernetes resources"
kubectl create configmap --namespace=$namespace openvpn-crl --from-file=crl.pem=$PWD/pki/crl.pem
kubectl apply --namespace=$namespace -f ./kube/configmaps-example.yaml
kubectl apply --namespace=$namespace -f ./kube/template_config_map.yaml
kubectl apply --namespace=$namespace -f $kuberes/openvpn-pki.yaml
kubectl apply --namespace=$namespace -f $kuberes/openvpn-settings.yaml
kubectl apply --namespace=$namespace -f $kuberes/openvpn-svc.yaml
sed "s/\${OVPN_CN}/${OVPN_CN}/g;" kube/deployment.yaml | kubectl create --namespace=$namespace -f -
