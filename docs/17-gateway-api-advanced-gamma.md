# 17. Gateway API Advanced & GAMMA

## 학습 목표

- Gateway API의 traffic split, header/path rewrite, timeout 같은 고급 라우팅을 적용합니다.
- GRPCRoute와 TLSRoute가 필요한 상황을 이해합니다.
- GAMMA를 통해 east-west service routing을 Gateway API 모델로 다루는 방식을 학습합니다.

## 사전 조건

[07. Gateway API](07-gateway-api.md)를 완료한 `cilium-study-kpr` 클러스터에서 진행합니다.

```bash
kubectl config use-context kind-cilium-study-kpr
cilium status --wait
```

## Traffic Split

두 버전의 backend를 배포하고 HTTPRoute weight로 canary를 구성합니다.

```bash
kubectl apply -f labs/17-gateway-api-advanced-gamma/canary-app.yaml
kubectl apply -f labs/17-gateway-api-advanced-gamma/traffic-split-route.yaml
```

검증:

```bash
svc="$(kubectl -n gateway-advanced get svc -l io.cilium.gateway/owning-gateway=advanced-gateway -o jsonpath='{.items[0].metadata.name}')"
node_port="$(kubectl -n gateway-advanced get svc "$svc" -o jsonpath='{.spec.ports[0].nodePort}')"
node="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"
for i in $(seq 1 20); do docker exec "$node" curl -sS "http://127.0.0.1:${node_port}/version"; done
```

## GAMMA 개념

GAMMA는 Gateway API를 north-south ingress뿐 아니라 service-to-service east-west routing에도 사용하려는 모델입니다. Cilium에서는 HTTPRoute를 Service에 attach하여 mesh 내부 라우팅 정책을 표현할 수 있습니다.

## 운영 관점

- Gateway API는 서비스 팀과 플랫폼 팀의 책임 경계를 명확히 합니다.
- GAMMA는 서비스 메시의 일부 traffic management를 Gateway API로 표준화하려는 흐름입니다.
- 복잡한 L7 라우팅은 Envoy datapath를 사용하므로 latency와 error rate를 관찰해야 합니다.
- Istio처럼 전체 service mesh 운영 모델이 필요한지, Cilium Gateway/GAMMA로 충분한지 요구사항을 분리합니다.

## 실패 시 확인

```bash
kubectl -n gateway-advanced describe gateway advanced-gateway
kubectl -n gateway-advanced describe httproute
kubectl -n kube-system logs deploy/cilium-operator --tail=200 | grep -i gateway
```

## 참고

- Cilium Gateway API: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/
- Cilium GAMMA: https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gamma/
- Gateway API traffic splitting: https://gateway-api.sigs.k8s.io/guides/traffic-splitting/
