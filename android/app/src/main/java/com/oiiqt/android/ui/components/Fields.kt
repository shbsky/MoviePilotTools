package com.oiiqt.android.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.border
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.oiiqt.android.ui.theme.LocalOiiColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun BasicField(
    value: String,
    placeholder: String,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
    /**
     * 软键盘右下角动作键。单行框默认给「完成」——默认的 Default 在部分输入法上是回车，
     * 按下去既不收键盘也不做事，用户会以为卡住了；搜索框可传 Search 配合 [onImeAction]。
     */
    imeAction: ImeAction = ImeAction.Done,
    /** 用户按下键盘动作键（完成/搜索）时回调 */
    onImeAction: (() -> Unit)? = null,
    /** 密码类字段：默认打码，右侧带「眼睛」可临时查看 */
    secret: Boolean = false,
    onChange: (String) -> Unit
) {
    val colors = LocalOiiColors.current
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    var revealed by remember { mutableStateOf(false) }

    // 键盘弹出后把当前输入框滚到可见区域，避免遮住下面一行（密码框）
    val bringIntoView = remember { BringIntoViewRequester() }
    val scope = rememberCoroutineScope()

    // 描边色：textSecondary 低透明度，浅色主题下约为 #DADADD，深浅主题都清晰可见
    val fieldBorder = colors.textSecondary.copy(alpha = 0.28f)
    val fieldShape = RoundedCornerShape(9.dp)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .bringIntoViewRequester(bringIntoView)
            .height(38.dp)
            .clip(fieldShape)
            .background(colors.background)
            .border(1.dp, fieldBorder, fieldShape)
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.CenterStart
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) {
                    Text(placeholder, fontSize = 14.sp, color = colors.textSecondary, maxLines = 1)
                }
                BasicTextField(
                    value = value,
                    onValueChange = onChange,
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 14.sp, color = colors.textPrimary),
                    cursorBrush = SolidColor(colors.accent),
                    keyboardOptions = KeyboardOptions(
                        keyboardType = if (secret && !revealed) KeyboardType.Password else keyboardType,
                        imeAction = imeAction
                    ),
                    // 按「完成 / 搜索」一律先收键盘：留在屏幕上会挡住下面的字段和按钮
                    keyboardActions = KeyboardActions(
                        onSearch = { focusManager.clearFocus(); keyboardController?.hide(); onImeAction?.invoke() },
                        onDone = { focusManager.clearFocus(); keyboardController?.hide(); onImeAction?.invoke() },
                        onGo = { focusManager.clearFocus(); keyboardController?.hide(); onImeAction?.invoke() }
                    ),
                    visualTransformation = if (secret && !revealed) {
                        PasswordVisualTransformation()
                    } else {
                        VisualTransformation.None
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .onFocusChanged { focusState ->
                            if (focusState.isFocused) {
                                scope.launch {
                                    // 等软键盘展开动画（约 250~300ms）结束再滚，否则算出的可视区还是旧的
                                    delay(320)
                                    bringIntoView.bringIntoView()
                                }
                            }
                        }
                )
            }
            if (secret) {
                Icon(
                    imageVector = if (revealed) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                    contentDescription = if (revealed) "隐藏" else "显示",
                    tint = colors.textSecondary,
                    modifier = Modifier
                        .size(17.dp)
                        .clickable { revealed = !revealed }
                )
            }
        }
    }
}

@Composable
fun FieldLabel(text: String, trailing: (@Composable () -> Unit)? = null) {
    val colors = LocalOiiColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(text, fontSize = 12.sp, color = colors.textSecondary)
        if (trailing != null) {
            Box(Modifier.weight(1f))
            trailing()
        }
    }
}

/**
 * 多行输入框：一个框里填多个地址（内网 IP + 公网域名，一行一个）。
 * 风格和 [BasicField] 保持一致，只是不限单行、高度跟着内容走。
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun BasicFieldMulti(
    value: String,
    placeholder: String,
    modifier: Modifier = Modifier,
    minLines: Int = 2,
    onChange: (String) -> Unit
) {
    val colors = LocalOiiColors.current
    val bringIntoView = remember { BringIntoViewRequester() }
    val scope = rememberCoroutineScope()

    // 与 BasicField 同款描边，多行框保持风格统一
    val fieldBorder = colors.textSecondary.copy(alpha = 0.28f)
    val fieldShape = RoundedCornerShape(9.dp)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .bringIntoViewRequester(bringIntoView)
            // 留出两行的高度：用户一眼就能看出这里能填多个地址
            .heightIn(min = 58.dp)
            .clip(fieldShape)
            .background(colors.background)
            .border(1.dp, fieldBorder, fieldShape)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        contentAlignment = Alignment.TopStart
    ) {
        if (value.isEmpty()) {
            Text(placeholder, fontSize = 13.sp, color = colors.textSecondary, lineHeight = 18.sp)
        }
        BasicTextField(
            value = value,
            onValueChange = onChange,
            minLines = minLines,
            textStyle = TextStyle(fontSize = 13.sp, color = colors.textPrimary, lineHeight = 18.sp),
            cursorBrush = SolidColor(colors.accent),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { focusState ->
                    if (focusState.isFocused) {
                        scope.launch {
                            delay(320)
                            bringIntoView.bringIntoView()
                        }
                    }
                }
        )
    }
}
