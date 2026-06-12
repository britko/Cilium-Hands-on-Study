# 15. kube-proxy Replacement Deep Dive

## 학습 목표

- Cilium eBPF Service load balancing 경로를 더 깊게 관찰합니다.
- NodePort, LoadBalancer, externalTrafficPolicy, source IP 보존의 차이를 확인합니다.
- SNAT, DSR, Hybrid 같은 운영 모드의 선택 기준을 이해합니다.

## 사전 조건

이 장은 kube-proxy 없이 만든 `cilium-study-kpr` 클러스터에서 진행합니다. [06. kube-proxy Replacement](06-kube-proxy-replacement.md)를 진행한 뒤 클러스터를 남겨 두었다면 그대로 재사용합니다.

```bash
kubectl config use-context kind-cilium-study-kpr
cilium status --wait
```

리소스 부족으로 `cilium-study-kpr`를 삭제했다면 다시 생성한 뒤 이어갑니다. 06장의 `nodeport-demo` 리소스는 없어도 됩니다. 이 장은 `labs/15-kpr-deep-dive/source-ip-demo.yaml`만 새로 적용합니다.

```bash
bash scripts/create-kind-cluster.sh \
  --cluster-name cilium-study-kpr \
  --config labs/kind/kind-cilium-kpr.yaml

kubectl config use-context kind-cilium-study-kpr

helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-kpr-values.yaml

cilium hubble enable --ui
cilium status --wait
```

어느 경로로 시작했든 kube-proxy가 없는 클러스터인지 확인합니다.

```bash
kubectl -n kube-system get ds kube-proxy
```

`kube-proxy` DaemonSet이 없어야 합니다.

## Service map 관찰

```bash
kubectl apply -f labs/15-kpr-deep-dive/source-ip-demo.yaml
kubectl -n kpr-deep get svc,pod -o wide
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
```

`source-ip-demo.yaml`은 `DaemonSet`으로 각 node에 echo backend를 배치합니다. localhost NodePort는 kind control-plane node로 들어가므로, `externalTrafficPolicy: Local` Service도 control-plane의 local backend로 응답할 수 있어야 합니다.

## externalTrafficPolicy 비교

`Cluster`와 `Local` Service를 각각 호출하고 backend가 보는 source IP를 비교합니다.

```bash
curl -sS http://127.0.0.1:30081/ip
curl -sS http://127.0.0.1:30082/ip
```

`labs/kind/kind-cilium-kpr.yaml`은 30081, 30082 NodePort를 localhost로 매핑하므로 위 `curl`은 kind를 실행한 host에서 실행합니다.

`/ip` 응답의 `origin` 값이 backend가 관찰한 client 주소입니다. kind에서는 이 값이 실제 노트북/VM의 외부 주소가 아니라 Docker bridge나 node 경로의 주소로 보일 수 있습니다.

`externalTrafficPolicy: Cluster`는 트래픽이 들어온 node에 backend가 없어도 다른 node의 backend로 전달할 수 있습니다. 대신 중간 node에서 SNAT이 발생할 수 있어 backend가 실제 client IP 대신 node IP를 볼 수 있습니다. `externalTrafficPolicy: Local`은 트래픽이 들어온 node의 local backend로만 전달하므로 source IP 보존에 유리하지만, 해당 node에 backend가 없으면 응답할 수 없습니다.

kind의 localhost port mapping은 실제 외부 LoadBalancer와 다릅니다. 여기서는 Cilium service map과 local backend 조건을 관찰하는 데 집중하고, 실제 client IP 보존 여부는 VM/bare metal 또는 cloud LoadBalancer 환경에서 다시 검증합니다.

## Source IP 보존 설계

source IP 보존은 감사 로그, rate limit, WAF/ACL, 결제사/파트너 연동, abuse 대응에서 중요합니다. 하지만 Kubernetes Service, Cilium load balancer mode, 외부 LoadBalancer, 라우터 return path가 모두 맞아야 기대한 IP가 backend까지 도달합니다.

먼저 source IP가 필요한 Service와 필요 없는 Service를 나눕니다.

- source IP가 필요한 경우: 인증/감사 로그, client별 rate limit, 외부 파트너 allowlist, L7 보안 정책
- source IP가 덜 중요한 경우: 내부 stateless API, backend가 별도 identity header를 신뢰하는 구조, gateway/proxy에서 이미 client IP를 표준화하는 구조

Kubernetes Service 단위에서는 `externalTrafficPolicy`를 먼저 결정합니다.

