# 汉化资源包（构建期 · 纯附加）

这个目录是给 fork 仓库追加的**中文界面/报错/日志**支持，**不修改任何现有源码与构建脚本**，
同步主仓库时不会产生冲突。

```
.github/localization/
├── README.md                                   ← 本文件（索引）
└── zh-CN_2026-11-28/                           ← 一套按日期命名的汉化快照
    ├── apply-zh-cn_2026-11-28.ps1               ← 汉化脚本（逐行注释 + 逐条日志）
    ├── strings-zh-cn_2026-11-28.json            ← 翻译映射表
    └── README_zh-CN_2026-11-28.md               ← 详细说明 / 过时排查指南

Managed Source/Directory.Build.targets           ← 自动接入点（新增文件，不改 build.yml）
```

## 怎么用

什么都不用做：两个现有工作流（`build.yml` / `build-all.yml`）里的
`dotnet build` / `dotnet publish` 会自动导入 `Managed Source/Directory.Build.targets`，
由它在首次编译时调用汉化脚本。产物里的界面、MessageBox、异常文本、Trace/Console 日志
即为中文。

## 想关闭 / 重新应用

* 关闭：删除 `Managed Source/Directory.Build.targets`，或构建时加 `-p:ZH_CN_DISABLE=true`。
* 重新应用：删除 `localization-report/zh-cn_2026-11-28/.applied` 标记文件。
* 同步上游后更新汉化：复制一份新日期目录，改 `Directory.Build.targets` 里的版本路径即可。

完整说明、字段格式、日志释义和排查步骤见
[`zh-CN_2026-11-28/README_zh-CN_2026-11-28.md`](zh-CN_2026-11-28/README_zh-CN_2026-11-28.md)。
