####
# This script will install the microk8s, kubectl, flux, enable flux with the git repo provided in the environment variables, add
# cluster to Microsoft Azure using Azure Arc & Kubernetes secrets which contains Service principal details provided in environment.
# This scripts also generates the k8s sa token which can be used to access this cluster resources from Microsoft azure arc.

# Prerequisite: 
# 1. Environment variables listed in .env-template to be set
# 2. Azure CLI

###
# How to run this script
# Copy the .env-template to .env file and set all the appropriate values in the variables listed in .env file
# You'll need to add store name, tags (if any), Azure service principal for setting up Arc, gitops repo, branch name and token
# for flux. To setup Key vault you'll also need Azure service prinicpal which has permissions to get the secrets from KV 

# Run this script using <ScriptPath>/setup.sh 

### Optional - DNS Issue Fix - To be used only when resolv.conf related issue of DNS name appending at end of all http calls from microk8s is observed
## Uncomment lines below to overwrite resolv.conf file and make it immutable

# sudo apt-get install e2fsprogs
# sudo rm /etc/resolv.conf
# sudo bash -c 'echo "nameserver 127.0.0.53" > /etc/resolv.conf'
# sudo bash -c 'echo "options edns0 trust-ad" >> /etc/resolv.conf'
# sudo chattr +i /etc/resolv.conf

## To make the resolv.conf mutable again, in case one has to
# sudo chattr -i /etc/resolv.conf


####


#!/bin/bash
set -o errexit
#set -o nounset
set -o pipefail

#Load environment variables from the file
export $(grep -v '^#' .env | xargs)

# Check for Az Cli, env variables
check_vars()
{
    var_names=("$@")
    for var_name in "${var_names[@]}"; do
        [ -z "${!var_name}" ] && echo "$var_name is unset." && var_unset=true
    done
    [ -n "$var_unset" ] && exit 1
    return 0
}

check_vars STORE_NAME AZ_SP_ID AZ_SP_SECRET GITOPS_REPO GITOPS_PAT GITOPS_BRANCH AZ_ARC_RESOURCEGROUP AZ_ARC_RESOURCEGROUP_LOCATION AZ_KEYVAULT_SP_ID AZ_KEYVAULT_SP_SECRET SECRET_PROVIDER_NAME AZ_TEANANT_ID

if command -v az -v >/dev/null; then
     printf "\n AZ CLI is present ✅ \n"
else
     printf "\n AZ CLI could not be found ❌ \n"
     exit
fi


printf "\n Starting microk8s installation 🚧 \n"

sudo systemctl start snapd.socket
# Install & set up microk8s
sudo snap install microk8s --classic

# sleep to avoid timing issues
sleep 10

# Check microk8s status
sudo microk8s status --wait-ready
printf '\n microk8s installed successfully ✅'


# Install Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Set up config for kubectl
sudo rm -rf ~/.kube
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
--branch "$GITOPS_BRANCH" \
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
--interval 10m

flux reconcile source git gitops
printf '\n Flux installed successfully ✅\n'

##### ARC region ######

printf "\n Logging in Azure using Service Principal 🚧 \n"
# Az Login using SP
az login --service-principal -u $AZ_SP_ID  -p  $AZ_SP_SECRET --tenant $AZ_TEANANT_ID

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

printf "\n Creating k8s-extension 🚧 \n"
az k8s-extension create --cluster-name $STORE_NAME --resource-group $AZ_ARC_RESOURCEGROUP --cluster-type connectedClusters --extension-type Microsoft.AzureKeyVaultSecretsProvider --name $SECRET_PROVIDER_NAME

printf "\n Verifying k8s-extension 🚧 \n"
az k8s-extension show --cluster-type connectedClusters --cluster-name $STORE_NAME --resource-group $AZ_ARC_RESOURCEGROUP --name $SECRET_PROVIDER_NAME


#TODO: Check if service account already present
# Generate token to connect to Azure k8s cluster
ADMIN_USER=$(kubectl get serviceaccount admin-user -o jsonpath='{$.metadata.name}' --ignore-not-found)
if [ -z "$ADMIN_USER" ]; then
    printf "\n Creating service account 🚧 \n"
    kubectl create serviceaccount admin-user
else
    printf "\n Service account already exist. \n"
fi

CLUSTER_ROLE_BINDING=$(kubectl get clusterrolebinding admin-user-binding -o jsonpath='{$.metadata.name}' --ignore-not-found)
if [ -z "$CLUSTER_ROLE_BINDING" ]; then
    printf "\n Creating cluster role binding 🚧 \n"
    kubectl create clusterrolebinding admin-user-binding --clusterrole cluster-admin --serviceaccount default:admin-user
else
    printf "\n Cluster role binding already exist. \n"     
fi

# Generating a secret
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: admin-user
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF

TOKEN=$(kubectl get secret admin-user -o jsonpath='{$.data.token}' | base64 -d | sed $'s/$/\\\n/g')

printf "\n ####### Token to connect to Azure ARC starts here ######## \n"
printf $TOKEN
printf "\n ####### Token to connect to Azure ARC ends here   ######### \n"
echo $TOKEN > token.txt
printf "\n Token is saved at token.txt file \n"
printf "\n Creating Kubernetes Secrets for Key Valut 🚧 \n"

# Create kubernetes secrets for KV
SECRET_CREDS=$(kubectl get secret secrets-store-creds -o jsonpath='{$.metadata.name}' --ignore-not-found)
if [ -z "$SECRET_CREDS" ]; then
    printf "\n Creating secret store credentials 🚧 \n"   
    kubectl create secret generic secrets-store-creds --from-literal clientid=$AZ_KEYVAULT_SP_ID --from-literal clientsecret=$AZ_KEYVAULT_SP_SECRET
    #Label the created secret.
    kubectl label secret secrets-store-creds secrets-store.csi.k8s.io/used=true
else
    printf "\n Secret store credentials already exist. \n"         
fi
