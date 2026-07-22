import CoreGraphics
import Foundation

enum ClipboardLimits {
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxWebSocketMessageBytes = 16 * 1024 * 1024
    static let historyLimit = 10
}

enum SyncMode: String, Codable {
    case client
    case server
}

enum SleepPreventionDuration: String, Codable, CaseIterable {
    case disabled
    case forever
    case oneHour
    case twoHours
    case fourHours
    case sixHours
    case eightHours

    var hours: Int? {
        switch self {
        case .disabled, .forever:
            return nil
        case .oneHour:
            return 1
        case .twoHours:
            return 2
        case .fourHours:
            return 4
        case .sixHours:
            return 6
        case .eightHours:
            return 8
        }
    }

    var isTimed: Bool {
        hours != nil
    }

    var titleKey: String {
        switch self {
        case .disabled:
            return "sleep.doNotDisable"
        case .forever:
            return "sleep.forever"
        case .oneHour:
            return "sleep.oneHour"
        case .twoHours:
            return "sleep.twoHours"
        case .fourHours:
            return "sleep.fourHours"
        case .sixHours:
            return "sleep.sixHours"
        case .eightHours:
            return "sleep.eightHours"
        }
    }
}

enum ScreenEdge: String, Codable, CaseIterable {
    case left
    case right
    case top
    case bottom

    var title: String {
        AppText.edgeTitle(self)
    }

    var opposite: ScreenEdge {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        case .top:
            return .bottom
        case .bottom:
            return .top
        }
    }
}

enum AppText {
    private enum Language: String {
        case english = "en"
        case chinese = "zh"
        case korean = "ko"
        case japanese = "ja"
    }

