# 08. LoadBalancer IPAM과 L2 Announcement

## 학습 목표

- kind에서 `LoadBalancer` Service가 `<pending>`으로 남는 이유를 이해합니다.
- Cilium LB IPAM으로 `EXTERNAL-IP`를 할당합니다.
- Cilium L2 Announcement로 LoadBalancer VIP를 노드 네트워크에 광고합니다.
- 실제 LAN에서 다른 장비가 LoadBalancer IP로 접근한다는 의미와 운영 사례를 이해합니다.

## 사전 조건

이 문서는 [07. Gateway API](07-gateway-api.md)를 완료한 뒤 진행합니다. `gateway-demo` namespace의 `web` Deployment와 Service를 재사용합니다.

L2 Announcement는 kube-proxy replacement가 필요합니다. 또한 Cilium agent가 Kubernetes `Lease`를 사용하므로 Helm chart로 기능을 켜는 방식을 사용합니다.

macOS/Linux Bash:

```bash
kubectl config use-context kind-cilium-study-kpr

helm upgrade cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --reuse-values \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true \
  --set l2announcements.enabled=true \
  --set k8sClientRateLimit.qps=20 \
  --set k8sClientRateLimit.burst=40

kubectl -n kube-system rollout restart deploy/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```

## 개념

Kubernetes `LoadBalancer` Service는 “이 Service에 외부에서 들어올 IP를 하나 붙여 달라”는 요청입니다. EKS, GKE, AKS 같은 관리형 클러스터에서는 cloud controller가 클라우드 로드밸런서를 만들고 Service의 `EXTERNAL-IP` 또는 hostname을 채웁니다.

kind에는 그런 cloud controller가 없습니다. 그래서 기본 상태에서는 `LoadBalancer` Service가 계속 `<pending>`으로 남습니다.

Cilium에서는 역할이 둘로 나뉩니다.

- LB IPAM: Service에 쓸 `EXTERNAL-IP`를 pool에서 할당합니다.
- L2 Announcement: 할당된 IP를 같은 L2 네트워크에 ARP/NDP로 광고합니다.

LB IPAM만 있으면 Kubernetes object에는 IP가 붙지만, 클러스터 밖의 장비가 그 IP의 MAC 주소를 알 방법이 없습니다. L2 Announcement가 켜지면 선택된 Cilium 노드 중 하나가 “그 VIP는 내 MAC으로 보내라”고 응답하고, 그 노드가 Cilium service load balancing으로 backend Pod까지 전달합니다.

## 실제 LAN에서 다른 장비가 접근한다는 뜻

예를 들어 집이나 사무실 LAN이 `192.168.10.0/24`이고 Kubernetes 노드가 다음처럼 붙어 있다고 가정합니다.

```text
client laptop      192.168.10.50
k8s node-1         192.168.10.11
k8s node-2         192.168.10.12
k8s node-3         192.168.10.13
LoadBalancer VIP   192.168.10.240
```

Cilium LB IPAM이 Service에 `192.168.10.240`을 할당하고 L2 Announcement가 이 VIP를 광고하면, 같은 LAN의 `client laptop`에서 다음 호출이 가능합니다.

```bash
curl http://192.168.10.240/get
```

이때 `192.168.10.240`은 특정 노드의 NIC에 직접 설정된 주소가 아닙니다. Cilium이 선택한 노드 하나가 ARP에 응답하는 가상 IP입니다. 선택된 노드가 내려가거나 lease를 갱신하지 못하면 다른 노드가 VIP 응답자가 되어 트래픽을 이어받습니다.

실제 사례:

- 온프레미스 bare metal Kubernetes에서 `nginx`, `argocd`, `grafana` 같은 내부 서비스를 사내 LAN IP로 노출합니다.
- 연구실이나 홈랩에서 별도 클라우드 LB 없이 `192.168.x.x` 대역의 VIP를 여러 Service에 할당합니다.
- 사내 방화벽이나 DNS에 `app.dev.example.com -> 10.10.30.120`을 등록하고, 그 IP를 Cilium LoadBalancer VIP로 운영합니다.
- 외부 L4 장비가 없는 소규모 edge cluster에서 Gateway API나 Ingress Gateway를 LAN에 직접 노출합니다.

운영에서 주의할 점:

- VIP pool은 DHCP가 자동 할당하지 않는 예약 대역이어야 합니다.
- 클라이언트와 노드는 같은 L2 broadcast domain에 있어야 합니다. 라우터 너머의 다른 subnet에서는 L2 Announcement만으로는 부족하고 BGP, 정적 라우팅, 외부 LB가 필요합니다.
- `externalTrafficPolicy: Local`은 L2 Announcement와 조합할 때 노드별 backend 유무 때문에 드롭을 만들 수 있으므로 기본은 `Cluster`로 둡니다.
- Service 수가 많아지면 lease 갱신 API 트래픽이 늘어납니다. `k8sClientRateLimit.qps`와 `burst`를 운영 규모에 맞게 잡아야 합니다.

