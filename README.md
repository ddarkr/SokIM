# 속 입력기

<img src="https://github.com/kiding/SokIM/blob/main/SokIM/Assets.xcassets/AppIcon.appiconset/icon_128x128%402x%402x.png" width="128px">
<img src="https://github.com/kiding/SokIM/releases/download/v1.3.1/screenshot.png" width="300px">

빠르고 매끄러운 한영 전환을 위한 새로운 macOS 입력기

이 포크에는 원본의 [보안 입력 수정 #68](https://github.com/kiding/SokIM/pull/68)과
[설정 창 및 전환키 지정 #70](https://github.com/kiding/SokIM/pull/70),
[devuterian/SokIM](https://github.com/devuterian/SokIM)의 입력 및 호환성 개선을 반영했습니다.

## 로컬 빌드

Xcode가 설치된 macOS에서 실행합니다.

```sh
xcodebuild -project SokIM.xcodeproj -scheme SokIM -configuration Release \
  -derivedDataPath "$PWD/build" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

결과물은 `build/Build/Products/Release/SokIM.app`입니다. 로컬용 ad-hoc 서명이며 공증되지는 않습니다.
빌드만 수행하며 기존 입력기를 설치하거나 교체하지 않습니다.
이 앱은 원본과 같은 입력기 식별자를 사용하므로 기존 앱과 중복 설치하지 마세요.
교체하기 전에 기존 앱을 백업하고, 교체 후 입력 모니터링 및 손쉬운 사용 권한을 다시 허용해야 할 수 있습니다.

보안 입력 판정, 입력 설정과 한글 조합의 회귀 검사는 다음과 같이 실행합니다.

```sh
xcrun swiftc -swift-version 5 Tests/SokIMSmoke.swift SokIM/Engine.swift \
  SokIM/QwertyEngine.swift SokIM/TwoSetEngine.swift SokIM/Preferences.swift \
  SokIM/State.swift SokIM/SecureInput.swift -o build/SokIMSmoke && build/SokIMSmoke
```

설정 창에서 한/A 전환키와 권한 상태를 확인할 수 있습니다. 게임의 입력기 자동 복구, ABC 입력기 제한,
원격 제어 오른쪽 ⌥ 전환은 필요한 경우에만 켤 수 있습니다.

## 설치 방법

1. 직접 빌드한 `SokIM.app`을 `/Library/Input Methods`에 설치합니다. 기존 속 입력기를 교체하는 경우 먼저 백업하세요.
1. 시스템 설정 → 키보드 → 입력 소스 "편집..." 버튼 → "+" 버튼 → 영어 → "속 입력기" → "추가" 버튼
1. 메뉴 막대에서 현재 입력기를 속 입력기로 변경
1. 시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링에서 "속 입력기" 권한 허용
1. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 "속 입력기" 권한 허용

## 삭제 방법

1. 시스템 설정 → 키보드 → 입력 소스 "편집..." 버튼 → "속 입력기" → "-" 버튼
1. 로그아웃 후 재로그인
1. 시스템 설정 → 개인정보 보호 및 보안 → 입력 모니터링 → "속 입력기" → "-" 버튼  
1. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → "속 입력기" → "-" 버튼
1. `/Library/Input Methods/SokIM.app` 삭제 또는 `brew uninstall --cask sokim` 실행

## 디버그 메시지 보기

1. 속 입력기 → 설정 → 디버그 모드 활성화
1. 터미널에서 `log stream --predicate 'process == "SokIM" AND composedMessage CONTAINS ".swift"' --debug --style compact`
