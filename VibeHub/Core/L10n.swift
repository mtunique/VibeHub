//
//  L10n.swift
//  VibeHub
//
//  Lightweight localization helper – returns Chinese (zh) or English
//  strings based on the user's preferred system language.
//

import Foundation

enum L10n {
    /// `true` when the user's first preferred language is Chinese.
    static let isChinese: Bool = {
        guard let lang = Locale.preferredLanguages.first else { return false }
        return lang.hasPrefix("zh")
    }()

    // MARK: - Generic / Shared

    static var back: String { isChinese ? "返回" : "Back" }
    static var on: String { isChinese ? "开" : "On" }
    static var off: String { isChinese ? "关" : "Off" }
    static var enable: String { isChinese ? "启用" : "Enable" }
    static var quit: String { isChinese ? "退出" : "Quit" }
    static var add: String { isChinese ? "添加" : "Add" }
    static var search: String { isChinese ? "搜索" : "Search" }
    static var retry: String { isChinese ? "重试" : "Retry" }
    static var next: String { isChinese ? "下一步" : "Next" }
    static var deny: String { isChinese ? "拒绝" : "Deny" }
    static var always: String { isChinese ? "始终允许" : "Always" }
    static var allow: String { isChinese ? "允许" : "Allow" }
    static var terminal: String { isChinese ? "终端" : "Terminal" }

    // MARK: - Menu (NotchMenuView)

    static var expandOnCompletion: String { isChinese ? "完成时展开" : "Expand on Completion" }
    static var notifyCompletion: String { isChinese ? "完成通知" : "Completion" }
    static var notifyApproval: String { isChinese ? "审批弹出" : "Approval" }
    static var notifyNever: String { isChinese ? "关闭" : "Off" }
    static var notifyBackgroundOnly: String { isChinese ? "后台" : "BG" }
    static var notifyAlways: String { isChinese ? "始终" : "Always" }
    static var notificationsHeader: String { isChinese ? "通知" : "Notifications" }
    static var displayModeLabel: String { isChinese ? "显示模式" : "Display Mode" }
    static var displayModeAuto: String { isChinese ? "自动" : "Auto" }
    static var displayModeNotch: String { isChinese ? "灵动岛" : "Dynamic Island" }
    static var displayModeMenuBar: String { isChinese ? "菜单栏" : "Menu Bar" }
    static var menuBarShowDetail: String { isChinese ? "菜单栏显示详情" : "Show Detail in Menu Bar" }

    // Onboarding
    static var onboardingTitle: String { isChinese ? "选择显示模式" : "Choose Display Mode" }
    static var onboardingSubtitle: String { isChinese ? "你可以随时在设置中更改" : "You can change this later in Settings" }
    static var onboardingAutoTitle: String { isChinese ? "自动" : "Auto" }
    static var onboardingAutoDesc: String { isChinese ? "根据物理屏幕自动选择最佳模式" : "Automatically picks the best mode for your screen" }
    static var onboardingNotchTitle: String { isChinese ? "灵动岛模式" : "Dynamic Island" }
    static var onboardingNotchDesc: String { isChinese ? "在屏幕顶部刘海区域显示，沉浸感更强" : "Shows in the notch area at the top of the screen" }
    static var onboardingMenuBarTitle: String { isChinese ? "菜单栏模式" : "Menu Bar" }
    static var onboardingMenuBarDesc: String { isChinese ? "在菜单栏显示图标，点击弹出面板" : "Shows an icon in the menu bar with a popover panel" }
    static var onboardingShowDetail: String { isChinese ? "在菜单栏显示会话详情" : "Show session details in menu bar" }
    static var onboardingGetStarted: String { isChinese ? "开始使用" : "Get Started" }
    static var settingsTitle: String { isChinese ? "设置" : "Settings" }
    static var settingsAppearance: String { isChinese ? "外观" : "Appearance" }
    static var settingsNotifications: String { isChinese ? "通知" : "Notifications" }
    static var settingsSystem: String { isChinese ? "系统" : "System" }
    static var settingsAbout: String { isChinese ? "关于" : "About" }
    static var remote: String { isChinese ? "远程" : "Remote" }
    static var settingsRemoteHint: String { isChinese ? "在菜单中管理远程主机连接" : "Manage remote host connections from the menu" }
    static var launchAtLogin: String { isChinese ? "开机启动" : "Launch at Login" }
    static var hooks: String { isChinese ? "Hook 脚本" : "Hooks" }
    static var starOnGitHub: String { isChinese ? "在 GitHub 上点星" : "Star on GitHub" }
    static var accessibility: String { isChinese ? "辅助功能" : "Accessibility" }
    static var notificationSound: String { isChinese ? "通知音" : "Notification Sound" }
    static var screen: String { isChinese ? "屏幕" : "Screen" }

    static var version: String { isChinese ? "版本" : "Version" }

    // MARK: - Update Row

