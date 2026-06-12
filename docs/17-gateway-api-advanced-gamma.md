# 17. Gateway API Advanced & GAMMA

## 학습 목표

- Gateway API의 traffic split, header/path rewrite, timeout 같은 표준 라우팅 기능을 이해합니다.
- Cilium이 Gateway API controller와 Envoy datapath로 이 기능을 어떻게 구현하는지 확인합니다.
- GRPCRoute와 TLSRoute가 필요한 상황을 이해합니다.
- GAMMA를 통해 east-west service routing을 Gateway API 모델로 다루는 방식을 학습합니다.

이 장의 주제는 "Cilium 전용 라우팅 문법"이 아니라 Gateway API 표준 기능입니다. Cilium은 Gateway API 리소스(`GatewayClass`, `Gateway`, `HTTPRoute`)를 watch하고, 실제 datapath와 Gateway Service를 구성하는 구현체 역할을 합니다. 실습에 나오는 `CiliumGatewayClassConfig`만 Cilium 고유 리소스이며, 여기서는 Gateway가 만들 Service를 `NodePort`로 노출하기 위해 사용합니다.

## 사전 조건

이 장은 `cilium-study-kpr`를 재사용하지 않고 전용 `cilium-gateway-advanced` 클러스터에서 진행합니다. 15장의 kube-proxy replacement deep dive는 같은 클러스터의 Cilium Helm values를 여러 번 바꾸므로, Gateway API 실습과 섞으면 CRD나 controller 설정이 빠진 상태가 되기 쉽습니다.

```bash
bash scripts/create-kind-cluster.sh \
  --cluster-name cilium-gateway-advanced \
  --config labs/kind/kind-cilium-gateway-advanced.yaml

kubectl config use-context kind-cilium-gateway-advanced
```

Gateway API 표준 CRD를 설치합니다.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
```

Cilium을 Gateway API controller가 켜진 상태로 설치합니다.

```bash
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/17-gateway-api-advanced-gamma/cilium-values.yaml

cilium status --wait
```

이 장의 `traffic-split-route.yaml`은 다음 CRD가 있어야 적용됩니다.

- `CiliumGatewayClassConfig`: Cilium Gateway controller가 사용하는 Cilium CRD입니다.
- `GatewayClass`, `Gateway`, `HTTPRoute`: Kubernetes Gateway API 표준 CRD입니다.

설치 상태를 확인합니다.

```bash
kubectl get crd ciliumgatewayclassconfigs.cilium.io
kubectl get crd gatewayclasses.gateway.networking.k8s.io
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io
```

## Traffic Split

두 버전의 backend를 배포하고 Gateway API `HTTPRoute`의 `backendRefs.weight`로 canary를 구성합니다. weight 기반 분산 자체는 Gateway API 기능이고, Cilium은 이를 Envoy 설정으로 반영해 트래픽을 실제 backend로 보냅니다.

이 실습의 backend는 일부러 응답을 다르게 만들었습니다.

- `web-v1`: `version=v1` 반환
- `web-v2`: `version=v2` 반환

`traffic-split-route.yaml`의 `/version` route는 두 backend를 `80:20` 비율로 참조합니다. 즉 `/version`을 여러 번 호출했을 때 대부분은 `version=v1`, 일부는 `version=v2`가 보여야 canary가 동작한다고 판단할 수 있습니다.

```bash
kubectl apply -f labs/17-gateway-api-advanced-gamma/canary-app.yaml
kubectl apply -f labs/17-gateway-api-advanced-gamma/traffic-split-route.yaml
kubectl -n gateway-advanced rollout status deploy/web-v1 --timeout=120s
kubectl -n gateway-advanced rollout status deploy/web-v2 --timeout=120s
```

Gateway와 HTTPRoute가 Cilium controller에 의해 처리됐는지 먼저 확인합니다.

```bash
kubectl -n gateway-advanced get gateway advanced-gateway
kubectl -n gateway-advanced get httproute web-split
kubectl -n gateway-advanced describe httproute web-split
```

`Accepted=True`가 보여야 route가 Gateway에 붙은 상태입니다.

이제 Gateway Service의 NodePort를 찾습니다.

```bash
svc="$(kubectl -n gateway-advanced get svc -l io.cilium.gateway/owning-gateway=advanced-gateway -o jsonpath='{.items[0].metadata.name}')"
node_port="$(kubectl -n gateway-advanced get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}')"
node="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"
echo "gateway service=$svc nodePort=$node_port node=$node"
```

단일 호출로 응답 형식을 확인합니다.

```bash
docker exec "$node" curl -sS "http://127.0.0.1:${node_port}/version"
```

기대 결과는 `version=v1` 또는 `version=v2`입니다.

canary 비율은 여러 번 호출해서 집계합니다.

```bash
for i in $(seq 1 50); do
  docker exec "$node" curl -sS "http://127.0.0.1:${node_port}/version"
done | sort | uniq -c
```

예상 출력 예:

```text
  40 version=v1
  10 version=v2
```

정확히 `40/10`이 나와야 하는 것은 아닙니다. 요청 수가 적으면 분포는 흔들릴 수 있습니다. 중요한 것은 `version=v1`이 더 많이 나오고, `version=v2`도 일부 나온다는 점입니다. `version=v2`가 전혀 나오지 않으면 HTTPRoute weight, backend Service endpoint, Gateway 상태를 확인합니다.

## GAMMA 개념

GAMMA는 Gateway API를 north-south ingress뿐 아니라 service-to-service east-west routing에도 사용하려는 모델입니다. Cilium에서는 HTTPRoute를 Service에 attach하여 mesh 내부 라우팅 정책을 표현할 수 있습니다.

## 운영 관점

- Gateway API는 서비스 팀과 플랫폼 팀의 책임 경계를 명확히 합니다.
- GAMMA는 서비스 메시의 일부 traffic management를 Gateway API로 표준화하려는 흐름입니다.
- 복잡한 L7 라우팅은 Envoy datapath를 사용하므로 latency와 error rate를 관찰해야 합니다.
- Istio처럼 전체 service mesh 운영 모델이 필요한지, Cilium Gateway/GAMMA로 충분한지 요구사항을 분리합니다.

## 실패 시 확인

```bash
kubectl get crd | grep -E 'ciliumgatewayclassconfigs|gateway.networking.k8s.io'
kubectl get gatewayclass
kubectl -n gateway-advanced describe gateway advanced-gateway
kubectl -n gateway-advanced describe httproute
kubectl -n kube-system logs deploy/cilium-operator --tail=200 | grep -i gateway
```

## 참고

- Cilium Gateway API: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/
- Cilium GAMMA: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gamma/
- Gateway API traffic splitting: https://gateway-api.sigs.k8s.io/guides/traffic-splitting/

## 정리

```bash
kubectl delete -f labs/17-gateway-api-advanced-gamma/traffic-split-route.yaml --ignore-not-found
kubectl delete -f labs/17-gateway-api-advanced-gamma/canary-app.yaml --ignore-not-found
kind delete cluster --name cilium-gateway-advanced
```
