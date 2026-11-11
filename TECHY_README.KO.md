# Brother DCP-T420W 기술 안내

[간단한 사용 설명서](README.KO.md) · [English technical guide](TECHY_README.md) · [실측한 펌웨어 주의사항](PITFALLS.md)

설치·일상 사용은 기본 설명서를 참고하세요. 이 문서는 드라이버 구조, 버전별 변경,
빌드·검증, 고장 진단과 보안 설정을 다룹니다. 장치별 관찰 결과와 실측 기록은
[PITFALLS.md](PITFALLS.md)에 영문으로 보존되어 있습니다.

## 1.5.0: 기본 인쇄 옵션과 DPI 표시

- `APAirPrint: True`로 macOS 기본 컬러 스위치와 **미디어 및 품질** 컨트롤을 사용합니다.
  실제 기기가 AirPrint를 지원한다는 뜻은 아닙니다. 기존 PWG 변환 필터는 계속 필요하며
  프린터 공유 설정도 별개입니다. 자동 PPD 교체나 필터 우회는 추가하지 않습니다.
- 한·영 드라이버 프리셋 8개를 제공합니다. 6개 문서 프리셋은 색상·품질·일반 용지를,
  2개 사진 프리셋은 컬러·고화질·각 인화지를 설정합니다. 이름에 출력 래스터 DPI를 표시합니다.
- macOS 기본 품질 메뉴의 ‘초안·일반·최상’ 이름과 섹션 펼침 상태는 OS가 관리합니다.
  PPD에서 이를 임의로 바꾸거나 모든 섹션을 항상 펼치도록 지정할 수는 없습니다.
- CUPS 클라이언트에도 품질 3단계가 모두 광고됩니다. 이전에는 `cupsPrintQuality` 선택지가
  있어도 macOS CUPS의 IPP 응답에는 표준만 나타났습니다.
- BP71의 PPD 선택값을 `com.brother-bp71`로 수정했습니다. 이전 `Com.brotherBp71`은
  macOS CUPS에서 `com.brother-bp-71`로 잘못 변환됐습니다. 오래된 BP71 사용자 프리셋은
  새 ‘BP71 사진’ 프리셋으로 바꾸거나 다시 저장하세요. 필터는 이전 CLI 표기도 인식합니다.

텍스트 편집기의 실제 인쇄 창에서 기본 컬러 스위치·미디어 및 품질·DPI 프리셋을
확인했습니다. 루프백 주소를 향하는 중지된 검증 큐에서 생성한 작업의 색상·품질 설정도
확인했으며, 테스트 작업은 취소했습니다. `make check`의 PDF→래스터 검증은 8개
프리셋의 실제 DPI·색 공간·용지 종류를 확인합니다. 새 버전으로 실제 용지를 출력한
검증은 별도입니다.

## 1.4.0 변경 사항과 이전 버전에서의 전환

**동작 변경: 기본 출력 순서가 역순입니다.** PPD에 `DefaultOutputOrder: Reverse`를 선언하여
macOS가 마지막 페이지부터 렌더링합니다. 설치 프로그램이 기존 프린터 큐의 PPD도 갱신하므로
업그레이드한 큐의 ‘자동’ 순서에도 적용됩니다. 인쇄 작업이나 프리셋에 명시된 정순 설정은
기본값보다 우선합니다.

이전 방식으로 사용하려면 **용지 프린트 방식 → 시트 순서 → 정순**을 선택하고 프리셋으로
저장하세요. 명령줄에서 한 번만 정순으로 출력하려면 다음과 같이 실행합니다.

```sh
lp -d Brother_DCP_T420W -o outputorder=normal document.pdf
```

현재 사용자의 명령줄 기본값을 정순으로 고정하거나 해제하는 방법입니다.

```sh
lpoptions -p Brother_DCP_T420W -o outputorder=normal
lpoptions -p Brother_DCP_T420W -r outputorder
```

두 번째 명령은 첫 번째 명령으로 추가한 설정을 해제합니다. 앱별 저장 설정은 별도로
적용될 수 있습니다. 순서 변경은 PDF 렌더러가 담당합니다. 이미 렌더링된 PWG·URF 입력을
받는 최종 필터가 전체 작업을 버퍼에 담아 다시 뒤집는 구조는 아닙니다.

