# 16. Transparent Encryption

## 학습 목표

- Cilium WireGuard/IPsec transparent encryption이 보호하는 구간을 이해합니다.
- Pod-to-Pod traffic encryption을 활성화하고 Cilium 상태와 실제 트래픽으로 검증합니다.
- encryption과 mTLS/mutual auth가 해결하는 문제가 어떻게 다른지 구분합니다.

## 왜 필요한가

Kubernetes Pod 트래픽은 보통 여러 노드를 지나갑니다. 같은 노드 안에서 Pod끼리 통신하면 노드 내부 datapath만 지나지만, 서로 다른 노드의 Pod가 통신하면 패킷은 노드 간 네트워크를 통과합니다.

클러스터가 단일 신뢰 경계 안에 있으면 이 구간을 평문으로 두는 경우도 많습니다. 하지만 bare metal, shared network, 여러 팀이 같이 쓰는 데이터센터, cloud VPC peering, 규제 환경에서는 노드 간 구간도 보호해야 합니다. Transparent encryption은 애플리케이션 코드를 바꾸지 않고 Cilium datapath에서 Pod traffic을 암호화하는 기능입니다.

Cilium에서는 대표적으로 두 가지 방식을 사용할 수 있습니다.

- WireGuard: Linux kernel WireGuard를 사용해 노드 간 암호화 터널을 구성합니다. 설정이 단순하고 이 장의 kind 실습에서 사용합니다.
- IPsec: XFRM/IPsec 기반 암호화입니다. 기존 네트워크 보안 운영 모델과 맞춰야 하는 환경에서 선택할 수 있습니다.

이 기능은 TLS나 mTLS를 대체하지 않습니다. Transparent encryption은 노드 간 네트워크 구간을 보호합니다. 애플리케이션이 누구와 통신하는지 인증하거나 HTTP request 단위 권한을 판단하지는 않습니다. 서비스 identity 인증, workload-to-workload 인증, request-level 인증은 mTLS/mutual auth 영역입니다.

## 이 장에서 확인할 것

이 장의 실습은 다음 흐름을 확인합니다.

```text
Cilium WireGuard encryption 활성화
  -> Cilium agent가 encryption enabled 상태로 기동
  -> 노드별 WireGuard peer/encrypt 정보 생성
  -> frontend Pod에서 api Pod로 통신 성공
  -> 서로 다른 노드의 Pod IP를 직접 호출해 cross-node traffic 생성
```

중요한 통과 기준은 "HTTP 응답이 암호문처럼 보이는가"가 아닙니다. Pod 안에서 `curl`을 실행하면 애플리케이션은 평소처럼 HTTP JSON 응답을 봅니다. 암호화는 Pod와 애플리케이션 바깥, 노드 간 네트워크 구간에서 적용됩니다.

kind에서는 Docker 네트워크와 노드 컨테이너 구조 때문에 packet capture 검증이 환경마다 다를 수 있습니다. 따라서 kind 기본 검증은 "Cilium encryption 상태 정상 + cross-node Pod 통신 성공"을 기준으로 삼고, 실제 wire에서 평문 payload가 보이지 않는지는 VM/bare metal에서 선택 검증합니다.

## 사전 조건

`cilium-encryption`은 encryption datapath 검증용 선택 클러스터입니다. 리소스가 부족하면 BGP/Egress/Cluster Mesh 선택 클러스터를 삭제한 뒤 진행합니다.

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-encryption --config labs/kind/kind-cilium-encryption.yaml
kubectl config use-context kind-cilium-encryption
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/16-transparent-encryption/cilium-wireguard-values.yaml
cilium status --wait
```

이 클러스터는 `labs/16-transparent-encryption/cilium-wireguard-values.yaml`로 Cilium을 설치합니다.

```yaml
encryption:
  enabled: true
  type: wireguard
```

즉 지금 켜는 것은 Ingress/Gateway TLS가 아니라 Cilium datapath의 노드 간 WireGuard encryption입니다.

## 1. WireGuard 상태 확인

먼저 Cilium agent가 encryption 기능을 켠 상태로 동작하는지 확인합니다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -i encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

여기서 보는 것은 애플리케이션 통신 결과가 아니라 Cilium datapath 상태입니다.

확인할 결과:

- encryption 또는 WireGuard가 enabled 상태여야 합니다.
- `cilium-dbg encrypt status`에서 노드 간 encryption 관련 정보가 보여야 합니다.
- Cilium agent가 Ready 상태여야 합니다.

이 단계가 실패하면 뒤에서 `curl`이 성공하더라도 encryption 검증은 통과로 보지 않습니다. 트래픽이 되는 것과 암호화 datapath가 켜진 것은 별개의 확인 항목입니다.

## 2. 샘플 앱 배포

이 장에서는 02장에서 사용한 `frontend`와 `api` 샘플을 재사용합니다.

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl -n app rollout status deploy/frontend --timeout=120s
kubectl -n app rollout status deploy/api --timeout=120s
kubectl -n app get pod -o wide
```

