package com.ordo.desktop.ui.common

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronLeft
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DarkMode
import androidx.compose.material.icons.outlined.DateRange
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.DragIndicator
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FormatListBulleted
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Label
import androidx.compose.material.icons.outlined.LightMode
import androidx.compose.material.icons.outlined.MenuBook
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Notes
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Undo
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * 图标集合(全部来自 material-icons-extended,不引入任何外部资源)。
 * 集中一处便于替换与统一尺寸。
 */
object OrdoIcons {
    val Inbox: ImageVector = Icons.Outlined.Inbox
    val Today: ImageVector = Icons.Outlined.Star
    val Upcoming: ImageVector = Icons.Outlined.DateRange
    val Anytime: ImageVector = Icons.Outlined.FormatListBulleted
    val Someday: ImageVector = Icons.Outlined.Archive
    val Logbook: ImageVector = Icons.Outlined.MenuBook
    val Area: ImageVector = Icons.Outlined.Folder
    val Tag: ImageVector = Icons.Outlined.Label
    val Search: ImageVector = Icons.Outlined.Search
    val Close: ImageVector = Icons.Outlined.Close
    val Add: ImageVector = Icons.Outlined.Add
    val Check: ImageVector = Icons.Outlined.Check
    val CheckCircle: ImageVector = Icons.Outlined.CheckCircle
    val Calendar: ImageVector = Icons.Outlined.CalendarToday
    val Bell: ImageVector = Icons.Outlined.NotificationsNone
    val Flag: ImageVector = Icons.Outlined.Flag
    val Repeat: ImageVector = Icons.Outlined.Repeat
    val Note: ImageVector = Icons.Outlined.Notes
    val Checklist: ImageVector = Icons.Outlined.FormatListBulleted
    val Drag: ImageVector = Icons.Outlined.DragIndicator
    val More: ImageVector = Icons.Outlined.MoreHoriz
    val Delete: ImageVector = Icons.Outlined.DeleteOutline
    val Copy: ImageVector = Icons.Outlined.ContentCopy
    val Settings: ImageVector = Icons.Outlined.Settings
    val Dark: ImageVector = Icons.Outlined.DarkMode
    val Light: ImageVector = Icons.Outlined.LightMode
    val ChevronRight: ImageVector = Icons.Outlined.ChevronRight
    val ChevronLeft: ImageVector = Icons.Outlined.ChevronLeft
    val ExpandMore: ImageVector = Icons.Outlined.ExpandMore
    val Sync: ImageVector = Icons.Outlined.Sync

    /** 状态栏刷新控件(04-UI规范 §5.3):点一下连续旋转到同步结束 */
    val Refresh: ImageVector = Icons.Outlined.Refresh

    /** 口令显示 / 隐藏(登录页 §5.1) */
    val Visible: ImageVector = Icons.Outlined.Visibility
    val Hidden: ImageVector = Icons.Outlined.VisibilityOff
    val Edit: ImageVector = Icons.Outlined.Edit
    val Restore: ImageVector = Icons.Outlined.Undo
    val Back: ImageVector = Icons.Outlined.ArrowBack

    /** 归档标题(项目内标题操作,契约 §2.3 的 archived) */
    val Archive: ImageVector = Icons.Outlined.Archive
}
