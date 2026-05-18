# 18. Mutual Auth & SPIRE

## 학습 목표

- SPIFFE/SPIRE와 Cilium mutual authentication의 역할을 이해합니다.
- network encryption, mTLS, mutual auth의 보호 계층을 구분합니다.
- beta 기능을 운영에 검토할 때 확인해야 할 항목을 정리합니다.

## 사전 조건

Cilium mutual authentication은 버전과 기능 상태를 반드시 확인합니다. 이 장은 kind 개념 실습과 운영 검토 체크리스트 중심으로 구성합니다.

```bash
kubectl config use-context kind-cilium-study-kpr
cilium status --wait
```

## 개념

Transparent encryption은 노드 사이 또는 Pod traffic을 암호화합니다. Mutual authentication은 두 workload가 서로의 identity를 확인하고 허용된 identity 간 통신인지 검증하는 모델입니다.

SPIFFE는 workload identity 형식을 정의하고, SPIRE는 해당 identity를 발급/검증하는 구현체입니다.

## 실습 흐름

```bash
helm upgrade cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --reuse-values \
  --set authentication.mutual.spire.enabled=true

kubectl -n kube-system rollout restart deploy/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```

인증 대상 정책을 적용합니다.

```bash
kubectl apply -f labs/18-mutual-auth-spire/mutual-auth-policy.yaml
```

## 운영 관점

- CA, trust domain, SPIRE server persistence, backup 전략이 필요합니다.
- 인증 실패 시 애플리케이션 장애처럼 보일 수 있으므로 Hubble과 Cilium logs를 함께 봅니다.
- Istio mTLS와 비교할 때 traffic management와 telemetry 범위가 다릅니다.
- beta 기능은 upgrade compatibility와 rollback 절차를 별도로 검증합니다.

## 실패 시 확인

```bash
kubectl -n kube-system get pod | grep spire
kubectl -n kube-system logs -l app.kubernetes.io/name=spire-server --tail=200
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i auth
```

## 참고

- Cilium Mutual Authentication: https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/
