# 19. Policy Design at Scale & Host Firewall

## 학습 목표

- 팀/namespace 단위의 policy layering 모델을 설계합니다.
- CNP, CCNP, Kubernetes NetworkPolicy의 책임 범위를 구분합니다.
- Host Firewall/Host Policy로 노드 접근을 보호할 때의 위험과 복구 절차를 이해합니다.

## Policy layering

운영에서는 단일 정책 파일보다 계층을 나눠 관리합니다.

| 계층 | 소유자 | 예시 |
|---|---|---|
| platform baseline | 플랫폼 팀 | kube-dns, observability, metadata endpoint 제한 |
| namespace baseline | 서비스 팀 + 플랫폼 팀 | default deny, team 공통 egress |
| service policy | 서비스 팀 | caller identity별 ingress, L7 method/path |
| exception policy | 보안 승인 필요 | 외부 SaaS, 임시 migration traffic |

## 실습

```bash
kubectl apply -f labs/19-policy-host-firewall/team-baseline.yaml
kubectl apply -f labs/19-policy-host-firewall/service-exception.yaml
kubectl get cnp,ccnp -A
```

정책 적용 전후 Hubble flow를 비교합니다.

```bash
hubble observe --namespace app --since 10m
hubble observe --namespace app --verdict DROPPED --since 10m
```

## Host Firewall

Host policy는 Pod가 아니라 node host namespace의 traffic을 다룹니다. SSH, kubelet, node exporter, Cilium health endpoint를 잘못 차단하면 복구가 어려워질 수 있습니다.

이 문서에서는 host firewall을 운영 검토 대상으로 다루고, 실제 차단 정책은 VM/bare metal 선택 실습으로만 적용합니다.

## 운영 관점

- 정책 PR에는 허용 근거, Hubble flow, owner, 만료일을 포함합니다.
- CCNP는 강력하므로 platform baseline과 예외 절차를 명확히 둡니다.
- host firewall은 out-of-band 접속 경로가 있을 때만 적용합니다.
- 정책 테스트는 staging namespace에서 먼저 수행하고, 배포 후 drop alert를 확인합니다.

## 실패 시 확인

```bash
kubectl get cnp,ccnp -A
kubectl describe cnp -A
hubble observe --verdict DROPPED --since 10m
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
```

## 참고

- Cilium Policy: https://docs.cilium.io/en/stable/security/policy/
- Host Policies: https://docs.cilium.io/en/stable/security/policy/host/
