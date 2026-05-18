# 06. kube-proxy Replacement

## 학습 목표

- kube-proxy 없이 kind 클러스터를 생성합니다.
- Cilium이 Service load balancing을 처리하는지 확인합니다.
- ClusterIP, NodePort 트래픽을 Cilium service map과 연결해 봅니다.

## 별도 클러스터 생성

kube-proxy replacement는 기존 클러스터 설정과 충돌할 수 있으므로 별도 kind 클러스터를 사용합니다.

Windows WSL2/macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh \
  --cluster-name cilium-study-kpr \
  --config labs/kind/kind-cilium-kpr.yaml
```

컨텍스트를 전환합니다.

```bash
kubectl config use-context kind-cilium-study-kpr
```

## Cilium 설치

[01. Cilium 설치](01-cilium-install.md)와 같은 방식으로 Helm으로 직접 설치합니다. values 파일만 kube-proxy replacement용으로 바꿉니다.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-kpr-values.yaml

cilium hubble enable --ui
cilium status --wait
```

핵심 옵션:

```yaml
kubeProxyReplacement: true
k8sServiceHost: cilium-study-kpr-control-plane
k8sServicePort: 6443
nodePort:
  enabled: true
```

kube-proxy가 없으면 Cilium agent가 Kubernetes API Service를 통하지 않고 control-plane 주소로 직접 API server에 접근해야 합니다.

## kube-proxy 미설치 확인

```bash
kubectl -n kube-system get ds kube-proxy
cilium status --wait
```

`kube-proxy` DaemonSet이 없어야 합니다.

## NodePort 실습

```bash
kubectl apply -f labs/06-kube-proxy-replacement/nodeport-demo.yaml
kubectl -n kpr-demo rollout status deploy/echo
curl http://127.0.0.1:30080/get
```

Cilium service map을 확인합니다.

```bash
cilium service list
kubectl -n kpr-demo get svc echo-nodeport -o wide
kubectl -n kpr-demo get endpointslice -l kubernetes.io/service-name=echo-nodeport
```

## 실전 운영 관점

kube-proxy replacement는 운영상 큰 이점이 있지만, 변경 영향도도 큽니다.

- 장점: iptables rule 폭증 완화, eBPF 기반 Service load balancing, NodePort/LoadBalancer 처리 개선
- 확인: 커널 기능, Cilium agent readiness, NodePort/HostPort/ExternalIP 사용 여부
- 전환 전략: 신규 클러스터부터 적용하고 기존 클러스터는 별도 검증 후 migration
- rollback: Helm values, kube-proxy DaemonSet 복구 절차, change window 확보

## 실패 시 확인

```bash
kubectl -n kube-system logs -l k8s-app=cilium --tail=100
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

## 정리

```bash
kubectl delete -f labs/06-kube-proxy-replacement/nodeport-demo.yaml --ignore-not-found
kind delete cluster --name cilium-study-kpr
kubectl config use-context kind-cilium-study
```
