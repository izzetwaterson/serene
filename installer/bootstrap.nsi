;==============================================================================
; Serene - tek dosyalik kurulum TASIYICISI
;
; Bu betik bir kurulum sihirbazi DEGILDIR: hicbir pencere, sayfa ya da metin
; cizmez. Tek isi, iki klasoru gecici bir yere acip ozel Flutter kurulum
; uygulamasini (`installer_app/`) calistirmak ve bitince temizlemektir. Boylece
; kullaniciya tek bir `Serene-Setup-X.Y.Z.exe` verilir, gorunen her sey ise
; Flutter arayuzudur.
;
;   ui\       Flutter kurulum uygulamasi (SereneSetup.exe + DLL'ler + data\)
;   payload\  kurulacak Serene dosyalari (yayin klasoru)
;
; Komut satiri bayraklari aynen Flutter uygulamasina iletilir (`--silent`,
; `--dir KLASOR`, `--autostart`, `--no-startmenu`, `--lang tr|en` ...).
;
; Derleme (scripts/release.mjs yapar):
;   makensis /INPUTCHARSET UTF8 ^
;     -DSERENE_VERSION=1.0.0 -DSERENE_VERSION_QUAD=1.0.0.0 ^
;     -DSERENE_STAGE=<yayin klasoru> -DSETUP_UI=<Flutter Release klasoru> ^
;     -DSERENE_ICON=<app_icon.ico> -DOUTFILE=<cikti.exe> ^
;     installer\bootstrap.nsi
;==============================================================================

Unicode true
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!insertmacro GetParameters

!ifndef SERENE_VERSION
  !error "SERENE_VERSION verilmedi (scripts/release.mjs gecirir)"
!endif
!ifndef SERENE_STAGE
  !error "SERENE_STAGE verilmedi"
!endif
!ifndef SETUP_UI
  !error "SETUP_UI verilmedi (flutter build windows --release, installer_app)"
!endif
!ifndef OUTFILE
  !define OUTFILE "Serene-Setup-${SERENE_VERSION}.exe"
!endif

Name "Serene"
OutFile "${OUTFILE}"
SetCompressor /SOLID lzma
SetCompressorDictSize 32

; Gorunur hicbir sey yok.
SilentInstall silent
RequestExecutionLevel user
ShowInstDetails nevershow
AutoCloseWindow true

!ifdef SERENE_ICON
  Icon "${SERENE_ICON}"
!endif

!ifdef SERENE_VERSION_QUAD
  VIProductVersion "${SERENE_VERSION_QUAD}"
  VIAddVersionKey "ProductName" "Serene"
  VIAddVersionKey "FileDescription" "Serene Setup"
  VIAddVersionKey "FileVersion" "${SERENE_VERSION}"
  VIAddVersionKey "ProductVersion" "${SERENE_VERSION}"
  VIAddVersionKey "LegalCopyright" "MIT License"
!endif

Var work
Var params
Var code

Section
  ; Gecici calisma klasoru: surume ozel, onceki yarim kalmis denemeyi ezer.
  StrCpy $work "$TEMP\SereneSetup-${SERENE_VERSION}"
  RMDir /r "$work"

  SetOutPath "$work\ui"
  File /r "${SETUP_UI}\*.*"

  SetOutPath "$work\payload"
  File /r "${SERENE_STAGE}\*.*"

  ; Cagiranin verdigi bayraklari oldugu gibi ilet.
  ${GetParameters} $params

  SetOutPath "$work\ui"
  ClearErrors
  ExecWait '"$work\ui\SereneSetup.exe" --payload "$work\payload" --version ${SERENE_VERSION} $params' $code
  ${If} ${Errors}
    StrCpy $code 1
  ${EndIf}

  ; Calisma klasorunu temizle. Calisma dizinini disari al: kilitli klasor
  ; silinemez.
  SetOutPath "$TEMP"
  RMDir /r "$work"

  SetErrorLevel $code
SectionEnd