그 밖의 변경 사항은 다음과 같습니다.

- 인쇄 옵션을 **색상 → 품질 → 용지 종류** 순서로 정리하고 한국어·영어 표시를 개선했습니다.
- 컬러 문서·흑백 문서·잉크 절약의 세 프리셋 조합과 저장 방법을 안내합니다.
  프리셋은 macOS 사용자별 설정이며 설치 패키지가 자동으로 등록하지 않습니다.
- 스캔 UI로 **Brother ICA 드라이버 + 이미지 캡처**를 사용하는 경로를 안내합니다.
  별도 GUI나 ICA 드라이버를 이 프로젝트에 추가한 것은 아닙니다.
- 일반 안내와 기술 안내를 분리하고 두 안내 모두 한국어 문서를 제공합니다.
- v1.3.4의 macOS 호환성 사용자 보고를 추가했습니다.

## 호환성과 검증 범위

| 환경 | 버전 | 확인 내용 |
|---|---|---|
| macOS 26.5, Apple Silicon | 최초 개발 환경 | 개발 과정에서 빌드·테스트 |
| Golden Gate 27.0.1 (26A434) | 1.3.4 | 사용자 정상 작동 보고 |
| Tahoe 26.7.1 (25G241) | 1.3.4 | 사용자 정상 작동 보고 |

실행 파일은 arm64·x86_64 유니버설 바이너리이며 최소 배포 대상은 macOS 11.0입니다.
최소 배포 대상 지정은 해당 OS에서 실제 사용을 검증했다는 뜻이 아닙니다.
v1.3.4 사용자 보고는 모든 기능의 상세 시험이나 v1.4.0·Brother ICA 호환성 확인을
대신하지 않습니다.

## 설치와 업그레이드

