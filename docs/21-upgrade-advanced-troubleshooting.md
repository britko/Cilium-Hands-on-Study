# 21. Upgrade & Advanced Troubleshooting

## 학습 목표

- Cilium upgrade와 rollback을 change window 기준으로 준비합니다.
- sysdump, cilium-dbg, BPF map, Envoy log를 이용해 깊은 장애를 분석합니다.
- advanced 기능별 장애 분리 순서를 정리합니다.

## Upgrade 준비

```bash
cilium version
cilium status
cilium connectivity test --flow-validation disabled
cilium sysdump --output-filename "pre-upgrade-cilium-sysdump.zip"
helm -n kube-system get values cilium > cilium-values-before-upgrade.yaml
```

확인 항목:

- Cilium chart/app version
- Kubernetes version compatibility
- kube-proxy replacement 여부
- Gateway API CRD version
- encryption, BGP, clustermesh, egress gateway 활성화 여부

## Upgrade 실행

```bash
helm upgrade cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --reuse-values

cilium status --wait
cilium connectivity test --flow-validation disabled
```

## Advanced troubleshooting 루틴

```bash
cilium status --verbose
kubectl -n kube-system get pod -o wide
kubectl -n kube-system logs ds/cilium --tail=200
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
hubble observe --since 10m
```

## 기능별 분리

| 증상 | 먼저 볼 것 |
|---|---|
| Service만 실패 | service map, endpoint slice, kube-proxy replacement 상태 |
| Gateway만 실패 | Gateway/HTTPRoute status, Cilium operator logs, Envoy logs |
| BGP 경로 없음 | BGP peer status, FRR routes, CiliumBGP resources |
| Egress IP 불일치 | CiliumEgressGatewayPolicy, gateway node, external echo 결과 |
| 암호화 실패 | encryption status, node kernel/module, MTU |
| 멀티클러스터 실패 | clustermesh status, apiserver service, CIDR 충돌 |

## Rollback

```bash
helm -n kube-system history cilium
helm -n kube-system rollback cilium <REVISION>
cilium status --wait
```

Rollback 후에도 datapath 상태가 불안정하면 Cilium agent restart와 connectivity test를 분리해서 수행합니다.

## 참고

- Cilium upgrade guide: https://docs.cilium.io/en/stable/operations/upgrade/
- Cilium sysdump: https://docs.cilium.io/en/stable/operations/troubleshooting/
