#!/bin/bash -xe

#helm repo add openperouter https://openperouter.github.io/openperouter

#helm repo update
#helm install openperouter openperouter/openperouter -f values.yaml -n openperouter-system --create-namespace

helm install openperouter $HOME/Documents/cnv/sandbox/gcp/openperouter/charts/openperouter/ --namespace openperouter-system -f values.yaml --create-namespace
oc apply -f ipvlan-and-route.yaml
	
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-controller
oc adm policy add-scc-to-user privileged -n openperouter-system -z openperouter-perouter

kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/l2vnis.openpe.openperouter.github.io
kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/l3vnis.openpe.openperouter.github.io
kubectl -n openperouter-system wait --for condition=established --timeout=60s crd/underlays.openpe.openperouter.github.io