`frontend`는 `curl`을 실행할 client 역할이고, `api`는 HTTP 응답을 반환하는 backend 역할입니다. `-o wide` 출력에서 각 Pod의 `NODE`를 봅니다. Transparent encryption에서 의미 있는 트래픽은 서로 다른 노드에 있는 Pod 사이의 트래픽입니다.

## 3. 기본 통신 확인

먼저 Service 이름으로 호출해 애플리케이션이 정상인지 확인합니다.

```bash
frontend_pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get
```

확인할 결과:

- httpbin JSON 응답이 반환되어야 합니다.
- 이 결과는 encryption을 켠 뒤에도 일반 Pod-to-Service 통신이 깨지지 않았다는 의미입니다.

다만 이 호출만으로는 노드 간 암호화 검증이 끝나지 않습니다. `http://api/get`은 Service load balancing을 거치기 때문에 같은 노드에 있는 `api` Pod로 전달될 수 있습니다.

## 4. Cross-node 트래픽 만들기

노드 간 암호화 경로를 검증하려면 호출하는 `frontend` Pod와 호출 대상 `api` Pod가 서로 다른 노드에 있어야 합니다. Service를 거치지 않고 다른 노드의 `api` Pod IP를 직접 골라 호출합니다.

```bash
frontend_pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
frontend_node="$(kubectl -n app get pod "$frontend_pod" -o jsonpath='{.spec.nodeName}')"

api_pod=""
api_ip=""
for candidate in $(kubectl -n app get pod -l app=api -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  candidate_node="$(kubectl -n app get pod "$candidate" -o jsonpath='{.spec.nodeName}')"
  if [[ "$candidate_node" != "$frontend_node" ]]; then
    api_pod="$candidate"
    api_ip="$(kubectl -n app get pod "$candidate" -o jsonpath='{.status.podIP}')"
    break
  fi
done

echo "frontend=$frontend_pod node=$frontend_node"
echo "api=$api_pod ip=$api_ip"
if [[ -z "$api_ip" ]]; then
  echo "No api Pod was found on a different node from $frontend_pod." >&2
  exit 1
fi
kubectl -n app exec "$frontend_pod" -- curl -sS "http://${api_ip}:8080/get"
```

확인할 결과:

- `frontend`와 `api`의 `node` 값이 달라야 합니다.
- 마지막 `curl`에서 httpbin JSON 응답이 반환되어야 합니다.
- 이 호출은 Service load balancing을 우회하고 특정 `api` Pod IP로 직접 가므로, cross-node Pod-to-Pod 트래픽을 만들었다고 볼 수 있습니다.

`api_pod`나 `api_ip`가 비어 있으면 현재 Pod 배치상 다른 노드의 backend를 찾지 못한 상태입니다. 이 경우 Pod를 다시 배치한 뒤 확인합니다.

```bash
kubectl -n app rollout restart deploy/api
kubectl -n app rollout status deploy/api --timeout=120s
kubectl -n app get pod -o wide
```

그래도 같은 노드에만 배치되면 `frontend`도 다시 배치합니다.

```bash
kubectl -n app rollout restart deploy/frontend
kubectl -n app rollout status deploy/frontend --timeout=120s
kubectl -n app get pod -o wide
```

## 5. 결과 해석

이 실습에서 확인한 것은 세 가지입니다.

- Cilium이 WireGuard encryption enabled 상태로 동작합니다.
- 암호화를 켠 뒤에도 Service 통신이 정상입니다.
- 서로 다른 노드에 있는 Pod IP를 직접 호출해 cross-node Pod traffic이 정상 동작합니다.

중요한 점:

- Pod 안에서 HTTP 응답이 JSON으로 보이는 것은 정상입니다. Transparent encryption은 애플리케이션 payload를 Pod 내부에서 암호문으로 바꾸는 기능이 아닙니다.
- 같은 노드에 있는 Pod 간 트래픽은 노드 간 WireGuard 암호화 경로를 타지 않을 수 있습니다.
- Service 호출은 backend 선택이 load balancing에 의해 결정되므로 cross-node 검증으로는 부족합니다.
- kind 기본 검증에서는 packet capture를 필수 통과 기준으로 삼지 않습니다.

## 암호화됐다는 것을 어떻게 확인하는가

`curl` 응답이 JSON 평문으로 도착하는 것은 정상입니다. Transparent encryption은 애플리케이션이 보는 데이터를 암호문으로 바꾸는 기능이 아닙니다. 송신 Pod는 평문 HTTP를 보내고, Cilium이 노드 밖으로 내보내기 전에 암호화합니다. 수신 노드의 Cilium은 복호화한 뒤 목적지 Pod에 평문 HTTP를 전달합니다.

