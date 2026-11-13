## BUG-4219 · Android manga search crashes when Mihon extensions resolve ProtoBuf from Injekt
- **报告**：2026-11-12（用户）
- **真实性**：✅ 真 bug。Android 的 `MihonChannelHandler` Injekt 模块（`fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt:44-58`）注册了 `Json`，但没有注册 `ProtoBuf`。MANGA Plus 扩展的静态初始化器调用 `Injekt.get<ProtoBuf>()`，抛出 `InjektionException` → `ExceptionInInitializerError` → `NoClassDefFoundError`，最终作为 `DefaultDispatcher-worker` 未捕获异常杀掉 Android 进程。缺少可选的 `libfushi_torrent_ffi.so` 是另一个被 `probeCapabilities` 捕获并记录的诊断，不是这次 fatal exception 的根因。
- **[x] ① 修复** — Android Mihon Injekt 模块现在以显式 `addSingletonFactory<ProtoBuf> { ProtoBuf }` 注册 ProtoBuf，和 sidecar 的修复保持一致。提交哈希：待提交。
- **[x] ② 自动化测试** — `fushi/android/app/src/test/kotlin/app/fushi/reader/mihon/MihonInjektModuleTest.kt` 验证 Android Mihon 模块能解析 `Json` 与 `ProtoBuf`。`:app:testDebugUnitTest -Ptarget-platform=android-arm64 --tests app.fushi.reader.mihon.MihonInjektModuleTest` 通过。
- **备注**：Release APK build 通过并已更新安装至 `app.fushi.reader.local`（`versionCode=1000136802`）。本轮未在设备上重做 MANGA Plus 原始搜索路径；等待用户复测。