    private static let language: Language = {
        let identifier = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
        if identifier.hasPrefix("zh") { return .chinese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("ja") { return .japanese }
        return .english
    }()

    private static let values: [Language: [String: String]] = [
        .english: [
            "app.name": "Clipboard Sync",
            "app.shortName": "Clip",
            "state.enabled": "Enabled",
            "state.disabled": "Disabled",
            "state.unknown": "Unknown",
            "device.unknown": "Unknown Device",
            "device.unknownWithSuffix": "Unknown Device · %@",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "Status: %@",
            "status.stopped": "stopped",
            "status.syncPaused": "sync paused",
            "status.copyFilesFirst": "copy files first",
            "status.fileTransferStarted": "file transfer started",
            "status.filesReceived": "files received",
            "status.filesReceivedPasteHint": "Files received. Paste them where you need them.",
            "status.fileSendProgress": "sending files to %@… %d%%",
            "status.fileReceiveProgress": "receiving files… %d%%",
            "status.filesSent": "files sent to %@",
            "status.fileTransferFailed": "file transfer failed: %@",
            "status.fileTransferBusy": "a file transfer is already running",
            "status.setSyncPassword": "set sync password",
            "status.setServerLanIp": "set server LAN IP",
            "status.useLanIp": "use LAN IP, not 127.0.0.1",
            "status.encryptionFailed": "encryption failed",
            "status.clipboardPayloadTooLarge": "clipboard payload too large",
            "status.inputPayloadTooLarge": "input payload too large",
            "status.restoreHistoryFailed": "failed to restore history item",
            "status.folderUnsupported": "folder clipboard is not supported",
            "status.fileTooLarge": "file over 10 MB skipped",
            "status.imageTooLarge": "image over 10 MB skipped",
            "status.invalidPort": "invalid port",
            "status.serverFailed": "server failed: %@",
            "status.startingServer": "starting server %@",
            "status.serverError": "server error: %@",
            "status.serverPeers": "server %@, %d peer(s)",
            "status.sendFailed": "send failed: %@",
            "status.connecting": "connecting %@:%d",
            "status.connected": "connected %@:%d",
            "status.disconnectedError": "disconnected: %@",
            "status.disconnectedKeepalive": "disconnected: keepalive timeout",
            "status.disconnectedRetrying": "disconnected; retrying",
            "menu.clipboardHistory": "Clipboard History",
            "menu.noClipboardHistory": "No clipboard history",
            "menu.clearClipboardHistory": "Clear Clipboard History",
            "menu.sendFiles": "Send Files from Clipboard",
            "menu.sendFilesNoFile": "Send Files from Clipboard (no file copied)",
            "menu.sendFilesWithName": "Send Files from Clipboard (%@)",
            "menu.noPeers": "No Connected Devices",
            "menu.enableInputSharing": "Enable Input Sharing",
            "menu.controlDevice": "Control Device",
            "menu.controlDeviceWithTitle": "Control Device: %@",
            "menu.screenLayout": "Screen Layout...",
            "menu.portForward": "Port Forward...",
            "menu.completeSetup": "Complete Setup...",
            "menu.reconnect": "Reconnect",
            "menu.moreFeatures": "More Features",
            "menu.preventSystemSleep": "Prevent System Sleep",
            "menu.preventSystemSleepPausedLowBattery": "Prevent System Sleep (paused: battery below 20%)",
            "menu.preventSystemSleepPausedBatteryUnavailable": "Prevent System Sleep (paused: battery status unavailable)",
            "sleep.doNotDisable": "Do not disable",
            "sleep.forever": "Forever",
            "sleep.oneHour": "1 hour",
            "sleep.twoHours": "2 hour",
            "sleep.fourHours": "4 hour",
            "sleep.sixHours": "6 hour",
            "sleep.eightHours": "8 hour",
            "sleep.disableBelow20OnBattery": "Disable below 20% battery (on battery power)",
            "sleep.statusOff": "Status: Off",
            "sleep.statusForever": "Status: On — Forever",
            "sleep.statusPausedForever": "Status: Paused — Forever selected",
            "sleep.statusRemainingHoursMinutes": "Status: %d h %d min remaining",
            "sleep.statusRemainingMinutes": "Status: %d min remaining",
            "sleep.statusPausedRemainingHoursMinutes": "Status: Paused — %d h %d min remaining",
            "sleep.statusPausedRemainingMinutes": "Status: Paused — %d min remaining",
            "sleep.errorTitle": "Could Not Update Sleep Prevention",
            "sleep.errorMessage": "Clipboard Sync could not update system sleep prevention:\n\n%@",
            "forward.title": "Port Forward",
            "forward.subtitle": "Forward a TCP port on one device to a port on another. Connections to In are tunneled over the encrypted sync connection and delivered to Out.",
            "forward.in": "In (listen)",
            "forward.out": "Out (destination)",
            "forward.lan": "LAN",
            "forward.note": "Note",
            "forward.notePlaceholder": "Optional note",
            "forward.lanTooltip": "Off: listen on 127.0.0.1 only (this machine). On: listen on 0.0.0.0 so other machines on the LAN can reach this port.",
            "forward.hostTooltip": "Address the Out device connects to. Default 127.0.0.1 (a service on the Out device itself); change it to reach another host the Out device can see.",
            "forward.status": "",
            "forward.enabled": "On",
            "forward.enabledTooltip": "Enable or disable this forward. Changes apply when you save.",
            "forward.reasonPrivileged": "needs a port ≥ 1024 (admin required)",
            "forward.offlineDevice": "Offline Device",
            "forward.statusListening": "listening on port %d",
            "forward.statusFailed": "port listening failed: %@",
            "forward.statusDisabled": "disabled",
            "forward.statusOffline": "In device offline",
            "forward.statusOutOffline": "Out device offline",
            "forward.statusStarting": "starting…",
            "forward.add": "Add Forward",
            "forward.remove": "Remove",
            "forward.empty": "No port forwards yet. Click Add Forward to create one.",
            "forward.validationPort": "Ports must be numbers from 1 to 65535.",
            "forward.validationSame": "In and Out cannot be the same port on the same device.",
            "forward.validationDuplicate": "Two rules listen on the same port of the same device.",
            "forward.remoteConflict": "Rules changed on another device. Your draft is preserved; close and reopen this window to load the remote changes.",
            "status.forwardListenFailed": "port forward %d failed: %@",
            "status.forwardListenPermission": "port forward %d denied — use a port ≥ 1024 (privileged ports need admin)",
            "menu.settings": "Settings...",
            "menu.checkForUpdates": "Check for Updates...",
            "menu.pauseSync": "Pause Sync",
            "menu.resumeSync": "Resume Sync",
            "menu.launchAtLogin": "Launch at Login",
            "menu.about": "About Clipboard Sync",
            "menu.homepage": "Project Homepage",
            "menu.feedback": "Send Feedback…",
            "menu.quit": "Quit",
            "edge.left": "Left",
            "edge.right": "Right",
            "edge.top": "Top",
            "edge.bottom": "Bottom",
            "history.text": "Text",
            "history.textWithPreview": "Text: %@",
            "history.image": "Image: %@",
            "history.files": "Files: %@%@",
            "input.off": "Input Sharing: off",
            "input.waitingPeer": "Input Sharing: waiting for peer",
            "input.grantAccessibility": "Input Sharing: grant Accessibility",
            "input.grantInputMonitoring": "Input Sharing: grant Input Monitoring",
            "input.peerDisabled": "Input Sharing: peer disabled",
            "input.waitingPeerScreen": "Input Sharing: waiting for peer screen",
            "input.controllingPeer": "Input Sharing: controlling peer (%@)",
            "input.receiving": "Input Sharing: receiving input",
            "input.ready": "Input Sharing: ready",
            "input.grantBoth": "Input Sharing: grant Accessibility/Input Monitoring",
            "settings.title": "Clipboard Sync Settings",
            "settings.header": "Clipboard Sync",
            "settings.subtitle": "Configure how this Mac syncs clipboard updates.",
            "settings.firstRunHeader": "Connect your devices",
            "settings.firstRunSubtitle": "Set one device as the server, then configure the others as child devices using the same address and password.",
            "settings.sectionConnection": "CONNECTION",
            "settings.sectionInput": "INPUT SHARING",
            "settings.mode": "Mode",
            "settings.host": "Host",
            "settings.port": "Port",
            "settings.password": "Password",
            "settings.input": "Input",
            "layout.title": "Screen Layout",
            "layout.subtitle": "Drag screens to match your desk. Right-click an offline device to forget it.",
            "layout.done": "Done",
            "layout.disconnected": "Disconnected",
            "layout.inputDisabled": "Input Sharing Off",
            "layout.thisDevice": "This Device",
            "layout.autoArrange": "Auto Arrange",
            "layout.saved": "Layout saved",
            "layout.forgetDevice": "Forget This Device",
            "layout.forgetConfirm": "Forget this offline device and remove its saved screens?",
            "settings.scroll": "Scroll",
            "settings.modifierKeys": "Receive Key Mapping",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "Child Device",
            "settings.server": "Server",
            "settings.enableInputSharing": "Enable Input Sharing",
            "settings.permissions": "Permissions",
            "settings.permissionReady": "Accessibility and Input Monitoring are ready.",
            "settings.permissionNeeded": "Grant Accessibility and Input Monitoring in System Settings.",
            "settings.openPrivacySettings": "Open Privacy Settings",
            "settings.reverseVerticalScroll": "Reverse Vertical Scroll",
            "settings.save": "Save",
            "settings.cancel": "Cancel",
            "settings.hostDefaultHint": "Used only on child devices.",
            "settings.hostClientHint": "Enter the LAN IP shown on the server Mac.",
            "settings.hostServerHint": "Share this address with clients on the same LAN.",
            "settings.copyAddress": "Copy Address",
            "settings.copyPassword": "Copy Password",
            "settings.passwordPlaceholder": "Required on every device",
            "settings.validationHost": "Enter the server LAN address for this child device.",
            "settings.validationLoopback": "Use the server Mac's LAN IP, not 127.0.0.1.",
            "settings.validationPort": "Port must be a number from 1 to 65535.",
            "settings.validationPassword": "Enter the same sync password on every device.",
            "settings.confirmNoEncryptionTitle": "Disable transport encryption?",
            "settings.confirmNoEncryption": "Clipboard and input data will travel unencrypted, authenticated by the sync password. Only do this on a trusted network.",
            "settings.encryptTransport": "Encrypt transport (uncheck on trusted networks to save CPU)",
            "settings.confirmNoEncryptionContinue": "Continue",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command",
            "status.betaExpired": "beta ended, update required",
            "beta.expiredTitle": "Beta Period Ended",
            "beta.expiredMessage": "This beta build's 30-day trial has ended. Please check for updates to keep using Clipboard Sync."
        ],
        .chinese: [
            "app.name": "剪贴板同步",
            "app.shortName": "剪贴板",
            "state.enabled": "已启用",
            "state.disabled": "已禁用",
            "state.unknown": "未知",
            "device.unknown": "未知设备",
            "device.unknownWithSuffix": "未知设备 · %@",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "状态：%@",
            "status.stopped": "已停止",
            "status.syncPaused": "同步已暂停",
            "status.copyFilesFirst": "请先复制文件",
            "status.fileTransferStarted": "文件传输已开始",
            "status.filesReceived": "已收到文件",
            "status.filesReceivedPasteHint": "已收到文件，你可以在需要的位置粘贴。",
            "status.fileSendProgress": "正在发送文件到 %@… %d%%",
            "status.fileReceiveProgress": "正在接收文件… %d%%",
            "status.filesSent": "文件已发送到 %@",
            "status.fileTransferFailed": "文件传输失败：%@",
            "status.fileTransferBusy": "已有文件传输正在进行",
            "status.setSyncPassword": "请设置同步密码",
            "status.setServerLanIp": "请设置服务器局域网 IP",
            "status.useLanIp": "请使用局域网 IP，不要用 127.0.0.1",
            "status.encryptionFailed": "加密失败",
            "status.clipboardPayloadTooLarge": "剪贴板内容过大",
            "status.inputPayloadTooLarge": "输入数据过大",
            "status.restoreHistoryFailed": "恢复历史记录失败",
            "status.folderUnsupported": "不支持文件夹剪贴板",
            "status.fileTooLarge": "文件超过 10 MB，已跳过",
            "status.imageTooLarge": "图片超过 10 MB，已跳过",
            "status.invalidPort": "端口无效",
            "status.serverFailed": "服务器失败：%@",
            "status.startingServer": "正在启动服务器 %@",
            "status.serverError": "服务器错误：%@",
            "status.serverPeers": "服务器 %@，%d 个对端",
            "status.sendFailed": "发送失败：%@",
            "status.connecting": "正在连接 %@:%d",
            "status.connected": "已连接 %@:%d",
            "status.disconnectedError": "已断开：%@",
            "status.disconnectedKeepalive": "已断开：保活超时",
            "status.disconnectedRetrying": "已断开，正在重试",
            "menu.clipboardHistory": "剪贴板历史",
            "menu.noClipboardHistory": "无剪贴板历史",
            "menu.clearClipboardHistory": "清除剪贴板历史",
            "menu.sendFiles": "从剪贴板发送文件",
            "menu.sendFilesNoFile": "从剪贴板发送文件（未复制文件）",
            "menu.sendFilesWithName": "从剪贴板发送文件（%@）",
            "menu.noPeers": "无已连接设备",
            "menu.enableInputSharing": "启用输入共享",
            "menu.controlDevice": "控制设备",
            "menu.controlDeviceWithTitle": "控制设备：%@",
            "menu.screenLayout": "屏幕布局...",
            "menu.portForward": "端口转发...",
            "menu.completeSetup": "完成设置...",
            "menu.reconnect": "重新连接",
            "menu.moreFeatures": "更多功能",
            "menu.preventSystemSleep": "防止系统睡眠",
            "menu.preventSystemSleepPausedLowBattery": "防止系统睡眠（已暂停：电池低于 20%）",
            "menu.preventSystemSleepPausedBatteryUnavailable": "防止系统睡眠（已暂停：无法获取电池状态）",
            "sleep.doNotDisable": "不禁用系统睡眠",
            "sleep.forever": "永久",
            "sleep.oneHour": "1 小时",
            "sleep.twoHours": "2 小时",
            "sleep.fourHours": "4 小时",
            "sleep.sixHours": "6 小时",
            "sleep.eightHours": "8 小时",
            "sleep.disableBelow20OnBattery": "电池供电且电量低于 20% 时禁用",
            "sleep.statusOff": "状态：未启用",
            "sleep.statusForever": "状态：已启用 — 永久",
            "sleep.statusPausedForever": "状态：已暂停 — 已选择永久",
            "sleep.statusRemainingHoursMinutes": "状态：剩余 %d 小时 %d 分钟",
            "sleep.statusRemainingMinutes": "状态：剩余 %d 分钟",
            "sleep.statusPausedRemainingHoursMinutes": "状态：已暂停 — 剩余 %d 小时 %d 分钟",
            "sleep.statusPausedRemainingMinutes": "状态：已暂停 — 剩余 %d 分钟",
            "sleep.errorTitle": "无法更新睡眠防止设置",
            "sleep.errorMessage": "Clipboard Sync 无法更新系统睡眠防止设置：\n\n%@",
            "forward.title": "端口转发",
            "forward.subtitle": "将一台设备的 TCP 端口转发到另一台设备的端口。连接到“入口”的流量会经加密同步连接隧道送达“出口”。",
            "forward.in": "入口（监听）",
            "forward.out": "出口（目标）",
            "forward.lan": "局域网",
            "forward.note": "备注",
            "forward.notePlaceholder": "备注（可选）",
            "forward.lanTooltip": "关闭：仅监听 127.0.0.1（本机）。开启：监听 0.0.0.0，局域网内其他机器也能访问此端口。",
            "forward.hostTooltip": "出口设备连接的地址。默认 127.0.0.1（出口设备自身的服务）；可改为出口设备能访问的其他主机。",
            "forward.status": "",
            "forward.enabled": "启用",
            "forward.enabledTooltip": "启用或禁用此转发，保存后生效。",
            "forward.reasonPrivileged": "需要 ≥ 1024 的端口（否则需要管理员权限）",
            "forward.offlineDevice": "离线设备",
            "forward.statusListening": "正在监听端口 %d",
            "forward.statusFailed": "端口监听失败：%@",
            "forward.statusDisabled": "已禁用",
            "forward.statusOffline": "入口设备离线",
            "forward.statusOutOffline": "出口设备离线",
            "forward.statusStarting": "正在启动…",
            "forward.add": "添加转发",
            "forward.remove": "删除",
            "forward.empty": "暂无端口转发。点击“添加转发”创建。",
            "forward.validationPort": "端口必须是 1 到 65535 之间的数字。",
            "forward.validationSame": "入口和出口不能是同一设备上的同一端口。",
            "forward.validationDuplicate": "同一设备上的同一端口被多条规则监听。",
            "forward.remoteConflict": "规则已在另一台设备上更改。你的草稿已保留；关闭并重新打开此窗口可载入远端更改。",
            "status.forwardListenFailed": "端口转发 %d 失败：%@",
            "status.forwardListenPermission": "端口转发 %d 被拒绝 — 请使用 ≥ 1024 的端口（特权端口需要管理员权限）",
            "menu.settings": "设置...",
            "menu.checkForUpdates": "检查更新...",
            "menu.pauseSync": "暂停同步",
            "menu.resumeSync": "恢复同步",
            "menu.launchAtLogin": "登录时自动启动",
            "menu.about": "关于剪贴板同步",
            "menu.homepage": "项目主页",
            "menu.feedback": "发送反馈…",
            "menu.quit": "退出",
            "edge.left": "左侧",
            "edge.right": "右侧",
            "edge.top": "上方",
            "edge.bottom": "下方",
            "history.text": "文本",
            "history.textWithPreview": "文本：%@",
            "history.image": "图片：%@",
            "history.files": "文件：%@%@",
            "input.off": "输入共享：关闭",
            "input.waitingPeer": "输入共享：等待对端",
            "input.grantAccessibility": "输入共享：请授权辅助功能",
            "input.grantInputMonitoring": "输入共享：请授权输入监控",
            "input.peerDisabled": "输入共享：对端已禁用",
            "input.waitingPeerScreen": "输入共享：等待对端屏幕信息",
            "input.controllingPeer": "输入共享：正在控制对端（%@）",
            "input.receiving": "输入共享：正在接收输入",
            "input.ready": "输入共享：就绪",
            "input.grantBoth": "输入共享：请授权辅助功能/输入监控",
            "settings.title": "剪贴板同步设置",
            "settings.header": "剪贴板同步",
            "settings.subtitle": "配置这台 Mac 如何同步剪贴板更新。",
            "settings.firstRunHeader": "连接你的设备",
            "settings.firstRunSubtitle": "先将一台设备设为服务端，再让其它设备使用相同的地址和密码作为子设备连接。",
            "settings.sectionConnection": "连接",
            "settings.sectionInput": "输入共享",
            "settings.mode": "模式",
            "settings.host": "主机",
            "settings.port": "端口",
            "settings.password": "密码",
            "settings.input": "输入",
            "layout.title": "屏幕布局",
            "layout.subtitle": "拖动屏幕以匹配桌面摆放；右键离线设备可将其忘记。",
            "layout.done": "完成",
            "layout.disconnected": "已断开",
            "layout.inputDisabled": "输入共享已关闭",
            "layout.thisDevice": "本机",
            "layout.autoArrange": "自动排列",
            "layout.saved": "布局已保存",
            "layout.forgetDevice": "忘记此设备",
            "layout.forgetConfirm": "忘记这台离线设备并移除其已保存的屏幕吗？",
            "settings.scroll": "滚动",
            "settings.modifierKeys": "接收按键映射",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "子设备",
            "settings.server": "服务端",
            "settings.enableInputSharing": "启用输入共享",
            "settings.permissions": "权限",
            "settings.permissionReady": "辅助功能和输入监控权限已就绪。",
            "settings.permissionNeeded": "请在系统设置中授权辅助功能和输入监控。",
            "settings.openPrivacySettings": "打开隐私设置",
            "settings.reverseVerticalScroll": "反转垂直滚动",
            "settings.save": "保存",
            "settings.cancel": "取消",
            "settings.hostDefaultHint": "仅用于子设备。",
            "settings.hostClientHint": "输入服务器 Mac 显示的局域网 IP。",
            "settings.hostServerHint": "将此地址分享给同一局域网内的客户端。",
            "settings.copyAddress": "复制地址",
            "settings.copyPassword": "复制密码",
            "settings.passwordPlaceholder": "每台设备都需要一致",
            "settings.validationHost": "请输入这台子设备要连接的服务端局域网地址。",
            "settings.validationLoopback": "请使用服务器 Mac 的局域网 IP，不要用 127.0.0.1。",
            "settings.validationPort": "端口必须是 1 到 65535 之间的数字。",
            "settings.validationPassword": "请在每台设备上输入相同的同步密码。",
            "settings.confirmNoEncryptionTitle": "禁用传输加密？",
            "settings.confirmNoEncryption": "剪贴板与输入数据将不加密传输，仅使用同步密码进行认证。请仅在可信网络中使用。",
            "settings.encryptTransport": "加密传输（可信网络可取消勾选以降低 CPU 占用）",
            "settings.confirmNoEncryptionContinue": "继续",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command",
            "status.betaExpired": "测试已结束，需要更新",
            "beta.expiredTitle": "测试期已结束",
            "beta.expiredMessage": "此测试版本的 30 天试用期已结束，请检查更新以继续使用剪贴板同步。"
        ],
        .korean: [
            "app.name": "클립보드 동기화",
            "app.shortName": "클립",
            "state.enabled": "활성",
            "state.disabled": "비활성",
            "state.unknown": "알 수 없음",
            "device.unknown": "알 수 없는 장치",
            "device.unknownWithSuffix": "알 수 없는 장치 · %@",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "상태: %@",
            "status.stopped": "중지됨",
            "status.syncPaused": "동기화 일시 정지됨",
            "status.copyFilesFirst": "먼저 파일을 복사하세요",
            "status.fileTransferStarted": "파일 전송 시작됨",
            "status.filesReceived": "파일을 받았습니다",
            "status.filesReceivedPasteHint": "파일을 받았습니다. 필요한 위치에 붙여넣을 수 있습니다.",
            "status.fileSendProgress": "%@(으)로 파일 전송 중… %d%%",
            "status.fileReceiveProgress": "파일 수신 중… %d%%",
            "status.filesSent": "%@(으)로 파일을 보냈습니다",
            "status.fileTransferFailed": "파일 전송 실패: %@",
            "status.fileTransferBusy": "이미 파일 전송이 진행 중입니다",
            "status.setSyncPassword": "동기화 암호를 설정하세요",
            "status.setServerLanIp": "서버 LAN IP를 설정하세요",
            "status.useLanIp": "127.0.0.1 대신 LAN IP를 사용하세요",
            "status.encryptionFailed": "암호화 실패",
            "status.clipboardPayloadTooLarge": "클립보드 데이터가 너무 큼",
            "status.inputPayloadTooLarge": "입력 데이터가 너무 큼",
            "status.restoreHistoryFailed": "기록 항목 복원 실패",
            "status.folderUnsupported": "폴더 클립보드는 지원되지 않음",
            "status.fileTooLarge": "10 MB 초과 파일 건너뜀",
            "status.imageTooLarge": "10 MB 초과 이미지 건너뜀",
            "status.invalidPort": "잘못된 포트",
            "status.serverFailed": "서버 실패: %@",
            "status.startingServer": "서버 시작 중 %@",
            "status.serverError": "서버 오류: %@",
            "status.serverPeers": "서버 %@, 상대 %d개",
            "status.sendFailed": "전송 실패: %@",
            "status.connecting": "%@:%d 연결 중",
            "status.connected": "%@:%d 연결됨",
            "status.disconnectedError": "연결 끊김: %@",
            "status.disconnectedKeepalive": "연결 끊김: keepalive 시간 초과",
            "status.disconnectedRetrying": "연결 끊김; 다시 시도 중",
            "menu.clipboardHistory": "클립보드 기록",
            "menu.noClipboardHistory": "클립보드 기록 없음",
            "menu.clearClipboardHistory": "클립보드 기록 지우기",
            "menu.sendFiles": "클립보드에서 파일 보내기",
            "menu.sendFilesNoFile": "클립보드에서 파일 보내기 (복사된 파일 없음)",
            "menu.sendFilesWithName": "클립보드에서 파일 보내기 (%@)",
            "menu.noPeers": "연결된 기기 없음",
            "menu.enableInputSharing": "입력 공유 활성화",
            "menu.controlDevice": "제어 장치",
            "menu.controlDeviceWithTitle": "제어 장치: %@",
            "menu.screenLayout": "화면 레이아웃...",
            "menu.portForward": "포트 포워딩...",
            "menu.completeSetup": "설정 완료...",
            "menu.reconnect": "다시 연결",
            "menu.moreFeatures": "더 많은 기능",
            "menu.preventSystemSleep": "시스템 잠자기 방지",
            "menu.preventSystemSleepPausedLowBattery": "시스템 잠자기 방지 (일시 중지: 배터리 20% 미만)",
            "menu.preventSystemSleepPausedBatteryUnavailable": "시스템 잠자기 방지 (일시 중지: 배터리 상태 확인 불가)",
            "sleep.doNotDisable": "잠자기를 비활성화하지 않음",
            "sleep.forever": "계속",
            "sleep.oneHour": "1시간",
            "sleep.twoHours": "2시간",
            "sleep.fourHours": "4시간",
            "sleep.sixHours": "6시간",
            "sleep.eightHours": "8시간",
            "sleep.disableBelow20OnBattery": "배터리 사용 중 20% 미만이면 비활성화",
            "sleep.statusOff": "상태: 꺼짐",
            "sleep.statusForever": "상태: 켜짐 — 무기한",
            "sleep.statusPausedForever": "상태: 일시 중지 — 무기한 선택됨",
            "sleep.statusRemainingHoursMinutes": "상태: %d시간 %d분 남음",
            "sleep.statusRemainingMinutes": "상태: %d분 남음",
            "sleep.statusPausedRemainingHoursMinutes": "상태: 일시 중지 — %d시간 %d분 남음",
            "sleep.statusPausedRemainingMinutes": "상태: 일시 중지 — %d분 남음",
            "sleep.errorTitle": "잠자기 방지 설정을 업데이트할 수 없음",
            "sleep.errorMessage": "Clipboard Sync에서 시스템 잠자기 방지 설정을 업데이트하지 못했습니다.\n\n%@",
            "forward.title": "포트 포워딩",
            "forward.subtitle": "한 기기의 TCP 포트를 다른 기기의 포트로 전달합니다. In으로 들어온 연결은 암호화된 동기화 연결을 통해 Out으로 전달됩니다.",
            "forward.in": "In (수신)",
            "forward.out": "Out (대상)",
            "forward.lan": "LAN",
            "forward.note": "메모",
            "forward.notePlaceholder": "메모 (선택)",
            "forward.lanTooltip": "끄면 127.0.0.1(이 기기)에서만 수신합니다. 켜면 0.0.0.0에서 수신하여 LAN의 다른 기기도 이 포트에 접근할 수 있습니다.",
            "forward.hostTooltip": "Out 기기가 연결하는 주소. 기본값 127.0.0.1(Out 기기 자체의 서비스); Out 기기가 접근 가능한 다른 호스트로 변경할 수 있습니다.",
            "forward.status": "",
            "forward.enabled": "사용",
            "forward.enabledTooltip": "이 포워딩을 사용/해제합니다. 저장하면 적용됩니다.",
            "forward.reasonPrivileged": "1024 이상 포트가 필요합니다(특권 포트는 관리자 권한 필요)",
            "forward.offlineDevice": "오프라인 기기",
            "forward.statusListening": "포트 %d 수신 중",
            "forward.statusFailed": "포트 수신 실패: %@",
            "forward.statusDisabled": "사용 안 함",
            "forward.statusOffline": "In 기기 오프라인",
            "forward.statusOutOffline": "Out 기기 오프라인",
            "forward.statusStarting": "시작 중…",
            "forward.add": "포워딩 추가",
            "forward.remove": "삭제",
            "forward.empty": "포트 포워딩이 없습니다. 포워딩 추가를 눌러 만드세요.",
            "forward.validationPort": "포트는 1에서 65535 사이의 숫자여야 합니다.",
            "forward.validationSame": "In과 Out은 같은 기기의 같은 포트일 수 없습니다.",
            "forward.validationDuplicate": "같은 기기의 같은 포트를 여러 규칙이 수신합니다.",
            "forward.remoteConflict": "다른 기기에서 규칙이 변경되었습니다. 현재 초안은 유지됩니다. 창을 닫았다가 다시 열어 원격 변경 사항을 불러오세요.",
            "status.forwardListenFailed": "포트 포워딩 %d 실패: %@",
            "status.forwardListenPermission": "포트 포워딩 %d 거부됨 — 1024 이상 포트를 사용하세요(특권 포트는 관리자 권한 필요)",
            "menu.settings": "설정...",
            "menu.checkForUpdates": "업데이트 확인...",
            "menu.pauseSync": "동기화 일시 정지",
            "menu.resumeSync": "동기화 재개",
            "menu.launchAtLogin": "로그인 시 자동 실행",
            "menu.about": "Clipboard Sync 정보",
            "menu.homepage": "프로젝트 홈페이지",
            "menu.feedback": "피드백 보내기…",
            "menu.quit": "종료",
            "edge.left": "왼쪽",
            "edge.right": "오른쪽",
            "edge.top": "위",
            "edge.bottom": "아래",
            "history.text": "텍스트",
            "history.textWithPreview": "텍스트: %@",
            "history.image": "이미지: %@",
            "history.files": "파일: %@%@",
            "input.off": "입력 공유: 꺼짐",
            "input.waitingPeer": "입력 공유: 상대 대기 중",
            "input.grantAccessibility": "입력 공유: 손쉬운 사용 권한 필요",
            "input.grantInputMonitoring": "입력 공유: 입력 모니터링 권한 필요",
            "input.peerDisabled": "입력 공유: 상대가 비활성화됨",
            "input.waitingPeerScreen": "입력 공유: 상대 화면 정보 대기 중",
            "input.controllingPeer": "입력 공유: 상대 제어 중 (%@)",
            "input.receiving": "입력 공유: 입력 수신 중",
            "input.ready": "입력 공유: 준비됨",
            "input.grantBoth": "입력 공유: 손쉬운 사용/입력 모니터링 권한 필요",
            "settings.title": "클립보드 동기화 설정",
            "settings.header": "클립보드 동기화",
            "settings.subtitle": "이 Mac의 클립보드 동기화 방식을 설정합니다.",
            "settings.firstRunHeader": "기기 연결",
            "settings.firstRunSubtitle": "한 기기를 서버로 설정한 다음, 다른 기기를 같은 주소와 암호를 사용하는 하위 기기로 설정하세요.",
            "settings.sectionConnection": "연결",
            "settings.sectionInput": "입력 공유",
            "settings.mode": "모드",
            "settings.host": "호스트",
            "settings.port": "포트",
            "settings.password": "암호",
            "settings.input": "입력",
            "layout.title": "화면 레이아웃",
            "layout.subtitle": "기기들의 실제 배치에 맞게 각 화면을 드래그하세요.",
            "layout.done": "완료",
            "layout.disconnected": "연결 끊김",
            "layout.inputDisabled": "입력 공유 꺼짐",
            "layout.thisDevice": "이 기기",
            "layout.autoArrange": "자동 정렬",
            "layout.saved": "레이아웃 저장됨",
            "layout.forgetDevice": "이 기기 잊기",
            "layout.forgetConfirm": "이 오프라인 기기와 저장된 화면을 지울까요?",
            "settings.scroll": "스크롤",
            "settings.modifierKeys": "수신 키 매핑",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "하위 기기",
            "settings.server": "서버",
            "settings.enableInputSharing": "입력 공유 활성화",
            "settings.permissions": "권한",
            "settings.permissionReady": "손쉬운 사용 및 입력 모니터링 권한이 준비되었습니다.",
            "settings.permissionNeeded": "시스템 설정에서 손쉬운 사용 및 입력 모니터링을 허용하세요.",
            "settings.openPrivacySettings": "개인정보 설정 열기",
            "settings.reverseVerticalScroll": "세로 스크롤 반전",
            "settings.save": "저장",
            "settings.cancel": "취소",
            "settings.hostDefaultHint": "하위 기기에서만 사용됩니다.",
            "settings.hostClientHint": "서버 Mac에 표시된 LAN IP를 입력하세요.",
            "settings.hostServerHint": "같은 LAN의 클라이언트와 이 주소를 공유하세요.",
            "settings.copyAddress": "주소 복사",
            "settings.copyPassword": "암호 복사",
            "settings.passwordPlaceholder": "모든 장치에서 필요",
            "settings.validationHost": "이 하위 기기가 연결할 서버 LAN 주소를 입력하세요.",
            "settings.validationLoopback": "127.0.0.1이 아닌 서버 Mac의 LAN IP를 사용하세요.",
            "settings.validationPort": "포트는 1에서 65535 사이의 숫자여야 합니다.",
            "settings.validationPassword": "모든 장치에 동일한 동기화 암호를 입력하세요.",
            "settings.confirmNoEncryptionTitle": "전송 암호화를 비활성화할까요?",
            "settings.confirmNoEncryption": "클립보드와 입력 데이터가 암호화되지 않은 채 전송되며 동기화 암호로만 인증됩니다. 신뢰할 수 있는 네트워크에서만 사용하세요.",
            "settings.encryptTransport": "전송 암호화 (신뢰할 수 있는 네트워크에서는 해제해 CPU 절약)",
            "settings.confirmNoEncryptionContinue": "계속",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command",
            "status.betaExpired": "베타 종료, 업데이트 필요",
            "beta.expiredTitle": "베타 기간 종료",
            "beta.expiredMessage": "이 베타 빌드의 30일 체험 기간이 종료되었습니다. 계속 사용하려면 업데이트를 확인하세요."
        ],
        .japanese: [
            "app.name": "クリップボード同期",
            "app.shortName": "クリップ",
            "state.enabled": "有効",
            "state.disabled": "無効",
            "state.unknown": "不明",
            "device.unknown": "不明なデバイス",
            "device.unknownWithSuffix": "不明なデバイス · %@",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "状態: %@",
            "status.stopped": "停止中",
            "status.syncPaused": "同期は一時停止中",
            "status.copyFilesFirst": "先にファイルをコピーしてください",
            "status.fileTransferStarted": "ファイル転送を開始しました",
            "status.filesReceived": "ファイルを受信しました",
            "status.filesReceivedPasteHint": "ファイルを受信しました。必要な場所に貼り付けできます。",
            "status.fileSendProgress": "%@ へファイル送信中… %d%%",
            "status.fileReceiveProgress": "ファイル受信中… %d%%",
            "status.filesSent": "%@ へファイルを送信しました",
            "status.fileTransferFailed": "ファイル転送に失敗しました: %@",
            "status.fileTransferBusy": "ファイル転送は既に実行中です",
            "status.setSyncPassword": "同期パスワードを設定してください",
            "status.setServerLanIp": "サーバーの LAN IP を設定してください",
            "status.useLanIp": "127.0.0.1 ではなく LAN IP を使用してください",
            "status.encryptionFailed": "暗号化に失敗しました",
            "status.clipboardPayloadTooLarge": "クリップボード内容が大きすぎます",
            "status.inputPayloadTooLarge": "入力データが大きすぎます",
            "status.restoreHistoryFailed": "履歴項目の復元に失敗しました",
            "status.folderUnsupported": "フォルダのクリップボードは未対応です",
            "status.fileTooLarge": "10 MB を超えるファイルをスキップしました",
            "status.imageTooLarge": "10 MB を超える画像をスキップしました",
            "status.invalidPort": "ポートが無効です",
            "status.serverFailed": "サーバー失敗: %@",
            "status.startingServer": "サーバー %@ を開始中",
            "status.serverError": "サーバーエラー: %@",
            "status.serverPeers": "サーバー %@、相手 %d 台",
            "status.sendFailed": "送信に失敗しました: %@",
            "status.connecting": "%@:%d に接続中",
            "status.connected": "%@:%d に接続済み",
            "status.disconnectedError": "切断されました: %@",
            "status.disconnectedKeepalive": "切断されました: keepalive タイムアウト",
            "status.disconnectedRetrying": "切断されました。再試行中",
            "menu.clipboardHistory": "クリップボード履歴",
            "menu.noClipboardHistory": "クリップボード履歴はありません",
            "menu.clearClipboardHistory": "クリップボード履歴を消去",
            "menu.sendFiles": "クリップボードからファイルを送信",
            "menu.sendFilesNoFile": "クリップボードからファイルを送信（ファイル未コピー）",
            "menu.sendFilesWithName": "クリップボードからファイルを送信（%@）",
            "menu.noPeers": "接続中のデバイスなし",
            "menu.enableInputSharing": "入力共有を有効化",
            "menu.controlDevice": "制御デバイス",
            "menu.controlDeviceWithTitle": "制御デバイス: %@",
            "menu.screenLayout": "画面レイアウト...",
            "menu.portForward": "ポート転送...",
            "menu.completeSetup": "設定を完了...",
            "menu.reconnect": "再接続",
            "menu.moreFeatures": "その他の機能",
            "menu.preventSystemSleep": "システムのスリープを防止",
            "menu.preventSystemSleepPausedLowBattery": "システムのスリープを防止（一時停止中：バッテリー 20% 未満）",
            "menu.preventSystemSleepPausedBatteryUnavailable": "システムのスリープを防止（一時停止中：バッテリー状態を取得できません）",
            "sleep.doNotDisable": "スリープを無効にしない",
            "sleep.forever": "無期限",
            "sleep.oneHour": "1 時間",
            "sleep.twoHours": "2 時間",
            "sleep.fourHours": "4 時間",
            "sleep.sixHours": "6 時間",
            "sleep.eightHours": "8 時間",
            "sleep.disableBelow20OnBattery": "バッテリー使用時に 20% 未満なら無効化",
            "sleep.statusOff": "状態：オフ",
            "sleep.statusForever": "状態：オン — 無期限",
            "sleep.statusPausedForever": "状態：一時停止 — 無期限を選択中",
            "sleep.statusRemainingHoursMinutes": "状態：残り %d 時間 %d 分",
            "sleep.statusRemainingMinutes": "状態：残り %d 分",
            "sleep.statusPausedRemainingHoursMinutes": "状態：一時停止 — 残り %d 時間 %d 分",
            "sleep.statusPausedRemainingMinutes": "状態：一時停止 — 残り %d 分",
            "sleep.errorTitle": "スリープ防止設定を更新できません",
            "sleep.errorMessage": "Clipboard Sync はシステムのスリープ防止設定を更新できませんでした。\n\n%@",
            "forward.title": "ポート転送",
            "forward.subtitle": "あるデバイスの TCP ポートを別のデバイスのポートへ転送します。In への接続は暗号化された同期接続を経由して Out に届きます。",
            "forward.in": "In（待ち受け）",
            "forward.out": "Out（宛先）",
            "forward.lan": "LAN",
            "forward.note": "メモ",
            "forward.notePlaceholder": "メモ（任意）",
            "forward.lanTooltip": "オフ: 127.0.0.1（このマシン）のみで待ち受けます。オン: 0.0.0.0 で待ち受け、LAN 上の他のマシンからもこのポートにアクセスできます。",
            "forward.hostTooltip": "Out デバイスが接続する宛先アドレス。既定は 127.0.0.1（Out デバイス自身のサービス）。Out デバイスから到達できる別のホストに変更できます。",
            "forward.status": "",
            "forward.enabled": "有効",
            "forward.enabledTooltip": "この転送を有効/無効にします。保存時に反映されます。",
            "forward.reasonPrivileged": "1024 以上のポートが必要です（特権ポートは管理者権限が必要）",
            "forward.offlineDevice": "オフラインデバイス",
            "forward.statusListening": "ポート %d で待ち受け中",
            "forward.statusFailed": "ポート待ち受け失敗: %@",
            "forward.statusDisabled": "無効",
            "forward.statusOffline": "In デバイスがオフライン",
            "forward.statusOutOffline": "Out デバイスがオフライン",
            "forward.statusStarting": "開始中…",
            "forward.add": "転送を追加",
            "forward.remove": "削除",
            "forward.empty": "ポート転送はまだありません。「転送を追加」で作成してください。",
            "forward.validationPort": "ポートは 1 から 65535 の数字である必要があります。",
            "forward.validationSame": "In と Out を同じデバイスの同じポートにはできません。",
            "forward.validationDuplicate": "同じデバイスの同じポートを複数のルールが待ち受けています。",
            "forward.remoteConflict": "別のデバイスでルールが変更されました。編集中の内容は保持されています。ウインドウを閉じて再度開くとリモートの変更を読み込めます。",
            "status.forwardListenFailed": "ポート転送 %d が失敗しました: %@",
            "status.forwardListenPermission": "ポート転送 %d は拒否されました — 1024 以上のポートを使用してください（特権ポートは管理者権限が必要）",
            "menu.settings": "設定...",
            "menu.checkForUpdates": "アップデートを確認...",
            "menu.pauseSync": "同期を一時停止",
            "menu.resumeSync": "同期を再開",
            "menu.launchAtLogin": "ログイン時に自動起動",
            "menu.about": "Clipboard Sync について",
            "menu.homepage": "プロジェクトのホームページ",
            "menu.feedback": "フィードバックを送信…",
            "menu.quit": "終了",
            "edge.left": "左",
            "edge.right": "右",
            "edge.top": "上",
            "edge.bottom": "下",
            "history.text": "テキスト",
            "history.textWithPreview": "テキスト: %@",
            "history.image": "画像: %@",
            "history.files": "ファイル: %@%@",
            "input.off": "入力共有: オフ",
            "input.waitingPeer": "入力共有: 相手を待機中",
            "input.grantAccessibility": "入力共有: アクセシビリティを許可してください",
            "input.grantInputMonitoring": "入力共有: 入力監視を許可してください",
            "input.peerDisabled": "入力共有: 相手が無効です",
            "input.waitingPeerScreen": "入力共有: 相手の画面情報を待機中",
            "input.controllingPeer": "入力共有: 相手を制御中 (%@)",
            "input.receiving": "入力共有: 入力を受信中",
            "input.ready": "入力共有: 準備完了",
            "input.grantBoth": "入力共有: アクセシビリティ/入力監視を許可してください",
            "settings.title": "クリップボード同期設定",
            "settings.header": "クリップボード同期",
            "settings.subtitle": "この Mac のクリップボード同期方法を設定します。",
            "settings.firstRunHeader": "デバイスを接続",
            "settings.firstRunSubtitle": "1 台をサーバーに設定し、ほかのデバイスを同じアドレスとパスワードを使う子デバイスとして設定します。",
            "settings.sectionConnection": "接続",
            "settings.sectionInput": "入力共有",
            "settings.mode": "モード",
            "settings.host": "ホスト",
            "settings.port": "ポート",
            "settings.password": "パスワード",
            "settings.input": "入力",
            "layout.title": "画面レイアウト",
            "layout.subtitle": "実際の配置に合わせて各画面をドラッグしてください。",
            "layout.done": "完了",
            "layout.disconnected": "切断済み",
            "layout.inputDisabled": "入力共有オフ",
            "layout.thisDevice": "このデバイス",
            "layout.autoArrange": "自動整列",
            "layout.saved": "レイアウトを保存しました",
            "layout.forgetDevice": "このデバイスを削除",
            "layout.forgetConfirm": "このオフラインデバイスと保存済み画面を削除しますか？",
            "settings.scroll": "スクロール",
            "settings.modifierKeys": "受信キー割り当て",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "子デバイス",
            "settings.server": "サーバー",
            "settings.enableInputSharing": "入力共有を有効化",
            "settings.permissions": "権限",
            "settings.permissionReady": "アクセシビリティと入力監視の準備ができています。",
            "settings.permissionNeeded": "システム設定でアクセシビリティと入力監視を許可してください。",
            "settings.openPrivacySettings": "プライバシー設定を開く",
            "settings.reverseVerticalScroll": "垂直スクロールを反転",
            "settings.save": "保存",
            "settings.cancel": "キャンセル",
            "settings.hostDefaultHint": "子デバイスでのみ使用します。",
            "settings.hostClientHint": "サーバー Mac に表示された LAN IP を入力してください。",
            "settings.hostServerHint": "同じ LAN のクライアントにこのアドレスを共有してください。",
            "settings.copyAddress": "アドレスをコピー",
            "settings.copyPassword": "パスワードをコピー",
            "settings.passwordPlaceholder": "すべてのデバイスで必要",
            "settings.validationHost": "この子デバイスが接続するサーバーの LAN アドレスを入力してください。",
            "settings.validationLoopback": "127.0.0.1 ではなくサーバー Mac の LAN IP を使用してください。",
            "settings.validationPort": "ポートは 1 から 65535 の数字である必要があります。",
            "settings.validationPassword": "すべてのデバイスで同じ同期パスワードを入力してください。",
            "settings.confirmNoEncryptionTitle": "転送の暗号化を無効にしますか？",
            "settings.confirmNoEncryption": "クリップボードと入力データは暗号化されずに送信され、同期パスワードで認証のみ行われます。信頼できるネットワークでのみ使用してください。",
            "settings.encryptTransport": "転送を暗号化（信頼できるネットワークではオフにして CPU を節約）",
            "settings.confirmNoEncryptionContinue": "続行",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command",
            "status.betaExpired": "ベータ終了、更新が必要です",
            "beta.expiredTitle": "ベータ期間終了",
            "beta.expiredMessage": "このベータビルドの30日間の試用期間が終了しました。引き続きご利用いただくにはアップデートを確認してください。"
        ]
    ]

    static func text(_ key: String) -> String {
        values[language]?[key] ?? values[.english]?[key] ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func edgeTitle(_ edge: ScreenEdge) -> String {
        text("edge.\(edge.rawValue)")
    }

    static func modifierTitle(_ modifier: KeyboardModifier) -> String {
        text("modifier.\(modifier.key.lowercased())")
    }
}

enum KeyboardModifier: String, Codable, CaseIterable {
    case shift = "Shift"
    case control = "Control"
    case alt = "Alt"
    case meta = "Meta"

    var key: String {
        rawValue
    }

    var title: String {
        AppText.modifierTitle(self)
    }
}

struct KeyboardModifierMap: Codable, Equatable {
    var shift: KeyboardModifier
    var control: KeyboardModifier
    var alt: KeyboardModifier
    var meta: KeyboardModifier

    static let identity = KeyboardModifierMap(
        shift: .shift,
        control: .control,
        alt: .alt,
        meta: .meta
    )

    func target(for source: String) -> String {
        switch source {
        case "Shift":
            return shift.key
        case "Control":
            return control.key
        case "Alt":
            return alt.key
        case "Meta":
            return meta.key
        default:
            return source
        }
    }
}

struct AppConfig: Codable {
    var mode: SyncMode
    var host: String
    var port: Int
    var password: String
    /// The password always authenticates messages; this only chooses whether
    /// the transport payload is also encrypted (AES-GCM) or just HMAC-signed.
    var encryptTransport: Bool
    var inputSharingEnabled: Bool
    var controlDeviceId: String?
    var reverseMouseVerticalScroll: Bool
    var keyboardModifierMap: KeyboardModifierMap
    var sleepPreventionDuration: SleepPreventionDuration
    var sleepPreventionUntil: Date?
    var disableSleepPreventionBelow20PercentOnBattery: Bool

    static let defaults = AppConfig(
        mode: .client,
        host: "",
        port: 8787,
        password: "",
        encryptTransport: true,
        inputSharingEnabled: false,
        controlDeviceId: nil,
        reverseMouseVerticalScroll: false,
        keyboardModifierMap: .identity,
        sleepPreventionDuration: .disabled,
        sleepPreventionUntil: nil,
        disableSleepPreventionBelow20PercentOnBattery: false
    )
    private static let storageKey = "ClipboardSyncMac.config"

    static var hasSavedConfiguration: Bool {
        UserDefaults.standard.object(forKey: storageKey) != nil
    }

    init(
        mode: SyncMode,
        host: String,
        port: Int,
        password: String,
        encryptTransport: Bool = true,
        inputSharingEnabled: Bool,
        controlDeviceId: String?,
        reverseMouseVerticalScroll: Bool,
        keyboardModifierMap: KeyboardModifierMap = .identity,
        sleepPreventionDuration: SleepPreventionDuration,
        sleepPreventionUntil: Date?,
        disableSleepPreventionBelow20PercentOnBattery: Bool
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.password = password
        self.encryptTransport = encryptTransport
        self.inputSharingEnabled = inputSharingEnabled
        self.controlDeviceId = controlDeviceId
        self.reverseMouseVerticalScroll = reverseMouseVerticalScroll
        self.keyboardModifierMap = keyboardModifierMap
        self.sleepPreventionDuration = sleepPreventionDuration
        self.sleepPreventionUntil = sleepPreventionUntil
        self.disableSleepPreventionBelow20PercentOnBattery = disableSleepPreventionBelow20PercentOnBattery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(SyncMode.self, forKey: .mode) ?? Self.defaults.mode
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaults.port
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? Self.defaults.password
        encryptTransport = try container.decodeIfPresent(Bool.self, forKey: .encryptTransport) ?? Self.defaults.encryptTransport
        inputSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .inputSharingEnabled) ?? Self.defaults.inputSharingEnabled
        controlDeviceId = try container.decodeIfPresent(String.self, forKey: .controlDeviceId) ?? Self.defaults.controlDeviceId
        reverseMouseVerticalScroll = try container.decodeIfPresent(Bool.self, forKey: .reverseMouseVerticalScroll) ?? Self.defaults.reverseMouseVerticalScroll
        keyboardModifierMap = try container.decodeIfPresent(KeyboardModifierMap.self, forKey: .keyboardModifierMap) ?? Self.defaults.keyboardModifierMap
        sleepPreventionDuration = try container.decodeIfPresent(SleepPreventionDuration.self, forKey: .sleepPreventionDuration) ?? Self.defaults.sleepPreventionDuration
        sleepPreventionUntil = try container.decodeIfPresent(Date.self, forKey: .sleepPreventionUntil)
        disableSleepPreventionBelow20PercentOnBattery = try container.decodeIfPresent(
            Bool.self,
            forKey: .disableSleepPreventionBelow20PercentOnBattery
        ) ?? Self.defaults.disableSleepPreventionBelow20PercentOnBattery
    }

    static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return defaults
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data).normalized()
        } catch {
            fatalError("Failed to decode saved Clipboard Sync configuration: \(error)")
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(normalized())
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            fatalError("Failed to encode Clipboard Sync configuration: \(error)")
        }
    }

    private func normalized() -> AppConfig {
        AppConfig(
            mode: mode,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(port, 1), 65_535),
            password: password,
            encryptTransport: encryptTransport,
            inputSharingEnabled: inputSharingEnabled,
            controlDeviceId: controlDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
            reverseMouseVerticalScroll: reverseMouseVerticalScroll,
            keyboardModifierMap: keyboardModifierMap,
            sleepPreventionDuration: sleepPreventionDuration,
            sleepPreventionUntil: sleepPreventionDuration.isTimed ? sleepPreventionUntil : nil,
            disableSleepPreventionBelow20PercentOnBattery: disableSleepPreventionBelow20PercentOnBattery
        )
    }
}

