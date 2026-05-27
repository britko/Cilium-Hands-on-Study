# 13. BGP Control Plane

## 학습 목표

- Cilium BGP Control Plane이 어떤 경로를 외부 라우터에 광고하는지 이해합니다.
- FRR 컨테이너를 BGP peer로 사용해 Service VIP 광고를 검증합니다.
- L2 Announcement와 BGP 노출 모델의 차이를 설명할 수 있게 됩니다.

## 왜 필요한가

Kubernetes `Service type=LoadBalancer`는 "이 Service에 외부에서 접근할 수 있는 IP를 붙여 달라"는 요청입니다. EKS, GKE, AKS 같은 관리형 클라우드에서는 cloud controller가 외부 load balancer를 만들고 Service의 `EXTERNAL-IP`를 채웁니다. 하지만 bare metal, on-premise, 홈랩 kind 환경에는 기본 cloud load balancer가 없습니다.

이때 필요한 기능은 두 가지입니다.

- LoadBalancer Service에 사용할 VIP를 할당합니다.
- 외부 네트워크가 그 VIP로 가는 경로를 알 수 있게 만듭니다.

Cilium은 첫 번째를 LB IPAM으로 처리하고, 두 번째를 BGP Control Plane으로 처리할 수 있습니다. 즉 Cilium이 Service에 `EXTERNAL-IP`를 할당하고, 그 IP를 외부 라우터에 BGP route로 광고합니다.

이 기능은 MetalLB의 BGP mode를 쓰던 목적과 겹칩니다. Cilium을 CNI로 이미 사용하는 환경이라면 별도 MetalLB speaker를 두지 않고 Cilium LB IPAM과 BGP Control Plane으로 LoadBalancer VIP 할당과 경로 광고를 한 스택에서 관리할 수 있습니다. 반대로 Cilium을 쓰지 않거나 CNI와 독립적인 LoadBalancer 구현이 필요하면 MetalLB가 더 단순한 선택일 수 있습니다.

BGP Control Plane의 장점은 L2 broadcast domain에 묶이지 않는다는 점입니다. L2 Announcement나 MetalLB L2 mode는 같은 subnet/VLAN 안에서 ARP/NDP로 VIP를 알리는 방식이라 단순하지만 범위가 제한됩니다. BGP는 라우터와 경로를 교환하므로 데이터센터, 라우터, route reflector가 있는 환경에서 더 자연스럽게 확장됩니다.

다만 BGP Control Plane은 실제 L7 load balancer가 아닙니다. 패킷을 프록시하거나 HTTP routing을 처리하지 않고, 외부 라우터에 "이 VIP는 Cilium node로 보내라"는 경로를 알려 줍니다. 노드로 들어온 트래픽은 Cilium Service load balancing을 통해 backend Pod로 전달됩니다.

## 사전 조건

이 장은 kube-proxy replacement와 Cilium LoadBalancer IPAM을 사용하는 별도 kind 클러스터를 권장합니다.

로컬 리소스가 부족하면 [12. Cluster Mesh](12-cluster-mesh.md)의 `cilium-east`, `cilium-west`를 먼저 삭제한 뒤 진행합니다. BGP 검증용 `cilium-bgp`는 선택 클러스터이므로 다른 선택 클러스터와 동시에 유지하지 않는 것을 권장합니다.

