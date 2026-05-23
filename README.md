# Garen Tech Notes

Garen 的个人技术知识库，用于沉淀源码阅读、Runtime 机制分析、工程排障和长期技术笔记。

## 目录约定

- `runtime/`：Runtime 相关源码阅读、机制分析、API 行为说明
- 后续可按主题继续增加目录，例如：
  - `cpp/`
  - `linux/`
  - `ai-infra/`
  - `debugging/`
  - `architecture/`

## 当前内容

- `runtime/context-global-role.md`：Runtime Context 全局作用说明，以及 Context 与 Stream 的关系分析
- `code-reading/runtime-context-mechanism-guide.md`：Runtime Context 防 UAF 重构后的机制导读
- `code-reading/runtime-context-uaf-refactor-review-8fbd393a.md`：`8fbd393a` Context 防 UAF 重构审查，包含保护机制、漏点和修复建议

## GitHub 私有归档

如果需要把本知识库上传到 GitHub 私有仓库，先设置：

```bash
export GITHUB_TOKEN="<your_github_token>"
```

然后在本目录执行：

```bash
./scripts/publish-github-private.sh
```

默认仓库名：`garen-tech-notes`。
