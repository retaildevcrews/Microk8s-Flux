####
# This script will install the microk8s, kubectl, flux, enable flux with the git repo provided in the environment variables, add
# cluster to Microsoft Azure using Azure Arc & Kubernetes secrets which contains Service principal details provided in environment.
# This scripts also generates the k8s sa token which can be used to access this cluster resources from Microsoft azure arc.

# Prerequisite: 
# 1. Environment variables listed in .env-template to be set
# 2. Azure CLI

###
# How to run this script
# Set all the environment variables listed in .env-tempalte usign appropriate values in your terminal
# Run this script using <ScriptPath>/setup.sh 
####


#!/bin/bash

# Check for Az Cli, env variables
##TODO: Check for empty strings in variables
check_vars()
{
    var_names=("$@")
    for var_name in "${var_names[@]}"; do
        if [ -z "$var_name" ]
        then
            printf "\$var_name is empty. Please set it up."
        else
            printf "$var_name is not set." && var_unset=true
        fi 
    done
    [ -n "$var_unset" ] && exit 1
    return 0
}

check_vars STORE_NAME STORE_TAGS AZ_SP_ID AZ_SP_SECRET GITOPS_REPO GITOPS_PAT GITOPS_BRANCH AZ_ARC_RESOURCEGROUP AZ_ARC_RESOURCEGROUP_LOCATION

if command -v az -v >/dev/null; then
     printf "\n AZ CLI is present ✅ \n"
else
     printf "\n AZ CLI could not be found ❌ \n"
     exit
fi


printf "\n Starting microk8s installation 🚧 \n"
# Install & set up microk8s
sudo snap install microk8s --classic

# Check microk8s status
sudo microk8s status --wait-ready
printf '\n microk8s installed successfully ✅'


# Install Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Set up config for kubectl
mkdir ~/.kube
sudo microk8s config > ~/.kube/config
printf '\n Kubectl installed successfully ✅ \n'

# Enable microk8s extensions - DNS, HELM
sudo microk8s enable dns
sleep 5
kubectl wait --for=condition=containersReady pod -l k8s-app=kube-dns -n kube-system
printf '\n microk8s dns enabled successfully ✅\n'

printf "Installing flux 🚧 \n"
# Install Flux
curl -s https://fluxcd.io/install.sh | sudo bash
. <(flux completion bash)

# Setup flux
flux bootstrap git \
--url "https://github.com/$GITOPS_REPO" \
--branch main \
--password "$GITOPS_PAT" \
--token-auth true \
--path "./deploy/bootstrap/$STORE_NAME"

flux create secret git gitops \
--url "https://github.com/$GITOPS_REPO" \
--password "$GITOPS_PAT" \
--username gitops

flux create source git gitops \
--url "https://github.com/$GITOPS_REPO" \
--branch "$GITOPS_BRANCH" \
--secret-ref gitops

flux create kustomization apps \
--source GitRepository/gitops \
--path "./deploy/apps/$STORE_NAME" \
--prune true \
--interval 1m

flux reconcile source git gitops
printf '\n Flux installed successfully ✅\n'

##### ARC region ######

printf "\n Logging in Azure using Service Principal 🚧 \n"
# Az Login using SP
az login --service-principal -u $AZ_SP_ID  -p  $AZ_SP_SECRET --tenant 72f988bf-86f1-41af-91ab-2d7cd011db47

# Arc setup 
az extension add --name connectedk8s

az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation

# Check for existing resource group
if [ $(az group exists --name $AZ_ARC_RESOURCEGROUP) == false ]; then
    az group create --name $AZ_ARC_RESOURCEGROUP --location $AZ_ARC_RESOURCEGROUP_LOCATION --output table
    printf "\n Resource group $AZ_ARC_RESOURCEGROUP created ✅\n"
fi

printf "\n Connecting to Azure Arc 🚧 \n"
az connectedk8s connect --name $STORE_NAME --resource-group $AZ_ARC_RESOURCEGROUP

# Generate token to connect to Azure k8s cluster
kubectl create serviceaccount admin-user
kubectl create clusterrolebinding admin-user-binding --clusterrole cluster-admin --serviceaccount default:admin-user
SECRET_NAME=$(kubectl get serviceaccount admin-user -o jsonpath='{$.secrets[0].name}')
TOKEN=$(kubectl get secret ${SECRET_NAME} -o jsonpath='{$.data.token}' | base64 -d | sed $'s/$/\\\n/g')

printf "\n Token to connect to Azure ARC starts here \n"
printf $TOKEN
printf "\n Token to connect to Azure ARC ends here \n"

printf "\n Creating Kubernetes Secrets for Key Valut 🚧 \n"
# Create kubernetes secrets for KV
kubectl create secret generic secrets-store-creds --from-literal clientid=$AZ_SP_ID --from-literal clientsecret=$AZ_SP_SECRET
