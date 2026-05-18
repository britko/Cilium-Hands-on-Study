# 03. Hubble Observability

## 학습 목표

- Hubble CLI/UI로 DNS, TCP, HTTP flow를 관찰합니다.
- 정상 통신과 정책 차단 통신을 구분합니다.
- 장애 신고를 flow 기반으로 분석하는 습관을 익힙니다.

## 준비

이 장은 `02-ebpf-datapath`의 샘플 앱을 사용합니다.

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl apply -f labs/03-hubble/traffic-generator.yaml
```

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

```bash
hubble observe --namespace app --follow
hubble observe --namespace app --protocol http
hubble observe --namespace app --protocol dns
```

특정 Pod의 흐름만 보려면 다음과 같이 필터링합니다.

```bash
hubble observe --namespace app --from-pod app/frontend --protocol http
```

관찰 포인트:

- DNS 요청이 먼저 발생한 뒤 Service 호출이 이어집니다.
- HTTP flow에는 method, path, status code가 표시됩니다.
- 정책으로 차단되면 verdict가 `DROPPED`로 보입니다.

## Hubble UI

```bash
cilium hubble ui
```

UI에서는 namespace별 서비스 맵과 실시간 flow를 볼 수 있습니다. 장애 분석 회의에서는 CLI 출력보다 UI가 통신 관계를 설명하기 쉽습니다.

## 실전 예시: 장애 신고 분석 루틴

사용자가 "frontend에서 api 호출이 안 된다"고 신고했다고 가정합니다.

```bash
hubble observe --namespace app --from-pod app/frontend --to-service app/api --last 5m
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
```