`cilium-bgp`는 kube-proxy 없이 생성되므로 Cilium이 bootstrap 단계에서 Kubernetes API Service IP(`10.51.0.1`)를 사용할 수 없습니다. values 파일의 `k8sServiceHost: cilium-bgp-control-plane`, `k8sServicePort: 6443` 설정으로 API server에 직접 접근하게 합니다.

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-bgp --config labs/kind/kind-cilium-bgp.yaml
kubectl config use-context kind-cilium-bgp
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/13-bgp-control-plane/cilium-values.yaml
cilium status --wait
```

## BGP 기본 개념

BGP(Border Gateway Protocol)는 라우터끼리 "이 네트워크 대역은 나를 통해 갈 수 있다"는 경로 정보를 교환하는 프로토콜입니다. 인터넷 사업자 간 라우팅에 쓰이는 프로토콜이지만, 데이터센터 내부에서도 ToR router, route reflector, firewall, load balancer와 경로를 교환하는 용도로 자주 사용합니다.

BGP에서 중요한 용어는 다음과 같습니다.

- ASN: BGP 라우팅 도메인을 구분하는 번호입니다. 이 실습에서는 FRR이 `65000`, Cilium node가 `65001`을 사용합니다.
- peer/neighbor: BGP session을 맺는 상대입니다. Cilium node는 FRR 컨테이너 `172.18.0.254`와 peer를 맺습니다.
- prefix/route: 광고되는 네트워크 경로입니다. 이 장에서는 LoadBalancer Service VIP인 `172.18.255.220-230` 대역의 IP가 광고 대상입니다.
- advertisement: 특정 prefix를 BGP peer에게 알리는 동작입니다.
- next-hop: 해당 prefix로 가기 위해 다음에 패킷을 보내야 하는 장비입니다. FRR 입장에서는 Cilium node가 Service VIP의 next-hop이 됩니다.

BGP는 패킷을 직접 프록시하거나 터널링하지 않습니다. BGP가 하는 일은 라우터의 routing table에 경로를 넣을 수 있도록 control-plane 정보를 교환하는 것입니다. 실제 패킷 전달은 커널 라우팅, L2/L3 네트워크, Cilium datapath가 처리합니다.

## Cilium BGP Control Plane

Cilium BGP Control Plane은 Cilium node가 BGP speaker처럼 동작해 외부 라우터에 Kubernetes 경로를 광고하게 해 주는 기능입니다. 여기서 Cilium이 외부 라우터를 대체하는 것은 아닙니다. Cilium은 Service VIP나 PodCIDR 같은 Kubernetes 내부 주소를 외부 네트워크가 알 수 있도록 BGP session을 맺고 경로를 광고합니다.

이 기능이 필요한 대표적인 상황은 bare metal이나 on-premise Kubernetes입니다. 클라우드 환경에서는 Service `type: LoadBalancer`를 만들면 cloud controller가 외부 load balancer를 생성하고 라우팅을 처리합니다. 반면 bare metal 환경에는 그런 기본 제공 장치가 없으므로, LoadBalancer VIP를 실제 네트워크에서 도달 가능하게 만드는 방법이 필요합니다. Cilium은 LB IPAM으로 VIP를 할당하고, BGP Control Plane으로 그 VIP를 라우터에 광고할 수 있습니다.

이 장의 실습 구성은 다음과 같습니다.

```text
client/router side
  |
  | BGP route: 172.18.255.220/32 -> Cilium node
  v
FRR container ASN 65000
  |
  | BGP peering
  v
Cilium node ASN 65001
  |
  | Cilium Service load balancing
  v
