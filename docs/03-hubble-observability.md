# 03. Hubble Observability

## 학습 목표

- Hubble CLI/UI로 DNS, TCP, HTTP flow를 관찰합니다.
- 정상 통신과 정책 차단 통신을 구분합니다.
- 장애 신고를 flow 기반으로 분석하는 습관을 익힙니다.

## 준비

이 장은 `02-ebpf-datapath`의 샘플 앱을 사용합니다.

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl apply -f labs/03-hubble/l7-visibility.yaml
kubectl apply -f labs/03-hubble/traffic-generator.yaml
```

HTTP/DNS를 `--protocol http`, `--protocol dns`로 보려면 L7 visibility가 필요합니다. 기본 Hubble flow는 L3/L4 packet event 중심이고, L7 visibility는 L7 rule이 있는 CiliumNetworkPolicy가 트래픽을 Envoy proxy로 연결할 때 활성화됩니다.

## Hubble 상태 확인

`hubble` CLI는 로컬 `127.0.0.1:4245`로 Hubble Relay에 접속합니다. 새 터미널을 열어 다음 port-forward를 유지한 상태에서 이 장의 `hubble` 명령을 실행합니다.

```bash
kubectl -n kube-system port-forward svc/hubble-relay 4245:80
```

다른 터미널:

```bash
hubble status
cilium status
```

Relay가 준비되지 않았다면 다음을 확인합니다.

```bash
kubectl -n kube-system get pods -l k8s-app=hubble-relay
kubectl -n kube-system logs deploy/hubble-relay --tail=100
```

## Flow 관찰

`hubble observe`는 Hubble buffer에 이미 들어온 flow 중 필터에 맞는 것만 출력합니다. 아무 출력이 없으면 먼저 트래픽을 직접 발생시킵니다.

macOS/Linux Bash:

```bash
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- sh -c 'curl -sS http://api/get >/dev/null && nslookup kubernetes.default.svc.cluster.local >/dev/null'
```

```bash
hubble observe --namespace app --since 5m
hubble observe --namespace app --protocol http --since 5m
hubble observe --namespace app --protocol dns --since 5m
```

특정 Pod의 흐름만 보려면 다음과 같이 필터링합니다.

```bash
hubble observe --from-pod "app/$pod" --protocol http --since 5m
```

`--from-pod`, `--to-pod`, `--to-service`에 `app/frontend`처럼 `namespace/name`을 넣는 경우 `--namespace app`을 함께 사용할 수 없습니다. namespace 범위를 따로 줄 때는 `--from-namespace app` 또는 `--to-namespace app`을 사용하고, 특정 Pod/Service를 볼 때는 위처럼 필터 값에 namespace를 포함합니다.

관찰 포인트:

- DNS 요청이 먼저 발생한 뒤 Service 호출이 이어집니다.
- HTTP flow에는 method, path, status code가 표시됩니다.
- 정책으로 차단되면 verdict가 `DROPPED`로 보입니다.
- `--protocol http` 또는 `--protocol dns`가 비어 있는데 `hubble observe --namespace app --since 5m`에는 flow가 보이면, L3/L4 flow는 보이지만 L7 visibility가 빠진 상태입니다.

## Hubble UI

```bash
cilium hubble ui
```

UI에서는 namespace별 서비스 맵과 실시간 flow를 볼 수 있습니다. 장애 분석 회의에서는 CLI 출력보다 UI가 통신 관계를 설명하기 쉽습니다.

## 실전 예시: 장애 신고 분석 루틴

사용자가 "frontend에서 api 호출이 안 된다"고 신고했다고 가정합니다.

```bash
hubble observe --from-pod app/frontend --to-service app/api --since 5m
kubectl -n app get endpointslice -l kubernetes.io/service-name=api
kubectl -n app describe netpol
kubectl -n app get ciliumnetworkpolicy
```

판단 기준:

- `FORWARDED`: 네트워크 정책 관점에서는 통과했습니다. 애플리케이션 로그를 봅니다.
- `DROPPED`: Cilium 정책, DNS, L7 proxy, routing 문제를 확인합니다.
- Flow가 없음: Pod가 요청을 보내지 않았거나 DNS/Service 이름이 틀렸을 수 있습니다.

## 정리

```bash
kubectl delete -f labs/03-hubble/traffic-generator.yaml
kubectl delete -f labs/03-hubble/l7-visibility.yaml
```
