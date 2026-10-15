; ============================================================================
; Ordo（序）· Windows 安装包(NSIS 3.11)
;
; 用 Tauri bundler 自带的那份 NSIS 编译(`%LOCALAPPDATA%\tauri\NSIS\makensis.exe`),
; 但不引入 Tauri 外壳 —— 本端是 Compose Multiplatform(JVM)桌面应用,Tauri 的 WebView
; 外壳对它没有意义(见 README §2「为什么不是 Tauri 应用」),要的只是 NSIS 这个安装器。
;
; 编译:
;   makensis.exe /DSRC_DIR=<app-image 目录> /DOUT_FILE=<输出的 setup.exe> installer\Ordo.nsi
; 或走 Gradle:`gradle :apps:windows:packageNsis`(见 build.gradle.kts)
;
; 安装形态与 jpackage 那套保持一致:**每用户安装**($LOCALAPPDATA\Ordo,不需要管理员),
; 开始菜单 + 桌面快捷方式,自带卸载器(HKCU 的「应用和功能」里可见)。
; 卸载**不动用户数据**(%APPDATA%\Ordo\<id> 保留),但会清掉应用自己注册的
; 开机自启项与 ordo:// 协议(它们都指向安装目录,留着就是死链)。
; ============================================================================

Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 32

!include "MUI2.nsh"
!include "LogicLib.nsh"

; —— 可在命令行覆盖:见上面的编译说明 ——
!ifndef SRC_DIR
  !define SRC_DIR "..\build\compose\binaries\main\app\Ordo"
!endif
!ifndef OUT_FILE
  !define OUT_FILE "..\build\compose\binaries\main\nsis\Ordo_1.0.0_x64-setup.exe"
!endif
!ifndef APP_VERSION
  !define APP_VERSION "1.0.0"
!endif
!ifndef APP_ICON
  !define APP_ICON "..\icons\ordo-ring.ico"
!endif

!define APP_EXE "Ordo.exe"
!define APP_DISPLAY "Ordo（序）"
!define APP_PUBLISHER "Ordo Project"
!define UNINST_EXE "Uninstall.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Ordo"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"

Name "${APP_DISPLAY} ${APP_VERSION}"
OutFile "${OUT_FILE}"
InstallDir "$LOCALAPPDATA\Ordo"
InstallDirRegKey HKCU "Software\Ordo" "InstallDir"
RequestExecutionLevel user

VIProductVersion "1.0.0.0"
VIAddVersionKey /LANG=2052 "ProductName" "${APP_DISPLAY}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_DISPLAY} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "© 2026 Ordo Project"

!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "立即运行 Ordo"
!define MUI_FINISHPAGE_RUN_NOTCHECKED
!define MUI_WELCOMEPAGE_TITLE "${APP_DISPLAY} ${APP_VERSION}"
!define MUI_WELCOMEPAGE_TEXT "本向导会把 ${APP_DISPLAY} 安装到你的电脑,并创建开始菜单与桌面快捷方式。$\r$\n$\r$\nOrdo 是**纯本地**应用:数据只写在本机 %APPDATA%\Ordo,不联服务器,也不需要管理员权限。$\r$\n$\r$\n点「下一步」继续。"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  SetRegView 64

  ; Ordo 默认「关闭窗口 = 最小化到托盘」,进程常常还在跑 —— 直接装会覆盖不了 Ordo.exe。
  ; 探测方式:`tasklist | findstr` 的退出码(0 = 有进程在跑,1 = 没有),本机实测两种状态都验过。
  ; 不用 System::Call + CreateFileW:NSIS 3.11 上取不到它的 HANDLE 返回值($R0 恒为垃圾值),
  ; 那种守卫会静默失效(踩过),而 tasklist 的组合没有这个坑。
  ; 交互安装 → 弹「请先退出 Ordo」并允许重试;静默安装(/S) → 以错误码 2 退出,不半途覆盖文件。
  ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
  ordo_running_check:
    nsExec::ExecToStack 'cmd /c tasklist /FI "IMAGENAME eq ${APP_EXE}" /NH | findstr /I /C:"${APP_EXE}"'
    Pop $R0
    Pop $R1
    ${If} $R0 == 0
      ${If} ${Silent}
        SetErrorLevel 2
        Abort
      ${Else}
        MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Ordo 正在运行,安装程序暂时无法替换它。$\r$\n$\r$\n请右键点击任务栏托盘里的 Ordo 图标 →「退出」,然后点「重试」。$\r$\n(也可以先点「取消」,退出 Ordo 后再运行本安装程序。)" IDRETRY ordo_running_check IDCANCEL ordo_running_abort
      ${EndIf}
    ${EndIf}
  ${EndIf}

  ; 已有旧版本 → 先静默跑它自己的卸载器(升级场景)。`_?=` 让卸载器就地运行、保留残留控制权;
  ; 卸载器只删程序与系统集成,**不动 %APPDATA%\Ordo 的用户数据**。
  ReadRegStr $R0 HKCU "${UNINST_KEY}" "UninstallString"
  ${If} $R0 != ""
    ReadRegStr $R1 HKCU "${UNINST_KEY}" "InstallLocation"
    ${If} $R1 == ""
      StrCpy $R1 "$INSTDIR"
    ${EndIf}
    ExecWait '"$R0" /S _?=$R1' $R2
  ${EndIf}
  Return

  ordo_running_abort:
    Abort
FunctionEnd

Section "Ordo（序）" SecMain
  SectionIn RO
  SetOverwrite on
  SetOutPath "$INSTDIR"

  ; 整棵 app-image:Ordo.exe + app\(jar 与依赖)+ runtime\(裁剪过的 JRE)
  File /r "${SRC_DIR}\*.*"

  WriteUninstaller "$INSTDIR\${UNINST_EXE}"

  SetShellVarContext current
  CreateDirectory "$SMPROGRAMS\Ordo"
  CreateShortCut "$SMPROGRAMS\Ordo\Ordo.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0
  CreateShortCut "$DESKTOP\Ordo.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0

  ; 「应用和功能」里的条目(每用户)
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP_DISPLAY}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\${UNINST_EXE}"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\${UNINST_EXE}" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" 165700

  WriteRegStr HKCU "Software\Ordo" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Ordo" "Version" "${APP_VERSION}"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$SMPROGRAMS\Ordo\Ordo.lnk"
  RMDir "$SMPROGRAMS\Ordo"
  Delete "$DESKTOP\Ordo.lnk"

  ; 应用自己写的系统集成(开机自启 + ordo:// 协议)都指向安装目录,卸载必须一起清掉
  DeleteRegValue HKCU "${RUN_KEY}" "Ordo"
  DeleteRegKey HKCU "Software\Classes\ordo"

  ; 程序本体(Ordo.exe 带只读属性,先复位再删)
  SetFileAttributes "$INSTDIR\${APP_EXE}" NORMAL
  Delete "$INSTDIR\${APP_EXE}"
  SetFileAttributes "$INSTDIR\app" NORMAL
  RMDir /r "$INSTDIR\app"
  SetFileAttributes "$INSTDIR\runtime" NORMAL
  RMDir /r "$INSTDIR\runtime"
  Delete "$INSTDIR\${UNINST_EXE}"
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\Ordo"
  ; 用户数据(%APPDATA%\Ordo\<id>)保留 —— 卸载不删数据,重装即回到原来的库
SectionEnd