struct EncryptedEnvelope: Codable {
    let type: String
    let version: Int
    let salt: String
    let nonce: String
    let ciphertext: String
    let tag: String
    /// Plaintext routing hints so a relaying server can deliver targeted traffic (file-transfer
    /// chunks, tunnel data) to just the matching peer connection instead of broadcasting it.
    /// `from` teaches the server which connection belongs to which device id; `to` names the
    /// intended receiver. Optional — absent on messages from older peers and on broadcasts — and
    /// advisory only: receivers still filter by the encrypted payload's own `target`.
    var from: String?
    var to: String?

    init(type: String, version: Int, salt: String, nonce: String, ciphertext: String, tag: String, from: String? = nil, to: String? = nil) {
        self.type = type
        self.version = version
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.from = from
        self.to = to
    }
}

/// Authenticated-plaintext wire frame used when transport encryption is off:
/// the payload is readable, but the HMAC (keyed by a password-derived key)
/// still proves the sender knows the sync password.
struct SignedEnvelope: Codable {
    var type: String = "signed"
    var version: Int = 1
    var payload: String = ""
    var mac: String = ""
    var from: String?
    var to: String?
}

/// Just the routing hints of an encrypted envelope, for relays that must not (and cannot) decrypt.
struct EnvelopeRouting: Codable {
    let from: String?
    let to: String?
}

