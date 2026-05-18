# 04. NetworkPolicy와 CiliumNetworkPolicy

## 학습 목표

- 기본 deny 정책을 적용하고 필요한 통신만 허용합니다.
- Kubernetes NetworkPolicy와 CiliumNetworkPolicy의 차이를 이해합니다.
- FQDN 기반 egress 제한을 실무 예시로 구성합니다.

## 준비

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
```

기본 통신을 확인합니다.

Windows WSL2/macOS/Linux Bash:

```bash
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

## 기본 deny 적용

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/04-network-policy/default-deny.yaml
kubectl -n app exec "$pod" -- curl -m 3 -sS http://api/get
```

통신이 실패해야 정상입니다.

Hubble로 차단을 확인합니다.

```bash
hubble observe --namespace app --verdict DROPPED --since 5m
```

## 필요한 통신만 허용

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/04-network-policy/allow-frontend-to-api.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

이 정책은 `frontend` Pod가 `api` Pod로 가는 트래픽과 DNS 질의를 허용합니다.

## Cilium FQDN Egress 정책

외부 SaaS 접근을 `api.github.com`으로 제한하는 예시입니다.

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/04-network-policy/cilium-fqdn-egress.yaml
kubectl -n app exec "$pod" -- curl -I https://api.github.com
kubectl -n app exec "$pod" -- curl -m 5 -I https://example.com
```

`api.github.com`은 허용되고 `example.com`은 차단되어야 합니다.

## Kubernetes NetworkPolicy와 CiliumNetworkPolicy 비교

Kubernetes NetworkPolicy:

- 표준 API라 이식성이 좋습니다.
- Pod/namespace/IPBlock/port 수준 정책에 적합합니다.
- DNS 이름, HTTP method/path 같은 L7 조건은 다루지 못합니다.

CiliumNetworkPolicy:

- Cilium identity, FQDN, DNS, HTTP, Kafka 등 더 풍부한 조건을 사용할 수 있습니다.
- 운영 보안 요구사항을 더 세밀하게 표현할 수 있습니다.
- Cilium 의존성이 있으므로 플랫폼 표준으로 채택할 때 팀 합의가 필요합니다.

## 실전 예시: 기본 정책 모델

운영 namespace는 다음 모델을 기본값으로 잡는 것이 안전합니다.

- namespace 전체 `default-deny`
- ingress는 호출 주체 label 기준으로 허용
- egress는 DNS와 필요한 내부 서비스만 허용
- 외부 API는 FQDN allowlist로 제한
- 신규 서비스 배포 전 Hubble flow로 필요한 통신을 확인

## 정리

```bash
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
```
