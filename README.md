# 课堂实时听写（中英文双语）

从已发布课堂助手提取真实的流式假设去重、分句、英文术语规范、二次定稿选择、PCM 增强与48 kHz双声道转16 kHz单声道处理。纯 Dart 核心可独立运行；真实 ASR、单路采集、录音和通知桥接保留在 `reference/`，不会把文本示例称为完整语音识别应用。

## 快速运行

需要 Dart >=3.4，验证环境为 Dart 3.13.2。

```sh
dart pub get
dart run example/main.dart
dart test
dart analyze lib test
```

示例先确认“今天介绍 Fourier transform”，再接收更长 final，输出新增尾部“的性质”。原算法未为这次抽取重新优化。模型不在仓库内；[models](models) 保留版本、来源、SHA 与 Apache 许可材料，[模型获取工具](tool/models.py) 只在明确传入 `--download` 时下载。

## 源码导航

| 代码 | 职责 |
| --- | --- |
| `lib/services/asr/streaming_hypothesis_tracker.dart` | partial 是整段假设，commit 保存前缀，真实 final 只追加剩余内容 |
| `transcript_refiner.dart`、`live_transcript_window.dart` | 本地排版与有限可见窗口，不截断保存的完整课堂 |
| `dual_pass_result_picker.dart` | 二次结果丢英文或中文覆盖不足时保留流式结果 |
| `lib/services/audio/` | 增益/峰值保护、跨任意分块 PCM 降采样 |
| `reference/flutter/lib/services/asr/live_session_controller.dart` | 原会话、预警、翻译/纠错队列与保存协调 |
| `reference/android/` | 系统识别、前台服务、模型安装与音频编码桥接 |

[原理、接入与排错](docs/ARCHITECTURE.md) · [本次验证](VALIDATION.md) · [来源与许可](THIRD-PARTY.md) · [总览](https://github.com/TrueYuanYing/study-app-modules)

姓名/学号预警原实现在 reference 的 alert/name_matcher，依赖 pinyin；注释提到 Sentinel 研究来源，尚未确认足够的权属证据，因此该文件未纳入首次公开白名单。规则接口和上下文抓取仍可参考，不能据此宣称独立示例含完整点名识别。