extension EnvelopeRouting {
    /// Pulls `from`/`to` out of an envelope without parsing it.
    ///
    /// A `JSONDecoder` pass has to unescape and allocate the envelope's `ciphertext` (or `payload`)
    /// string, which for a file chunk is ~100 KB of base64 that a relay immediately discards. This
    /// walks the top level instead, stepping over string values without copying them, and
    /// materializes only the two short device ids.
    ///
    /// Key order is not assumed: the three clients emit these keys in different positions
    /// (Swift/`JSONSerializer` use declaration order, Qt's `QJsonObject` sorts alphabetically), so
    /// the routing hints can sit either side of the large value.
    ///
    /// Returns nil when the input isn't a JSON object or escapes appear in a key or in a routing
    /// value — device ids are UUIDs, so that does not happen in practice. Callers treat nil as
    /// "no routing hint", which degrades to the pre-existing broadcast fallback rather than
    /// misrouting.
    static func scan(_ text: String) -> EnvelopeRouting? {
        var text = text
        return text.withUTF8 { buffer in scan(buffer) }
    }

    private static func scan(_ buf: UnsafeBufferPointer<UInt8>) -> EnvelopeRouting? {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
        let colon = UInt8(ascii: ":"), comma = UInt8(ascii: ",")
        let count = buf.count
        var index = 0

        func skipWhitespace() {
            while index < count, buf[index] == 0x20 || buf[index] == 0x09 || buf[index] == 0x0A || buf[index] == 0x0D {
                index += 1
            }
        }

        /// Offset of the next `byte` at or after `from`, via `memchr` — the envelope's one large
        /// value is ~100 KB of base64 that this has to step over, and a byte-at-a-time loop there
        /// costs more than everything else combined.
        func nextIndex(of byte: UInt8, from: Int) -> Int? {
            guard from < count, let base = buf.baseAddress else {
                return nil
            }
            guard let hit = memchr(base + from, Int32(byte), count - from) else {
                return nil
            }
            return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
        }

        /// `buf[index]` must be the opening quote. Leaves `index` just past the closing quote and
        /// returns the content range.
        ///
        /// Finding the real closing quote costs one `memchr` plus an O(1) look backwards: a quote
        /// is escaped exactly when an odd number of backslashes immediately precede it. That
        /// matters because the envelope's one large value is ~100 KB of base64 this has to step
        /// over, and a second forward search for backslashes would double the work.
        ///
        /// `escaped` reports whether the content holds any escape at all, which needs its own
        /// bounded search — so it is only computed when `wantEscaped` is set. Callers that merely
        /// skip a value do not care, and those are exactly the large ones.
        func scanString(wantEscaped: Bool) -> (range: Range<Int>, escaped: Bool)? {
            guard index < count, buf[index] == quote else {
                return nil
            }
            index += 1
            let start = index

            var searchFrom = index
            var end = 0
            while true {
                guard let closing = nextIndex(of: quote, from: searchFrom) else {
                    return nil
                }
                var runStart = closing
                while runStart > start, buf[runStart - 1] == backslash {
                    runStart -= 1
                }
                if (closing - runStart) % 2 != 0 {
                    // Odd run of backslashes: this quote is escaped and does not close the string.
                    searchFrom = closing + 1
                    continue
                }
                end = closing
                index = closing + 1
                break
            }

            var escaped = false
            if wantEscaped, let escape = nextIndex(of: backslash, from: start), escape < end {
                escaped = true
            }
            return (start..<end, escaped)
        }

        func skipValue() -> Bool {
            skipWhitespace()
            guard index < count else {
                return false
            }
            switch buf[index] {
            case quote:
                return scanString(wantEscaped: false) != nil
            case openBrace, openBracket:
                var depth = 0
                while index < count {
                    let byte = buf[index]
                    if byte == quote {
                        guard scanString(wantEscaped: false) != nil else {
                            return false
                        }
                        continue
                    }
                    if byte == openBrace || byte == openBracket {
                        depth += 1
                    } else if byte == closeBrace || byte == closeBracket {
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return true
                        }
                    }
                    index += 1
                }
                return false
            default:
                // Number, true, false, or null: runs until the next structural byte.
                while index < count, buf[index] != comma, buf[index] != closeBrace {
                    index += 1
                }
                return true
            }
        }