kind에서는 Docker bridge 네트워크 안에서만 이 모델을 재현합니다. macOS, Windows WSL2, Colima 환경에서는 Docker bridge가 호스트 OS 뒤의 VM/NAT 안에 있으므로 노트북 브라우저에서 VIP로 직접 접근하는 검증은 환경별로 달라집니다. 이 문서의 검증 기준은 kind 노드 컨테이너 내부에서 VIP로 접근하는 것입니다.

## kind 네트워크 확인

실습 매니페스트는 기본 kind Docker 네트워크인 `172.18.0.0/16` 안의 `172.18.255.200-172.18.255.210`을 VIP pool로 사용합니다.

먼저 현재 kind 네트워크 subnet을 확인합니다.

```bash
docker network inspect kind --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}'
```

출력에 `172.18.0.0/16`이 없다면 [labs/08-loadbalancer-ipam-l2/lb-ipam-l2.yaml](../labs/08-loadbalancer-ipam-l2/lb-ipam-l2.yaml)의 `CiliumLoadBalancerIPPool.spec.blocks`를 현재 Docker subnet 안의 미사용 IP range로 바꿉니다.

## LB IPAM과 L2 Announcement 적용

07장의 NodePort Gateway와 충돌하지 않도록 별도 GatewayClass와 Gateway를 만듭니다. backend `web` Service는 그대로 재사용합니다.

macOS/Linux Bash:

```bash
kubectl apply -f labs/07-gateway-api/gateway-demo.yaml
kubectl -n gateway-demo rollout status deploy/web --timeout=120s

kubectl apply -f labs/08-loadbalancer-ipam-l2/lb-ipam-l2.yaml
kubectl get ippools
kubectl get ciliuml2announcementpolicy
kubectl -n gateway-demo get gateway,httproute,svc -o wide
```

`cilium-gateway-cilium-gateway-lb` Service의 `EXTERNAL-IP`가 `172.18.255.200-172.18.255.210` 범위 중 하나로 표시되어야 합니다.

## VIP 호출

macOS/Linux Bash:

```bash
lb_svc="$(kubectl -n gateway-demo get svc -l io.cilium.gateway/owning-gateway=cilium-gateway-lb -o jsonpath='{.items[0].metadata.name}')"
vip="$(kubectl -n gateway-demo get svc "$lb_svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
node="$(kubectl get node -o jsonpath='{.items[0].metadata.name}')"

docker exec "$node" curl -sS "http://${vip}/get"
docker exec "$node" curl -i "http://${vip}/status/404"
```

`/get`은 `200 OK`로 라우팅되고 `/status/404`는 HTTPRoute match가 없어서 Envoy `404`가 반환됩니다.

## L2 상태 확인

Cilium은 Service별로 lease를 만들고, 한 노드가 해당 VIP의 announcer가 됩니다.

```bash
kubectl -n kube-system get lease | grep cilium-l2announce
kubectl -n kube-system get pod -l k8s-app=cilium -o wide
```

특정 agent의 내부 L2 announce 상태를 확인합니다.

```bash
agent="$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')"
kubectl -n kube-system exec "$agent" -- cilium-dbg shell -- db/show l2-announce
```

출력에 Gateway Service의 VIP와 `eth0`가 보이면 L2 Announcement가 적용된 것입니다.

## 실패 시 확인

macOS/Linux Bash:

```bash
kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.enable-l2-announcements}{"\n"}'
kubectl get ippools -o wide
kubectl describe ippools gateway-demo-pool
kubectl describe ciliuml2announcementpolicy gateway-demo-l2
kubectl -n gateway-demo describe svc "$lb_svc"
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i l2
```

자주 보는 원인:

- IP pool이 kind Docker subnet 밖의 대역입니다.
- IP pool이 Docker가 이미 쓰는 주소와 겹칩니다.
- `l2announcements.enabled=true`로 재설치하지 않아 agent가 lease 권한이나 L2 기능을 갖지 못했습니다.
- `CiliumL2AnnouncementPolicy.spec.interfaces`가 실제 selected device와 맞지 않습니다.

## 정리

```bash
kubectl delete -f labs/08-loadbalancer-ipam-l2/lb-ipam-l2.yaml --ignore-not-found
kubectl delete -f labs/07-gateway-api/gateway-demo.yaml --ignore-not-found
```

L2 Announcement 기능을 끄려면 Cilium을 다시 업그레이드합니다.

```bash
helm upgrade cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --reuse-values \
  --set l2announcements.enabled=false

kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```

## 참고

- Cilium LB IPAM: https://docs.cilium.io/en/stable/network/lb-ipam/
- Cilium L2 Announcements: https://docs.cilium.io/en/stable/network/l2-announcements/
