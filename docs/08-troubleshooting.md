# 08. 트러블슈팅

## 학습 목표

- Cilium 환경에서 네트워크 장애를 재현하고 원인을 좁힙니다.
- Hubble, Cilium CLI, Kubernetes 기본 명령을 함께 사용합니다.
- 운영 장애 대응용 점검 순서를 익힙니다.

## 표준 점검 루틴

장애가 발생하면 다음 순서로 확인합니다.

```bash
cilium status
cilium connectivity test
kubectl get pods -A -o wide
hubble observe --last 5m
kubectl -n kube-system logs -l k8s-app=cilium --tail=100
```

더 깊은 분석이 필요하면 sysdump를 생성합니다.

```bash
cilium sysdump --output-filename cilium-sysdump.zip
```

운영 환경에서는 sysdump에 민감 정보가 포함될 수 있으므로 외부 공유 전에 검토합니다.

## 장애 1: Service selector 오류

샘플 앱을 배포합니다.

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl apply -f labs/08-troubleshooting/broken-service-selector.yaml
```

호출합니다.

Windows WSL2/macOS/Linux Bash:

```bash
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -m 3 -sS http://api-broken/get
```

진단:

```bash
kubectl -n app get svc api-broken -o wide
kubectl -n app get endpointslice -l kubernetes.io/service-name=api-broken
cilium service list
```

원인:

- Service selector가 `app=does-not-exist`라 endpoint가 없습니다.
- Cilium 문제가 아니라 Kubernetes Service와 label 설계 문제입니다.

복구:

```bash
kubectl -n app patch service api-broken -p '{"spec":{"selector":{"app":"api"}}}'
kubectl -n app get endpointslice -l kubernetes.io/service-name=api-broken
```

## 장애 2: DNS egress 누락

DNS 허용 없이 API Pod만 허용하는 정책을 적용합니다.

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/08-troubleshooting/deny-dns-egress.yaml
kubectl -n app exec "$pod" -- curl -m 5 -sS http://api/get
```

진단:

```bash
hubble observe --namespace app --protocol dns --last 5m
hubble observe --namespace app --verdict DROPPED --last 5m
kubectl -n app get cnp frontend-deny-dns-by-omission -o yaml
```

원인:

- `frontend`가 `api` Service 이름을 해석하려면 CoreDNS로 egress해야 합니다.
- 정책에는 `app=api` endpoint만 허용되어 DNS 요청이 차단됩니다.

복구:

```bash
kubectl delete -f labs/08-troubleshooting/deny-dns-egress.yaml
kubectl apply -f labs/04-network-policy/cilium-fqdn-egress.yaml
```

## 장애 3: Cilium agent 문제 의심

정책과 Service가 정상인데도 여러 namespace에서 통신 장애가 발생하면 Cilium agent 상태를 봅니다.

```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system describe pods -l k8s-app=cilium
kubectl -n kube-system logs -l k8s-app=cilium --tail=200
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

판단 기준:

- 특정 노드의 Cilium agent만 NotReady면 해당 노드의 Pod만 영향받을 수 있습니다.
- 모든 agent가 NotReady면 Helm values, API server 접근, kernel 기능, CRD 상태를 확인합니다.
- Hubble flow가 전혀 없으면 Hubble Relay/UI 문제가 아니라 datapath 또는 agent 문제일 수 있습니다.

## 장애 4: connectivity test의 json-mock CrashLoopBackOff

`cilium connectivity test` 실행 중 `cilium-test-1` namespace의 `echo-same-node` Pod가 `CrashLoopBackOff`가 될 수 있습니다.

예시:

```bash
kubectl get pods -A -o wide
kubectl -n cilium-test-1 describe pod -l name=echo-same-node
```

증상:

```text
echo-same-node-...   1/2   CrashLoopBackOff
Readiness probe failed: dial tcp <pod-ip>:8080: connect: connection refused
```

`echo-same-node` 컨테이너 로그를 확인합니다.

```bash
pod="$(kubectl -n cilium-test-1 get pod -l name=echo-same-node -o jsonpath='{.items[0].metadata.name}')"
kubectl -n cilium-test-1 logs "$pod" -c echo-same-node --previous
```

대표 로그:

```text
Error: EMFILE: too many open files, watch '/'
    at FSWatcher.<computed> (node:internal/fs/watchers:254:19)