        func matches(_ range: Range<Int>, _ literal: StaticString) -> Bool {
            guard range.count == literal.utf8CodeUnitCount else {
                return false
            }
            let bytes = literal.utf8Start
            for offset in 0..<range.count where buf[range.lowerBound + offset] != bytes[offset] {
                return false
            }
            return true
        }

        skipWhitespace()
        guard index < count, buf[index] == openBrace else {
            return nil
        }
        index += 1

        var from: String?
        var to: String?
        while true {
            skipWhitespace()
            guard index < count else {
                return nil
            }
            if buf[index] == closeBrace {
                break
            }
            if buf[index] == comma {
                index += 1
                continue
            }
            guard let key = scanString(wantEscaped: true), !key.escaped else {
                return nil
            }
            skipWhitespace()
            guard index < count, buf[index] == colon else {
                return nil
            }
            index += 1

            let isFrom = matches(key.range, "from")
            let isTo = !isFrom && matches(key.range, "to")
            guard isFrom || isTo else {
                guard skipValue() else {
                    return nil
                }
                continue
            }

            skipWhitespace()
            guard index < count else {
                return nil
            }
            guard buf[index] == quote else {
                // `null` or an unexpected type: no hint, but the envelope is still well-formed.
                guard skipValue() else {
                    return nil
                }
                continue
            }
            guard let value = scanString(wantEscaped: true), !value.escaped else {
                return nil
            }
            let decoded = String(decoding: UnsafeBufferPointer(rebasing: buf[value.range]), as: UTF8.self)
            if isFrom {
                from = decoded
            } else {
                to = decoded
            }
        }

