# IKO 双语离线模型

模型：sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20。
用途：同一流式模型识别普通话、英语和句内混说。CPU / int8 encoder + joiner / greedy search / 2 threads。

- 官方说明：https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html
- 发布者镜像：https://www.modelscope.cn/pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20
- 来源模型卡标注 Apache License 2.0，许可全文见 LICENSE-2.0.txt。
- 下载日期：2026-09-21。权重未修改，仅重命名以兼容原模型加载接口。

| 包内文件 | 上游文件 | SHA-256 |
| --- | --- | --- |
| encoder.int8.onnx | encoder-epoch-99-avg-1.int8.onnx | 8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b |
| decoder.onnx | decoder-epoch-99-avg-1.onnx | 2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d |
| joiner.onnx | joiner-epoch-99-avg-1.int8.onnx | 1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0 |
| tokens.txt | tokens.txt | a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3 |

本轮 tokens.txt 与旧小双语模型逐字节相同（SHA-256 相同）；其余三个文件长度均改变，ModelManager 会替换旧版本，随后按完整文件长度检查就绪。不要以同长度占位文件替代模型。

这是本地开源模型，有限回归样本不代表达到豆包云端识别的总体准确率。