web Pod replicas
```

각 리소스의 역할은 다음과 같습니다.

- `CiliumLoadBalancerIPPool`: LoadBalancer Service에 할당할 VIP 대역을 정의합니다.
- `Service type: LoadBalancer`: 외부에서 접근할 Kubernetes Service를 만듭니다.
- `CiliumBGPAdvertisement`: 어떤 종류의 주소를 광고할지 정합니다. 이 실습에서는 `LoadBalancerIP`만 광고합니다.
- `CiliumBGPPeerConfig`: IPv4 unicast 같은 BGP address family와 advertisement 선택 조건을 정의합니다.
- `CiliumBGPClusterConfig`: 어떤 node가 어떤 ASN으로 어떤 peer와 BGP session을 맺을지 정의합니다.
- FRR: 실제 운영 환경의 ToR router, route reflector, firewall, external router 역할을 대신하는 실습용 BGP peer입니다.

중요한 한계도 있습니다. BGP 경로가 광고되었다고 해서 애플리케이션이 자동으로 고가용성이 되는 것은 아닙니다. return path가 맞아야 하고, 방화벽/ACL이 허용되어야 하며, Service backend가 정상이어야 합니다. 또한 BGP Control Plane은 경로 광고 기능이지 L7 load balancer, ingress controller, DNS failover, 데이터 복제 도구가 아닙니다.

## L2 Announcement와 차이

L2 Announcement는 같은 L2 broadcast domain에서 ARP/NDP로 VIP를 알립니다. BGP Control Plane은 라우터와 BGP session을 맺고 Service VIP나 PodCIDR 같은 경로를 광고합니다.

```text
client subnet -> router/FRR -> Cilium node -> Service backend Pod
```

이 모델은 L2 broadcast domain을 넘어서 동작할 수 있어 데이터센터, bare metal, lab router 환경에서 더 현실적인 외부 노출 방식입니다.

## 실습 흐름

이 실습에서 최종적으로 확인할 상태는 다음과 같습니다.

```text
Service type=LoadBalancer 생성
  -> Cilium LB IPAM이 EXTERNAL-IP 할당
  -> Cilium BGP Control Plane이 FRR과 BGP session 수립
  -> Cilium이 Service VIP를 FRR에 /32 route로 광고
  -> FRR routing table에서 Service VIP 경로 확인
```

즉 이 장은 "LoadBalancer Service에 IP가 붙었다"에서 끝나지 않습니다. 그 VIP가 외부 라우터 역할의 FRR까지 BGP route로 전달되는지 확인하는 것이 핵심입니다.

### 1. 외부 라우터 역할의 FRR 실행

FRR 컨테이너는 실제 운영 환경의 ToR router나 route reflector를 흉내 냅니다. Kubernetes 클러스터 안의 Pod가 아니라, kind가 사용하는 Docker network에 직접 붙는 외부 BGP peer입니다.

```bash
docker compose -f labs/13-bgp-control-plane/frr/docker-compose.yaml up -d
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast summary"
```

처음에는 Cilium 쪽 BGP 설정을 아직 적용하지 않았으므로 peer가 없거나 established 상태가 아닐 수 있습니다. 이 단계의 목적은 `172.18.0.254`, ASN `65000`을 가진 라우터 역할 컨테이너를 준비하는 것입니다.

### 2. LoadBalancer VIP pool 생성

`CiliumLoadBalancerIPPool`은 LoadBalancer Service에 할당할 IP 대역을 정의합니다. 이 실습에서는 `expose: bgp` 라벨이 붙은 Service만 `172.18.255.220-230` 대역에서 IP를 받습니다.

```bash
kubectl apply -f labs/13-bgp-control-plane/lb-pool.yaml
kubectl get ciliumloadbalancerippool -A
```

이 단계에서는 아직 Service가 없으므로 VIP가 실제로 할당되지는 않습니다. "어떤 Service가 생기면 어떤 IP pool에서 주소를 줄 것인가"만 준비한 상태입니다.

### 3. BGP peer와 광고 정책 적용

`bgp-policy.yaml`은 세 가지를 정의합니다.

- `CiliumBGPPeerConfig`: IPv4 unicast address family와 어떤 advertisement를 사용할지 정의합니다.
- `CiliumBGPAdvertisement`: `expose: bgp` 라벨이 붙은 Service의 `LoadBalancerIP`를 광고 대상으로 선택합니다.
- `CiliumBGPClusterConfig`: Cilium node가 ASN `65001`로 FRR `172.18.0.254`, ASN `65000`과 BGP session을 맺도록 지정합니다.

```bash
kubectl apply -f labs/13-bgp-control-plane/bgp-policy.yaml
kubectl get ciliumbgppeerconfig,ciliumbgpadvertisement,ciliumbgpclusterconfig
kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast summary"
```

이 단계의 관찰 포인트는 BGP session입니다. `cilium-dbg bgp peers`와 FRR summary에서 Cilium node와 FRR 사이의 peer가 `Established` 상태가 되어야 합니다. 아직 LoadBalancer Service를 만들지 않았으므로 session은 올라와도 광고되는 VIP route는 없을 수 있습니다.

### 4. LoadBalancer Service 생성

`demo-service.yaml`은 `bgp-demo` namespace에 `web` Deployment와 `type: LoadBalancer` Service를 만듭니다. Service에는 `expose: bgp` 라벨이 있으므로 앞에서 만든 LB IPAM pool과 BGP advertisement selector에 모두 매칭됩니다.

```bash
kubectl apply -f labs/13-bgp-control-plane/demo-service.yaml
kubectl -n bgp-demo get deploy,pod,svc -o wide
```

Service의 `EXTERNAL-IP`에 `172.18.255.220-230` 범위의 IP가 할당되어야 합니다. 이 IP는 Kubernetes 객체에만 붙은 값이 아니라, 다음 단계에서 FRR에 BGP route로 보여야 합니다.

### 5. FRR에서 Service VIP route 확인

FRR은 외부 라우터 역할입니다. 여기서 LoadBalancer VIP가 보인다는 것은 Cilium이 Kubernetes Service 정보를 BGP route로 외부 네트워크에 광고했다는 뜻입니다.

```bash
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast"
```

출력에서 Service `EXTERNAL-IP`가 `/32` route로 보여야 합니다. next-hop은 해당 VIP를 처리할 Cilium node IP입니다.

### 6. 전체 상태 요약 확인

마지막으로 Cilium과 Kubernetes 양쪽에서 상태를 다시 확인합니다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers
kubectl -n bgp-demo get svc -o wide
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast summary"
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast"
```