        return EnvelopeRouting(from: from, to: to)
    }
}

struct MessageHeader: Codable {
    let type: String
    let origin: String?
}

struct SyncMessage: Codable {
    let type: String
    let origin: String
    let kind: String?
    let text: String?
    let image: ClipboardImagePayload?
    let files: [ClipboardFilePayload]?
    let sentAt: TimeInterval
}

struct InputMessage: Codable {
    let type: String
    let origin: String
    let target: String?
    let kind: String
    let role: String?
    let deviceName: String?
    let deviceAddress: String?
    let screens: [ScreenMetrics]?
    let enabled: Bool?
    let controlDeviceId: String?
    let layout: [ScreenLayoutEntry]?
    let capture: InputCapturePayload?
    let mouse: InputMousePayload?
    let key: InputKeyPayload?
    let sentAt: TimeInterval
    let cursor: InputCursorPayload?
    let forwards: [PortForwardRule]?
    let forwardStatuses: [PortForwardStatus]?

    init(
        type: String,
        origin: String,
        target: String?,
        kind: String,
        role: String?,
        deviceName: String?,
        deviceAddress: String?,
        screens: [ScreenMetrics]?,
        enabled: Bool?,
        controlDeviceId: String?,
        layout: [ScreenLayoutEntry]?,
        capture: InputCapturePayload?,
        mouse: InputMousePayload?,
        key: InputKeyPayload?,
        sentAt: TimeInterval,
        cursor: InputCursorPayload? = nil,
        forwards: [PortForwardRule]? = nil,
        forwardStatuses: [PortForwardStatus]? = nil
    ) {
        self.type = type
        self.origin = origin
        self.target = target
        self.kind = kind
        self.role = role
        self.deviceName = deviceName
        self.deviceAddress = deviceAddress
        self.screens = screens
        self.enabled = enabled
        self.controlDeviceId = controlDeviceId
        self.layout = layout
        self.capture = capture
        self.mouse = mouse
        self.key = key
        self.sentAt = sentAt
        self.cursor = cursor
        self.forwards = forwards
        self.forwardStatuses = forwardStatuses
    }

