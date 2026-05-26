# 99. 전체 검증 체크리스트

이 문서는 모든 랩을 순서대로 검증할 때 사용하는 체크리스트입니다.

## 1. 기본 클러스터

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh
```

이후 [01. Cilium 설치](01-cilium-install.md)의 수동 명령으로 Cilium을 설치하고 검증합니다.

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-values.yaml
cilium hubble enable --ui
cilium status --wait
hubble status
cilium connectivity test --flow-validation disabled
```

`hubble status`는 별도 터미널에서 `kubectl -n kube-system port-forward svc/hubble-relay 4245:80`를 유지한 상태에서 실행합니다.
기본 클러스터는 `kubeProxyReplacement=false`이므로 Hubble flow validation은 [06. kube-proxy Replacement](06-kube-proxy-replacement.md)에서 별도로 검증합니다.

기본 kind node image는 `kindest/node:v1.34.0`입니다. 검증 기록에는 실제 사용한 node image도 함께 남깁니다.

통과 기준:

- `cilium status --wait` 성공
- `hubble status` 성공
- `cilium connectivity test --flow-validation disabled` 성공

## 2. eBPF Datapath

macOS/Linux Bash:

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg identity list
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf ipcache list
```

통과 기준:

- `frontend`에서 `api` 호출 성공
- `app=frontend`, `app=api` endpoint가 Cilium에 표시됨
- `api` Service가 `cilium-dbg service list`에 표시됨
- `bpf lb list`에서 `api` Service frontend/backend mapping 확인 가능
- `bpf ipcache list`에서 app Pod IP와 identity mapping 확인 가능

## 3. Hubble

```bash
kubectl apply -f labs/03-hubble/l7-visibility.yaml
kubectl apply -f labs/03-hubble/traffic-generator.yaml
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- sh -c 'curl -sS http://api/get >/dev/null && nslookup kubernetes.default.svc.cluster.local >/dev/null'
hubble observe --namespace app --protocol http --since 5m
hubble observe --namespace app --protocol dns --since 5m
```

통과 기준:

- HTTP flow와 DNS flow가 표시됨
- source/destination namespace와 Pod가 기대한 값과 일치함

## 4. NetworkPolicy

macOS/Linux Bash:

```bash
kubectl apply -f labs/04-network-policy/default-deny.yaml
kubectl -n app exec "$pod" -- curl -m 3 -sS http://api/get
kubectl apply -f labs/04-network-policy/allow-frontend-to-api.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

통과 기준:

- default deny 이후 호출 실패
- allow 정책 적용 후 호출 성공
- Hubble에서 차단/허용 flow가 구분됨

## 5. L7 Policy

macOS/Linux Bash:

```bash
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl apply -f labs/05-l7-policy/http-l7-policy.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -m 5 -X POST -sS http://api/post
hubble observe --namespace app --protocol http --since 5m
```

통과 기준:

- `GET /get` 허용
- `POST /post` 차단
- Hubble에서 HTTP method/path와 verdict 확인 가능

## 6. kube-proxy Replacement

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-study-kpr --config labs/kind/kind-cilium-kpr.yaml
kubectl config use-context kind-cilium-study-kpr
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-kpr-values.yaml
cilium status --wait
kubectl -n kube-system get ds kube-proxy
kubectl apply -f labs/06-kube-proxy-replacement/nodeport-demo.yaml
curl http://127.0.0.1:30080/get
hubble status
cilium connectivity test --flow-validation strict
```

통과 기준:

- kube-proxy DaemonSet이 없음
- Cilium이 Ready
- NodePort 호출 성공
- `cilium connectivity test --flow-validation strict` 성공

## 7. Gateway API

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f labs/07-gateway-api/gateway-demo.yaml
kubectl -n gateway-demo get gateway,httproute,svc
svc="$(kubectl -n gateway-demo get svc -l io.cilium.gateway/owning-gateway=cilium-gateway -o jsonpath='{.items[0].metadata.name}')"
node_port="$(kubectl -n gateway-demo get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}')"
node="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"
docker exec "$node" curl -sS "http://127.0.0.1:${node_port}/get"
```

통과 기준:

- Gateway와 HTTPRoute가 Accepted 상태
- Cilium Gateway Service가 NodePort로 생성됨
- kind 노드 컨테이너 안에서 NodePort `/get` 호출 성공
- Cilium operator 로그에 CRD 누락 오류가 없음