[Releases](https://github.com/hwisu/DCP-T420W/releases)의 `.pkg` 설치 파일을 사용합니다.
필터·PPD·스캔 도구를 설치하고, Bonjour로 프린터를 찾아 `Brother_DCP_T420W` 큐를 만듭니다.
기존 큐가 있으면 PPD를 교체하되 장치 주소와 공유 상태를 유지합니다.

설치 파일에는 유료 Developer ID Installer 인증서에 의한 서명이 없습니다.
macOS에서 차단될 수 있습니다. 이 저장소의 파일을 신뢰하는 경우에만 설치하세요.
버전에 따라 Finder에서 우클릭 → 열기가 가능하며, 터미널에서는 다음과 같이 설치할 수 있습니다.
Gatekeeper를 시스템 전체에서 해제할 필요는 없습니다.

```sh
sudo installer -pkg DCP-T420W-1.5.0.pkg -target /
```

명령줄 설치는 공유 선택 화면을 표시하지 않습니다. 공유를 켜는 명령줄 설치 예시는
[영문 기술 안내](TECHY_README.md#printing-from-an-iphone-or-ipad)에 있습니다.
네트워크에서 프린터를 찾지 못하더라도 설치된 파일은 남아 있으므로 시스템 설정에서
드라이버를 선택하여 프린터를 추가할 수 있습니다.

| 구성 요소 | 설치 위치 | 역할 |
|---|---|---|
| `rastertobrother` | `/usr/libexec/cups/filter/` | CUPS Raster를 PWG Raster로 변환 |
| `Brother DCP-T420W.ppd` | `/Library/Printers/PPDs/Contents/Resources/` | 용지·품질·기본 출력 순서 |
| `brscan` | `/usr/local/bin/` | eSCL 스캔 클라이언트 |
| `brairprint` | `/usr/local/libexec/` | 선택적 AirPrint 공유 알림 |
| AirPrint LaunchDaemon | `/Library/LaunchDaemons/` | 공유를 선택했을 때만 상시 실행 |

PPD는 CUPS가 `/etc/cups/ppd/` 아래에도 따로 복사합니다. 모델 파일만 바꿔서는 기존 큐가
갱신되지 않습니다. 새 PPD 적용 후에도 이전 메뉴가 보이면 인쇄 앱을 재시작하세요.

## 빌드와 소스 설치

Xcode 또는 Command Line Tools, Swift 6 컴파일러, macOS SDK, Python 3가 필요합니다.
Python은 PPD 생성·테스트용이며 배포 실행 파일의 의존성이 아닙니다.
런타임은 macOS의 CUPS·Bonjour·ImageIO 등을 사용합니다.

```sh
make
make check
./packaging/build-pkg.sh              # build/DCP-T420W-1.5.0.pkg
sudo ./install.sh                    # 인쇄 드라이버 설치
sudo make -C scanner install          # brscan 별도 설치
```

장치 검색을 생략하거나 다른 큐 이름을 사용하려면 다음 옵션을 사용합니다.

```sh
sudo ./install.sh --uri ipp://192.0.2.25:631/ipp/print
sudo ./install.sh --name Office
sudo ./install.sh --no-queue          # 드라이버 파일만 설치
sudo ./install.sh --share             # 아래 공유 보안 안내를 먼저 확인
```

`SDK`, `MIN_OS`, `CC`, `SWIFTC`와 컴파일·링크 플래그는 make 변수로 바꿀 수 있습니다.
도구 체인이나 옵션 변경 후에는 `make -B`로 다시 빌드하세요. Swift 모듈 캐시는
기본적으로 `build/swift-module-cache`에 생성됩니다. 네이티브 단일 아키텍처 빌드는
각 구성 요소 디렉터리에서 `make native`로 수행합니다.

패키지는 arm64·x86_64 모두 포함하도록 빌드합니다. 임시 스테이징은 부팅 볼륨에 생성하며,
`com.apple.provenance`에 따른 AppleDouble 항목 등 패키징 세부사항은
[PITFALLS.md](PITFALLS.md)의 Part 3에 설명되어 있습니다.

## 인쇄 처리 구조

DCP-T420W는 Mopria 장치로, 프린터 자체에 macOS가 요구하는 AirPrint의 `urf-supported`
속성이 없습니다. 대신 기기가 지원하는 PWG Raster를 IPP로 보내도록 구성합니다.

```text
PDF → macOS cgpdftoraster → CUPS Raster → rastertobrother → PWG Raster → IPP → 프린터
```

`cgpdftoraster`의 직접 PWG 출력은 일부 이름을 `A4.Borderless`, `Stationery` 같은
PPD 명칭으로 기록합니다. 최종 필터는 이를 실제 IPP 키워드인 `iso_a4_210x297mm`,
`stationery` 등으로 정리하고, 필요할 때 영역 패딩·회색조 변환을 수행합니다.
`ImagingBoundingBox`도 PWG 규격에 맞게 기록합니다.

PPD의 필터 경로는 다음 두 가지입니다.

- `application/vnd.cups-raster → image/pwg-raster`: PDF 렌더링 결과를 변환합니다.
- `image/urf → image/pwg-raster`: iOS의 Apple Raster 입력을 직접 처리합니다.

`cupsFilter2`는 순차 실행 목록이 아니라 필터 경로 그래프를 정의합니다. 경로를 임의로
추가하면 최종 필터가 생략될 수 있습니다. URF 입력은 libcups가 자동 감지하므로
별도 Apple Raster 디코더는 필요하지 않습니다.

### 인쇄 옵션과 제약

- A4, Letter, Legal, A5, A6, 사진 용지·봉투 등과 사용자 지정 크기를 지원합니다.
  전체 목록과 물리 치수는 `scripts/genppd.py`의 `MEDIA`를 확인하세요.
- 사용자 지정 크기는 88.9×127mm부터 215.9×355.6mm까지입니다.
- 일반 용지 여백은 3mm, 봉투 상하 여백은 12mm입니다. 여백 없는 크기는 인화지와
  함께 사용해야 하며 일반 용지 조합은 거부합니다.
- 에코는 300dpi, 표준·고화질은 600dpi로 렌더링합니다. 별도의 해상도 UI를 만들지 않습니다.
  IPP의 프린터 해상도는 기기가 보고한 600dpi를 유지합니다.
- `ColorModel=RGB`는 컬러, `ColorModel=Gray`는 회색조입니다.
- `cupsManualCopies`를 선언하므로 복사 매 수 확장은 렌더러가 담당합니다.
  최종 필터에서 다시 복제하면 안 됩니다.
- 홀수·짝수 선택은 macOS가 `page-set=odd/even`으로 처리합니다.
  PPD에 중복 기능을 추가하여 두 번 필터링하지 마세요.
- 이 모델에는 자동 양면 인쇄 기능이 없습니다.

`프린터 옵션 → 프린터 기능`에서 색상·품질·용지 종류를 설정한 뒤, 상단 프리셋 메뉴에서
현재 설정을 저장하면 매번 세부 메뉴를 열 필요가 없습니다. 프린트 작업 프리셋에는
용지 크기·방향·매 수·배율도 함께 저장될 수 있으므로 저장 전 확인하세요.

### 필터의 오류 처리

지원하는 PWG 해상도는 300×300·600×600dpi입니다. 장치 범위를 벗어나는 용지,
과도한 래스터 크기·패딩, 잘못된 오프셋, 일반 용지의 여백 없는 출력, 중복 복사 수를 거부합니다.
신호 취소·닫힌 출력 파이프·불완전한 헤더나 픽셀도 오류로 처리합니다.
이미 앞 페이지를 처리했어도 뒤 페이지가 잘렸다면 전체 작업을 성공으로 보고하지 않습니다.

PDF·이미지 작업의 페이지 집계는 Apple 렌더러에 맡기고, 직접 래스터 입력은 최종 필터에서
집계하여 중복을 방지합니다. 이 검사는 데이터 형식과 오류 처리 검증이며 기기 발열 시험은
아닙니다. 필터는 모터·헤드 전류나 열 보호 장치를 제어하지 않습니다.

## 공유와 보안

공유는 설치 화면에서 선택할 때만 켜집니다. 다음 세 설정이 함께 필요합니다.

| 설정 | 효과 |
|---|---|
| `cupsctl --share-printers` | 로컬 네트워크에서 CUPS 접근 허용 |
| `printer-is-shared=true` | 해당 큐를 공유 대상으로 지정 |
| `brairprint` LaunchDaemon | iOS가 찾는 Bonjour `_universal`·URF 정보를 알림 |

macOS가 기본으로 알리는 IPP 정보만으로는 iPhone에 프린터가 보이지 않습니다.
`brairprint`는 네트워크에 이름과 기능을 알리며, 실제 출력은 기존 CUPS 경로가 수행합니다.
휴대폰에서 인쇄하는 동안 맥이 켜져 있어야 합니다.

**공유가 켜지면 같은 서브넷의 누구나 비밀번호 없이 인쇄할 수 있습니다.**
설정은 노트북이 접속하는 다른 네트워크에도 유지됩니다. 집처럼 신뢰하는 네트워크에서만
사용하고 공공 Wi-Fi에서는 끄세요. 공유 포트를 인터넷으로 포워딩하지 마세요.
큐 관리에는 시스템 사용자 인증이 필요하며, 이 설치는 CUPS 웹 인터페이스를 켜지 않습니다.

공유를 중지하고 재부팅 시에도 켜지지 않게 하려면 다음을 실행합니다.

```sh
sudo launchctl bootout system/com.hwisu.dcp-t420w.airprint
sudo rm -f /Library/LaunchDaemons/com.hwisu.dcp-t420w.airprint.plist
sudo cupsctl --no-share-printers
```

`--no-share-printers`는 다른 공유 프린터에도 영향을 줄 수 있습니다. 큐의 공유 표시까지
해제하려면 `sudo lpadmin -p Brother_DCP_T420W -o printer-is-shared=false`를 실행합니다.
업그레이드는 기존 공유 상태를 보존할 수 있으므로 설치 화면에서 선택하지 않았다는
이유만으로 기존 공유가 꺼졌다고 판단하지 마세요.

실제 네트워크 알림과 데몬 상태는 다음으로 확인합니다.

```sh
ippfind -T 6 _ipp._tcp.local. -x echo "{service_name} URF=[{txt_URF}] rp=[{txt_rp}]" \;
sudo launchctl print system/com.hwisu.dcp-t420w.airprint
```

로그는 `/var/log/brairprint.log`에 있습니다. 휴대폰 스캔은 이 공유 경로의 기능이 아닙니다.

## 스캔 UI와 명령줄 도구

### 이미지 캡처

Brother는 이 모델에서 별도 **Scanner Driver (ICA)**를 설치해 macOS **이미지 캡처**를
사용하는 방법을 [공식 설명서](https://support.brother.com/g/s/id/htmldoc/mfc/cv_dcp220/mexlte/html/GUID-6A4819EC-1724-4DEE-ABA5-BC35B08593A0_70.html)에 안내합니다.
[다운로드 페이지](https://support.brother.com/g/b/downloadtop.aspx?c=eu_ot&lang=en&prod=dcpt420w_all)에서
OS별 드라이버 제공 여부를 확인하세요. USB 연결은 ‘기기’, 네트워크 연결은 ‘공유됨’에서
선택하고 ‘세부사항 보기’를 눌러 형식·저장 위치·스캔 영역을 설정합니다.

이 프로젝트의 PPD와 `brscan`은 ICA 장치 드라이버를 설치하지 않습니다.
이미지 캡처 인식이나 Brother 드라이버의 최신 OS 호환성을 이 프로젝트의 인쇄 성공 여부로
판단해서는 안 됩니다. 네트워크 스캔은 프린터가 맥에서 접근 가능한 상태여야 합니다.

### brscan

```sh
brscan                                      # 전체 유리판, 컬러, PDF
brscan --mode gray --out receipt.pdf
brscan --mode lineart --rotate 180 --out doc.pdf
brscan --crop a6 --out photo.jpg
brscan --raw --out original.jpg
brscan --caps
brscan --list
brscan --help
```

Swift 네이티브 구현은 Bonjour·URLSession·ImageIO·CoreGraphics를 사용하며 별도의
Python·SANE·ICA가 필요하지 않습니다. `scanner/brscan.py`는 Python 대체 구현입니다.
이 구현의 이미지 변환은 macOS의 `sips`를 사용합니다.

### 펌웨어의 스캔 제약

측정한 DCP-T420W 펌웨어는 eSCL 요청 본문의 스캔 설정을 무시했습니다.
흑백·PDF·해상도·영역을 요청해도 전체 유리판을 컬러 JPEG, 고정 크기로 반환했습니다.
따라서 올바른 요청을 보내되 다음 처리는 맥에서 수행합니다.

| 옵션 | 처리 위치 |
|---|---|
| `--mode gray/lineart` | 맥에서 회색조·임계값 변환 |
| `--crop`, `--rotate` | 맥에서 자르기·회전 |
| `--format pdf/jpeg/png` | 맥에서 형식 변환 |
| `--dpi`, `--intent` | 기기에 요청하지만 측정한 펌웨어에서는 무시됨 |
| `--raw` | 로컬 처리를 생략하고 받은 바이트 그대로 저장 |

반환 영상은 1680×2195px로 측정됐고 가로·세로의 실효 DPI가 다릅니다.
자르기는 보고된 유리판의 물리 치수에 따라 두 축을 각각 환산합니다.
PDF 크기는 요청 DPI가 아닌 실제 스캔 영역을 기준으로 기록하며, 90°·270° 회전 시
가로·세로 크기를 교환합니다. 이 보정은 회색조·흑백 변환 후에도 유지됩니다.

자동 급지 장치가 없으므로 한 번에 한 장이며 양면 자동 스캔도 지원하지 않습니다.
잘못된 자르기 크기·회전·임계값은 네트워크 요청 전에 거부합니다. 잘린 다운로드,
잘못된 기능 응답, 유효하지 않은 유리판 크기를 성공으로 처리하지 않습니다.
네이티브 클라이언트는 Ctrl+C·SIGTERM 시 다운로드를 취소하고 스캔 작업 삭제를 시도하며
130·143 상태로 종료합니다. 장치가 응답하지 않는 경우 작업 삭제는 보장할 수 없습니다.
여러 페이지가 반환되면 덮어쓰지 않도록 `scan.pdf`, `scan-2.pdf`처럼 저장합니다.

## 검증과 진단

```sh
make check
```

빌드, 자동 회귀 검사, PPD 재생성 일치 검사, `cupstestppd`, 셸 구문 검사를 실행합니다.
Python 선택은 `PYTHON=/path/to/python3 make check`로 지정할 수 있습니다.
기존 빌드 검증 환경은 Apple Swift 6.4, Apple Clang 21, Python 3.14.6입니다.

검사 범위는 다음과 같습니다.

- 래스터 패딩·색상 변환·기하 범위·불완전한 입력·취소·출력 파이프 오류
- 모든 등록 용지 크기, 가로 방향, 1·10·11부, CUPS·PWG·URF 경로와 페이지 집계
- 기본 역순, 명시적 정순·역순, 홀수·짝수 선택 후 실제 페이지 픽셀 순서
- 로컬 가상 eSCL 서버를 사용한 잘못된 옵션·응답·작업 해제·이미지 처리·PDF 물리 크기

이 검사는 실제 프린터를 검색하거나 출력·스캔하지 않습니다. 하드웨어 확인과 구분하세요.
`BROTHER_FILTER`, `BROTHER_SCANNER` 환경 변수로 패키지에서 추출한 실행 파일이나
sanitizer 빌드를 지정할 수 있습니다.

설치된 버전·필터와 프린터 설정을 확인하려면 다음을 사용합니다.

```sh
pkgutil --pkg-info com.hwisu.dcp-t420w
shasum -a 256 /usr/libexec/cups/filter/rastertobrother
lpstat -p -d
lpoptions -p Brother_DCP_T420W -l
scripts/probe.sh
brscan --caps
```

소스 폴더만 업데이트해도 설치된 실행 파일이 바뀌지는 않습니다. 실제 드라이버 업데이트에는
설치 과정이 필요합니다. 필터 출력의 디코딩 예시는
[영문 기술 안내의 Verification](TECHY_README.md#verification)에 있습니다.
장치의 전력·발열·장기 연속 사용은 자동 회귀 검사로 검증할 수 없습니다.

## 제거하기

소스 폴더에서 다음을 실행합니다.

```sh
sudo ./uninstall.sh
sudo rm -f /usr/local/bin/brscan
sudo pkgutil --forget com.hwisu.dcp-t420w
sudo pkgutil --forget com.hwisu.dcp-t420w.sharing
```

공유를 켰던 경우 다른 프린터에 미치는 영향을 확인한 뒤
`sudo cupsctl --no-share-printers`로 시스템 공유도 해제하세요.
별도로 설치한 Brother ICA 드라이버는 이 제거 스크립트의 대상이 아닙니다.

## 파일 안내와 다른 모델 적용

| 파일·폴더 | 역할 |
|---|---|
| `filter/rastertobrother.c` | CUPS 필터, libcups 사용 |
| `scripts/genppd.py` | PPD 생성 원본, 용지·옵션·기본값 |
| `ppd/Brother-DCP-T420W.ppd` | 생성 결과, 직접 수정 대신 생성기 수정 |
| `scanner/brscan.swift`, `scanner/brscan.py` | 스캔 도구 |
| `airprint/brairprint.c` | AirPrint 알림 |
| `packaging/` | 설치 파일 생성과 설치 후 큐 갱신 |
| `test/` | 래스터·스캔·macOS 인쇄 경로 검사 |
| `scripts/probe.sh` | 실제 장치의 IPP 기능 조회 |
| `PITFALLS.md` | 실측한 기기 특성·주의사항 상세 기록 |

다른 모델은 먼저 `scripts/probe.sh`로 PWG Raster 지원, 용지·여백·품질 정보를 확인하고
생성기의 `MEDIA`와 관련 상수를 수정해야 합니다. 비슷한 모델명만으로 호환을 단정하지 마세요.
