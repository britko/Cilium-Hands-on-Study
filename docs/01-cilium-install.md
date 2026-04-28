# 01. Cilium 설치

## 학습 목표

- Helm으로 Cilium을 설치하고 상태를 검증합니다.
- Hubble Relay/UI를 활성화합니다.
- 설치 실패 시 확인해야 할 기본 지점을 익힙니다.

## 설치

기본 설치 값은 `labs/01-install/cilium-values.yaml`에 있습니다.

Windows PowerShell:

```powershell
.\scripts\install-cilium.ps1
```

macOS/Linux Bash:

```bash
bash scripts/install-cilium.sh
```

수동으로 실행하려면 다음 명령을 사용합니다.

Windows PowerShell:

```powershell
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm upgrade --install cilium cilium/cilium `
  --version 1.19.3 `
  --namespace kube-system `
  --values labs/01-install/cilium-values.yaml
```

macOS/Linux Bash:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-values.yaml
```

## 검증

```bash
cilium status --wait
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pods -l k8s-app=hubble-relay
hubble status
```

정상 상태에서는 Cilium agent, operator, Hubble Relay가 모두 Ready 상태여야 합니다.

## Hubble UI 접속

```bash
cilium hubble ui
```

브라우저가 열리면 namespace, pod, DNS, HTTP flow를 시각적으로 확인할 수 있습니다.

## 연결성 테스트

```bash
cilium connectivity test
```

이 테스트는 Cilium의 기본 datapath, service, DNS, policy 기능을 한 번에 검증합니다. 스터디 환경에서는 시간이 걸려도 첫 설치 후 반드시 실행합니다.

## 설치 옵션 해설

`labs/01-install/cilium-values.yaml`의 핵심 옵션:

```yaml
ipam:
  mode: kubernetes
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
```

- `ipam.mode=kubernetes`: kind 환경에서 Kubernetes PodCIDR를 사용합니다.
- `hubble.enabled=true`: flow 관측 기능을 활성화합니다.
- `hubble.relay.enabled=true`: Hubble CLI/UI가 여러 노드의 flow를 조회할 수 있게 합니다.
- `hubble.ui.enabled=true`: 스터디에서 시각적 분석을 할 수 있게 합니다.

## 실패 시 확인

```bash
kubectl -n kube-system describe pods -l k8s-app=cilium
kubectl -n kube-system logs -l k8s-app=cilium --tail=100
kubectl -n kube-system logs deploy/cilium-operator --tail=100
```

자주 발생하는 문제:

- kind 클러스터 생성 시 `disableDefaultCNI`를 빼먹어 CNI가 중복됨
- Docker Desktop이 실행 중이 아님
- 회사 VPN과 Pod/Service CIDR 충돌
- Cilium CLI와 설치된 Cilium 버전의 호환성 문제

## 실전 운영 관점

운영 설치는 단순히 `helm install`로 끝내지 않습니다.

- Helm values를 GitOps 저장소에서 버전 관리합니다.
- 업그레이드 전 `cilium status`, `cilium connectivity test`, `cilium sysdump`를 기준선으로 남깁니다.
- 기존 NetworkPolicy 영향 범위를 Hubble flow로 확인합니다.
- kube-proxy replacement, Gateway API, encryption 같은 기능은 별도 change window에서 켭니다.

## 정리

Cilium만 제거하려면 다음을 실행합니다.

```bash
helm uninstall cilium -n kube-system
```

전체 kind 클러스터를 제거하려면 Windows에서는 `scripts/cleanup.ps1`, macOS/Linux에서는 `scripts/cleanup.sh`를 사용합니다.
