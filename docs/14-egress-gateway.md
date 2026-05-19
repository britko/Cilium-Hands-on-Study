# 14. Egress Gateway

## 학습 목표

- 특정 workload의 외부 egress traffic을 지정한 노드와 IP로 고정합니다.
- FQDN allowlist와 Egress Gateway가 해결하는 문제가 어떻게 다른지 구분합니다.
- 방화벽 allowlist, 감사 로그, 외부 SaaS 연동 관점에서 egress 출구를 설계합니다.

## 사전 조건

Egress Gateway는 kind에서 개념 검증은 가능하지만, 실제 source IP 고정 효과는 VM/bare metal 또는 cloud VM 환경에서 더 명확합니다. 이 장은 kind 명령과 선택 VM 검증을 나눠 설명합니다.

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-egress --config labs/kind/kind-cilium-egress.yaml
kubectl config use-context kind-cilium-egress
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/14-egress-gateway/cilium-values.yaml
cilium status --wait
```

## 개념

FQDN policy는 “어디로 나갈 수 있는가”를 제어합니다. Egress Gateway는 “어떤 출구 IP로 나가는가”를 제어합니다.

운영 예시:

- 결제사 방화벽에 `203.0.113.10`만 allowlist로 등록합니다.
- `app=payment` Pod의 외부 호출만 egress gateway node를 통해 나가게 합니다.
- Hubble과 외부 echo 서버로 source IP를 검증합니다.

## 정책 적용

```bash
kubectl apply -f labs/14-egress-gateway/demo-app.yaml
kubectl apply -f labs/14-egress-gateway/egress-policy.yaml
```

검증:

```bash
pod="$(kubectl -n egress-demo get pod -l app=client -o jsonpath='{.items[0].metadata.name}')"
kubectl -n egress-demo exec "$pod" -- curl -sS https://ifconfig.me
hubble observe --namespace egress-demo --since 5m
```

## 선택 VM 검증

VM/bare metal 환경에서는 egress gateway node의 secondary IP 또는 node IP가 외부 echo 서버에 보이는지 확인합니다.

```bash
kubectl get nodes -o wide
kubectl -n egress-demo exec "$pod" -- curl -sS https://ifconfig.me
```

## 운영 관점

- gateway node가 장애나 drain 상태가 되면 egress 영향 범위를 명확히 알아야 합니다.
- Egress Gateway 정책은 identity selector와 destination CIDR를 좁게 잡습니다.
- NAT 이후의 외부 관측 IP와 Hubble 내부 flow를 함께 남겨야 장애 분석이 가능합니다.
- FQDN policy와 함께 쓸 때는 DNS resolution, TTL, destination CIDR 확장 방식을 문서화합니다.

## 실패 시 확인

```bash
kubectl get ciliumnode -o wide
kubectl get ciliumegressgatewaypolicy -A
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i egress
```

## 참고

- Cilium Egress Gateway: https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/
