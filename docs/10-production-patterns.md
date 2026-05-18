# 10. 실전 운영 패턴

이 장은 앞선 랩에서 익힌 기능을 실제 서비스 운영 기준으로 조합하는 예시입니다. 목표는 Cilium을 "설치해 봤다"에서 끝내지 않고, 신규 서비스 온보딩, 외부 API 통제, 내부 API 최소 권한, 장애 분석 루틴에 바로 적용할 수 있는 기준을 만드는 것입니다.

## 적용 전제

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
```

운영에서는 같은 정책을 바로 적용하기 전에 staging namespace에서 Hubble flow를 최소 하루 이상 관찰하고, 실제 호출 관계와 배포 작업을 함께 검증합니다.

## 패턴 1: Namespace 기본 보안선

신규 namespace는 기본적으로 모든 ingress/egress를 차단하고, 필요한 통신만 허용합니다.

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/10-production-examples/namespace-zero-trust-baseline.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

이 예시는 다음 운영 기준을 표현합니다.

- namespace 전체에 `default-deny`를 먼저 적용합니다.
- DNS egress는 모든 Pod에 공통으로 허용하되, 대상은 CoreDNS로 제한합니다.
- `frontend -> api` 통신은 label과 port 기준으로만 허용합니다.
- Service 이름이 아니라 workload label을 정책 기준으로 삼아 Pod IP 변경에 흔들리지 않게 합니다.

검증:

```bash
hubble observe --namespace app --since 5m
hubble observe --namespace app --verdict DROPPED --since 5m
```

## 패턴 2: 외부 SaaS Egress Allowlist

업무 서비스가 GitHub, 결제사, 메일 발송 API 같은 외부 SaaS를 호출할 때는 전체 인터넷 egress를 열지 않고 FQDN allowlist로 제한합니다.

Windows WSL2/macOS/Linux Bash:

```bash
kubectl apply -f labs/10-production-examples/saas-egress-allowlist.yaml
kubectl -n app exec "$pod" -- curl -I https://api.github.com
kubectl -n app exec "$pod" -- curl -m 5 -I https://example.com
```

`api.github.com`은 허용되고 `example.com`은 차단되어야 합니다. 실제 운영에서는 다음을 함께 관리합니다.

- SaaS 도메인, 포트, 소유 팀, 만료일을 정책 PR에 기록합니다.
- wildcard FQDN은 최소화하고, 불가피하면 사유와 검토 주기를 명시합니다.
- DNS 정책은 캐시와 TTL 영향을 받으므로 변경 직후 Hubble DNS flow를 확인합니다.

관찰:

```bash
hubble observe --namespace app --protocol dns --since 10m
hubble observe --namespace app --to-fqdn api.github.com --since 10m
```

## 패턴 3: 내부 API L7 최소 권한

같은 API Service라도 호출자별로 허용 method/path를 다르게 제한할 수 있습니다.

Windows WSL2/macOS/Linux Bash:

```bash
kubectl delete -f labs/10-production-examples/namespace-zero-trust-baseline.yaml --ignore-not-found
kubectl apply -f labs/10-production-examples/internal-api-l7-guardrail.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -m 5 -X POST -sS http://api/post
```

운영 예시:

- `frontend`: `GET /get` 같은 조회 endpoint만 허용합니다.
- `batch-worker`: 정산이나 동기화 endpoint만 별도 identity로 허용합니다.
- `admin`: 관리 endpoint는 별도 namespace, service account, 감사 로그 기준을 붙입니다.

주의할 점:

- L7 정책은 Envoy 기반 proxy 경로를 사용하므로 지연 시간과 오류율을 함께 봅니다.
- mTLS termination 위치, HTTP/2, gRPC 사용 여부에 따라 정책 단위를 다시 설계합니다.
- 고트래픽 경로는 모든 요청을 L7로 검사하기보다 보안 가치가 높은 경계부터 적용합니다.

## 패턴 4: 장애 신고 대응 루틴

"특정 화면이 느리다" 또는 "API가 간헐적으로 실패한다"는 신고가 들어오면 다음 순서로 증거를 모읍니다.

```bash
cilium status
kubectl -n app get pods -o wide
kubectl -n app get networkpolicy,ciliumnetworkpolicy
hubble observe --namespace app --since 10m
hubble observe --namespace app --verdict DROPPED --since 10m
hubble observe --namespace app --protocol http --since 10m
```

판단 기준:

- `DROPPED`가 많으면 정책, DNS, identity 변경을 먼저 확인합니다.
- HTTP status가 5xx 위주면 애플리케이션과 upstream 상태를 함께 확인합니다.
- 특정 노드의 Pod만 실패하면 Cilium agent, node route, host firewall 상태를 확인합니다.
- flow가 전혀 보이지 않으면 Hubble 문제가 아니라 datapath 또는 agent 상태를 먼저 봅니다.

## 운영 PR 체크리스트

정책 변경 PR에는 다음 정보를 포함합니다.

- 어떤 서비스 identity가 어떤 대상과 통신해야 하는지
- 허용할 protocol, port, method, path, FQDN
- Hubble로 확인한 실제 flow 근거
- 차단될 것으로 예상되는 트래픽과 사용자 영향
- rollback 명령과 검증 명령

## 정리

```bash
kubectl delete -f labs/10-production-examples/internal-api-l7-guardrail.yaml --ignore-not-found
kubectl delete -f labs/10-production-examples/saas-egress-allowlist.yaml --ignore-not-found
kubectl delete -f labs/10-production-examples/namespace-zero-trust-baseline.yaml --ignore-not-found
```