    static func hello(
        origin: String,
        role: SyncMode,
        deviceName: String,
        deviceAddress: String?,
        screens: [ScreenMetrics],
        enabled: Bool,
        controlDeviceId: String?
    ) -> InputMessage {
        InputMessage(
            type: "input",
            origin: origin,
            target: nil,
            kind: "hello",
            role: role.rawValue,
            deviceName: deviceName,
            deviceAddress: deviceAddress,
            screens: screens,
            enabled: enabled,
            controlDeviceId: controlDeviceId,
            layout: nil,
            capture: nil,
            mouse: nil,
            key: nil,
            sentAt: Date().timeIntervalSince1970
        )
    }
}

/// Describes one physical monitor. `localX`/`localY` are that monitor's origin within its own
/// machine's local coordinate space (macOS: Quartz global coordinates), used to preserve each
/// machine's real monitor arrangement when first auto-placing its screens into the shared layout.
struct ScreenMetrics: Codable {
    let width: Double
    let height: Double
    let scale: Double
    let localX: Double
    let localY: Double
}

/// One physical monitor's rect in the shared layout canvas. `screenId` (`"<deviceId>#<index>"`)
/// identifies the individual monitor; `deviceId` is the machine that owns it — several entries
/// can share the same `deviceId` when that machine has more than one screen.
struct ScreenLayoutEntry: Codable, Equatable {
    var screenId: String
    var deviceId: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

final class ScreenLayoutStore {
    private(set) var entries: [String: ScreenLayoutEntry] = [:]
    private static let storageKey = "ClipboardSyncMac.screenLayout"

    init() {
        entries = Self.load()
    }

    /// Merges a device's current monitor list into the store: updates sizes for known screens
    /// (keeping any dragged position), places newly-seen screens next to their siblings (or to
    /// the right of everything, for a brand-new device) while preserving their real relative
    /// arrangement, and drops entries for monitors that disappeared (unplugged). Returns whether
    /// anything changed.
    @discardableResult
    func merge(deviceId: String, screens: [ScreenMetrics]) -> Bool {
        var changed = false

        let priorScreenIds = Set(entries.values.filter { $0.deviceId == deviceId }.map(\.screenId))
        let nextScreenIds = Set((0..<screens.count).map { "\(deviceId)#\($0)" })
        for staleId in priorScreenIds.subtracting(nextScreenIds) {
            entries.removeValue(forKey: staleId)
            changed = true
        }

        let isNewDevice = priorScreenIds.isEmpty
        let groupOffsetX = isNewDevice ? (entries.values.map { $0.x + $0.width }.max() ?? 0) : 0
        let localMinX = screens.map(\.localX).min() ?? 0
        let localMinY = screens.map(\.localY).min() ?? 0

        for (index, screen) in screens.enumerated() {
            let screenId = "\(deviceId)#\(index)"
            if let existing = entries[screenId] {
                guard existing.width != screen.width || existing.height != screen.height else {
                    continue
                }
                entries[screenId] = ScreenLayoutEntry(screenId: screenId, deviceId: deviceId, x: existing.x, y: existing.y, width: screen.width, height: screen.height)
                changed = true
                continue
            }

            let x: Double
            let y: Double
            if isNewDevice {
                x = groupOffsetX + (screen.localX - localMinX)
                y = screen.localY - localMinY
            } else if let sibling = entries.values.filter({ $0.deviceId == deviceId }).max(by: { $0.x < $1.x }) {
                x = sibling.x + sibling.width
                y = sibling.y
            } else {
                x = entries.values.map { $0.x + $0.width }.max() ?? 0
                y = 0
            }
            entries[screenId] = ScreenLayoutEntry(screenId: screenId, deviceId: deviceId, x: x, y: y, width: screen.width, height: screen.height)
            changed = true
        }

        if changed {
            save()
        }
        return changed
    }

    /// Drops every screen belonging to `deviceId` (e.g. once that device has been considered
    /// disconnected), so it stops showing in the Screen Layout window. Returns whether anything
    /// changed.
    @discardableResult
    func remove(deviceId: String) -> Bool {
        let staleIds = entries.values.filter { $0.deviceId == deviceId }.map(\.screenId)
        guard !staleIds.isEmpty else {
            return false
        }
        for screenId in staleIds {
            entries.removeValue(forKey: screenId)
        }
        save()
        return true
    }

