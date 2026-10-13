# Account Dock

macOS에서 AI 서비스의 계정과 로그인 상태를 한곳에서 관리하기 위한 앱입니다.

ChatGPT 앱에는 개인 계정, VS Code 확장에는 업무 계정을 사용하는 것처럼, 사용 환경별로 계정을 확인하고 전환하는 것을 목표로 합니다. 현재는 **OpenAI ChatGPT·Codex를 대상으로 개발 중인 초기 시제품**이며, 향후 **Anthropic Claude 등 다른 AI 서비스**도 지원할 예정입니다.

> 현재 버전은 Codex 로컬 계정 조회를 제공합니다. 로그인·로그아웃, 계정 전환, 앱 간 계정 분리는 아직 지원하지 않습니다.

## 현재 기능

- SwiftUI 관리 창에서 Codex 로컬 계정의 이메일과 플랜 조회
- ChatGPT 앱과 Visual Studio Code 실행
- 명령줄에서 앱 설치 여부 및 Codex 인증 상태 확인
- 지정한 `CODEX_HOME`의 인증 상태 조회
- 명령줄 출력의 이메일 기본 숨김, 인증 토큰 출력 제외

조회 결과는 지정된 로컬 인증 저장소를 기준으로 합니다. 실행 중인 VS Code 확장의 계정과 일치하는지, 서버에서 세션이 유효한지는 별도로 확인해야 합니다. ChatGPT 데스크톱 앱의 현재 계정은 아직 조회하지 않습니다.

## 지원 현황

| 대상 | 현재 상태 | 예정 기능 |
| --- | --- | --- |
| OpenAI Codex · VS Code | 로컬 인증 저장소의 계정 조회 | 로그인·로그아웃, 계정 전환, 실행 중 세션 대조 |
| OpenAI ChatGPT · macOS 앱 | 앱 실행 | 계정 조회 및 전환 방식 조사·구현 |
| Anthropic Claude | 미지원 | 인증 연동 조사 후 지원 추가 |
| 기타 AI 서비스 | 미지원 | 서비스별 연동 방식에 따라 확장 |

각 서비스의 공식 인증 방식과 실제 앱 동작을 확인하며 지원 범위를 늘릴 예정입니다. 계정 분리는 검증을 마친 환경부터 제공할 계획입니다.

## 실행 환경

- macOS 14 이상
- Swift 6.0 이상을 사용할 수 있는 Xcode 또는 Command Line Tools
- Python 3.9 이상 (`python3` 명령 사용 가능)
- 로컬 VS Code에 설치된 공식 Codex 확장 (`openai.chatgpt`)

현재 진단 도구는 `~/.vscode/extensions`에서 확장에 포함된 Codex 실행 파일을 찾습니다. 다른 설치 경로는 CLI의 `--binary` 옵션으로 지정할 수 있습니다. 패키징된 `.app` 배포판은 아직 제공하지 않습니다.

## 시작하기

```sh
git clone https://github.com/z8086486/account-dock.git
cd account-dock
swift run AccountDock "$PWD/scripts/doctor.py"
```

관리 창에서 **계정 확인**을 누르면 이메일과 플랜을 조회합니다. **ChatGPT 열기**, **VS Code 열기** 버튼은 각 앱을 실행합니다.

### 명령줄 사용

```sh
# 이메일을 숨긴 상태로 조회
python3 scripts/doctor.py

# 이메일을 포함해 조회
python3 scripts/doctor.py --show-email

# 특정 인증 저장소 조회
python3 scripts/doctor.py --codex-home /absolute/path/to/codex-home

# Codex 실행 파일 직접 지정
python3 scripts/doctor.py --binary /absolute/path/to/codex
```

인증 저장소는 `--codex-home`, 현재 프로세스의 `CODEX_HOME`, `~/.codex` 순서로 결정합니다. 실행 중인 VS Code 프로세스의 환경을 자동으로 감지하지는 않습니다.

| 상태 | 의미 |
| --- | --- |
| `cached_account` | 로컬 저장소에서 계정 정보를 읽음. 세션 유효성을 보장하지 않음 |
| `signed_out` | 해당 저장소에서 계정 정보가 반환되지 않음 |
| `unavailable` | Codex 실행 파일을 찾지 못함 |
| `error` | 조회 실패. 로그아웃 상태와 구분됨 |

## 인증 정보 처리

계정 조회는 Codex app-server의 `account/read`를 `refreshToken: false`로 호출합니다. Account Dock은 로그인·로그아웃이나 토큰 갱신을 요청하지 않으며, 인증 파일을 직접 읽거나 복사하지 않습니다. Codex app-server 자체는 로컬 로그나 상태 파일을 생성할 수 있습니다.

명령줄에서는 이메일을 기본적으로 숨기고, 관리 창에서는 계정 구분을 위해 표시합니다. 인증 토큰과 원본 서버 오류는 출력하지 않습니다. 계정 정보가 보이는 화면이나 진단 결과를 공유할 때는 개인정보를 확인하세요.

## 개발

```sh
swift build
python3 -m unittest discover -s tests -v
```

```text
Package.swift                   Swift 패키지 설정
Sources/AccountDock/main.swift  macOS 관리 창
scripts/doctor.py               Codex 계정 진단
tests/test_doctor.py            계정 응답 처리 테스트
```

`.gitignore`는 공개할 소스·테스트·설정·README 파일만 허용합니다. 새 파일을 추가할 때는 공개 대상인지 확인하고 허용 목록을 갱신해 주세요. 로컬 작업 기록, 인증 정보, 로그, 빌드 결과물은 저장소에 포함하지 않습니다.

## 개발 방향

- OpenAI 앱·확장의 실제 계정 상태와 인증 공유 범위 검증
- 공식 로그인·로그아웃 흐름 연결 및 계정 전환 구현
- 서비스별 연동 모듈을 분리해 Anthropic Claude 등 추가
- 진단 기능의 Swift 이전, 메뉴 막대 지원, macOS 앱 패키징

현재는 OpenAI 연동을 검증하는 단계입니다. Claude 및 기타 서비스 지원 일정은 아직 정하지 않았습니다.
