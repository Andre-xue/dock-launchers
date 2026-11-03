# 本地 AI 安装测试：Whisper.cpp + ComfyUI

日期：2026-11-04
机器：MacBook Air M1 / 8GB / 512GB

## 1. Whisper.cpp

### 安装

```bash
brew install whisper.cpp
```

- 版本：1.9.5
- 可执行文件：`/opt/homebrew/bin/whisper-cli`
- 模型：`ggml-base.bin`，141 MB
- 模型路径：`~/Library/Application Support/DockLaunchers/Models/ggml-base.bin`

### 实测

输入：

```text
audit/testdata/sample.wav
```

命令：

```bash
whisper-cli -m ggml-base.bin -f sample.wav -l zh -otxt -of /tmp/whisper_test
```

输出：

```text
你好,这是DogLunchers的测试音频
```

性能：

- 推理 total time：1.379 秒
- 进程总耗时约 14.7 秒（含模型加载）
- 8GB 内存无压力

### DockLaunchers 配置

已写入：

```text
centerSTTEngine = 2
centerWhisperExe = /opt/homebrew/bin/whisper-cli
centerWhisperModel = .../Models/ggml-base.bin
```

## 2. ComfyUI + SD1.5

### 安装

- Python 3.11.18（Homebrew）
- ComfyUI 0.43.0：`~/ComfyUI`
- PyTorch 2.15.0（MPS）
- SD1.5 fp16：`v1-5-pruned-emaonly-fp16.safetensors`，2.13 GB
- 模型路径：`~/ComfyUI/models/checkpoints/`

启动：

```bash
cd ~/ComfyUI
./venv/bin/python main.py --listen 127.0.0.1 --port 8188 --lowvram
```

### 实测

直接 API：

```text
512x512
8 steps
约 52 秒
输出 406 KB PNG
```

DockLaunchers 端到端：

```text
AI 图片生成 → ComfyUI 本地
模型：v1-5-pruned-emaonly-fp16.safetensors
地址：http://127.0.0.1:8188
512x512
```

结果：

```text
已生成：AI图片-20261104-014006.png
```

20 steps 约 2 分钟以上，8GB 可用但偏慢。

### 8GB 建议

```text
只用 SD1.5
512x512
20 steps 以内
不要同时加载 Ollama 3B
```

ComfyUI 加载模型约 1.6GB；生成时系统内存压力明显。

## 当前配置

AI 管理新增：

```text
Ollama 本地
  qwen2.5:3b
  http://127.0.0.1:11434/v1

ComfyUI 本地
  v1-5-pruned-emaonly-fp16.safetensors
  http://127.0.0.1:8188

语音转写
  本地 Whisper
  /opt/homebrew/bin/whisper-cli
  ggml-base.bin
```

## 使用提醒

- Ollama 和 ComfyUI 同时加载会吃紧，建议用哪个开哪个
- 不用时停止：
  - `ollama stop qwen2.5:3b`
  - 关闭 ComfyUI 终端进程
- ComfyUI 8GB 只建议 SD1.5，不要 SDXL/Flux
