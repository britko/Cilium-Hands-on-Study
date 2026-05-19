# 07. Gateway API

## 학습 목표

- Cilium Gateway API Controller를 활성화합니다.
- Gateway와 HTTPRoute로 north-south HTTP 라우팅을 구성합니다.
- Ingress 대신 Gateway API를 사용할 때의 운영 장점을 이해합니다.

## 사전 조건

Cilium `1.19.x` 안정 버전 기준으로 Gateway API CRD `v1.4.1`을 설치합니다.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
```

Gateway API는 kube-proxy replacement와 L7 proxy가 필요합니다. 이 장은 `06-kube-proxy-replacement` 클러스터에서 진행하는 것을 권장합니다.

## Gateway API 활성화

기존 설치를 업그레이드합니다.

macOS/Linux Bash:

```bash
helm upgrade cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --reuse-values \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true

kubectl -n kube-system rollout restart deploy/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```

GatewayClass를 확인합니다.

macOS/Linux Bash:

```bash
kubectl get gatewayclass
kubectl -n kube-system logs deploy/cilium-operator --tail=100 | grep gateway
```

## 데모 배포

```bash
kubectl apply -f labs/07-gateway-api/gateway-demo.yaml
kubectl -n gateway-demo get gateway,httproute,svc,pod
```

kind에는 기본 LoadBalancer 구현이 없습니다. 또한 Cilium Gateway가 생성하는 Service는 일반 Service selector가 없으므로 `kubectl port-forward service/...` 대상이 될 수 없습니다. 이 실습은 Gateway Service를 `NodePort`로 만들고 kind 노드 컨테이너 안에서 호출합니다.

macOS/Linux Bash:

```bash
kubectl -n gateway-demo rollout status deploy/web --timeout=120s

svc="$(kubectl -n gateway-demo get svc -l io.cilium.gateway/owning-gateway=cilium-gateway -o jsonpath='{.items[0].metadata.name}')"
node_port="$(kubectl -n gateway-demo get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}')"
node="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"
```

Gateway를 호출합니다.

```bash
docker exec "$node" curl -sS "http://127.0.0.1:${node_port}/get"
docker exec "$node" curl -i "http://127.0.0.1:${node_port}/status/404"
```

`/get`은 라우팅되고 `/status/404`는 HTTPRoute match에 없으므로 기대한 응답이 아닐 수 있습니다.

`Gateway`의 `Programmed` 상태가 `AddressNotAssigned`로 남아 있어도 NodePort 호출이 성공하면 이 실습의 라우팅 검증은 통과입니다. LoadBalancer 주소까지 검증하는 흐름은 [08. LoadBalancer IPAM과 L2 Announcement](08-loadbalancer-ipam-l2.md)에서 별도로 다룹니다.

## 실전 운영 관점

Gateway API는 Ingress보다 역할 분리가 좋습니다.

- 플랫폼 팀: GatewayClass, Gateway, 공통 TLS/Listener 관리
- 서비스 팀: HTTPRoute로 경로와 backend 연결 관리
- 보안 팀: ReferenceGrant, namespace 경계, Cilium policy와 결합

운영 적용 예시:

- 팀별 namespace는 HTTPRoute만 관리하게 하고 Gateway는 플랫폼 팀이 관리합니다.
- 외부 노출 서비스는 Gateway API와 CiliumNetworkPolicy를 함께 리뷰합니다.
- Hubble로 Gateway에서 backend까지의 flow를 확인합니다.

## 실패 시 확인

macOS/Linux Bash:

```bash
kubectl get crd | grep gateway.networking.k8s.io
kubectl get gatewayclass
kubectl -n gateway-demo describe gateway cilium-gateway
kubectl -n gateway-demo describe httproute web
kubectl -n gateway-demo get svc -l io.cilium.gateway/owning-gateway=cilium-gateway -o wide
kubectl -n kube-system logs deploy/cilium-operator --tail=200
```

## 정리

```bash
kubectl delete -f labs/07-gateway-api/gateway-demo.yaml --ignore-not-found
```
