# 14. Egress Gateway

## 학습 목표

- 특정 workload의 외부 egress traffic을 지정한 노드와 IP로 고정합니다.
- FQDN allowlist와 Egress Gateway가 해결하는 문제가 어떻게 다른지 구분합니다.
- 방화벽 allowlist, 감사 로그, 외부 SaaS 연동 관점에서 egress 출구를 설계합니다.

## 사전 조건

Egress Gateway는 kind에서 개념 검증은 가능하지만, 실제 source IP 고정 효과는 VM/bare metal 또는 cloud VM 환경에서 더 명확합니다. 이 장은 kind 명령과 선택 VM 검증을 나눠 설명합니다.

`cilium-egress`는 선택 검증용 별도 클러스터입니다. 로컬 리소스가 부족하면 `cilium-bgp`, `cilium-east`, `cilium-west` 같은 이전 선택 클러스터를 삭제한 뒤 진행합니다.

`cilium-egress`는 kube-proxy 없이 생성되므로 Cilium이 bootstrap 단계에서 Kubernetes API Service IP(`10.61.0.1`)를 사용할 수 없습니다. values 파일의 `k8sServiceHost: cilium-egress-control-plane`, `k8sServicePort: 6443` 설정으로 API server에 직접 접근하게 합니다.

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
kubectl -n egress-demo exec "$pod" -- curl -k -sS https://1.1.1.1/cdn-cgi/trace
```

`ip=` 값이 출력되면 외부 egress 연결은 성공한 것입니다. 이 명령은 IP로 직접 접속하므로 실습 환경의 외부 DNS 상태에 영향을 덜 받습니다.

`hubble` CLI는 로컬 `127.0.0.1:4245`의 Hubble Relay에 접속합니다. 별도 터미널에서 port-forward를 유지한 뒤 observe 명령을 실행합니다.

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80
```

다른 터미널:

```bash
hubble observe --namespace egress-demo --since 5m
```

kind 환경에서 외부 DNS 조회가 실패할 수 있습니다. `nslookup ifconfig.me`가 timeout이나 `SERVFAIL`을 반환해도 위의 `https://1.1.1.1/cdn-cgi/trace` 검증이 성공하면 이 장의 기본 egress 검증은 통과로 봅니다.

외부 DNS까지 함께 확인하려면 다음 명령으로 실패 지점을 분리합니다. 이 확인은 통과 기준이 아니라 DNS 환경 점검입니다.

```bash
kubectl -n egress-demo exec "$pod" -- nslookup ifconfig.me
kubectl -n egress-demo exec "$pod" -- nslookup kubernetes.default.svc.cluster.local
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=80
```

`kubernetes.default.svc.cluster.local` 조회가 성공하면 Pod에서 kube-dns Service(`10.61.0.10:53`)까지는 도달한 것입니다. 앞의 `https://1.1.1.1/cdn-cgi/trace`도 성공했다면 외부 IP egress 자체도 정상입니다. 이 상태에서 CoreDNS 로그에 다음과 같은 메시지가 보이면 실패 지점은 CoreDNS가 외부 upstream DNS로 forward하는 구간입니다.

```text
read udp 10.60.1.x:xxxxx->172.18.0.1:53: i/o timeout
read udp 10.60.1.x:xxxxx->172.18.0.1:53: connection refused
```

이 경우 CoreDNS의 `forward . /etc/resolv.conf` 설정이 kind Docker host DNS(`172.18.0.1:53` 등)를 사용하지만, 해당 주소에서 DNS 응답을 받지 못하는 상태입니다. 임시 확인은 CoreDNS upstream을 명시 DNS로 바꿔 수행할 수 있습니다.

```bash
kubectl -n kube-system edit configmap coredns
kubectl -n kube-system rollout restart deployment/coredns
```

Corefile의 `forward . /etc/resolv.conf`를 예를 들어 `forward . 1.1.1.1 8.8.8.8`로 바꾼 뒤 다시 `nslookup ifconfig.me`를 확인합니다. 단, 운영 환경에서는 로컬 resolver나 firewall 정책상 `172.18.0.1:53` 접근이 왜 실패하는지 먼저 확인하는 것이 좋습니다.

Egress Gateway 정책이 클러스터 내부 DNS Service CIDR까지 gateway 대상으로 잡은 문제인지도 함께 확인합니다. 이 실습 정책은 `excludedCIDRs`로 PodCIDR, ServiceCIDR, kind Docker subnet을 제외해 DNS와 클러스터 내부 통신은 gateway SNAT 대상에서 제외합니다.

## Optional: VM/bare metal에서 source IP 검증

VM/bare metal 환경에서는 egress gateway node의 secondary IP 또는 node IP가 외부 echo 서버에 보이는지 확인합니다.

```bash
kubectl get nodes -o wide
kubectl -n egress-demo exec "$pod" -- curl -k -sS https://1.1.1.1/cdn-cgi/trace
```

DNS가 정상인 환경에서는 `curl -sS https://ifconfig.me`로도 외부 관측 IP를 확인할 수 있습니다.

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

## 정리

```bash
kubectl delete -f labs/14-egress-gateway/egress-policy.yaml --ignore-not-found
kubectl delete -f labs/14-egress-gateway/demo-app.yaml --ignore-not-found
kind delete cluster --name cilium-egress
```