| 설정 | 의미 | source IP 관점 |
|---|---|---|
| `Cluster` | 어떤 node로 들어와도 전체 backend로 전달 | 가용성과 분산은 쉽지만 SNAT으로 원본 IP가 사라질 수 있음 |
| `Local` | 트래픽이 들어온 node의 local backend로만 전달 | 원본 IP 보존에 유리하지만 node별 backend 배치와 health check가 중요 |

`Local`을 선택하면 Service backend가 모든 ingress 대상 node에 떠 있는지 확인해야 합니다. DaemonSet, topology spread, LoadBalancer health check, node drain 절차가 함께 설계되지 않으면 특정 node로 들어온 트래픽이 실패할 수 있습니다.

다음으로 Cilium의 load balancer mode를 결정합니다. 이 값은 Service YAML이 아니라 Cilium Helm values에 설정합니다.

```yaml
loadBalancer:
  mode: snat
```

현재 모드는 다음 명령으로 확인합니다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

출력의 `KubeProxyReplacement Details`에서 `Mode`를 확인합니다.

```text
KubeProxyReplacement Details:
  Mode: SNAT
```

## 운영 모드 선택

| 모드 | 장점 | 주의점 |
|---|---|---|
| SNAT | 기본 동작이 단순하고 return path가 안정적 | backend에서 원본 source IP가 보존되지 않을 수 있음 |
| DSR | 원본 source IP 보존과 효율적 return path | 네트워크 경로, MTU, 옵션 지원 확인 필요 |
| Hybrid | TCP/UDP 특성을 나눠 최적화 | 운영 설명과 장애 분석이 복잡해짐 |

SNAT 모드는 return path가 단순합니다. backend 응답이 다시 Cilium node를 거쳐 나가므로 경로 비대칭 문제가 적습니다. 대신 backend 애플리케이션은 실제 client IP 대신 node 또는 load balancer 경로의 IP를 볼 수 있습니다.

DSR 모드는 요청은 Cilium load balancer node를 거치지만 응답은 backend가 client로 직접 보낼 수 있게 설계합니다. 원본 source IP 보존과 효율적인 return path가 장점이지만, 외부 네트워크가 backend의 직접 응답 경로를 허용해야 하고 MTU, 방화벽, 라우팅, cloud fabric 지원 여부를 검증해야 합니다.

Hybrid 모드는 TCP와 UDP의 특성을 나눠 운영하는 선택지입니다. 특정 트래픽에는 DSR 장점을 쓰고 다른 트래픽은 SNAT처럼 안정적인 경로를 유지할 수 있지만, 장애 분석과 운영 설명이 복잡해집니다.

kind에서는 기본값인 `snat`로 Cilium service map과 `externalTrafficPolicy` 차이를 확인하는 데 집중합니다. `dsr`와 `hybrid`는 VM/bare metal 또는 cloud 환경에서 다음 항목까지 함께 검증합니다.

- backend access log에 기록되는 client IP
- 외부 client에서 본 응답 성공 여부와 return path
- node drain 또는 backend 축소 시 `externalTrafficPolicy: Local` Service의 health check 동작
- 방화벽/ACL이 backend의 직접 응답을 허용하는지 여부
- MTU, encapsulation, direct routing 환경에서 fragmentation이나 drop이 없는지 여부

## Optional: kind에서 mode 설정 확인

kind에서도 `loadBalancer.mode`를 바꿔 Cilium agent가 해당 모드로 기동되는지 확인할 수 있습니다. 다만 kind의 Docker 네트워크와 localhost port mapping은 실제 외부 LoadBalancer 경로가 아니므로, source IP 보존이나 DSR return path 검증을 통과 기준으로 삼지 않습니다.

이 섹션의 Helm 명령은 `labs/15-kpr-deep-dive/*.yaml` 또는 `labs/01-install/cilium-kpr-values.yaml`을 다시 적용합니다. 이 values 파일들은 Gateway API 설정을 포함하지 않습니다. 따라서 07장에서 Gateway API를 켰던 같은 `cilium-study-kpr` 클러스터를 이어 쓰는 경우, 이 섹션을 수행한 뒤에는 Gateway API controller 설정이 꺼졌을 수 있습니다. 17장은 이 상태 충돌을 피하기 위해 별도 `cilium-gateway-advanced` 클러스터에서 진행합니다.

검증 루트:

1. Helm values로 모드를 변경합니다.
2. Cilium agent가 재기동되어 ready 상태가 되는지 확인합니다.
3. `cilium-dbg status --verbose`에서 `Mode`가 기대값인지 확인합니다.
4. `cilium-dbg service list`에서 NodePort Service가 계속 BPF LB map에 올라오는지 확인합니다.
5. localhost NodePort 호출이 여전히 성공하는지 확인합니다.