    static var checkForUpdates: String { isChinese ? "检查更新" : "Check for Updates" }
    static var checking: String { isChinese ? "检查中…" : "Checking..." }
    static var upToDate: String { isChinese ? "已是最新" : "Up to date" }
    static var downloadUpdate: String { isChinese ? "下载更新" : "Download Update" }
    static var downloading: String { isChinese ? "下载中…" : "Downloading..." }
    static var extracting: String { isChinese ? "解压中…" : "Extracting..." }
    static var installAndRelaunch: String { isChinese ? "安装并重启" : "Install & Relaunch" }
    static var installing: String { isChinese ? "安装中…" : "Installing..." }
    static var updateFailed: String { isChinese ? "更新失败" : "Update failed" }

    // MARK: - Chat View

    static var loadingMessages: String { isChinese ? "正在加载消息…" : "Loading messages..." }
    static var noMessagesYet: String { isChinese ? "暂无消息" : "No messages yet" }
    static var messageClaude: String { isChinese ? "给 Claude 发消息…" : "Message Claude..." }
    static var messageOpenCode: String { isChinese ? "给 OpenCode 发消息…" : "Message OpenCode..." }
    static var noTTYAvailable: String { isChinese ? "该会话无可用 TTY" : "No TTY available for this session" }
    static var remoteSendFailed: String { isChinese ? "远程发送失败" : "Remote send failed" }
    static var copiedPasteInTerminal: String { isChinese ? "已复制，请在终端粘贴" : "Copied. Paste in terminal" }
    static func copied(hint: String) -> String { isChinese ? "已复制 (\(hint))" : "Copied (\(hint))" }
    static var processing: String { isChinese ? "处理中" : "Processing" }
    static var working: String { isChinese ? "工作中" : "Working" }
    static var interrupted: String { isChinese ? "已中断" : "Interrupted" }
    static var claudeCodeNeedsInput: String { isChinese ? "Claude Code 需要你的输入" : "Claude Code needs your input" }
    static var typeAnswer: String { isChinese ? "输入回答…" : "Type your answer…" }
    static var submit: String { isChinese ? "提交" : "Submit" }

    static func newMessages(_ count: Int) -> String {
        if isChinese {
            return "\(count) 条新消息"
        }
        return count == 1 ? "1 new message" : "\(count) new messages"
    }

    // MARK: - Tool View

    static func runningAgent(description: String, toolCount: Int) -> String {
        if isChinese {
            return "\(description) (\(toolCount) 个工具)"
        }
        return "\(description) (\(toolCount) tools)"
    }

    static func moreToolUses(_ count: Int) -> String {
        if isChinese {
            return "+\(count) 个更多工具调用"
        }
        return "+\(count) more tool uses"
    }

    static func subagentUsedTools(_ count: Int) -> String {
        if isChinese {
            return "子代理使用了 \(count) 个工具："
        }
        return "Subagent used \(count) tools:"
    }

    // MARK: - Instances View

    static var noSessions: String { isChinese ? "暂无会话" : "No sessions" }
    static var runClaudeInTerminal: String { isChinese ? "在终端运行 claude" : "Run claude in terminal" }
    static var needsYourInput: String { isChinese ? "需要你的输入" : "Needs your input" }
    static var you: String { isChinese ? "你：" : "You:" }
    static var goToTerminal: String { isChinese ? "前往终端" : "Go to Terminal" }

    // MARK: - Remote Hosts View

    static var remoteHosts: String { isChinese ? "远程主机" : "Remote Hosts" }
    static var noRemoteHostsYet: String { isChinese ? "暂无远程主机" : "No remote hosts yet" }
    static var addOrImportSSH: String { isChinese ? "在下方添加或从 ~/.ssh/config 导入" : "Add one below or import from ~/.ssh/config" }
    static var installOK: String { isChinese ? "安装成功" : "Install OK" }
    static var installNeedsAttention: String { isChinese ? "安装需要关注" : "Install needs attention" }
    static var installNotStarted: String { isChinese ? "未开始安装" : "Install not started" }
    static var installingRemoteHooks: String { isChinese ? "正在安装远程钩子/插件…" : "Installing remote hooks/plugins..." }
    static var installLog: String { isChinese ? "安装日志" : "Install log" }
    static var ok: String { "ok" } // keep technical
    static var fail: String { "fail" } // keep technical
    static var importFromSSHConfig: String { isChinese ? "从 SSH 配置导入" : "Import from SSH config" }
    static var name: String { isChinese ? "名称" : "Name" }
    static var userAtHost: String { "user@host" } // universal
    static var port: String { isChinese ? "端口" : "Port" }
    static var identityFileOptional: String { isChinese ? "密钥文件（可选）" : "Identity file (optional)" }
    static var sshConfig: String { "~/.ssh/config" } // path, no translation
    static var noEntriesFound: String { isChinese ? "未找到条目" : "No entries found" }
    static var noMatches: String { isChinese ? "无匹配" : "No matches" }
    static var connect: String { isChinese ? "连接" : "Connect" }
    static var connecting: String { isChinese ? "连接中…" : "Connecting..." }
    static var disconnect: String { isChinese ? "断开" : "Disconnect" }
    static var disconnected: String { isChinese ? "已断开" : "Disconnected" }
    static var connectingStatus: String { isChinese ? "连接中" : "Connecting" }
    static var connected: String { isChinese ? "已连接" : "Connected" }
    static var failed: String { isChinese ? "失败" : "Failed" }
    static var noUser: String { isChinese ? "（无用户）" : "(no user)" }
    static var defaultPort: String { isChinese ? "（默认）" : "(default)" }
    static var sshConfigSuffix: String { "(ssh config)" }

