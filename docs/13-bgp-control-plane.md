# 13. BGP Control Plane

## 학습 목표

- Cilium BGP Control Plane이 어떤 경로를 외부 라우터에 광고하는지 이해합니다.
- FRR 컨테이너를 BGP peer로 사용해 Service VIP 광고를 검증합니다.
- L2 Announcement와 BGP 노출 모델의 차이를 설명할 수 있게 됩니다.

## 사전 조건

이 장은 kube-proxy replacement와 Cilium LoadBalancer IPAM을 사용하는 별도 kind 클러스터를 권장합니다.

Windows WSL2/macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-bgp --config labs/kind/kind-cilium-bgp.yaml
kubectl config use-context kind-cilium-bgp
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/13-bgp-control-plane/cilium-values.yaml
cilium status --wait
```

## 개념

L2 Announcement는 같은 L2 broadcast domain에서 ARP/NDP로 VIP를 알립니다. BGP Control Plane은 라우터와 BGP session을 맺고 Service VIP나 PodCIDR 같은 경로를 광고합니다.

```text
client subnet -> router/FRR -> Cilium node -> Service backend Pod
```

이 모델은 L2 broadcast domain을 넘어서 동작할 수 있어 데이터센터, bare metal, lab router 환경에서 더 현실적인 외부 노출 방식입니다.

## 실습 흐름

1. FRR BGP peer 컨테이너를 kind 네트워크에 붙입니다.
2. Cilium `CiliumBGPClusterConfig`와 advertisement policy를 적용합니다.
3. LoadBalancer Service에 VIP를 할당합니다.
4. FRR routing table과 Cilium BGP status에서 경로 광고를 확인합니다.

Windows WSL2/macOS/Linux Bash:

```bash
docker compose -f labs/13-bgp-control-plane/frr/docker-compose.yaml up -d
kubectl apply -f labs/13-bgp-control-plane/lb-pool.yaml
kubectl apply -f labs/13-bgp-control-plane/bgp-policy.yaml
kubectl apply -f labs/13-bgp-control-plane/demo-service.yaml
```

## 검증

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast summary"
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast"
kubectl -n bgp-demo get svc -o wide
```

## 운영 관점

- BGP speaker가 경로를 광고하더라도 return path가 맞지 않으면 연결은 실패합니다.
- BGP ASN, peer address, route advertisement 범위는 네트워크 팀과 공동 관리해야 합니다.
- L2 Announcement와 BGP를 같은 Service에 동시에 적용하지 않는 것을 기본 원칙으로 둡니다.
- 운영에서는 FRR 대신 ToR router, route reflector, cloud router와 연동합니다.

## 실패 시 확인

```bash
kubectl get ciliumbgpclusterconfig,ciliumbgpadvertisement -A
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i bgp
docker logs cilium-frr
```

## 참고

- Cilium BGP Control Plane: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/
- BGP configuration resources: https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane-configuration/
