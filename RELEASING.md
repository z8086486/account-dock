# 배포 가이드

Account Dock은 GitHub Releases에서 macOS 프리뷰를 배포합니다. 현재 Apple Silicon용이며, 앱 내 업데이트에는 Sparkle 2와 Ed25519 서명을 사용합니다. Apple Developer ID 서명·공증은 아직 적용하지 않습니다.

## 버전과 패키징

`Sources/AccountDock/Resources/release.json`에서 `version`과 `build`를 증가시킵니다. Sparkle은 `build`를 비교하므로 반드시 이전 배포보다 큰 값을 사용합니다.

```sh
swift test
python3 -m unittest discover -s tests -v
python3 scripts/package_app.py --dmg
```

`dist/<version>-<architecture>/`에 APP, ZIP, DMG, SHA256SUMS가 생성됩니다. 로컬 설치까지 하려면 `--install`을 추가합니다. 이미 생성한 버전의 출력 폴더는 덮어쓰지 않습니다.

## 업데이트 서명

공개 키는 release.json의 `updatePublicKey`에, 개인 키는 배포 담당 Mac의 Keychain `app.accountdock.updates` 계정에 보관합니다. 개인 키·인증서·Keychain 내보내기를 Git에 넣지 마세요. 개인 키를 잃으면 기존 프리뷰에 업데이트를 배포할 수 없으므로 안전하게 관리해야 합니다.

```sh
python3 scripts/generate_update_feed.py
```

이 명령은 로컬 공개 키와 앱의 키가 같은지 확인하고, Sparkle 공식 도구로 ZIP과 appcast에 서명한 뒤 피드 서명을 검증합니다. 개인 키는 명령줄이나 출력에 노출하지 않습니다.

앱은 HTTPS 피드와 `SUPublicEDKey`를 사용하며 `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`을 활성화합니다. 서명이 맞지 않는 피드·업데이트 파일은 설치하지 않습니다. 계정 작업 중에는 재실행을 미룹니다.

## GitHub 공개 순서

1. 제품 소스와 버전을 검토·커밋하고 테스트합니다.
2. 해당 커밋에 버전 태그를 붙이고 GitHub Pre-release를 만듭니다.
3. ZIP, DMG, SHA256SUMS, 생성한 `appcast-arm64.xml`을 업로드합니다.
4. 공개 ZIP의 체크섬과 서명을 확인합니다.
5. 생성한 피드를 **수정하지 않고** `updates/appcast-arm64.xml`에 복사해 커밋합니다. 파일을 먼저 올리고 피드를 나중에 갱신해야 합니다.
6. 이전 빌드에서 업데이트 확인 → 다운로드 → 설치·재실행을 검증합니다.

피드 주소: `https://raw.githubusercontent.com/z8086486/account-dock/main/updates/appcast-arm64.xml`

앱이 ARM64와 Intel을 모두 지원하게 되면 아키텍처별 피드와 산출물을 별도로 검증해야 합니다. 현재 Intel 배포 파일은 제공하지 않습니다.

## 설치와 권한

0.9.4 및 이전 버전은 새 DMG로 한 번 직접 교체해야 앱 내 설치를 사용할 수 있습니다. 이후 업데이트는 기존 앱 위치를 유지합니다. 저장 계정은 앱 번들 밖의 Keychain에 보관됩니다.

업데이트 서명은 파일의 출처·무결성 검증용이며 Apple 공증을 대신하지 않습니다. macOS 실행 확인, Keychain 재승인, 관리자 권한이 필요한 설치 위치의 승인 요청은 남을 수 있습니다. 앱은 Gatekeeper·Keychain 보호를 해제하지 않습니다.

향후 Developer ID 서명·공증을 적용하려면 `package_app.py`에 `--signing-identity`와 `--notary-profile`을 함께 지정합니다. 이 경로와 서명 전환 시 Keychain 유지 여부는 별도로 검증해야 합니다.

## 검증 범위

로컬 빌드·프로토콜·저장소 테스트와 실제 업데이트 결과는 [지원·검증 체크리스트](RELEASE_CHECKLIST.md)에 정리합니다. 깨끗한 Mac, 설치 위치 권한 차이, 네트워크 단절과 다양한 OS 버전의 검증은 따로 수행해야 합니다.
