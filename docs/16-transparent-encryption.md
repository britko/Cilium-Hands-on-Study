# 16. Transparent Encryption

## 학습 목표

- Cilium WireGuard/IPsec transparent encryption의 보호 범위를 이해합니다.
- Pod-to-Pod traffic encryption을 활성화하고 상태를 검증합니다.
- encryption과 mTLS/mutual auth의 차이를 구분합니다.

## 사전 조건

kind에서는 커널, container runtime, 노드 권한에 따라 packet capture 검증이 제한될 수 있습니다. 이 장은 kind 기본 검증과 Linux VM/bare metal 선택 검증을 나눕니다.

Windows WSL2/macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-encryption --config labs/kind/kind-cilium-encryption.yaml
kubectl config use-context kind-cilium-encryption
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/16-transparent-encryption/cilium-wireguard-values.yaml
cilium status --wait
```

## WireGuard 상태 확인

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -i encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
```

## 트래픽 검증

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

선택 VM 환경에서는 node interface에서 packet capture를 수행해 평문 payload가 노출되지 않는지 확인합니다.

## 운영 관점

- WireGuard/IPsec은 네트워크 구간 암호화이고, 애플리케이션 identity 인증은 아닙니다.
- mutual auth/mTLS는 서비스 identity와 request-level 인증을 다룹니다.
- encryption enable/disable은 datapath 변경이므로 change window와 rollback 절차가 필요합니다.
- MTU, tunnel mode, cloud network offload와 함께 검증합니다.

## 실패 시 확인

```bash
cilium status
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i encrypt
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

## 참고

- WireGuard encryption: https://docs.cilium.io/en/stable/security/network/encryption-wireguard/