```

### 원인

이 경우 원인은 Cilium datapath가 아니라 테스트용 애플리케이션 컨테이너의 파일 watcher 한도입니다.

`cilium connectivity test`는 여러 테스트 Pod를 만들고, 그중 `echo-same-node`는 `quay.io/cilium/json-mock` 이미지를 사용합니다. 이 이미지는 Node.js 기반 `json-server`를 실행하며 시작 시 파일 변경 감시 watcher를 생성합니다. kind 노드는 Docker/Colima 컨테이너 안에서 실행되므로 노드 컨테이너의 프로세스 한도와 Linux sysctl 값을 물려받습니다. 이 한도가 낮으면 `json-server`가 `/` 경로 watch를 만들다가 `EMFILE`로 종료됩니다.

확인:

```bash
docker exec cilium-study-worker2 sh -c '
  echo "nofile=$(ulimit -n)"
  echo "max_user_instances=$(cat /proc/sys/fs/inotify/max_user_instances)"
  echo "max_user_watches=$(cat /proc/sys/fs/inotify/max_user_watches)"
'
```

문제가 발생한 환경에서는 다음처럼 낮은 값이 보일 수 있습니다.

```text
nofile=1024
max_user_instances=128
max_user_watches=1048576
```

### 설정값 의미

`nofile`:

- 프로세스가 동시에 열 수 있는 file descriptor 수입니다.
- 파일, socket, pipe, inotify descriptor 등이 여기에 포함됩니다.
- kind 노드 안의 `containerd`와 `kubelet` 한도가 낮으면 새로 생성되는 컨테이너도 낮은 한도를 물려받을 수 있습니다.
- 이 실습에서는 `1048576`으로 올려 테스트 컨테이너가 충분한 descriptor를 사용할 수 있게 합니다.

`fs.inotify.max_user_instances`:

- 같은 사용자 기준으로 만들 수 있는 inotify instance 개수입니다.
- Node.js, webpack, json-server처럼 파일 변경 감시를 사용하는 프로세스가 영향을 받습니다.
- 기본값이 `128`이면 테스트 Pod나 다른 watcher 사용 프로세스가 겹칠 때 부족할 수 있습니다.
- 이 실습에서는 `8192`로 올립니다.

`fs.inotify.max_user_watches`:

- inotify가 감시할 수 있는 파일/디렉터리 watch 개수입니다.
- 디렉터리 트리를 넓게 감시하는 도구는 watch를 많이 소비합니다.
- 이 실습에서는 일반적인 개발 환경에서 넉넉한 값인 `1048576`을 사용합니다.

이 값들은 kind 노드 컨테이너 내부에 적용되는 실습용 보정입니다. 운영 Kubernetes 노드에서는 노드 OS 기준, 워크로드 특성, 보안 정책, 시스템 전체 리소스 한도를 함께 검토해야 합니다.

### 해결 방법

이 저장소의 `create-kind-cluster.sh`는 kind 클러스터 생성 또는 기존 클러스터 감지 후 각 kind 노드에 다음 값을 자동 적용합니다.

```bash
KIND_NODE_NOFILE_LIMIT=1048576
KIND_NODE_INOTIFY_MAX_USER_INSTANCES=8192
KIND_NODE_INOTIFY_MAX_USER_WATCHES=1048576
```

새 클러스터를 만들 때는 일반 환경 준비 절차를 다시 실행하면 됩니다.

```bash
bash scripts/create-kind-cluster.sh
```

이미 떠 있는 클러스터에서 즉시 복구하려면 각 kind 노드에 수동으로 적용합니다.

```bash
for node in $(kind get nodes --name cilium-study); do
  docker exec "$node" sysctl -w fs.inotify.max_user_instances=8192
  docker exec "$node" sysctl -w fs.inotify.max_user_watches=1048576

  for pid in $(docker exec "$node" sh -c 'pidof containerd kubelet 2>/dev/null || true'); do
    docker exec "$node" prlimit --pid "$pid" --nofile=1048576:1048576
  done
done
```

기존에 `CrashLoopBackOff`가 된 Pod는 낮은 한도에서 이미 시작됐으므로 삭제해서 새 설정을 물려받게 합니다.

```bash
kubectl -n cilium-test-1 delete pod -l name=echo-same-node
```

### 결과 확인

Pod가 다시 생성된 뒤 `2/2 Running`이어야 합니다.

```bash
kubectl -n cilium-test-1 get pod -l name=echo-same-node -o wide
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

정상 예시:

```text
echo-same-node-...   2/2   Running   0
No resources found
```

이후 connectivity test를 다시 실행합니다.

```bash
cilium connectivity test
```

## 실전 운영 체크리스트

- 장애 범위: 특정 Pod, namespace, node, cluster 전체 중 어디인가
- 변경 이력: Helm upgrade, policy 변경, node 교체, Gateway 변경이 있었는가
- 증거: Hubble flow, Cilium status, Kubernetes event, app log를 함께 남겼는가
- 복구: 정책 rollback, Service selector 수정, Cilium rollout restart 중 무엇이 최소 변경인가

## 정리

```bash
kubectl delete -f labs/08-troubleshooting/deny-dns-egress.yaml --ignore-not-found
kubectl delete -f labs/08-troubleshooting/broken-service-selector.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
```
