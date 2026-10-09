package com.ordo.desktop.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 备注的轻量 Markdown 预览。
 *
 * 支持(与各端一致的最小子集):`# 标题`、`- 列表`、`> 引用`、`**加粗**`、`` `代码` ``、`[链接](地址)`。
 */
@Composable
fun MarkdownNote(text: String, modifier: Modifier = Modifier) {
    val colors = ordoColors
    val lines = remember(text) { text.lines() }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        lines.forEach { raw ->
            val line = raw.trimEnd()
            when {
                line.startsWith("### ") -> BlockText(line.removePrefix("### "), OrdoType.bodyStrong, colors.textPrimary, colors)
                line.startsWith("## ") -> BlockText(line.removePrefix("## "), OrdoType.bodyStrong, colors.textPrimary, colors)
                line.startsWith("# ") -> BlockText(line.removePrefix("# "), OrdoType.title, colors.textPrimary, colors)
                line.startsWith("- ") || line.startsWith("* ") -> Row(verticalAlignment = Alignment.Top) {
                    Text("•", style = OrdoType.body, color = colors.textSecondary)
                    Spacer(Modifier.width(6.dp))
                    BlockText(line.drop(2), OrdoType.body, colors.textPrimary, colors, Modifier.weight(1f))
                }
                line.startsWith("> ") -> Row(verticalAlignment = Alignment.Top) {
                    Box(
                        Modifier
                            .width(2.dp)
                            .height(18.dp)
                            .background(colors.hairline, RoundedCornerShape(OrdoRadius.pill))
                    )
                    Spacer(Modifier.width(8.dp))
                    BlockText(line.removePrefix("> "), OrdoType.caption, colors.textSecondary, colors, Modifier.weight(1f))
                }
                line.isBlank() -> Spacer(Modifier.height(OrdoSpace.xs))
                else -> BlockText(line, OrdoType.body, colors.textPrimary, colors)
            }
        }
    }
}

@Composable
private fun BlockText(
    text: String,
    style: androidx.compose.ui.text.TextStyle,
    color: Color,
    colors: com.ordo.desktop.ui.theme.OrdoPalette,
    modifier: Modifier = Modifier
) {
    Text(
        text = markdownInline(text, colors.accent, colors.chipBg),
        style = style,
        color = color,
        modifier = modifier.fillMaxWidth()
    )
}

private val INLINE_RE = Regex("\\*\\*(.+?)\\*\\*|`([^`]+)`|\\[(.+?)]\\((.+?)\\)")

/** 行内标记 → AnnotatedString */
fun markdownInline(text: String, accent: Color, codeBackground: Color): AnnotatedString = buildAnnotatedString {
    var last = 0
    INLINE_RE.findAll(text).forEach { match ->
        if (match.range.first > last) append(text.substring(last, match.range.first))
        val bold = match.groupValues[1]
        val code = match.groupValues[2]
        val link = match.groupValues[3]
        when {
            bold.isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(bold) }
            code.isNotEmpty() -> withStyle(
                SpanStyle(fontFamily = FontFamily.Monospace, background = codeBackground)
            ) { append(code) }
            link.isNotEmpty() -> withStyle(
                SpanStyle(color = accent, textDecoration = TextDecoration.Underline)
            ) { append(link) }
        }
        last = match.range.last + 1
    }
    if (last < text.length) append(text.substring(last))
}

/** 单行纯文本预览(去掉 Markdown 记号,用于列表行) */
fun plainPreview(note: String, limit: Int = 90): String {
    if (note.isBlank()) return ""
    val clean = note
        .replace(Regex("^#{1,3}\\s*", RegexOption.MULTILINE), "")
        .replace(Regex("^[->*]\\s*", RegexOption.MULTILINE), "")
        .replace("**", "")
        .replace("`", "")
        .replace(Regex("\\[(.+?)]\\((.+?)\\)"), "$1")
        .replace(Regex("\\s+"), " ")
        .trim()
    return if (clean.length <= limit) clean else clean.take(limit) + "…"
}
