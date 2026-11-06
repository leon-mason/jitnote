# 弹窗挂着时 NSApp.terminate 不生效

## 现象

Mac 版下载完新版本后点「退出并安装」，弹窗一直停在「正在等同步完成，完成后自动退出…」，App 不退出。

## 复现

最小 SwiftUI App：主窗口用 `.sheet` 弹出一个窗口，弹窗出现 1 秒后在主线程调用 `NSApp.terminate(nil)`。

- 直接调用：`terminate` 立即返回，`applicationWillTerminate` 没被调用，进程一直在运行。
- 先对每个窗口 `window.endSheet(window.attachedSheet!)`，再调用 `terminate`：`applicationWillTerminate` 被调用，进程正常退出。

环境：macOS 27，Command Line Tools 的 MacOSX26.5 SDK，`swiftc -parse-as-library` 直接编译。

## 结论

AppKit 在窗口挂着 sheet 时会悄悄忽略 `terminate(_:)`。「退出并安装」的按钮本身就在更新弹窗里，所以退出前要先关掉所有挂着的弹窗。修复在 `mac/Sources/UI/HistoryAndUpdates.swift` 的 `quitForInstall()`。
