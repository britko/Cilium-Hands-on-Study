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

- Windows 10/11 + PowerShell 7 이상
- macOS 또는 Linux + Bash
- Docker Desktop, Docker Engine, Colima, Rancher Desktop 등 kind를 구동할 수 있는 컨테이너 런타임
- `kind`, `kubectl`, `helm`, `cilium`, `hubble`
- Kubernetes in Docker cluster

기본 실습은 Cilium `1.19.x` 안정 버전을 기준으로 작성했습니다. Gateway API 실습은 Cilium `1.19.x` 안정 문서 기준인 Gateway API CRD `v1.4.1`을 사용합니다.

## 빠른 시작

Windows PowerShell:

```powershell
.\scripts\create-kind-cluster.ps1
.\scripts\install-cilium.ps1
.\scripts\validate.ps1
```

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh
bash scripts/install-cilium.sh
bash scripts/validate.sh
```

설치가 끝나면 다음 명령으로 기본 상태를 확인합니다.

```powershell
cilium status --wait
cilium connectivity test
hubble status
```

## 커리큘럼

1. [환경 준비](docs/00-environment.md)
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
    ├── *.ps1
    └── *.sh
```

## 정리

Windows PowerShell:

```powershell
.\scripts\cleanup.ps1
```

macOS/Linux Bash:

```bash
bash scripts/cleanup.sh
```

개별 랩에서 만든 리소스는 각 문서의 정리 절차를 우선 사용하고, 전체 클러스터를 제거할 때만 cleanup 스크립트를 실행합니다.
