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
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "Status: %@",
            "status.stopped": "stopped",
            "status.copyFilesFirst": "copy files first",
            "status.fileTransferStarted": "file transfer started",
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
            "menu.enableInputSharing": "Enable Input Sharing",
            "menu.controlDevice": "Control Device",
            "menu.controlDeviceWithTitle": "Control Device: %@",
            "menu.screenLayout": "Screen Layout...",
            "menu.clientMode": "Client mode",
            "menu.serverMode": "Server mode",
            "menu.settings": "Settings...",
            "menu.checkForUpdates": "Check for Updates...",
            "menu.start": "Start",
            "menu.restart": "Restart",
            "menu.stop": "Stop",
            "menu.about": "About Clipboard Sync",
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
            "settings.mode": "Mode",
            "settings.host": "Host",
            "settings.port": "Port",
            "settings.password": "Password",
            "settings.input": "Input",
            "layout.title": "Screen Layout",
            "layout.subtitle": "Drag each screen to match how your machines sit relative to each other.",
            "layout.done": "Done",
            "layout.disconnected": "Disconnected",
            "layout.forgetDevice": "Forget This Device",
            "settings.scroll": "Scroll",
            "settings.modifierKeys": "Keys",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "Client",
            "settings.server": "Server",
            "settings.enableInputSharing": "Enable Input Sharing",
            "settings.reverseVerticalScroll": "Reverse Vertical Scroll",
            "settings.save": "Save",
            "settings.cancel": "Cancel",
            "settings.hostDefaultHint": "Used only in client mode.",
            "settings.hostClientHint": "Enter the LAN IP shown on the server Mac.",
            "settings.hostServerHint": "Share this address with clients on the same LAN.",
            "settings.passwordPlaceholder": "Required on every device",
            "settings.validationHost": "Enter a server host for client mode.",
            "settings.validationLoopback": "Use the server Mac's LAN IP, not 127.0.0.1.",
            "settings.validationPort": "Port must be a number from 1 to 65535.",
            "settings.validationPassword": "Enter the same sync password on every device.",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command"
        ],
        .chinese: [
            "app.name": "剪贴板同步",
            "app.shortName": "剪贴板",
            "state.enabled": "已启用",
            "state.disabled": "已禁用",
            "state.unknown": "未知",
            "device.unknown": "未知设备",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "状态：%@",
            "status.stopped": "已停止",
            "status.copyFilesFirst": "请先复制文件",
            "status.fileTransferStarted": "文件传输已开始",
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
            "menu.enableInputSharing": "启用输入共享",
            "menu.controlDevice": "控制设备",
            "menu.controlDeviceWithTitle": "控制设备：%@",
            "menu.screenLayout": "屏幕布局...",
            "menu.clientMode": "客户端模式",
            "menu.serverMode": "服务器模式",
            "menu.settings": "设置...",
            "menu.checkForUpdates": "检查更新...",
            "menu.start": "启动",
            "menu.restart": "重启",
            "menu.stop": "停止",
            "menu.about": "关于剪贴板同步",
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
            "settings.mode": "模式",
            "settings.host": "主机",
            "settings.port": "端口",
            "settings.password": "密码",
            "settings.input": "输入",
            "layout.title": "屏幕布局",
            "layout.subtitle": "拖动每个屏幕以匹配设备之间的实际摆放位置。",
            "layout.done": "完成",
            "layout.disconnected": "已断开",
            "layout.forgetDevice": "忘记此设备",
            "settings.scroll": "滚动",
            "settings.modifierKeys": "按键",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "客户端",
            "settings.server": "服务器",
            "settings.enableInputSharing": "启用输入共享",
            "settings.reverseVerticalScroll": "反转垂直滚动",
            "settings.save": "保存",
            "settings.cancel": "取消",
            "settings.hostDefaultHint": "仅在客户端模式下使用。",
            "settings.hostClientHint": "输入服务器 Mac 显示的局域网 IP。",
            "settings.hostServerHint": "将此地址分享给同一局域网内的客户端。",
            "settings.passwordPlaceholder": "每台设备都需要一致",
            "settings.validationHost": "请输入客户端模式的服务器主机。",
            "settings.validationLoopback": "请使用服务器 Mac 的局域网 IP，不要用 127.0.0.1。",
            "settings.validationPort": "端口必须是 1 到 65535 之间的数字。",
            "settings.validationPassword": "请在每台设备上输入相同的同步密码。",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command"
        ],
        .korean: [
            "app.name": "클립보드 동기화",
            "app.shortName": "클립",
            "state.enabled": "활성",
            "state.disabled": "비활성",
            "state.unknown": "알 수 없음",
            "device.unknown": "알 수 없는 장치",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "상태: %@",
            "status.stopped": "중지됨",
            "status.copyFilesFirst": "먼저 파일을 복사하세요",
            "status.fileTransferStarted": "파일 전송 시작됨",
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
            "menu.enableInputSharing": "입력 공유 활성화",
            "menu.controlDevice": "제어 장치",
            "menu.controlDeviceWithTitle": "제어 장치: %@",
            "menu.screenLayout": "화면 레이아웃...",
            "menu.clientMode": "클라이언트 모드",
            "menu.serverMode": "서버 모드",
            "menu.settings": "설정...",
            "menu.checkForUpdates": "업데이트 확인...",
            "menu.start": "시작",
            "menu.restart": "다시 시작",
            "menu.stop": "중지",
            "menu.about": "Clipboard Sync 정보",
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
            "settings.mode": "모드",
            "settings.host": "호스트",
            "settings.port": "포트",
            "settings.password": "암호",
            "settings.input": "입력",
            "layout.title": "화면 레이아웃",
            "layout.subtitle": "기기들의 실제 배치에 맞게 각 화면을 드래그하세요.",
            "layout.done": "완료",
            "layout.disconnected": "연결 끊김",
            "layout.forgetDevice": "이 기기 잊기",
            "settings.scroll": "스크롤",
            "settings.modifierKeys": "키",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "클라이언트",
            "settings.server": "서버",
            "settings.enableInputSharing": "입력 공유 활성화",
            "settings.reverseVerticalScroll": "세로 스크롤 반전",
            "settings.save": "저장",
            "settings.cancel": "취소",
            "settings.hostDefaultHint": "클라이언트 모드에서만 사용됩니다.",
            "settings.hostClientHint": "서버 Mac에 표시된 LAN IP를 입력하세요.",
            "settings.hostServerHint": "같은 LAN의 클라이언트와 이 주소를 공유하세요.",
            "settings.passwordPlaceholder": "모든 장치에서 필요",
            "settings.validationHost": "클라이언트 모드의 서버 호스트를 입력하세요.",
            "settings.validationLoopback": "127.0.0.1이 아닌 서버 Mac의 LAN IP를 사용하세요.",
            "settings.validationPort": "포트는 1에서 65535 사이의 숫자여야 합니다.",
            "settings.validationPassword": "모든 장치에 동일한 동기화 암호를 입력하세요.",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command"
        ],
        .japanese: [
            "app.name": "クリップボード同期",
            "app.shortName": "クリップ",
            "state.enabled": "有効",
            "state.disabled": "無効",
            "state.unknown": "不明",
            "device.unknown": "不明なデバイス",
            "device.titleStatus": "%@ [%@]",
            "status.prefix": "状態: %@",
            "status.stopped": "停止中",
            "status.copyFilesFirst": "先にファイルをコピーしてください",
            "status.fileTransferStarted": "ファイル転送を開始しました",
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
            "menu.enableInputSharing": "入力共有を有効化",
            "menu.controlDevice": "制御デバイス",
            "menu.controlDeviceWithTitle": "制御デバイス: %@",
            "menu.screenLayout": "画面レイアウト...",
            "menu.clientMode": "クライアントモード",
            "menu.serverMode": "サーバーモード",
            "menu.settings": "設定...",
            "menu.checkForUpdates": "アップデートを確認...",
            "menu.start": "開始",
            "menu.restart": "再起動",
            "menu.stop": "停止",
            "menu.about": "Clipboard Sync について",
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
            "settings.mode": "モード",
            "settings.host": "ホスト",
            "settings.port": "ポート",
            "settings.password": "パスワード",
            "settings.input": "入力",
            "layout.title": "画面レイアウト",
            "layout.subtitle": "実際の配置に合わせて各画面をドラッグしてください。",
            "layout.done": "完了",
            "layout.disconnected": "切断済み",
            "layout.forgetDevice": "このデバイスを削除",
            "settings.scroll": "スクロール",
            "settings.modifierKeys": "キー",
            "settings.mapShift": "Shift",
            "settings.mapControl": "Control",
            "settings.mapAlt": "Alt",
            "settings.mapMeta": "Win/Mac",
            "settings.client": "クライアント",
            "settings.server": "サーバー",
            "settings.enableInputSharing": "入力共有を有効化",
            "settings.reverseVerticalScroll": "垂直スクロールを反転",
            "settings.save": "保存",
            "settings.cancel": "キャンセル",
            "settings.hostDefaultHint": "クライアントモードでのみ使用します。",
            "settings.hostClientHint": "サーバー Mac に表示された LAN IP を入力してください。",
            "settings.hostServerHint": "同じ LAN のクライアントにこのアドレスを共有してください。",
            "settings.passwordPlaceholder": "すべてのデバイスで必要",
            "settings.validationHost": "クライアントモードのサーバーホストを入力してください。",
            "settings.validationLoopback": "127.0.0.1 ではなくサーバー Mac の LAN IP を使用してください。",
            "settings.validationPort": "ポートは 1 から 65535 の数字である必要があります。",
            "settings.validationPassword": "すべてのデバイスで同じ同期パスワードを入力してください。",
            "modifier.shift": "Shift",
            "modifier.control": "Control",
            "modifier.alt": "Alt/Option",
            "modifier.meta": "Win/Command"
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
    var inputSharingEnabled: Bool
    var controlDeviceId: String?
    var reverseMouseVerticalScroll: Bool
    var keyboardModifierMap: KeyboardModifierMap

    static let defaults = AppConfig(
        mode: .client,
        host: "",
        port: 8787,
        password: "",
        inputSharingEnabled: false,
        controlDeviceId: nil,
        reverseMouseVerticalScroll: false,
        keyboardModifierMap: .identity
    )
    private static let storageKey = "ClipboardSyncMac.config"

    init(
        mode: SyncMode,
        host: String,
        port: Int,
        password: String,
        inputSharingEnabled: Bool,
        controlDeviceId: String?,
        reverseMouseVerticalScroll: Bool,
        keyboardModifierMap: KeyboardModifierMap = .identity
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.password = password
        self.inputSharingEnabled = inputSharingEnabled
        self.controlDeviceId = controlDeviceId
        self.reverseMouseVerticalScroll = reverseMouseVerticalScroll
        self.keyboardModifierMap = keyboardModifierMap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(SyncMode.self, forKey: .mode) ?? Self.defaults.mode
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? Self.defaults.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaults.port
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? Self.defaults.password
        inputSharingEnabled = try container.decodeIfPresent(Bool.self, forKey: .inputSharingEnabled) ?? Self.defaults.inputSharingEnabled
        controlDeviceId = try container.decodeIfPresent(String.self, forKey: .controlDeviceId) ?? Self.defaults.controlDeviceId
        reverseMouseVerticalScroll = try container.decodeIfPresent(Bool.self, forKey: .reverseMouseVerticalScroll) ?? Self.defaults.reverseMouseVerticalScroll
        keyboardModifierMap = try container.decodeIfPresent(KeyboardModifierMap.self, forKey: .keyboardModifierMap) ?? Self.defaults.keyboardModifierMap
    }

    static func load() -> AppConfig {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return defaults
        }
        return config.normalized()
    }

    func save() {
        if let data = try? JSONEncoder().encode(normalized()) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func normalized() -> AppConfig {
        AppConfig(
            mode: mode,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(port, 1), 65_535),
            password: password,
            inputSharingEnabled: inputSharingEnabled,
            controlDeviceId: controlDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
            reverseMouseVerticalScroll: reverseMouseVerticalScroll,
            keyboardModifierMap: keyboardModifierMap
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
        cursor: InputCursorPayload? = nil
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
