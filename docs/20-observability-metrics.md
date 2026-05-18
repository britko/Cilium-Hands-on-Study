# 20. Observability Metrics

## 학습 목표

- Hubble flow 관찰을 Prometheus/Grafana 기반 운영 지표로 확장합니다.
- Cilium, Hubble, Envoy metrics의 역할을 구분합니다.
- drop, policy verdict, DNS/L7 error를 alert 기준으로 설계합니다.

## 사전 조건

기본 Hubble CLI 실습은 [03. Hubble Observability](03-hubble-observability.md)에서 완료했다고 가정합니다. 이 장은 metrics와 dashboard 중심입니다.

```bash
kubectl config use-context kind-cilium-study
```

## Metrics 활성화

```bash
helm upgrade cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --reuse-values \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set hubble.metrics.enabled='{dns,drop,tcp,flow,icmp,http}'

kubectl -n kube-system rollout restart ds/cilium
cilium status --wait
```

## Prometheus/Grafana

실습용 Prometheus stack을 별도로 설치하거나 기존 모니터링 환경을 사용합니다. 이 repo에서는 설치 자체보다 어떤 지표를 봐야 하는지에 집중합니다.

핵심 지표:

- Cilium agent health와 API rate limit
- policy verdict: forwarded/dropped
- DNS error와 latency
- HTTP status code와 L7 proxy error
- Envoy upstream reset, timeout

## 검증

```bash
kubectl -n kube-system get svc | grep -E 'cilium|hubble'
kubectl -n kube-system port-forward svc/hubble-metrics 9965:9965
curl -sS http://127.0.0.1:9965/metrics | grep hubble
```

## Alert 설계

- namespace별 drop 급증
- 특정 service의 HTTP 5xx 증가
- DNS NXDOMAIN/SERVFAIL 증가
- Cilium agent restart 또는 NotReady
- clustermesh, BGP, egress gateway 같은 advanced component 상태 이상

## 참고

- Hubble: https://docs.cilium.io/en/stable/observability/hubble/
- Metrics: https://docs.cilium.io/en/stable/observability/metrics/
