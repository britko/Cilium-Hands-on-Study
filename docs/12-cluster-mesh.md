# 12. Cluster Mesh

## 학습 목표

- 두 개의 kind 클러스터를 Cilium Cluster Mesh로 연결합니다.
- cluster identity, global service, cross-cluster service discovery를 이해합니다.
- 멀티클러스터 장애와 failover를 검증합니다.

## 사전 조건

Cluster Mesh는 클러스터별 PodCIDR와 ServiceCIDR가 겹치면 안 됩니다. 이 장은 `east`, `west` 두 클러스터를 별도로 만듭니다.

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-east --config labs/kind/kind-cilium-clustermesh-east.yaml
bash scripts/create-kind-cluster.sh --cluster-name cilium-west --config labs/kind/kind-cilium-clustermesh-west.yaml
```

각 클러스터에 Cilium을 설치할 때 cluster name과 id를 다르게 지정합니다.

```bash
kubectl config use-context kind-cilium-east
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/12-cluster-mesh/cilium-values-east.yaml
cilium status --wait

kubectl config use-context kind-cilium-west
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/12-cluster-mesh/cilium-values-west.yaml
cilium status --wait
```

## Cluster Mesh 연결

```bash
cilium clustermesh enable --context kind-cilium-east --service-type NodePort
cilium clustermesh enable --context kind-cilium-west --service-type NodePort
cilium clustermesh connect --context kind-cilium-east --destination-context kind-cilium-west
cilium clustermesh status --context kind-cilium-east --wait
cilium clustermesh status --context kind-cilium-west --wait
```

## Global Service 검증

```bash
kubectl --context kind-cilium-east apply -f labs/12-cluster-mesh/east-app.yaml
kubectl --context kind-cilium-west apply -f labs/12-cluster-mesh/west-app.yaml

kubectl --context kind-cilium-east -n mesh-demo get svc,pod -o wide
kubectl --context kind-cilium-west -n mesh-demo get svc,pod -o wide
```

`frontend` Pod에서 global service를 호출합니다.

```bash
pod="$(kubectl --context kind-cilium-east -n mesh-demo get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl --context kind-cilium-east -n mesh-demo exec "$pod" -- curl -sS http://api.mesh-demo.svc.cluster.local/get
```

## Failover 확인

west cluster의 backend를 줄이고 east에서 호출을 반복합니다.

```bash
kubectl --context kind-cilium-west -n mesh-demo scale deploy/api --replicas=0
kubectl --context kind-cilium-east -n mesh-demo exec "$pod" -- curl -m 5 -sS http://api.mesh-demo.svc.cluster.local/get
```

## 운영 관점

- Cluster name과 cluster id는 전체 mesh에서 고유해야 합니다.
- CIDR 충돌은 연결 이후에 발견하면 복구 비용이 큽니다.
- global service는 장애 전파 범위를 키울 수 있으므로 서비스별로 적용합니다.
- 멀티클러스터 정책은 identity, namespace, service account 모델을 먼저 표준화해야 합니다.

## 실패 시 확인

```bash
cilium clustermesh status --context kind-cilium-east
cilium clustermesh status --context kind-cilium-west
kubectl --context kind-cilium-east -n kube-system get svc,pod | grep clustermesh
kubectl --context kind-cilium-east -n kube-system logs -l k8s-app=clustermesh-apiserver --tail=200
```

## 정리

```bash
kind delete cluster --name cilium-east
kind delete cluster --name cilium-west
```

## 참고

- Cilium Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/
