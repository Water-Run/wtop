# wtop locale catalogs

此目录是 wtop 翻译的权威来源，所有目录使用 `.yml`。

- [`manifest.yml`](manifest.yml) 记录计划语言和交付阶段。
- [`_template.yml`](_template.yml) 定义新目录的起始结构。
- 具体 schema、复数、回退、构建与质量门禁见 [国际化计划](../docs/I18N.md)。

`en-US` 与 `zh-CN` 是 0.1 的稳定目录。`zh-TW`、`ja-JP`、`ko-KR`、
`es-ES`、`fr-FR`、`de-DE`、`pt-BR` 和 `ru-RU` 当前为 preview；它们
缺失的 message 会逐 key 回退，不能按完整翻译对外宣传。

约定：

- UTF-8、YAML 1.2、单文档。
- 文件名使用规范 BCP 47 locale，例如 `pt-BR.yml`。
- 禁止 anchors、aliases、merge keys 和自定义 tags。
- 消息参数使用 `{name}` 命名占位符。
- 不拼接自然语言句子。
- 以下划线开头的文件不作为可发布目录。

校验并生成运行时模块：

```bash
lua tools/compile_locales.lua \
  --source locales \
  --output src/wtop/generated/locales
```

CI 使用 `--check` 验证已提交生成物逐字节同步：

```bash
lua tools/compile_locales.lua \
  --source locales \
  --output src/wtop/generated/locales \
  --check
```

编译器会拒绝重复 key、YAML anchor/alias/tag/merge、未知 schema 字段、
非法 message ID、占位符漂移和缺失的 CLDR plural category。生成的
`registry.lua` 对每个内置目录使用字面量 `require`，可被
`luainstaller` 的静态依赖扫描发现。
