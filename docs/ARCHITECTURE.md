# 原理、真实调用链与接入

`LiveCaptureScreen → startCapture → LiveSessionController` 负责权限、唯一音频源与会话。普通采集使用 `voiceRecognition`，远场优先尝试 mic/48 kHz双声道，再降为16 kHz；设备不支持时回退普通模式。增强是数值处理，不保证任意课堂收音准确率。

`asr_engine_factory` 的 local/zh,en 使用 Sherpa；local/auto 使用共享双语词表的流式 Zipformer，并可用 SenseVoice 二次定稿。worker isolate 管理模型、解码和 native pointer 释放。系统 SpeechRecognizer 自行占麦，可能联网，不能称为保证离线。

partial 通常是从当前 utterance 开始的完整假设。周期快照只 commit 已见文本，不重置 decoder；final 按确认前缀和重叠切出尾部，必要修订由会话层处理。单独调用 `finish` 不等于已实现完整 UI 修订链。窗口只影响听写页排版，存储仍保留完整转写。

姓名、学号、关键词与提问规则在本机运行。后台通知走 Android system_alert channel；云端答题/翻译/纠错/摘要通过独立 AI 服务与服务端授权计量。不能把云端问答说成离线识别。云服务不可用时本地采集/笔记不应被账号刷新拆掉。

## 接入步骤

1. 先将 `lib/services/asr`、`audio` 中所需核心放入自己的 Dart package，按原始接口传入 PCM；每条音频流只创建一个权威采集器。
2. Flutter 真识别接入需要 record、permission_handler、sherpa_onnx、模型管理与引擎工厂。参考文件有完整原调用，但还依赖宿主 providers/存储；按自己的应用注入这些端口，不直接复制整个 MainActivity。
3. Android 只申请实际需要的 RECORD_AUDIO、麦克风前台服务和通知权限。系统识别 MethodChannel 为 `com.classmate.classmate/system_speech`，事件通道后缀 `_events`；模型为 `com.iko.study/asr_models`。
4. 录音订阅已存在的 `live.audio.stream`，经 `com.iko.study/classroom_recording` 送到 MediaCodec/MediaMuxer。优先 Opus/WebM、兼容回退 AAC/M4A，不另开麦。分享要注入自己的 FileProvider，不依赖笔记模块私有路径。
5. 停止时结束流、取消翻译/纠错任务，等待已排队录音写入，释放 worker/native decoder、通知/前台服务与订阅。页面暂时不可见不等于结束课堂；app 生命周期与用户停止分别处理。

## 常见问题与取舍

字幕重复应先核对上游是否把 partial 当增量；不要每次 commit 都重启解码器。模型无法加载先核文件名、大小、SHA、模型类型与运行库 ABI。本产品原模型管理的就绪检查主要用长度；本仓库工具额外校验 SHA，不把它倒写成生产原行为。

本次只验证合成文本与数值音频。麦克风路由、后台通知、真模型推理、长课性能和导出分享需在自己的设备补测。模型线程/内存、热启动和噪声条件会影响效果，不提供虚构准确率。
