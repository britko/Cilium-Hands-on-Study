# Upgrade Checklist

- Record `cilium version`, `kubectl version`, and Kubernetes server version.
- Save `helm -n kube-system get values cilium`.
- Run `cilium status` and a connectivity test before upgrade.
- Capture a pre-upgrade sysdump.
- Confirm enabled advanced features: kube-proxy replacement, Gateway API, Cluster Mesh, BGP, Egress Gateway, encryption, host firewall.
- Upgrade in a maintenance window.
- Re-run the same connectivity and feature-specific checks after upgrade.
- Keep rollback revision from `helm -n kube-system history cilium`.
