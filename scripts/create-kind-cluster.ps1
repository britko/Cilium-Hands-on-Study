param(
    [string]$ClusterName = "cilium-study",
    [string]$ConfigPath = "labs/kind/kind-cilium.yaml"
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

Require-Command kind
Require-Command kubectl
Require-Command docker

$existing = kind get clusters
if ($existing -contains $ClusterName) {
    Write-Host "kind cluster '$ClusterName' already exists. Skipping creation."
} else {
    kind create cluster --name $ClusterName --config $ConfigPath
}

kubectl cluster-info --context "kind-$ClusterName"
kubectl get nodes -o wide
