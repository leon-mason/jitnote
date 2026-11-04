# 01 — Windows 安装包和两栏窗口

**Source:** [需求规格](<[spec]windows-client.md>)

**What to build:** 在 Mac 上打出 Windows 11 x64 的自包含压缩包。用户把这个包拿到 Windows 11 上安装打开后，看到记特的两栏窗口。界面用笔记本、同步、历史版本、云端账号这些说法。

**Blocked by:** None — can start immediately

**Status:** ready-for-agent

- [ ] 在 Mac 上完成编译和打包，得到 Windows 11 x64 的自包含压缩包，里面的程序可以直接运行
- [ ] 不把 Windows 10、更早的系统，或 Windows on ARM 当作这一版的安装包
- [ ] 在 Windows 11 上安装打开后，能看到两栏窗口
- [ ] 界面不出现 Git、Markdown、仓库、提交、分支、push、merge
