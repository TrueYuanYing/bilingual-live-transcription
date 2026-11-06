# 第三方来源与发布边界

根 LICENSE 只覆盖本人有权许可的代码与本次原创适配/文档；第三方实现、许可证文字、商标与资源不因此改为MIT。没有把“可以查看的网页/目录”当成可以统一再许可的素材库。依赖安装时以锁文件和包内许可为准。

核心为自有Dart实现。reference 中原 `name_matcher.dart` 提及 Sentinel 研究来源，证据不足的文件首次发布排除。sherpa-onnx为Apache-2.0；双语Zipformer的模型版本和本地来源证据在models/README，SenseVoice在models/SENSEVOICE；权重不分发。zh/en单语权重许可未逐项核实，不提供再分发承诺。原文中“随APK打包”的叙述属于产品基线，本仓库不含权重。

模型上游：[双语模型](https://www.modelscope.cn/models/pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20)、[SenseVoice转换](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09)、[原checkpoint](https://huggingface.co/ASLP-lab/WSYue-ASR/tree/main/sensevoice_small_yue)。2026-11-06只读核对：转换页明确原checkpoint；ModelScope动态页未返回可读模型卡，Apache来源说明来自已保存的本地README/许可证，不冒充本轮在线重新认证。

reference 的record、permission_handler、pinyin、sherpa_onnx、Dio等依赖未vendoring；按各依赖自己的许可安装。没有公开上游WAV及其base64副本，也没有用户课堂录音。
