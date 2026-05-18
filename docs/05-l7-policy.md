# 05. L7 Policy

## 학습 목표

- Cilium L7 HTTP policy를 적용합니다.
- 같은 service라도 method/path 기준으로 허용 범위를 제한합니다.
- Hubble에서 L7 proxy verdict를 확인합니다.

## 준비

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
```

이전 장의 L3/L4 정책이 남아 있으면 L7 차단 결과가 흐려질 수 있으므로 먼저 제거합니다.

기본 동작을 확인합니다.

Windows WSL2/macOS/Linux Bash:

```bash
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -sS http://api/status/418
```

## L7 정책 적용

```bash
kubectl apply -f labs/05-l7-policy/http-l7-policy.yaml
```

허용되는 요청:

Windows WSL2/macOS/Linux Bash:

```bash
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

차단되는 요청:

Windows WSL2/macOS/Linux Bash:

```bash
kubectl -n app exec "$pod" -- curl -m 5 -sS http://api/status/418
kubectl -n app exec "$pod" -- curl -m 5 -X POST -sS http://api/post
```

## Hubble 확인

```bash
hubble observe --namespace app --protocol http --since 5m
hubble observe --namespace app --verdict DROPPED --since 5m
```

관찰 포인트:

- `/get` 요청은 허용됩니다.
- `/status/418`, `POST /post`는 정책에 맞지 않아 차단됩니다.
- L7 정책을 적용하면 Cilium의 Envoy 기반 L7 proxy 경로가 사용됩니다.

## 실전 예시: 내부 API 최소 권한

예를 들어 `frontend`는 주문 API의 조회 endpoint만 호출해야 하고, 생성/삭제는 batch job만 호출해야 할 수 있습니다. 이때 L3/L4 정책만으로는 `frontend -> order-api:8080` 전체가 열립니다. L7 정책을 쓰면 다음처럼 더 좁힐 수 있습니다.

- `frontend`: `GET /orders/*`만 허용
- `batch-worker`: `POST /orders/reconcile`만 허용
- `admin`: `/admin/*` 접근은 별도 namespace와 identity로 제한

## 주의할 점

- L7 정책은 프록시 경로를 사용하므로 성능과 지연 시간을 관찰해야 합니다.
- 모든 트래픽을 L7로 검사하기보다 보안 가치가 큰 API 경계에 우선 적용합니다.
- HTTP/2, gRPC, TLS termination 위치에 따라 정책 적용 방식이 달라질 수 있습니다.

## 정리

```bash
kubectl delete -f labs/05-l7-policy/http-l7-policy.yaml --ignore-not-found
```
