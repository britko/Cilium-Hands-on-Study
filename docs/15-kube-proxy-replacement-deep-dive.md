# 15. kube-proxy Replacement Deep Dive

## 학습 목표

- Cilium eBPF Service load balancing 경로를 더 깊게 관찰합니다.
- NodePort, LoadBalancer, externalTrafficPolicy, source IP 보존의 차이를 확인합니다.
- SNAT, DSR, Hybrid 같은 운영 모드의 선택 기준을 이해합니다.

## 사전 조건

[06. kube-proxy Replacement](06-kube-proxy-replacement.md)를 완료한 `cilium-study-kpr` 클러스터에서 진행합니다.

```bash
kubectl config use-context kind-cilium-study-kpr
cilium status --wait
```

## Service map 관찰

```bash
kubectl apply -f labs/15-kpr-deep-dive/source-ip-demo.yaml
kubectl -n kpr-deep get svc,pod -o wide
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list
```

## externalTrafficPolicy 비교

`Cluster`와 `Local` Service를 각각 호출하고 backend가 보는 source IP를 비교합니다.

```bash
curl -sS http://127.0.0.1:30081/headers
curl -sS http://127.0.0.1:30082/headers
```

## 운영 모드 선택

| 모드 | 장점 | 주의점 |
|---|---|---|
| SNAT | 기본 동작이 단순하고 return path가 안정적 | backend에서 원본 source IP가 보존되지 않을 수 있음 |
| DSR | 원본 source IP 보존과 효율적 return path | 네트워크 경로, MTU, 옵션 지원 확인 필요 |
| Hybrid | TCP/UDP 특성을 나눠 최적화 | 운영 설명과 장애 분석이 복잡해짐 |

## 운영 관점

- source IP 보존이 필요한 서비스와 필요 없는 서비스를 구분합니다.
- cloud LB, on-prem router, Cilium LB 모드가 서로 다른 NAT를 만들 수 있습니다.
- Hubble flow, backend access log, 외부 client IP를 함께 비교해야 합니다.

## 실패 시 확인

```bash
kubectl -n kpr-deep describe svc
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

## 참고

- kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