## 8. LoadBalancer IPAM과 L2 Announcement

선택 심화 검증입니다. 자세한 절차는 [08. LoadBalancer IPAM과 L2 Announcement](08-loadbalancer-ipam-l2.md)를 따릅니다.

```bash
kubectl apply -f labs/07-gateway-api/gateway-demo.yaml
kubectl apply -f labs/08-loadbalancer-ipam-l2/lb-ipam-l2.yaml
kubectl get ippools
kubectl -n gateway-demo get svc -l io.cilium.gateway/owning-gateway=cilium-gateway-lb -o wide
lb_svc="$(kubectl -n gateway-demo get svc -l io.cilium.gateway/owning-gateway=cilium-gateway-lb -o jsonpath='{.items[0].metadata.name}')"
vip="$(kubectl -n gateway-demo get svc "$lb_svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
node="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"
docker exec "$node" curl -sS "http://${vip}/get"
```

통과 기준:

- Gateway용 LoadBalancer Service에 `EXTERNAL-IP`가 할당됨
- `kubectl -n kube-system get lease | grep cilium-l2announce`에서 lease 확인
- kind 노드 컨테이너 안에서 VIP `/get` 호출 성공

## 9. 트러블슈팅

macOS/Linux Bash:

```bash
kubectl config use-context kind-cilium-study
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl apply -f labs/09-troubleshooting/broken-service-selector.yaml
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -m 3 -sS http://api-broken/get
kubectl -n app get endpointslice -l kubernetes.io/service-name=api-broken
kubectl -n app patch service api-broken -p '{"spec":{"selector":{"app":"api"}}}'
kubectl -n app get endpointslice -l kubernetes.io/service-name=api-broken
```

통과 기준:

- 잘못된 Service selector에서 endpoint가 비어 있는 상태 확인
- selector 복구 후 `api-broken` EndpointSlice 생성 확인
- Cilium 문제가 아니라 Kubernetes Service label 문제로 원인 분리

## 10. 실전 운영 패턴

macOS/Linux Bash:

```bash
kubectl config use-context kind-cilium-study
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
pod=$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl apply -f labs/10-production-examples/namespace-zero-trust-baseline.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -m 5 -I https://example.com || echo "blocked as expected"
kubectl apply -f labs/10-production-examples/saas-egress-allowlist.yaml
kubectl -n app exec "$pod" -- curl -I https://api.github.com
kubectl -n app exec "$pod" -- curl -m 5 -I https://example.com
hubble observe --namespace app --verdict DROPPED --since 5m
kubectl -n app delete networkpolicy \
  production-default-deny \
  allow-egress-to-cluster-dns \
  allow-frontend-to-api \
  allow-frontend-egress-to-api \
  --ignore-not-found
kubectl apply -f labs/10-production-examples/internal-api-l7-guardrail.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -m 5 -X POST -sS http://api/post
```

통과 기준:

- zero-trust baseline 적용 후에도 명시적으로 허용한 `frontend -> api` 호출은 성공
- zero-trust baseline만 적용된 상태에서 허용하지 않은 외부 egress는 차단
- `api.github.com` 호출은 성공하고 허용하지 않은 외부 FQDN 호출은 차단
- `GET /get`은 허용되고 `POST /post`는 L7 정책으로 차단
- Hubble에서 허용/차단 flow와 DNS/HTTP 근거 확인 가능

## Advanced Validation

Advanced 과정은 환경 의존성이 높으므로 core validation과 선택 validation을 분리합니다.

