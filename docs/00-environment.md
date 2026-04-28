# 00. 환경 준비

## 학습 목표

- kind 기반 Cilium 실습 환경을 준비합니다.
- Cilium이 kind의 기본 CNI 대신 설치되도록 클러스터를 생성합니다.
- Windows PowerShell, macOS/Linux Bash 환경에서 반복 가능한 실습 루틴을 만듭니다.

## 사전 조건

필수 도구:

- Docker Desktop
- Windows: PowerShell 7 이상
- macOS/Linux: Bash
- `kind`
- `kubectl`
- `helm`
- `cilium`
- `hubble`

권장 버전:

- Cilium: `1.19.x`
- Cilium CLI: `0.19.x`
- Helm: `3.13.0` 이상
- kind: 최신 안정 버전

## Windows 설치 예시

```powershell
winget install Docker.DockerDesktop
winget install Kubernetes.kind
winget install Kubernetes.kubectl
winget install Helm.Helm
```

Cilium CLI와 Hubble CLI는 Cilium 공식 릴리스 페이지에서 Windows 바이너리를 내려받아 PATH에 추가합니다.

## macOS 설치 예시

```bash
brew install --cask docker
brew install kind kubectl helm cilium-cli hubble
```

Docker Desktop 대신 Colima를 사용할 수도 있습니다.

```bash
brew install colima docker
colima start --cpu 4 --memory 8
```

## Linux 설치 예시

Ubuntu 기준 예시입니다. Docker Engine 설치 후 현재 사용자를 `docker` 그룹에 추가하고 새 터미널을 여는 것을 권장합니다.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
```

`kind`, `kubectl`, `helm`, `cilium`, `hubble`은 각 공식 문서의 최신 설치 명령을 사용합니다. 패키지 매니저가 있다면 `brew` on Linux 또는 배포판 패키지를 사용해도 됩니다.

## 도구 확인

```powershell
cilium version
hubble version
kind version
kubectl version --client
helm version
```

## kind 클러스터 생성

기본 실습 클러스터는 `labs/kind/kind-cilium.yaml`을 사용합니다.

Windows PowerShell:

```powershell
.\scripts\create-kind-cluster.ps1
```

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh
```

핵심 설정은 다음과 같습니다.

```yaml
networking:
  disableDefaultCNI: true
  podSubnet: 10.10.0.0/16
  serviceSubnet: 10.11.0.0/16
```

`disableDefaultCNI: true`는 kind의 기본 CNI인 kindnet을 설치하지 않습니다. Cilium을 CNI로 직접 설치하기 위한 필수 설정입니다.

## 네트워크 대역 충돌 확인

회사 VPN, WSL, Docker Desktop 네트워크와 `podSubnet`, `serviceSubnet`이 겹치면 Pod 통신이 불안정할 수 있습니다. 충돌이 있으면 `labs/kind/kind-cilium.yaml`의 대역을 바꿉니다.

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

Cilium 설치 전에는 CoreDNS가 `Pending` 상태일 수 있습니다. CNI가 아직 없기 때문에 정상입니다.

## 실전 운영 관점

운영 클러스터에서는 설치 전에 다음을 확인합니다.

- Kubernetes 버전과 Cilium 지원 매트릭스
- 노드 커널 버전과 eBPF 기능 지원
- 기존 CNI 제거 또는 migration 절차
- Pod/Service CIDR이 사내 네트워크와 충돌하지 않는지
- kube-proxy replacement를 사용할 경우 rollback 계획

## 정리

Windows PowerShell:

```powershell
.\scripts\cleanup.ps1
```

macOS/Linux Bash:

```bash
bash scripts/cleanup.sh
```

개별 랩 리소스만 삭제하려면 각 장의 cleanup 명령을 사용합니다.
