# 02. eBPF Datapath 관찰

## 학습 목표

- eBPF program과 BPF map이 Cilium datapath에서 맡는 역할을 이해합니다.
- Cilium endpoint, identity, service map의 의미를 이해합니다.
- Pod-to-Service 트래픽이 Cilium에서 어떻게 보이는지 확인합니다.
- 실전 장애 분석에 필요한 기본 조회 명령을 익힙니다.

## eBPF와 Cilium Datapath 기본 개념

eBPF는 Linux kernel 안의 정해진 hook 지점에서 실행되는 작은 프로그램입니다. Cilium은 이 프로그램을 사용해 Kubernetes Pod 트래픽의 forwarding, Service load balancing, NetworkPolicy enforcement, observability event 생성을 처리합니다.

Cilium을 볼 때는 다음 두 가지를 구분하면 이해가 쉽습니다.

- BPF program: 패킷이 들어왔을 때 어떤 처리를 할지 결정하는 커널 내부 로직입니다.
- BPF map: program이 결정을 내릴 때 참조하는 상태 저장소입니다. Service frontend/backend, endpoint, identity, IP-to-identity mapping 같은 정보가 들어갑니다.

사용자는 보통 BPF program 자체를 직접 읽기보다, Cilium agent가 관리하는 endpoint, identity, service, BPF map을 조회하면서 datapath 상태를 확인합니다.

## Kubernetes 트래픽에서 Cilium이 보는 것

이 장의 샘플 앱은 다음 흐름을 만듭니다.

```text
frontend Pod -> api ClusterIP Service -> api backend Pod
```

기본 Kubernetes Service는 "Service IP로 들어온 트래픽을 backend Pod 중 하나로 보낸다"는 추상화를 제공합니다. Cilium은 이 추상화를 datapath에서 처리하기 위해 Service 정보와 endpoint 정보를 BPF map에 반영합니다.

흐름을 단순화하면 다음과 같습니다.

1. `frontend` Pod가 `api` Service로 요청을 보냅니다.
2. Cilium datapath가 Service frontend를 조회합니다.
3. BPF load-balancing map에서 backend Pod를 선택합니다.
4. ipcache와 identity 정보를 사용해 목적지 endpoint와 security identity를 확인합니다.
5. 정책상 허용되면 backend Pod로 패킷을 전달하고, Hubble이 볼 수 있는 flow event를 생성합니다.

여기서 중요한 점은 Cilium 정책 판단이 Pod IP만으로 끝나지 않는다는 것입니다. Cilium은 Kubernetes label을 기반으로 security identity를 만들고, datapath에서는 이 identity를 사용해 통신을 허용하거나 차단합니다. Pod가 재생성되어 IP가 바뀌어도 같은 label set이면 같은 정책 의도를 유지할 수 있습니다.

## Cilium 상태 객체와 BPF map 연결

| 조회 대상 | 의미 | 장애 분석에서 보는 이유 |
|---|---|---|
| Endpoint | Cilium이 관리하는 로컬 Pod datapath 상태 | Pod가 Cilium datapath에 붙었는지 확인 |
| Identity | Label set에 대응하는 security identity | 정책이 IP가 아니라 workload 정체성 기준으로 적용되는지 확인 |
| Service | Kubernetes Service frontend와 backend mapping | Service selector, EndpointSlice, Cilium service 상태를 연결 |
| `bpf lb` map | 커널 datapath에서 참조하는 Service load-balancing 상태 | Service가 BPF datapath에 반영되었는지 확인 |
| `bpf ipcache` map | IP/CIDR과 identity의 mapping | 목적지 IP가 어떤 identity로 인식되는지 확인 |

문제가 생겼을 때는 Kubernetes 객체와 Cilium 상태를 함께 봐야 합니다. 예를 들어 Service 호출이 실패할 때 `Service`와 `EndpointSlice`가 정상인데 `cilium-dbg service list`나 `bpf lb list`에 반영되지 않았다면 Cilium agent 쪽 동기화 문제를 의심할 수 있습니다. 반대로 EndpointSlice가 비어 있다면 Cilium 문제가 아니라 Service selector나 Pod readiness 문제일 가능성이 큽니다.

## 샘플 앱 배포

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl -n app rollout status deploy/frontend
kubectl -n app rollout status deploy/api
```

트래픽을 발생시킵니다.

macOS/Linux Bash:

```bash
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

