# macOS 환경 준비

macOS에서는 Colima와 Docker CLI 조합을 권장합니다. Docker Desktop 라이선스나 회사 정책 이슈를 피하면서 `kind`의 Docker provider 경로를 사용할 수 있습니다.

## Colima와 Docker CLI

```bash
brew install colima docker
colima start --cpu 4 --memory 8
docker version
```

Colima가 중지된 상태라면 `colima start`로 다시 시작합니다.

## kind 클러스터

`create-kind-cluster.sh`는 `kind`, `kubectl` CLI가 없을 때 프로젝트 로컬 `tools/bin`에 자동 설치하고 kind 클러스터를 생성합니다.
또한 Cilium connectivity test의 `json-mock` Pod가 macOS/Colima 환경에서 파일 watcher 한도 때문에 `CrashLoopBackOff`가 나지 않도록 kind 노드의 `nofile`과 inotify 한도를 조정합니다.

```bash
bash scripts/create-kind-cluster.sh
```

## 필수 도구

`helm`, `cilium`, `hubble` CLI를 설치합니다. `cilium`, `hubble`은 프로젝트 로컬 `tools/bin`에 설치합니다.

Helm:

```bash
brew install helm
```

Cilium/Hubble CLI:

```bash
bash scripts/install-cilium-tools.sh
source scripts/use-local-tools.sh
```

설치 확인:

```bash
kubectl version --client
helm version
cilium version
hubble version
```

`cilium version`에서 `zsh: exec format error: cilium`이 나오면 Linux용 바이너리를 받은 상태일 가능성이 큽니다. macOS에서는 다음처럼 `Mach-O` 형식이어야 합니다.

```bash
file "$(which cilium)"
```

Apple Silicon Mac은 `cilium-darwin-arm64.tar.gz`, Intel Mac은 `cilium-darwin-amd64.tar.gz`를 사용합니다. `ELF 64-bit`가 보이면 Linux용 파일이므로 위 Cilium/Hubble CLI 설치 명령으로 다시 설치합니다.

새 터미널에서 `kubectl` alias와 completion을 쓰려면 셸 설정 파일에 로컬 도구 설정을 추가합니다. Bash를 쓰면 스크립트로 `~/.bashrc`에 추가할 수 있습니다.

```bash
bash scripts/use-local-tools.sh --install-bashrc
source ~/.bashrc
```

zsh 기본 터미널이라면 `~/.zshrc`에 직접 추가합니다.

```bash
bash scripts/use-local-tools.sh --install-zshrc
source ~/.zshrc
```

이후 [01. Cilium 설치](01-cilium-install.md)부터는 Helm으로 Cilium을 설치하고 검증합니다.