    // MARK: - Session Phase Helpers

    static func waitingForApproval(tool: String) -> String {
        isChinese ? "等待审批：\(tool)" : "Waiting for approval: \(tool)"
    }
    static var readyForInput: String { isChinese ? "等待输入" : "Ready for input" }
    static var processingEllipsis: String { isChinese ? "处理中…" : "Processing..." }
    static var compactingContext: String { isChinese ? "压缩上下文…" : "Compacting context..." }
    static var idle: String { isChinese ? "空闲" : "Idle" }
    static var ended: String { isChinese ? "已结束" : "Ended" }
    static var now: String { isChinese ? "刚刚" : "now" }

    // MARK: - Screen Picker

    static var automatic: String { isChinese ? "自动" : "Automatic" }
    static var builtInOrMain: String { isChinese ? "内建或主屏幕" : "Built-in or Main" }
    static var auto_: String { isChinese ? "自动" : "Auto" }
    static var builtIn: String { isChinese ? "内建" : "Built-in" }
    static var main: String { isChinese ? "主屏幕" : "Main" }

    // MARK: - Welcome / Onboarding

    static var welcomeTitle: String { isChinese ? "欢迎使用 Vibe Hub" : "Welcome to Vibe Hub" }
    static var welcomeSubtitle: String {
        isChinese
            ? "Vibe Hub 通过 Hook 脚本监听 Claude Code 和 OpenCode 的会话状态，在屏幕顶部实时显示。"
            : "Vibe Hub monitors Claude Code and OpenCode sessions via hook scripts and shows real-time status at the top of your screen."
    }
    static var welcomeInstallStep: String {
        isChinese
            ? "点击下方按钮，选择你的 Home 文件夹以授权安装 Hook 脚本。"
            : "Tap the button below and select your Home folder to grant access for installing hook scripts."
    }
    static var welcomeInstallButton: String { isChinese ? "安装 Hook 脚本" : "Install Hooks" }
    static var welcomeSkipButton: String { isChinese ? "稍后再说" : "Later" }
    static var welcomeInstallingButton: String { isChinese ? "安装中…" : "Installing..." }

    // MARK: - License

    static var license: String { isChinese ? "许可证" : "License" }
    static var licenseActivated: String { isChinese ? "已激活" : "Activated" }
    static var licenseLocked: String { isChinese ? "需要激活" : "Activation Required" }
    static var licenseLockedTitle: String { isChinese ? "VibeHub 需要许可证" : "VibeHub Requires a License" }
    static var licenseLockedSubtitle: String { isChinese ? "请输入许可证密钥以继续使用" : "Enter your license key to continue" }
    static var licenseKeyPlaceholder: String { isChinese ? "许可证密钥" : "License key" }
    static var licenseActivate: String { isChinese ? "激活" : "Activate" }
    static var licensePurchase: String { isChinese ? "购买" : "Purchase" }
    static var licenseActivating: String { isChinese ? "激活中…" : "Activating..." }
    static var licenseManage: String { isChinese ? "管理许可证" : "Manage License" }
    static var licenseDeactivateDevice: String { isChinese ? "取消激活此设备" : "Deactivate This Device" }
    static var licenseKeyInvalid: String { isChinese ? "许可证密钥无效，请检查后重试" : "Invalid license key. Please check and try again." }
    static var licenseDeviceLimit: String { isChinese ? "已达到设备数量上限，请在其他设备上取消激活" : "Device limit reached. Deactivate another device first." }
    static var licenseKeyRevoked: String { isChinese ? "此许可证已被撤销，请联系支持" : "This license has been revoked. Contact support." }
    static var licenseNetworkError: String { isChinese ? "无法连接验证服务器，请检查网络" : "Cannot reach license server. Check your network." }
    static func licenseDeviceCount(_ current: Int, _ limit: Int) -> String {
        isChinese ? "已激活（最多 \(limit) 台）" : "Activated (up to \(limit) devices)"
    }
    static var trialActive: String { isChinese ? "试用中" : "Trial" }
    static var trialExpiredTitle: String { isChinese ? "试用期已结束" : "Trial Expired" }
    static var trialExpiredSubtitle: String { isChinese ? "请购买许可证以继续使用" : "Purchase a license to continue" }
    static func trialTimeRemaining(hours: Int) -> String {
        if hours >= 24 {
            let days = hours / 24
            return isChinese ? "剩余 \(days) 天" : "\(days) day\(days == 1 ? "" : "s") left"
        } else {
            return isChinese ? "剩余 \(hours) 小时" : "\(hours)h left"
        }
    }
}
