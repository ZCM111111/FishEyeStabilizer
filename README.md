# FishEye Stabilizer

实时鱼眼矫正 + 地平线防抖 iOS App（类似大疆 HorizonSteady）

## 功能

- **实时拍摄** — 拍摄时实时矫正鱼眼畸变 + 地平线保持水平
- **后期处理** — 对相册中的视频进行离线矫正和防抖
- **自动检测** — AI 自动分析视频中的鱼眼畸变参数
- **镜头预设** — 内置 DJI / GoPro / Insta360 / SONY 等 22 种预设

## 技术要求

- iOS 17.0+
- iPhone 13+ (Metal 3 GPU)
- Xcode 15.0+
- Swift 5.9

## 本地开发

```bash
# 1. 安装 XcodeGen
brew install xcodegen

# 2. 生成 Xcode 工程文件
xcodegen generate

# 3. 打开工程
open FishEyeStabilizer.xcodeproj

# 4. 在 Xcode 中选择真机运行 (Metal 着色器需要真机)
```

## Codemagic CI/CD

项目已配置 [Codemagic](https://codemagic.io) 自动构建:

| 工作流 | 触发条件 | 产出 |
|--------|---------|------|
| `debug-build` | push 到 `develop` | 模拟器 .app |
| `release-build` | push 到 `main` / tag `v*` | TestFlight IPA |
| `pr-check` | Pull Request | 编译检查 |

### Codemagic 设置步骤

1. 将项目推送到 GitHub/GitLab
2. 在 [codemagic.io](https://codemagic.io) 连接仓库
3. 在 Codemagic → App Settings → Environment variables 中配置:
   - `APPLE_DEVELOPER_TEAM` — 你的 Apple Developer Team ID
   - `APP_STORE_CONNECT_KEY_ID` — App Store Connect API Key
   - `APP_STORE_CONNECT_ISSUER_ID` — API Key Issuer ID
4. 推送代码即可自动触发构建