## 검증

핵심 검증 명령은 다음 네 가지입니다.

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bgp peers
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast summary"
docker exec cilium-frr vtysh -c "show bgp ipv4 unicast"
kubectl -n bgp-demo get svc -o wide
```

각 명령이 확인하는 대상은 다릅니다.

- `cilium-dbg bgp peers`: Cilium node 입장에서 BGP peer 상태를 봅니다.
- `show bgp ipv4 unicast summary`: FRR 입장에서 BGP session 상태를 봅니다.
- `show bgp ipv4 unicast`: FRR이 받은 route, 즉 Cilium이 광고한 Service VIP를 봅니다.
- `kubectl -n bgp-demo get svc -o wide`: Service가 어떤 LoadBalancer VIP를 받았는지 봅니다.

통과 기준:

- `web` Service에 `172.18.255.220-230` 범위의 `EXTERNAL-IP`가 할당됩니다.
- Cilium과 FRR 양쪽에서 BGP peer가 `Established` 상태입니다.
- FRR BGP table에 `web` Service의 `EXTERNAL-IP/32` route가 보입니다.
- route가 보이지 않으면 Service label, `CiliumLoadBalancerIPPool.serviceSelector`, `CiliumBGPAdvertisement.selector`를 먼저 확인합니다.

## 운영 관점

- BGP Control Plane은 경로를 광고하는 기능입니다. Service 트래픽 처리는 여전히 Cilium datapath와 Kubernetes Service backend 상태에 의존합니다.
- BGP speaker가 경로를 광고하더라도 return path가 맞지 않으면 연결은 실패합니다.
- BGP session이 `Established`여도 Service VIP가 광고 대상 selector에 매칭되지 않으면 라우터에는 경로가 보이지 않습니다.
- BGP ASN, peer address, route advertisement 범위는 네트워크 팀과 공동 관리해야 합니다.
- 어떤 VIP와 PodCIDR를 외부 라우터에 광고할지 최소 범위로 제한합니다. 실수로 넓은 대역을 광고하면 장애 범위가 클 수 있습니다.
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

## 정리

```bash
kubectl delete -f labs/13-bgp-control-plane/demo-service.yaml --ignore-not-found
kubectl delete -f labs/13-bgp-control-plane/bgp-policy.yaml --ignore-not-found
kubectl delete -f labs/13-bgp-control-plane/lb-pool.yaml --ignore-not-found
docker compose -f labs/13-bgp-control-plane/frr/docker-compose.yaml down
kind delete cluster --name cilium-bgp
```
