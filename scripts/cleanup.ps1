param(
    [string[]]$ClusterNames = @("cilium-study", "cilium-study-kpr")
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command kind -ErrorAction SilentlyContinue)) {
    throw "Required command 'kind' was not found in PATH."
}

$existing = kind get clusters
foreach ($cluster in $ClusterNames) {
    if ($existing -contains $cluster) {
        kind delete cluster --name $cluster
    } else {
        Write-Host "kind cluster '$cluster' does not exist. Skipping."
    }
}