## Endpoint와 Identity 확인

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list
kubectl -n app get pods --show-labels -o wide
```

로컬 `cilium` CLI는 클러스터 설치, 상태 확인, connectivity test 같은 외부 제어용 명령입니다. Endpoint, identity, service map처럼 Cilium agent가 노드 안에서 관리하는 datapath 상태는 Cilium DaemonSet 안의 `cilium-dbg`로 확인합니다.

관찰 포인트:

- 같은 label set을 가진 Pod는 같은 security identity를 공유합니다.
- Cilium policy는 Pod IP보다 identity와 label을 중심으로 동작합니다.
- Pod가 재생성되어 IP가 바뀌어도 identity 기반 정책은 유지됩니다.
- `endpoint list`에서 Pod가 보이지 않으면 해당 노드의 Cilium agent가 endpoint를 관리하지 못하는 상태일 수 있습니다.

## Service Datapath 확인

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n app get svc api -o wide
kubectl -n app get endpointslice -l kubernetes.io/service-name=api
```

Service 조회 결과는 Kubernetes control plane 상태와 Cilium datapath 상태를 나란히 비교하기 위한 것입니다.

- `kubectl get svc`: Service frontend인 ClusterIP와 port를 확인합니다.
- `kubectl get endpointslice`: 실제 backend Pod IP와 port를 확인합니다.
- `cilium-dbg service list`: Cilium agent가 Service frontend/backend mapping을 알고 있는지 확인합니다.

실무에서 Service 장애를 볼 때는 다음 순서로 확인합니다.

1. Service selector가 실제 Pod label과 맞는지 확인합니다.
2. EndpointSlice에 backend Pod가 있는지 확인합니다.
3. `cilium-dbg service list`에 frontend/backend mapping이 반영되었는지 확인합니다.
4. Hubble에서 DROP 또는 FORWARDED flow를 확인합니다.

## Cilium Agent 내부 상태

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ipcache list
```

`cilium-dbg`는 Cilium agent 컨테이너 안에서 datapath 상태를 더 자세히 볼 때 사용합니다. 현재 Cilium 버전에서는 전체 BPF map을 한 번에 나열하는 방식보다 목적별 하위 명령을 사용합니다.

- `bpf lb list`: Service frontend와 backend Pod mapping을 확인합니다.
- `bpf endpoint list`: 로컬 노드의 endpoint map을 확인합니다.
- `bpf ipcache list`: Pod IP, node IP, CIDR과 security identity mapping을 확인합니다.

이 명령들은 Cilium agent의 Kubernetes 객체 해석 결과가 실제 BPF datapath 상태로 내려갔는지 확인할 때 사용합니다. 일반적인 학습 단계에서는 `endpoint list`, `identity list`, `service list`만으로 충분하고, 장애 분석이나 kube-proxy replacement 검증에서는 `bpf` 하위 명령까지 확인합니다.

## Datapath 관찰 루틴

Pod-to-Service 통신이 실패할 때는 다음 순서로 원인을 좁힙니다.

1. 애플리케이션 Pod가 요청을 실제로 보내는지 확인합니다.
2. Service selector와 EndpointSlice로 Kubernetes Service 구성이 맞는지 확인합니다.
3. `cilium-dbg endpoint list`로 Cilium endpoint가 생성되었는지 확인합니다.
4. `cilium-dbg identity list`와 `bpf ipcache list`로 IP와 identity 연결을 확인합니다.
5. `cilium-dbg service list`와 `bpf lb list`로 Service mapping이 datapath에 반영되었는지 확인합니다.
6. Hubble에서 `FORWARDED`인지 `DROPPED`인지 확인해 정책/라우팅/애플리케이션 문제를 분리합니다.

이 순서를 따르면 "Cilium이 문제다" 또는 "애플리케이션이 문제다"로 바로 결론 내리지 않고, Kubernetes 객체, Cilium agent 상태, BPF datapath 상태, flow 관측을 단계적으로 연결할 수 있습니다.

## 실전 예시: Pod IP 변경 후 통신 확인

운영에서 배포나 노드 장애로 Pod IP는 계속 바뀝니다. Cilium 정책이 label/identity 기반으로 유지되는지 확인합니다.

macOS/Linux Bash:

```bash
kubectl -n app delete pod -l app=api
kubectl -n app rollout status deploy/api
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

## 정리

```bash
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml
```

다음 장에서 같은 앱을 계속 사용하려면 삭제하지 않아도 됩니다.
