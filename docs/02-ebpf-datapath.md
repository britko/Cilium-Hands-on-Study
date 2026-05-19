# 02. eBPF Datapath 관찰

## 학습 목표

- Cilium endpoint, identity, service map의 의미를 이해합니다.
- Pod-to-Service 트래픽이 Cilium에서 어떻게 보이는지 확인합니다.
- 실전 장애 분석에 필요한 기본 조회 명령을 익힙니다.

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

## Service Datapath 확인

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n app get svc api -o wide
kubectl -n app get endpointslice -l kubernetes.io/service-name=api
```

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
