# Ollama 安装与 DockLaunchers 联调测试

日期：2026-11-04
机器：MacBook Air M1 / 8GB / 512GB

## 安装结果

- 安装包：官方 `Ollama-darwin.zip`
- 安装位置：`/Applications/Ollama.app`
- 版本：`0.40.14`
- 服务地址：`http://127.0.0.1:11434`
- 签名校验：通过 `codesign --verify --deep --strict`

## 模型

Ollama 官方 registry 的 blob 域名被当前网络解析到非公网地址，`ollama pull qwen2.5:3b` 失败。

改用 Hugging Face GGUF 导入：

```text
Qwen/Qwen2.5-1.5B-Instruct-GGUF
qwen2.5-1.5b-instruct-q4_k_m.gguf
```

本地模型名：

```text
qwen2.5:1.5b
```

大小：1.1 GB
加载占用：约 977 MB，100% GPU（Metal）
上下文：4096

## API 测试

请求：

```text
POST http://127.0.0.1:11434/v1/chat/completions
model: qwen2.5:1.5b
```

结果：

```text
HTTP 200
耗时约 4.59 秒
prompt_tokens: 34
completion_tokens: 27
total_tokens: 61
```

回答：

```text
我是一个基于机器学习和自然语言处理技术的AI助手，可以回答各种问题、提供帮助和进行对话交流。
```

## DockLaunchers 联调

AI 管理已配置：

```text
名称：Ollama 本地
分类：文本
模型：qwen2.5:1.5b
地址：http://127.0.0.1:11434/v1
API Key：留空/本地占位
```

AI 助手端到端测试成功：

```text
输入：用一句中文回答：DockLaunchers 是什么？
输出：DockLaunchers是一款桌面应用，用于管理Dock图标。
```

界面轮询 1 次即拿到结果，未出现卡死或崩溃。

## 8GB 结论

- 1.5B Q4：可用，Metal GPU 加载，日常轻量对话/翻译/总结流畅
- 3B：建议网络恢复后 `ollama pull qwen2.5:3b`
- 7B：不建议常驻，8GB 容易内存压力
- 不使用时执行 `ollama stop qwen2.5:1.5b` 释放内存
