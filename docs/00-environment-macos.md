# macOS 환경 준비

macOS에서는 Colima와 Docker CLI 조합을 권장합니다. Docker Desktop 라이선스나 회사 정책 이슈를 피하면서 `kind`의 Docker provider 경로를 사용할 수 있습니다.

## Colima와 Docker CLI

```bash
brew install colima docker
colima start --cpu 4 --memory 8
docker version
```

Colima가 중지된 상태라면 `colima start`로 다시 시작합니다.

## 필수 도구

`create-kind-cluster.sh`는 `kind`, `kubectl` CLI가 없을 때 프로젝트 로컬 `tools/bin`에 자동 설치합니다.

`helm`, `cilium`, `hubble` CLI는 [01. Cilium 설치](01-cilium-install.md)에서 수동으로 설치합니다. Cilium 설치 이후 실습도 문서의 명령을 직접 실행하면서 진행합니다.

새 터미널에서 `kubectl` alias와 completion을 쓰려면 셸 설정 파일에 로컬 도구 설정을 추가합니다. Bash를 쓰면 `~/.bashrc`, zsh를 쓰면 `~/.zshrc`에 적용합니다.

```bash
bash scripts/use-local-tools.sh --install-bashrc
source ~/.bashrc
```

zsh 기본 터미널이라면 `source ~/.zshrc`를 사용합니다.

## 실습 시작

kind 클러스터만 스크립트로 생성합니다.

```bash
bash scripts/create-kind-cluster.sh
```

이후 [01. Cilium 설치](01-cilium-install.md)부터는 Helm과 Cilium CLI 명령을 직접 실행하면서 진행합니다.
