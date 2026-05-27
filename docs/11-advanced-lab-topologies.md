# 11. Advanced Lab Topologies

## 학습 목표

- Advanced 과정에서 사용할 실습 환경 유형을 구분합니다.
- kind에서 가능한 검증과 VM/bare metal이 필요한 검증을 분리합니다.
- BGP, Egress Gateway, encryption, host firewall 실습의 환경 의존성을 이해합니다.

## 과정 구조

Advanced 과정은 `kind`를 기본 실습 환경으로 사용하되, 실제 네트워크 동작이 중요한 장은 선택 VM/bare metal 경로를 함께 제공합니다.

```text
11  Advanced lab topologies
12  Cluster Mesh
13  BGP Control Plane
14  Egress Gateway
15  kube-proxy replacement deep dive
16  Transparent Encryption
17  Gateway API Advanced & GAMMA
18  Mutual Auth & SPIRE
19  Policy Design at Scale & Host Firewall
20  Observability Metrics
21  Upgrade & Advanced Troubleshooting
```

## 환경 등급

| 등급 | 용도 | 예시 |
|---|---|---|
| kind core | 모든 사용자가 재현 가능한 기본 검증 | Cluster Mesh, Gateway split, metrics, 정책 설계 |
| kind + container peer | 라우터나 외부 endpoint를 컨테이너로 흉내냄 | BGP with FRR, egress source 확인 |
| VM/bare metal optional | 실제 NIC, routing, host namespace 효과 확인 | Egress Gateway, WireGuard/IPsec, host firewall |

## 공통 원칙

- 장마다 필요한 Kubernetes context를 먼저 명시합니다.
- 기존 basic 과정의 `cilium-study`와 `cilium-study-kpr`를 재사용하되, 다중 클러스터 실습은 별도 kind 클러스터를 사용합니다.
- 로컬 리소스가 제한된 환경에서는 Advanced 실습 클러스터를 동시에 여러 개 유지하지 않습니다.
- VM/bare metal 절차는 선택 심화로 두고, kind에서 가능한 최소 검증을 항상 제공합니다.
- 네트워크 주소는 예시로 쓰고, 실습 전 Docker/VM subnet과 충돌 여부를 확인합니다.

## 리소스 운영 기준

Advanced 실습은 기능별 datapath 옵션이 달라서 모든 장을 하나의 클러스터에 계속 누적하지 않습니다. 대신 다음 기준으로 클러스터를 관리합니다.

| 범위 | 권장 클러스터 | 리소스 기준 |
|---|---|---|
| 01-05, 09-10, 20-21 | `cilium-study` | 기본 클러스터로 재사용 |
| 06-08, 15, 17-18 | `cilium-study-kpr` | kube-proxy replacement 클러스터로 재사용 |
| 12 | `cilium-east`, `cilium-west` | Cluster Mesh 검증 중에만 두 클러스터를 유지하고, 완료 후 삭제 |
| 13 | `cilium-bgp` | BGP 검증용 선택 클러스터입니다. 12장 클러스터 삭제 후 진행 |
| 14 | `cilium-egress` | Egress Gateway 검증용 선택 클러스터입니다. 다른 선택 클러스터와 동시에 유지하지 않음 |
| 16 | `cilium-encryption` | Encryption 검증용 선택 클러스터입니다. 필요한 경우에만 생성 |

메모리나 CPU가 부족하면 `cilium-study-kpr`만 남기고 `cilium-east`, `cilium-west`, `cilium-bgp`, `cilium-egress`, `cilium-encryption`은 장별로 생성했다가 바로 삭제합니다.

## 준비 확인

macOS/Linux Bash:

```bash
source scripts/use-local-tools.sh
kind get clusters
kubectl config get-contexts
docker network inspect kind --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}'
cilium version --client
```

## 운영 관점

Advanced 주제는 기능을 켜는 것보다 실패 범위를 설계하는 것이 중요합니다.

- BGP와 L2 Announcement는 외부 노출 모델이 다릅니다.
- Egress Gateway와 FQDN policy는 서로 보완하지만 해결하는 문제가 다릅니다.
- encryption과 mutual auth는 보호 계층이 다릅니다.
- host firewall은 노드 접근까지 차단할 수 있으므로 별도 복구 경로가 필요합니다.

## 참고

- Cilium docs: https://docs.cilium.io/en/stable/
- Kubernetes Services: https://kubernetes.io/docs/concepts/services-networking/service/