따라서 확인 위치에 따라 보이는 내용이 다릅니다.

| 확인 위치 | 기대 결과 | 의미 |
|---|---|---|
| Pod 내부 `curl` | JSON 평문 응답 | 애플리케이션 통신이 정상 |
| `cilium-dbg encrypt status` | WireGuard enabled, peer 정보 | Cilium encryption datapath가 켜짐 |
| `cilium_wg0` | Pod IP 간 트래픽 | 트래픽이 WireGuard tunnel device를 통과 |
| 노드 간 underlay interface | UDP 51871 중심, HTTP payload 미노출 | wire 구간에서 암호화됨 |

즉 "응답이 암호화됐다"는 것은 Pod 안에서 암호문이 보인다는 뜻이 아닙니다. 노드 간 네트워크에서 평문 HTTP payload가 보이지 않는다는 뜻입니다.

WireGuard 상태와 peer는 다음처럼 확인합니다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep Encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

`jq`가 준비된 환경에서는 `kubectl -n kube-system exec ds/cilium -- cilium-dbg debuginfo --output json | jq .encryption`로 peer의 allowed IP와 handshake 정보까지 더 자세히 볼 수 있습니다.

WireGuard tunnel device를 지나가는지 보려면 Cilium Pod 안에서 `cilium_wg0`를 캡처합니다. 이 캡처는 "암호문 확인"이 아니라 "WireGuard tunnel 경로를 탔다"는 확인입니다.

```bash
kubectl -n kube-system exec -it ds/cilium -- bash
apt-get update
apt-get -y install tcpdump
tcpdump -n -i cilium_wg0
```

진짜 wire 암호화 여부는 node의 underlay interface에서 봐야 합니다. VM/bare metal에서는 node interface에서 캡처했을 때 HTTP `GET /get`이나 JSON payload가 보이지 않고, 노드 IP 사이의 WireGuard UDP 트래픽이 보여야 합니다. Cilium WireGuard tunnel endpoint 기본 포트는 UDP `51871`입니다.

```bash
tcpdump -n -i eth0 'udp port 51871'
tcpdump -A -i eth0 'tcp port 8080'
```

첫 번째 명령에서 노드 간 UDP 51871 트래픽이 보이고, 두 번째 명령에서 노드 간 구간의 HTTP payload가 보이지 않는 것이 기대 결과입니다. 단, interface 이름은 환경마다 `eth0`, `ens*`, `bond*`처럼 다를 수 있습니다.

## Optional: VM/bare metal packet capture

VM/bare metal 환경에서는 node interface에서 packet capture를 수행해 노드 간 구간에 평문 HTTP payload가 노출되지 않는지 확인합니다.

검증할 때는 다음 조건을 먼저 맞춥니다.

- client Pod와 server Pod가 서로 다른 노드에 있어야 합니다.
- Service가 아니라 server Pod IP를 직접 호출해야 합니다.
- packet capture 위치는 Pod 내부가 아니라 노드 간 interface여야 합니다.

기대 결과:

- Pod 안에서는 `curl http://<api-pod-ip>:8080/get`이 성공합니다.
- 노드 간 interface 캡처에서는 HTTP payload가 평문으로 보이지 않아야 합니다.
- WireGuard를 사용하면 노드 간 구간에서 WireGuard UDP 트래픽이 보이는 것이 기대 결과입니다.

## 운영 관점

- WireGuard/IPsec은 네트워크 구간 암호화이고, 애플리케이션 identity 인증은 아닙니다.
- mutual auth/mTLS는 서비스 identity와 request-level 인증을 다룹니다.
- encryption enable/disable은 datapath 변경이므로 change window와 rollback 절차가 필요합니다.
- MTU, tunnel mode, cloud network offload와 함께 검증합니다.
- 운영 검증은 Cilium 상태, cross-node 통신, packet capture, 성능/MTU 영향까지 분리해서 봅니다.

## 실패 시 확인

```bash
cilium status
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i encrypt
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
kubectl -n app get pod -o wide
```

문제 분리 기준:

- `cilium-dbg encrypt status`가 비정상이면 Cilium encryption 설정 또는 agent 상태 문제입니다.
- Service 호출만 실패하면 앱, Service, DNS, policy 문제를 먼저 봅니다.
- Service 호출은 성공하지만 Pod IP 직접 호출이 실패하면 cross-node routing/datapath 문제를 의심합니다.
- Pod가 같은 노드에만 있으면 노드 간 encryption 검증이 되지 않은 상태입니다.

## 참고

- WireGuard encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/

## 정리

```bash
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml --ignore-not-found
kind delete cluster --name cilium-encryption
```
