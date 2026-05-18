# Cilium Hands-on Study

고급 Kubernetes 사용자를 위한 Cilium hands-on study 프로젝트입니다. 로컬 `kind` 클러스터에서 Cilium을 직접 설치하고, eBPF datapath, Hubble, NetworkPolicy, L7 policy, kube-proxy replacement, Gateway API, 운영 트러블슈팅까지 실전 시나리오 중심으로 다룹니다.

## 학습 목표

- Cilium이 Kubernetes CNI, service load balancing, policy enforcement를 eBPF로 처리하는 방식을 이해합니다.
- Hubble을 사용해 DNS, TCP, HTTP 흐름을 관찰하고 정책 적용 전후를 비교합니다.
- Kubernetes NetworkPolicy와 CiliumNetworkPolicy를 실무 기준으로 설계합니다.
- kube-proxy 없는 클러스터에서 Cilium service handling을 검증합니다.
- Gateway API를 Cilium으로 구동하고 north-south 트래픽을 라우팅합니다.
- `cilium sysdump`, `cilium connectivity test`, `hubble observe`를 활용한 장애 분석 루틴을 익힙니다.

## 대상 독자

- Kubernetes 네트워킹, Service, Ingress, NetworkPolicy 개념을 이미 알고 있는 사람
- CNI를 단순 설치 수준이 아니라 운영 관점에서 이해하고 싶은 사람
- 실전 보안 정책, 관측, 장애 대응 예시까지 포함한 스터디 자료가 필요한 사람

## 권장 환경

- Windows 10/11 + WSL2 Ubuntu + Docker Engine
- macOS + Colima + Docker CLI
- Linux + Docker Engine
- kind 로컬 Kubernetes 클러스터

지원 수준은 다음을 기준으로 합니다.

- Tier 1: Windows WSL2 Docker Engine, macOS Colima, Linux Docker Engine
- Tier 2: Docker Desktop 또는 Rancher Desktop의 Docker 호환 backend

처음 시작할 때는 OS별 문서로 바로 이동합니다.

- [Windows WSL2](docs/00-environment-windows-wsl2.md)
- [macOS](docs/00-environment-macos.md)
- [Linux](docs/00-environment-linux.md)

기본 실습은 Cilium `1.19.x` 안정 버전을 기준으로 작성했습니다. Gateway API 실습은 Cilium `1.19.x` 안정 문서 기준인 Gateway API CRD `v1.4.1`을 사용합니다.

## 빠른 시작

Windows 권장 경로는 WSL2 Ubuntu 안에서 Bash 스크립트와 문서를 함께 사용하는 방식입니다. macOS와 Linux도 같은 흐름입니다.

1. OS별 환경 준비 문서([Windows WSL2](docs/00-environment-windows-wsl2.md), [macOS](docs/00-environment-macos.md), [Linux](docs/00-environment-linux.md))에서 Docker, kind 클러스터, CLI 도구를 준비합니다.
2. [01. Cilium 설치](docs/01-cilium-install.md)부터는 Helm으로 Cilium을 설치하고 검증합니다.

```bash
bash scripts/create-kind-cluster.sh
bash scripts/install-cilium-tools.sh
source scripts/use-local-tools.sh
```

Windows host PowerShell 실행은 지원 경로에서 제외합니다. Windows 사용자는 WSL2 Ubuntu 안에서 Bash 스크립트를 실행합니다.

`create-kind-cluster` 스크립트는 `kind`, `kubectl` CLI가 없으면 프로젝트 로컬 `tools/bin`에 자동 설치합니다. `install-cilium-tools` 스크립트는 `cilium`, `hubble` CLI를 같은 경로에 설치합니다. Cilium 설치 이후 단계는 문서의 수동 명령으로 학습합니다.

새 터미널에서 `kubectl` alias와 completion을 쓰려면 OS별 환경 준비 문서에 따라 셸 설정 파일에 로컬 도구 설정을 추가합니다. Bash 예시는 다음과 같습니다.

```bash
bash scripts/use-local-tools.sh --install-bashrc
source ~/.bashrc
```

Cilium 설치와 검증은 [01. Cilium 설치](docs/01-cilium-install.md)의 Helm, `cilium status`, `hubble status`, `cilium connectivity test --flow-validation disabled` 절차를 따릅니다. Hubble flow validation은 [06. kube-proxy Replacement](docs/06-kube-proxy-replacement.md)에서 별도로 검증합니다.

## 커리큘럼

1. 환경 준비: [Windows WSL2](docs/00-environment-windows-wsl2.md), [macOS](docs/00-environment-macos.md), [Linux](docs/00-environment-linux.md)
2. [Cilium 설치](docs/01-cilium-install.md)
3. [eBPF datapath 관찰](docs/02-ebpf-datapath.md)
4. [Hubble observability](docs/03-hubble-observability.md)
5. [NetworkPolicy와 CiliumNetworkPolicy](docs/04-network-policy.md)
6. [L7 policy](docs/05-l7-policy.md)
7. [kube-proxy replacement](docs/06-kube-proxy-replacement.md)
8. [Gateway API](docs/07-gateway-api.md)
9. [트러블슈팅](docs/08-troubleshooting.md)
10. [실전 운영 패턴](docs/09-production-patterns.md)
11. [전체 검증 체크리스트](docs/99-validation-checklist.md)

## 실전 시나리오

이 프로젝트는 단순 명령 실행보다 운영에서 바로 응용할 수 있는 사례를 중심으로 구성합니다.

- 신규 서비스 배포 전 기본 deny 정책을 적용하고 필요한 통신만 허용합니다.
- DNS/FQDN 기반 egress 정책으로 외부 SaaS 접근을 제한합니다.
- HTTP method/path 기반 L7 정책으로 내부 API 호출 범위를 제한합니다.
- Hubble flow를 사용해 장애 신고 시 실제 차단 지점을 찾습니다.
- kube-proxy replacement 환경에서 Service, NodePort, LoadBalancer 동작을 검증합니다.
- Gateway API를 이용해 서비스별 라우팅과 외부 진입점을 관리합니다.
- 신규 서비스 온보딩에 사용할 zero-trust namespace baseline, SaaS egress allowlist, 내부 API L7 guardrail 예제를 제공합니다.

## 저장소 구조

```text
.
├── docs/
├── labs/
│   ├── kind/
│   ├── 01-install/
│   ├── 02-ebpf-datapath/
│   ├── 03-hubble/
│   ├── 04-network-policy/
│   ├── 05-l7-policy/
│   ├── 06-kube-proxy-replacement/
│   ├── 07-gateway-api/
│   ├── 08-troubleshooting/
│   └── 09-production-examples/
└── scripts/
    └── *.sh
```

## 정리

Windows WSL2/macOS/Linux Bash:

```bash
bash scripts/cleanup.sh
```

개별 랩에서 만든 리소스는 각 문서의 정리 절차를 우선 사용하고, 전체 클러스터를 제거할 때만 cleanup 스크립트를 실행합니다.
