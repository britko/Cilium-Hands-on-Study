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
