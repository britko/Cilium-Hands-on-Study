# 19. Policy Design at Scale & Host Firewall

## 학습 목표

- 팀/namespace 단위의 policy layering 모델을 설계하고 실제 정책 객체로 검증합니다.
- CNP, CCNP, Kubernetes NetworkPolicy의 책임 범위를 구분합니다.
- Host Firewall/Host Policy로 노드 접근을 보호할 때의 위험과 복구 절차를 이해합니다.

이 장의 핵심은 "정책을 하나 더 적용한다"가 아니라, 운영에서 여러 팀이 정책을 나눠 소유할 때 기준선을 어디에 두고 예외를 어떻게 검증할지 익히는 것입니다.

실습에서 확인할 흐름은 다음과 같습니다.

```text
샘플 앱 배포
  -> 정책 적용 전 frontend -> api 통신과 Hubble flow 확인
  -> cluster-wide DNS egress baseline + namespace default deny 적용
  -> service 예외 정책으로 frontend -> api GET /get만 허용
  -> 허용 flow와 차단 flow를 Hubble로 비교
```

## 클러스터 전제

19장은 전용 `cilium-policy-host-firewall` kind 클러스터에서 진행합니다.

이 장의 정책에는 `endpointSelector: {}`인 cluster-wide baseline이 포함됩니다. 기본 `cilium-study` 클러스터에 적용해도 정리하면 되지만, 실습 중 남아 있으면 다른 장의 앱과 검증을 깨뜨릴 수 있습니다. 또한 18장의 `cilium-mutual-auth` 클러스터를 그대로 재사용하면 authentication/SPIRE 구성이 남아 있어 policy layering 실습의 원인 분리가 흐려집니다.

새 전용 클러스터를 만들고 기본 Cilium+Hubble 설정으로 설치합니다.

```bash
bash scripts/create-kind-cluster.sh \
  --cluster-name cilium-policy-host-firewall \
  --config labs/kind/kind-cilium-policy-host-firewall.yaml

kubectl config use-context kind-cilium-policy-host-firewall

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/01-install/cilium-values.yaml

cilium status --wait
cilium hubble enable --ui
```

기본 `cilium-study`나 18장 `cilium-mutual-auth` 클러스터를 재사용하지 않습니다. 19장은 정책 적용 범위 자체가 학습 대상이므로, 전용 클러스터에서 적용하고 장이 끝나면 클러스터를 삭제하는 편이 안전합니다.

## Policy layering

운영에서는 단일 정책 파일보다 계층을 나눠 관리합니다.

| 계층 | 소유자 | 예시 |
|---|---|---|
| platform baseline | 플랫폼 팀 | kube-dns, observability, metadata endpoint 제한 |
| namespace baseline | 서비스 팀 + 플랫폼 팀 | default deny, team 공통 egress |
| service policy | 서비스 팀 | caller identity별 ingress, L7 method/path |
| exception policy | 보안 승인 필요 | 외부 SaaS, 임시 migration traffic |

## 준비

샘플 앱을 배포하고 기준 통신을 확인합니다.

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl -n app rollout status deploy/frontend --timeout=120s
kubectl -n app rollout status deploy/api --timeout=120s

frontend_pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get
```

`hubble` CLI는 로컬 `127.0.0.1:4245`의 Hubble Relay에 접속합니다. 별도 터미널에서 port-forward를 유지합니다.

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80
```

다른 터미널에서 상태를 확인합니다.

```bash
hubble status
hubble observe --namespace app --since 5m
```

`hubble observe`에서 아무 flow도 보이지 않으면 먼저 트래픽을 다시 발생시킵니다.

```bash
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get >/dev/null
hubble observe --namespace app --since 5m
```

## 실습: baseline과 service 예외

```bash
kubectl apply -f labs/19-policy-host-firewall/team-baseline.yaml
kubectl apply -f labs/19-policy-host-firewall/service-exception.yaml
kubectl get cnp,ccnp -A
```

이 정책 조합은 다음을 표현합니다.

- `platform-dns-egress`: cluster-wide baseline으로 DNS egress만 공통 허용합니다.
- `app-default-deny`: `app` namespace의 ingress/egress를 기본 차단합니다.
- `frontend-to-api-readonly`: `frontend`에서 `api`로 들어오는 `GET /get`만 서비스 ingress 예외로 허용합니다.
- `frontend-egress-to-api`: default deny egress 상태에서도 `frontend`가 `api` endpoint의 TCP 8080으로 나갈 수 있게 허용합니다.

허용된 요청과 차단될 요청을 각각 발생시킵니다.

```bash
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get
kubectl -n app exec "$frontend_pod" -- curl -m 5 -X POST -sS http://api/post || echo "blocked as expected"
kubectl -n app exec "$frontend_pod" -- curl -m 5 -sS https://example.com || echo "blocked as expected"
```

정책 적용 전후 Hubble flow를 비교합니다. `GET /get`은 허용되고, `POST /post`나 외부 egress는 drop 또는 timeout으로 확인되어야 합니다.

```bash
hubble observe --namespace app --since 10m
hubble observe --namespace app --verdict DROPPED --since 10m
hubble observe --namespace app --protocol http --since 10m
```

결과 해석:

- `FORWARDED`: 정책상 허용된 flow입니다.
- `DROPPED`: default deny 또는 L7 rule에 걸린 flow입니다.
- flow가 없음: 트래픽을 아직 발생시키지 않았거나 Hubble Relay 연결이 준비되지 않은 상태일 수 있습니다.

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
hubble status
kubectl -n kube-system get pods -l k8s-app=hubble-relay
kubectl -n kube-system port-forward svc/hubble-relay 4245:80
kubectl get cnp,ccnp -A
kubectl describe cnp -A
hubble observe --verdict DROPPED --since 10m
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
```

`hubble status` 또는 `hubble observe`가 `connection refused`로 실패하면 대부분 로컬 `127.0.0.1:4245`에 Hubble Relay port-forward가 떠 있지 않은 상태입니다. 새 터미널에서 `kubectl -n kube-system port-forward svc/hubble-relay 4245:80`를 계속 실행해 둔 뒤 다시 시도합니다.

## 정리

```bash
kubectl delete -f labs/19-policy-host-firewall/service-exception.yaml --ignore-not-found
kubectl delete -f labs/19-policy-host-firewall/team-baseline.yaml --ignore-not-found
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml --ignore-not-found
kind delete cluster --name cilium-policy-host-firewall
```

## 참고

- Cilium Policy: https://docs.cilium.io/en/stable/security/policy/
- Host Policies: https://docs.cilium.io/en/stable/security/policy/host/