### 12. Cluster Mesh

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-east --config labs/kind/kind-cilium-clustermesh-east.yaml
bash scripts/create-kind-cluster.sh --cluster-name cilium-west --config labs/kind/kind-cilium-clustermesh-west.yaml
kubectl --context kind-cilium-east apply -f labs/12-cluster-mesh/east-app.yaml
kubectl --context kind-cilium-west apply -f labs/12-cluster-mesh/west-app.yaml
cilium clustermesh status --context kind-cilium-east
cilium clustermesh status --context kind-cilium-west
```

통과 기준:

- 두 클러스터의 Cluster Mesh status가 ready
- global service 호출 성공
- west backend 축소 후에도 장애 범위 확인 가능

### 13. BGP Control Plane

```bash
docker compose -f labs/13-bgp-control-plane/frr/docker-compose.yaml up -d
kubectl apply -f labs/13-bgp-control-plane/lb-pool.yaml
kubectl apply -f labs/13-bgp-control-plane/bgp-policy.yaml
kubectl apply -f labs/13-bgp-control-plane/demo-service.yaml
kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast"
```

통과 기준:

- BGP peer session established
- LoadBalancer VIP route가 FRR에 표시됨

### 14. Egress Gateway

```bash
kubectl apply -f labs/14-egress-gateway/demo-app.yaml
kubectl apply -f labs/14-egress-gateway/egress-policy.yaml
pod="$(kubectl -n egress-demo get pod -l app=client -o jsonpath='{.items[0].metadata.name}')"
kubectl -n egress-demo exec "$pod" -- curl -sS https://ifconfig.me
```

통과 기준:

- kind에서는 정책 object와 flow 확인
- VM/bare metal에서는 외부 echo 서버의 source IP가 gateway 경로와 일치

### 15-21. 운영 심화

```bash
kubectl apply --dry-run=client -f labs/15-kpr-deep-dive/source-ip-demo.yaml
kubectl apply --dry-run=client -f labs/17-gateway-api-advanced-gamma/canary-app.yaml
kubectl apply --dry-run=client -f labs/17-gateway-api-advanced-gamma/traffic-split-route.yaml
kubectl apply --dry-run=client -f labs/19-policy-host-firewall/team-baseline.yaml
kubectl apply --dry-run=client -f labs/19-policy-host-firewall/service-exception.yaml
```

통과 기준:

- kind에서 가능한 manifest는 client dry-run 통과
- encryption, mutual auth, metrics, upgrade 장은 사전 상태 기록과 rollback 명령이 문서에 포함됨

## 22. Cleanup

macOS/Linux Bash:

```bash
kubectl delete -f labs/19-policy-host-firewall/service-exception.yaml --ignore-not-found
kubectl delete -f labs/19-policy-host-firewall/team-baseline.yaml --ignore-not-found
kubectl delete -f labs/18-mutual-auth-spire/mutual-auth-policy.yaml --ignore-not-found
kubectl delete -f labs/17-gateway-api-advanced-gamma/traffic-split-route.yaml --ignore-not-found
kubectl delete -f labs/17-gateway-api-advanced-gamma/canary-app.yaml --ignore-not-found
kubectl delete -f labs/15-kpr-deep-dive/source-ip-demo.yaml --ignore-not-found
kubectl delete -f labs/14-egress-gateway/egress-policy.yaml --ignore-not-found
kubectl delete -f labs/14-egress-gateway/demo-app.yaml --ignore-not-found
kubectl delete -f labs/13-bgp-control-plane/demo-service.yaml --ignore-not-found
kubectl delete -f labs/13-bgp-control-plane/bgp-policy.yaml --ignore-not-found
kubectl delete -f labs/13-bgp-control-plane/lb-pool.yaml --ignore-not-found
docker compose -f labs/13-bgp-control-plane/frr/docker-compose.yaml down
kubectl delete -f labs/10-production-examples/internal-api-l7-guardrail.yaml --ignore-not-found
kubectl delete -f labs/10-production-examples/saas-egress-allowlist.yaml --ignore-not-found
kubectl -n app delete networkpolicy production-default-deny allow-egress-to-cluster-dns allow-frontend-to-api allow-frontend-egress-to-api --ignore-not-found
kubectl delete -f labs/09-troubleshooting/deny-dns-egress.yaml --ignore-not-found
kubectl delete -f labs/09-troubleshooting/broken-service-selector.yaml --ignore-not-found
kubectl delete -f labs/08-loadbalancer-ipam-l2/lb-ipam-l2.yaml --ignore-not-found
kubectl delete -f labs/07-gateway-api/gateway-demo.yaml --ignore-not-found
kubectl delete -f labs/06-kube-proxy-replacement/nodeport-demo.yaml --ignore-not-found
kubectl delete -f labs/05-l7-policy/http-l7-policy.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/03-hubble/traffic-generator.yaml --ignore-not-found
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml --ignore-not-found
kind delete cluster --name cilium-east
kind delete cluster --name cilium-west
kind delete cluster --name cilium-bgp
kind delete cluster --name cilium-egress
kind delete cluster --name cilium-encryption
bash scripts/cleanup.sh
```

## 검증 기록 템플릿

```text
Date:
Host OS:
Container runtime:
kind version:
kind node image:
Kubernetes version:
Cilium version:
Cilium CLI version:
Hubble CLI version:
Result:
Notes:
```
