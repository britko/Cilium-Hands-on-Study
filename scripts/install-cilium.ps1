param(
    [string]$Version = "1.19.3",
    [string]$ValuesPath = "labs/01-install/cilium-values.yaml"
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

Require-Command helm
Require-Command kubectl
Require-Command cilium

helm repo add cilium https://helm.cilium.io/ | Out-Null
helm repo update cilium | Out-Null

helm upgrade --install cilium cilium/cilium `
    --version $Version `
    --namespace kube-system `
    --values $ValuesPath

cilium status --wait
cilium hubble enable --ui
hubble status