    func applySnapshot(_ snapshot: [ScreenLayoutEntry]) {
        entries = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.screenId, $0) })
        save()
    }

    func applyPositionUpdates(_ updates: [ScreenLayoutEntry]) {
        for update in updates {
            guard let existing = entries[update.screenId] else {
                continue
            }
            entries[update.screenId] = ScreenLayoutEntry(screenId: update.screenId, deviceId: existing.deviceId, x: update.x, y: update.y, width: existing.width, height: existing.height)
        }
        save()
    }

    func snapshot() -> [ScreenLayoutEntry] {
        Array(entries.values)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot()) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [String: ScreenLayoutEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let list = try? JSONDecoder().decode([ScreenLayoutEntry].self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.screenId, $0) })
    }
}

/// One user-configured port forward: TCP connections accepted on `inDeviceId`:`inPort` are
/// tunneled over the sync connection and delivered to `outHost`:`outPort` on `outDeviceId`.
/// `inAllowLan` chooses the listen interface — loopback-only by default, or all interfaces
/// (`0.0.0.0`) so other machines on the LAN can reach the forwarded port. `outHost` defaults to
/// `127.0.0.1` (a service on the Out device itself) but may be any address the Out device can
/// reach, letting the Out device act as a gateway to a third host.
struct PortForwardRule: Codable, Equatable {
    var id: String
    var inDeviceId: String
    var inPort: Int
    var inAllowLan: Bool
    var outDeviceId: String
    var outHost: String
    var outPort: Int
    var note: String
    var enabled: Bool

    init(
        id: String,
        inDeviceId: String,
        inPort: Int,
        inAllowLan: Bool = false,
        outDeviceId: String,
        outHost: String = "127.0.0.1",
        outPort: Int,
        note: String,
        enabled: Bool
    ) {
        self.id = id
        self.inDeviceId = inDeviceId
        self.inPort = inPort
        self.inAllowLan = inAllowLan
        self.outDeviceId = outDeviceId
        self.outHost = outHost
        self.outPort = outPort
        self.note = note
        self.enabled = enabled
    }

    // Tolerant decoding so rules saved before `inAllowLan`/`outHost` existed still load with their
    // safe defaults (loopback listen, 127.0.0.1 destination) instead of failing the whole table.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        inDeviceId = try container.decode(String.self, forKey: .inDeviceId)
        inPort = try container.decode(Int.self, forKey: .inPort)
        inAllowLan = try container.decodeIfPresent(Bool.self, forKey: .inAllowLan) ?? false
        outDeviceId = try container.decode(String.self, forKey: .outDeviceId)
        outHost = try container.decodeIfPresent(String.self, forKey: .outHost) ?? "127.0.0.1"
        outPort = try container.decode(Int.self, forKey: .outPort)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Persists the shared port-forward rule table. Like the screen layout, the server's copy is
/// canonical: clients send edits as requests and apply whatever the server rebroadcasts.
final class PortForwardStore {
    private(set) var rules: [PortForwardRule] = []
    private static let storageKey = "ClipboardSyncMac.portForwards"

    init() {
        rules = Self.load()
    }

    func applySnapshot(_ snapshot: [PortForwardRule]) {
        rules = snapshot
        save()
    }

    func snapshot() -> [PortForwardRule] {
        rules
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [PortForwardRule] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let list = try? JSONDecoder().decode([PortForwardRule].self, from: data)
        else {
            return []
        }
        return list
    }
}

/// Live listen state of one rule, reported by whichever device is the rule's "In" side (the only
/// device that actually opens the listening socket). `ok` true means the port is bound and
/// listening; `ok` false means the bind failed and `reason` says why. Broadcast to peers so the
/// Port Forward panel can show an accurate status light for rules that listen on other machines.
struct PortForwardStatus: Codable, Equatable {
    let id: String
    let ok: Bool
    let reason: String?
}

/// One hop of tunneled TCP traffic. `open` asks `target` to dial `127.0.0.1:port`, `data` carries
/// a chunk of the stream in either direction, and `close` tears the connection down. All three
/// share `connectionId`, allocated by the listening side when it accepts a local TCP connection.
struct TunnelMessage: Codable {
    let type: String
    let origin: String
    let target: String
    let kind: String
    let connectionId: String
    let host: String?
    let port: Int?
    let dataBase64: String?
    let reason: String?
    let sentAt: TimeInterval
}

/// One file's metadata inside a transfer offer. `size` is the raw byte count on disk at offer
/// time; the sender re-checks it while streaming and aborts if the file changed underneath it.
struct FileTransferFileInfo: Codable, Equatable {
    let name: String
    let size: Int64
}

/// One step of a chunked, targeted file transfer. `offer` proposes a file list, `accept` opens the
/// transfer, `chunk` carries one piece of file data (acknowledged by the receiver with `ack` for
/// windowed backpressure), `fileDone` closes one file with its SHA-256, `done` is the receiver's
/// final confirmation, and `cancel` aborts in either direction. Both ends stream disk-to-disk, so
/// there is no whole-file buffering and no hard size limit. Like `tunnel` messages, `target`
/// filtering happens on the receiver: messages addressed to another device are ignored.
struct FileTransferMessage: Codable {
    let type: String
    let origin: String
    let target: String
    let kind: String
    let transferId: String
    let files: [FileTransferFileInfo]?
    let fileIndex: Int?
    let chunkIndex: Int?
    let dataBase64: String?
    let sha256: String?
    let reason: String?
    let sentAt: TimeInterval
}

struct InputCapturePayload: Codable {
    let action: String
    let edge: String
    let screenId: String
    let normalizedX: Double
    let normalizedY: Double
}

/// Reports where a machine's own real cursor currently sits, for peers to render a "fake mouse"
/// dot on that machine's screens in the Screen Layout window. Broadcast (not targeted) only while
/// the sender's own Screen Layout window is open.
struct InputCursorPayload: Codable {
    let screenId: String
    let normalizedX: Double
    let normalizedY: Double
}

struct InputMousePayload: Codable {
    let action: String
    let button: String?
    let normalizedX: Double?
    let normalizedY: Double?
    let deltaX: Double?
    let deltaY: Double?
}

struct InputKeyPayload: Codable {
    let action: String
    let key: String
    let modifiers: [String]
}

struct ClipboardImagePayload: Codable, Equatable {
    let mimeType: String
    let fileName: String
    let dataBase64: String
    let size: Int
}

struct ClipboardFilePayload: Codable, Equatable {
    let name: String
    let dataBase64: String
    let size: Int
}

enum ClipboardContent: Equatable {
    case text(String)
    case image(ClipboardImagePayload)
    case files([ClipboardFilePayload])

    var kind: String {
        switch self {
        case .text:
            return "text"
        case .image:
            return "image"
        case .files:
            return "files"
        }
    }

    var signature: String {
        switch self {
        case .text(let text):
            return "text:\(text)"
        case .image(let image):
            return "image:\(image.dataBase64)"
        case .files(let files):
            return "files:\(files.map { "\($0.name):\($0.size):\($0.dataBase64)" }.joined(separator: "|"))"
        }
    }

    var historyTitle: String {
        switch self {
        case .text(let text):
            let compact = text.replacingOccurrences(of: "\n", with: " ")
            let preview = String(compact.prefix(42))
            return preview.isEmpty
                ? AppText.text("history.text")
                : AppText.format("history.textWithPreview", preview)
        case .image(let image):
            let size = ByteCountFormatter.string(fromByteCount: Int64(image.size), countStyle: .file)
            return AppText.format("history.image", size)
        case .files(let files):
            let names = files.prefix(2).map(\.name).joined(separator: ", ")
            let suffix = files.count > 2 ? " +\(files.count - 2)" : ""
            return AppText.format("history.files", names, suffix)
        }
    }

    func makeMessage(origin: String) -> SyncMessage {
        switch self {
        case .text(let text):
            return SyncMessage(
                type: "clipboard",
                origin: origin,
                kind: kind,
                text: text,
                image: nil,
                files: nil,
                sentAt: Date().timeIntervalSince1970
            )
        case .image(let image):
            return SyncMessage(
                type: "clipboard",
                origin: origin,
                kind: kind,
                text: nil,
                image: image,
                files: nil,
                sentAt: Date().timeIntervalSince1970
            )
        case .files(let files):
            return SyncMessage(
                type: "clipboard",
                origin: origin,
                kind: kind,
                text: nil,
                image: nil,
                files: files,
                sentAt: Date().timeIntervalSince1970
            )
        }
    }
}

extension SyncMessage {
    func clipboardContent() -> ClipboardContent? {
        let resolvedKind = kind ?? (text == nil ? nil : "text")
        switch resolvedKind {
        case "text":
            guard let text else {
                return nil
            }
            return .text(text)
        case "image":
            guard let image else {
                return nil
            }
            return .image(image)
        case "files":
            guard let files, !files.isEmpty else {
                return nil
            }
            return .files(files)
        default:
            return nil
        }
    }
}

struct ClipboardHistoryEntry {
    let id: UUID
    let content: ClipboardContent
    let createdAt: Date
}

enum DeviceIdentity {
    private static let storageKey = "ClipboardSyncMac.deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: storageKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: storageKey)
        return created
    }

    static var displayName: String {
        Host.current().localizedName ?? Host.current().name ?? ProcessInfo.processInfo.hostName
    }

    static var address: String? {
        NetworkAddress.localLANIPv4Address()
    }
}