DSR mode:

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/15-kpr-deep-dive/cilium-kpr-dsr-values.yaml

cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
curl -sS http://127.0.0.1:30081/ip
curl -sS http://127.0.0.1:30082/ip
```

Hybrid mode:

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/15-kpr-deep-dive/cilium-kpr-hybrid-values.yaml

cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
curl -sS http://127.0.0.1:30081/ip
curl -sS http://127.0.0.1:30082/ip
```

각 모드에서 출력의 `KubeProxyReplacement Details`를 확인합니다.

```text
KubeProxyReplacement Details:
  Mode: DSR
```

또는:

```text
KubeProxyReplacement Details:
  Mode: Hybrid
```

모드 확인 뒤 기본 실습 상태로 되돌립니다.

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-kpr-values.yaml

cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

되돌린 뒤 `Mode: SNAT`이면 기본 상태입니다.

kind 통과 기준:

- `cilium status --wait`가 성공함
- `KubeProxyReplacement Details`의 `Mode`가 기대값과 일치함
- `cilium-dbg service list`에 `0.0.0.0:30081/TCP`, `0.0.0.0:30082/TCP` NodePort가 보임
- `curl`이 두 NodePort 모두에서 응답함

kind에서 통과 기준으로 삼지 않는 것:

- backend가 보는 실제 외부 client IP
- DSR의 직접 return path
- 외부 LoadBalancer health check와 node별 endpoint 제거 동작
- 방화벽/라우터/MTU 영향

## Optional: VM/bare metal source IP 검증

DSR/Hybrid의 핵심은 backend가 실제 client IP를 볼 수 있고, 응답 경로가 네트워크에서 허용되는지입니다. 이 검증은 kind보다 VM/bare metal 또는 cloud 환경에서 수행합니다.

검증 루트:

1. 외부 client, Kubernetes node, backend Pod가 서로 다른 네트워크 관측 지점이 되도록 준비합니다.
2. `loadBalancer.mode`를 `snat`, `dsr`, `hybrid` 중 하나로 설정합니다.
3. `externalTrafficPolicy: Cluster`와 `Local` Service를 각각 호출합니다.
4. backend 응답 또는 access log에서 source IP를 확인합니다.
5. node별 backend 유무, drain, 방화벽, return path를 함께 확인합니다.

클러스터 상태 확인:

```bash
kubectl apply -f labs/15-kpr-deep-dive/source-ip-demo.yaml
kubectl -n kpr-deep get svc,pod -o wide
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

외부 client에서 node IP 또는 LoadBalancer IP로 접근합니다.

```bash
curl -sS http://<node-or-lb-ip>:30081/ip
curl -sS http://<node-or-lb-ip>:30082/ip
```

`origin` 값과 외부 client의 실제 IP를 비교합니다. 필요하면 backend가 보는 source IP를 애플리케이션 로그로도 확인합니다.

```bash
kubectl -n kpr-deep logs -l app=echo --tail=50
```

통과 기준:

- backend 응답 또는 access log에서 기대한 client IP가 관찰됨
- `externalTrafficPolicy: Local` Service는 backend가 있는 node만 healthy endpoint로 사용됨
- backend가 client로 응답하는 return path가 방화벽과 라우팅에서 허용됨
- node drain, backend 축소, 장애 상황에서 LoadBalancer health check가 잘못된 node로 트래픽을 보내지 않음

결과 해석 기준:

| 조합 | 기대 관찰 |
|---|---|
| `snat` + `Cluster` | 연결은 안정적이지만 backend source IP가 node/LB 경로의 IP로 보일 수 있음 |
| `snat` + `Local` | local backend가 있는 node에서는 원본 IP 보존 가능성이 높고, backend 없는 node는 제외되어야 함 |
| `dsr` + `Cluster` | backend가 원본 client IP를 볼 수 있어야 하며, backend의 직접 응답 경로가 성공해야 함 |
| `hybrid` + TCP | TCP는 DSR 경로 특성을 기대하고, UDP는 SNAT 경로 특성을 기대함 |

이 표와 다른 결과가 나오면 Cilium 설정만 보지 말고 외부 LoadBalancer, node 라우팅, reverse path filtering, 방화벽, MTU를 함께 확인합니다.

## 운영 관점

- source IP 보존이 필요한 서비스와 필요 없는 서비스를 구분합니다.
- cloud LB, on-prem router, Cilium LB 모드가 서로 다른 NAT를 만들 수 있습니다.
- Hubble flow, backend access log, 외부 client IP를 함께 비교해야 합니다.

## 실패 시 확인

```bash
kubectl -n kpr-deep describe svc
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

## 참고

- kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
