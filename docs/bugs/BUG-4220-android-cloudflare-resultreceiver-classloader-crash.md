## BUG-4220 · Android Cloudflare verification crashes while unparcelling its control callback
- **报告**：2026-11-12（用户）
- **真实性**：✅ 真 bug。Cloudflare challenge Activity 在独立进程 `:network_challenge` 里把匿名 `ResultReceiver` 放进结果 `Bundle`；主进程于 `CloudflareChallengeCoordinator.kt:68` 直接 `getParcelable("control")`，没有给 Bundle 设置应用 classloader。Android 延迟解析 Parcelable 时使用了错误的默认 loader，抛 `BadParcelableException` / `ClassNotFoundException`，致主进程 `FATAL EXCEPTION`。R8 mapping 确认匿名类名仍保留，问题是跨进程 Bundle 的 classloader 未设，不是类被混淆删除。Activity 入口的 `Intent` 也读取了跨进程传来的 `receiver` extra，同样应先设 loader。
- **[x] ① 修复** — `CloudflareChallengeActivity.onCreate` 在读取 Intent Parcelable 前调用 `setExtrasClassLoader`；协调器在 `Bundle.getParcelable("control")` 前设应用 classloader。
- **[x] ② 自动化测试** — `fushi/test/build/cloudflare_challenge_parcel_classloader_guard_test.dart` 钉住两处「先设 classloader、后解包 Parcelable」顺序。该测试与 `:app:testDebugUnitTest -Ptarget-platform=android-arm64 --tests app.fushi.reader.mihon.MihonInjektModuleTest` 均通过；arm64 Release APK 构建成功并已更新安装至 `app.fushi.reader.local`。提交哈希：待提交。
- **备注**：构建后未再次在设备上完成 Cloudflare 验证流程，待用户复测。独立的可选 torrent 库缺失诊断不是该 crash 根因。
