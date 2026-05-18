# 01. Cilium 설치

## 학습 목표

- Helm으로 Cilium을 설치하고 상태를 검증합니다.
- Hubble Relay/UI를 활성화합니다.
- 설치 실패 시 확인해야 할 기본 지점을 익힙니다.

이 장부터는 스크립트 대신 문서의 명령을 직접 실행하면서 진행합니다. kind 클러스터는 OS별 환경 준비 문서에서 이미 생성했다고 가정합니다.

- [Windows WSL2](00-environment-windows-wsl2.md)
- [macOS](00-environment-macos.md)
- [Linux](00-environment-linux.md)

## CLI 준비

다음 CLI가 PATH에 있어야 합니다.

- `kubectl`: `create-kind-cluster.sh`가 자동 설치했거나 직접 설치
- `helm`
- `cilium`
- `hubble`

Helm 설치 예시:

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Cilium CLI와 Hubble CLI는 공식 릴리스에서 OS/아키텍처에 맞는 바이너리를 받아 PATH에 추가합니다.

Linux amd64 예시:

```bash
curl -L --fail https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz | tar xz -C /tmp
sudo install /tmp/cilium /usr/local/bin/cilium

curl -L --fail https://github.com/cilium/hubble/releases/latest/download/hubble-linux-amd64.tar.gz | tar xz -C /tmp
sudo install /tmp/hubble /usr/local/bin/hubble
```

macOS는 `darwin-amd64` 또는 `darwin-arm64` asset을 사용합니다.

설치 확인:

```bash
kubectl version --client
helm version
cilium version
hubble version
```

새 터미널에서 `k` alias와 completion을 쓰려면 `~/.bashrc` 또는 `~/.zshrc`에 로컬 도구 설정을 추가합니다.

```bash
bash scripts/use-local-tools.sh --install-bashrc
source ~/.bashrc
```

## Helm으로 Cilium 설치

기본 설치 값은 `labs/01-install/cilium-values.yaml`에 있습니다.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-values.yaml
```

설치가 끝날 때까지 기다립니다.

```bash
kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m
```

## Hubble 활성화

Helm values에 Hubble 옵션이 포함되어 있어도 Relay/UI를 명시적으로 활성화합니다.

```bash
cilium hubble enable --ui
```

## 검증

`hubble` CLI는 로컬 `127.0.0.1:4245`로 Hubble Relay에 접속합니다. 별도 터미널에서 port-forward를 유지합니다.

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80
```

다른 터미널:

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
- Docker Engine 또는 Colima 등 Docker 호환 런타임이 실행 중이 아님
- 회사 VPN과 Pod/Service CIDR 충돌
- Cilium CLI와 설치된 Cilium 버전의 호환성 문제
- `hubble status` 실패: Hubble Relay port-forward가 열려 있지 않음

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

전체 kind 클러스터를 제거하려면 `scripts/cleanup.sh`를 사용합니다.
